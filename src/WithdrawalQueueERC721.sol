// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Enumerable, ERC721} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IUSDat} from "./interfaces/IUSDat.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";
import {IStakedUSDat} from "./interfaces/IStakedUSDat.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title WithdrawalQueueNFT
/// @notice NFT-based FIFO withdrawal queue where each request is an ERC721 token
/// @dev Each withdrawal request mints an NFT to the user, which is burned on claim
contract WithdrawalQueueERC721 is ERC721Enumerable, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The lifecycle status of a withdrawal request
    enum RequestStatus {
        Requested, // Request created, waiting to be processed
        Processed, // Processed by admin, USDat allocated, ready to claim
        Claimed // User has claimed their USDat (NFT burned)
    }

    struct Request {
        uint256 strcAmount;
        uint256 usdatOwed;
        uint256 timestamp;
        RequestStatus status;
    }

    // Roles
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    // Tokens
    IERC20 public immutable TSTRC;
    IUSDat public immutable USDAT;
    IStakedUSDat public stakedUSDat;

    // Queue state
    mapping(uint256 tokenId => Request) public requests;
    uint256 public nextTokenId;
    uint256 public nextToProcess;

    // Constants
    uint256 public constant MAX_TOLERANCE = 5000; // 50% in basis points

    // Errors
    error ZeroAmount();
    error NoRequestsToProcess();
    error AlreadyProcessed();
    error NothingToClaim();
    error NotOwner();
    error NotBlacklisted();
    error InvalidRequestOrder();
    error InvalidInputs();
    error ToleranceExceeded();
    error InvalidTolerance();
    error RequestNotProcessed();
    error AddressBlacklisted();
    error StakedUSDatNotSet();
    error StakedUSDatAlreadySet();

    // Events
    event WithdrawalRequested(uint256 indexed tokenId, address indexed user, uint256 strcAmount, uint256 timestamp);
    event WithdrawalProcessed(uint256 indexed tokenId, uint256 strcAmount, uint256 usdatAmount);
    event Claimed(uint256 indexed tokenId, address indexed user, uint256 usdatAmount);
    event FundsSeized(uint256 indexed tokenId, address indexed user, uint256 usdatAmount, address indexed to);

    constructor(address tstrc, address usdat, address admin) ERC721("Saturn Withdrawal Request", "sWR") {
        TSTRC = IERC20(tstrc);
        USDAT = IUSDat(usdat);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Set the StakedUSDat contract address (can only be set once)
    /// @dev Also grants STAKED_USDAT_ROLE to the contract
    /// @param _stakedUSDat The StakedUSDat contract address
    function setStakedUSDat(address _stakedUSDat) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(stakedUSDat) == address(0), StakedUSDatAlreadySet());
        require(_stakedUSDat != address(0), ZeroAmount());
        stakedUSDat = IStakedUSDat(_stakedUSDat);
        _grantRole(STAKED_USDAT_ROLE, _stakedUSDat);
    }

    function _requireNotBlacklisted(address account) internal view {
        require(!stakedUSDat.isBlacklisted(account), AddressBlacklisted());
    }

    // ============ Request Creation ============

    /// @notice Called by StakedUSDat to add a withdrawal request
    /// @dev Mints an NFT to the user representing their withdrawal request
    /// @param user The user requesting withdrawal
    /// @param strcAmount The amount of tSTRC owed to the user
    /// @return tokenId The NFT token ID (same as request ID)
    function addRequest(address user, uint256 strcAmount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(STAKED_USDAT_ROLE)
        returns (uint256 tokenId)
    {
        require(strcAmount != 0, ZeroAmount());

        tokenId = nextTokenId++;

        requests[tokenId] = Request({
            strcAmount: strcAmount, usdatOwed: 0, timestamp: block.timestamp, status: RequestStatus.Requested
        });

        _mint(user, tokenId);

        emit WithdrawalRequested(tokenId, user, strcAmount, block.timestamp);
    }

    // ============ Processing ============

    /// @notice Process the next batch of withdrawal requests
    /// @param tokenIds Array of token IDs to process (must match expected FIFO order)
    /// @param usdatAmounts Array of USDat amounts corresponding to each request
    /// @param vwapExecutionPrice Current STRC price (8 decimals)
    /// @param toleranceBps Tolerance in basis points (e.g., 1000 = 10%)
    function processNext(
        uint256[] calldata tokenIds,
        uint256[] calldata usdatAmounts,
        uint256 vwapExecutionPrice,
        uint256 toleranceBps
    ) external nonReentrant onlyRole(PROCESSOR_ROLE) {
        uint256 count = usdatAmounts.length;
        require(count > 0 && count == tokenIds.length, InvalidInputs());
        require(nextToProcess + count <= nextTokenId, NoRequestsToProcess());
        require(toleranceBps <= MAX_TOLERANCE, InvalidTolerance());

        uint256 totalUsdat = 0;
        uint256 totalStrc = 0;

        for (uint256 i = 0; i < count; i++) {
            require(tokenIds[i] == nextToProcess + i, InvalidRequestOrder());

            Request storage req = requests[tokenIds[i]];
            require(req.status == RequestStatus.Requested, AlreadyProcessed());

            // Calculate expected USDat amount: strcAmount * strcPrice / 1e8
            uint256 expectedUsdat = (req.strcAmount * vwapExecutionPrice) / 1e8;
            uint256 tolerance = (expectedUsdat * toleranceBps) / 10000;

            // Validate amount is within tolerance
            uint256 diff =
                usdatAmounts[i] > expectedUsdat ? usdatAmounts[i] - expectedUsdat : expectedUsdat - usdatAmounts[i];
            require(diff <= tolerance, ToleranceExceeded());

            // Update state
            req.usdatOwed = usdatAmounts[i];
            req.status = RequestStatus.Processed;
            totalUsdat += usdatAmounts[i];
            totalStrc += req.strcAmount;

            emit WithdrawalProcessed(tokenIds[i], req.strcAmount, usdatAmounts[i]);
        }

        nextToProcess += count;

        // External calls last
        USDAT.mint(address(this), totalUsdat);
        IERC20Burnable(address(TSTRC)).burn(totalStrc);
    }

    // ============ Claiming ============

    /// @notice Claim a specific withdrawal request by token ID
    /// @dev Burns the NFT and transfers USDat to the caller
    /// @param tokenId The NFT token ID to claim
    /// @return amount The amount of USDat claimed
    function claim(uint256 tokenId) external nonReentrant whenNotPaused returns (uint256 amount) {
        _requireNotBlacklisted(msg.sender);
        require(ownerOf(tokenId) == msg.sender, NotOwner());

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Processed, RequestNotProcessed());

        amount = req.usdatOwed;
        req.status = RequestStatus.Claimed;

        // Burn NFT (removes from enumeration automatically)
        _burn(tokenId);

        // Transfer USDat
        IERC20(address(USDAT)).safeTransfer(msg.sender, amount);

        emit Claimed(tokenId, msg.sender, amount);
    }

    /// @notice Claim multiple withdrawal requests
    /// @param tokenIds Array of token IDs to claim
    /// @return totalAmount The total amount of USDat claimed
    function claimBatch(uint256[] calldata tokenIds) external nonReentrant whenNotPaused returns (uint256 totalAmount) {
        _requireNotBlacklisted(msg.sender);
        uint256 len = tokenIds.length;
        require(len > 0, ZeroAmount());

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = tokenIds[i];
            require(ownerOf(tokenId) == msg.sender, NotOwner());

            Request storage req = requests[tokenId];
            require(req.status == RequestStatus.Processed, RequestNotProcessed());

            totalAmount += req.usdatOwed;
            req.status = RequestStatus.Claimed;

            _burn(tokenId);

            emit Claimed(tokenId, msg.sender, req.usdatOwed);
        }

        IERC20(address(USDAT)).safeTransfer(msg.sender, totalAmount);
    }

    /// @notice Claim all processed withdrawals for the caller
    /// @dev Iterates through all NFTs owned by caller - gas cost scales with ownership count
    /// @return totalAmount The total amount of USDat claimed
    function claimAll() external nonReentrant whenNotPaused returns (uint256 totalAmount) {
        _requireNotBlacklisted(msg.sender);
        totalAmount = _claimAllFor(msg.sender, msg.sender);
    }

    /// @notice Claim all processed withdrawals for a user (called by StakedUSDat)
    /// @param user The user to claim for
    /// @return totalAmount The total amount of USDat claimed
    function claimFor(address user)
        external
        nonReentrant
        whenNotPaused
        onlyRole(STAKED_USDAT_ROLE)
        returns (uint256 totalAmount)
    {
        _requireNotBlacklisted(user);
        totalAmount = _claimAllFor(user, user);
    }

    /// @dev Internal function to claim all processed withdrawals for a user
    /// @param user The user whose NFTs to process
    /// @param recipient The address to receive the USDat
    /// @return totalAmount The total amount of USDat claimed
    function _claimAllFor(address user, address recipient) internal returns (uint256 totalAmount) {
        uint256 balance = balanceOf(user);

        // Collect claimable token IDs (iterate backwards since we're burning)
        uint256[] memory toClaim = new uint256[](balance);
        uint256 claimCount = 0;

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            if (requests[tokenId].status == RequestStatus.Processed) {
                toClaim[claimCount++] = tokenId;
                totalAmount += requests[tokenId].usdatOwed;
            }
        }

        require(totalAmount != 0, NothingToClaim());

        // Burn all claimable NFTs
        for (uint256 i = 0; i < claimCount; i++) {
            requests[toClaim[i]].status = RequestStatus.Claimed;
            emit Claimed(toClaim[i], user, requests[toClaim[i]].usdatOwed);
            _burn(toClaim[i]);
        }

        IERC20(address(USDAT)).safeTransfer(recipient, totalAmount);
    }

    // ============ View Functions ============

    /// @notice Get all token IDs owned by the caller
    function getMyRequests() external view returns (uint256[] memory tokenIds) {
        return _getTokensOf(msg.sender);
    }

    /// @notice Get all token IDs owned by a user
    function getUserRequests(address user) external view returns (uint256[] memory tokenIds) {
        return _getTokensOf(user);
    }

    /// @dev Internal function to get all tokens owned by an address
    function _getTokensOf(address user) internal view returns (uint256[] memory tokenIds) {
        uint256 balance = balanceOf(user);
        tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(user, i);
        }
    }

    /// @notice Get claimable amount and token IDs for a user
    function getClaimable(address user) external view returns (uint256 total, uint256[] memory claimableIds) {
        uint256 balance = balanceOf(user);
        uint256[] memory temp = new uint256[](balance);
        uint256 count = 0;

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            Request storage req = requests[tokenId];
            if (req.status == RequestStatus.Processed) {
                temp[count++] = tokenId;
                total += req.usdatOwed;
            }
        }

        claimableIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            claimableIds[i] = temp[i];
        }
    }

    /// @notice Get pending (unprocessed) requests for a user
    function getPending(address user) external view returns (uint256 totalStrcAmount, uint256[] memory pendingIds) {
        uint256 balance = balanceOf(user);
        uint256[] memory temp = new uint256[](balance);
        uint256 count = 0;

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            Request storage req = requests[tokenId];
            if (req.status == RequestStatus.Requested) {
                temp[count++] = tokenId;
                totalStrcAmount += req.strcAmount;
            }
        }

        pendingIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            pendingIds[i] = temp[i];
        }
    }

    /// @notice Get a specific request's details
    function getRequest(uint256 tokenId) external view returns (Request memory) {
        return requests[tokenId];
    }

    /// @notice Get the status of a specific request
    /// @param tokenId The token ID to check
    /// @return The current status of the request
    function getStatus(uint256 tokenId) external view returns (RequestStatus) {
        return requests[tokenId].status;
    }

    /// @notice Check if a specific request is claimable
    /// @dev Returns false if token doesn't exist (was already claimed/burned)
    function isClaimable(uint256 tokenId) external view returns (bool) {
        return requests[tokenId].status == RequestStatus.Processed;
    }

    /// @notice Get the number of pending requests in the queue
    function getPendingCount() external view returns (uint256) {
        return nextTokenId - nextToProcess;
    }

    /// @notice Get total tSTRC waiting to be processed
    function getTotalPendingStrc() external view returns (uint256 total) {
        for (uint256 i = nextToProcess; i < nextTokenId; i++) {
            total += requests[i].strcAmount;
        }
    }

    /// @notice Get the total number of requests ever made
    function getTotalRequests() external view returns (uint256) {
        return nextTokenId;
    }

    // ============ Compliance Functions ============

    /// @notice Seize a single request for a blacklisted user
    /// @param tokenId The token ID to seize
    /// @param to The address to send the seized funds to
    function seizeRequest(uint256 tokenId, address to) external onlyRole(COMPLIANCE_ROLE) {
        address owner = ownerOf(tokenId);
        require(USDAT.isBlacklisted(owner), NotBlacklisted());

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Processed, RequestNotProcessed());

        uint256 amount = req.usdatOwed;
        req.status = RequestStatus.Claimed;

        _burn(tokenId);

        emit FundsSeized(tokenId, owner, amount, to);

        IERC20(address(USDAT)).safeTransfer(to, amount);
    }

    /// @notice Seize all claimable funds for a blacklisted user
    /// @param user The blacklisted user whose funds to seize
    /// @param to The address to send the seized funds to
    function seizeBlacklistedFunds(address user, address to) external onlyRole(COMPLIANCE_ROLE) {
        require(USDAT.isBlacklisted(user), NotBlacklisted());

        uint256 balance = balanceOf(user);
        uint256 totalSeized = 0;

        // Collect tokens to seize
        uint256[] memory toSeize = new uint256[](balance);
        uint256 seizeCount = 0;

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            if (requests[tokenId].status == RequestStatus.Processed) {
                toSeize[seizeCount++] = tokenId;
                totalSeized += requests[tokenId].usdatOwed;
            }
        }

        require(totalSeized > 0, NothingToClaim());

        // Burn seized NFTs
        for (uint256 i = 0; i < seizeCount; i++) {
            requests[toSeize[i]].status = RequestStatus.Claimed;
            emit FundsSeized(toSeize[i], user, requests[toSeize[i]].usdatOwed, to);
            _burn(toSeize[i]);
        }

        IERC20(address(USDAT)).safeTransfer(to, totalSeized);
    }

    // ============ Admin Functions ============

    function pause() external onlyRole(COMPLIANCE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============ Required Overrides ============

    /// @dev Override to check blacklist on transfers
    /// @param to The address receiving the token
    /// @param tokenId The token ID being transferred
    /// @param auth The address authorized to make the transfer
    /// @return The previous owner of the token
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow minting (from == address(0)) and burning (to == address(0))
        // Only check blacklist for actual transfers
        if (from != address(0) && to != address(0)) {
            require(address(stakedUSDat) != address(0), StakedUSDatNotSet());
            _requireNotBlacklisted(from);
            _requireNotBlacklisted(to);
        }

        return super._update(to, tokenId, auth);
    }

    /// @dev Override required by Solidity for multiple inheritance
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
