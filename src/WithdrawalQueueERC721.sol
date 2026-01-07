// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IUSDat} from "./interfaces/IUSDat.sol";
import {IStakedUSDat} from "./interfaces/IStakedUSDat.sol";

/// @title WithdrawalQueueERC721
/// @notice UUPS upgradeable NFT-based FIFO withdrawal queue where each request is an ERC721 token
/// @dev Each withdrawal request mints an NFT to the user, which is burned on claim
contract WithdrawalQueueERC721 is
    Initializable,
    ERC721EnumerableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice The lifecycle status of a withdrawal request
    enum RequestStatus {
        Requested, // Request created, waiting to be processed
        Processed, // Processed by admin, USDat allocated, ready to claim
        Claimed // User has claimed their USDat (NFT burned)
    }

    struct Request {
        uint256 shares; // sUSDat shares escrowed
        uint256 sharePriceAtRequest; // price per share at request time (18 decimals)
        uint256 maxSlippageBps; // max acceptable slippage in basis points
        uint256 usdatOwed;
        uint256 timestamp;
        RequestStatus status;
    }

    // Roles
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    // Tokens
    IUSDat public immutable USDAT;
    IStakedUSDat public stakedUSDat;

    // Queue state
    mapping(uint256 tokenId => Request) public requests;
    uint256 public nextTokenId;

    // Constants
    uint256 public constant MAX_SLIPPAGE = 5000; // 50% max slippage in basis points
    uint256 public constant WITHDRAWAL_FEE_BPS = 10; // 10bp (0.1%) withdrawal fee

    // Errors
    error ZeroAmount();
    error AlreadyProcessed();
    error NothingToClaim();
    error NotOwner();
    error NotBlacklisted();
    error InvalidInputs();
    error SlippageExceeded();
    error InvalidSlippage();
    error RequestNotProcessed();
    error AddressBlacklisted();
    error StakedUSDatNotSet();
    error StakedUSDatAlreadySet();

    // Events
    event WithdrawalRequested(
        uint256 indexed tokenId,
        address indexed user,
        uint256 shares,
        uint256 sharePriceAtRequest,
        uint256 maxSlippageBps,
        uint256 timestamp
    );
    event SlippageUpdated(uint256 indexed tokenId, uint256 newMaxSlippageBps);
    event WithdrawalProcessed(uint256 indexed tokenId, uint256 shares, uint256 usdatAmount);
    event Claimed(uint256 indexed tokenId, address indexed user, uint256 usdatAmount);
    event FundsSeized(uint256 indexed tokenId, address indexed user, uint256 usdatAmount, address indexed to);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param usdat USDat contract address
    constructor(address usdat) {
        require(usdat != address(0), ZeroAmount());
        USDAT = IUSDat(usdat);
        _disableInitializers();
    }

    /// @notice Initializes the contract (called once via proxy)
    /// @param admin The default admin of the contract
    function initialize(address admin) external initializer {
        require(admin != address(0), ZeroAmount());

        __ERC721_init("Saturn Withdrawal Request", "sWR");
        __ERC721Enumerable_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Only callable by DEFAULT_ADMIN_ROLE
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

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
        require(!USDAT.isBlacklisted(account), AddressBlacklisted());
    }

    // ============ Request Creation ============

    /// @notice Called by StakedUSDat to add a withdrawal request
    /// @dev Mints an NFT to the user representing their withdrawal request
    /// @param user The user requesting withdrawal
    /// @param shares The amount of sUSDat shares escrowed
    /// @param sharePriceAtRequest The price per share at request time (18 decimals)
    /// @param maxSlippageBps Maximum acceptable slippage in basis points
    /// @return tokenId The NFT token ID (same as request ID)
    function addRequest(address user, uint256 shares, uint256 sharePriceAtRequest, uint256 maxSlippageBps)
        external
        nonReentrant
        whenNotPaused
        onlyRole(STAKED_USDAT_ROLE)
        returns (uint256 tokenId)
    {
        require(shares != 0, ZeroAmount());
        require(maxSlippageBps <= MAX_SLIPPAGE, InvalidSlippage());

        tokenId = nextTokenId++;

        requests[tokenId] = Request({
            shares: shares,
            sharePriceAtRequest: sharePriceAtRequest,
            maxSlippageBps: maxSlippageBps,
            usdatOwed: 0,
            timestamp: block.timestamp,
            status: RequestStatus.Requested
        });

        _mint(user, tokenId);

        emit WithdrawalRequested(tokenId, user, shares, sharePriceAtRequest, maxSlippageBps, block.timestamp);
    }

    // ============ Processing ============

    /// @dev Validates usdatAmount against user's maxSlippageBps using current share price
    /// @param shares The number of shares being redeemed
    /// @param maxSlippageBps User's maximum acceptable slippage in basis points
    /// @param usdatAmount The USDat amount the processor is providing
    /// @param currentSharePrice Current price per share (18 decimals)
    function _validateAmount(uint256 shares, uint256 maxSlippageBps, uint256 usdatAmount, uint256 currentSharePrice)
        internal
        pure
    {
        // Calculate expected value at current share price
        uint256 currentValue = (shares * currentSharePrice) / 1e18;

        // Add 10bp fee to usdatAmount (user receives usdatAmount, protocol takes fee)
        // totalValue = usdatAmount + fee, where fee = usdatAmount * 10 / 10000
        uint256 totalValue = usdatAmount + (usdatAmount * WITHDRAWAL_FEE_BPS) / 10000;

        // Check that totalValue meets user's slippage tolerance
        uint256 minAcceptable = (currentValue * (10000 - maxSlippageBps)) / 10000;
        require(totalValue >= minAcceptable, SlippageExceeded());
    }

    /// @notice Process withdrawal requests (non-sequential)
    /// @param tokenIds Array of token IDs to process
    /// @param usdatAmounts Array of USDat amounts for each request
    /// @param totalStrcSold Total STRC amount sold off-chain for this batch
    function processRequests(uint256[] calldata tokenIds, uint256[] calldata usdatAmounts, uint256 totalStrcSold)
        external
        nonReentrant
        onlyRole(PROCESSOR_ROLE)
    {
        uint256 count = tokenIds.length;
        require(count > 0 && count == usdatAmounts.length, InvalidInputs());

        uint256 totalUsdat = 0;
        uint256 totalShares = 0;
        uint256 currentSharePrice = stakedUSDat.previewRedeem(1e18);

        for (uint256 i = 0; i < count; i++) {
            Request storage req = requests[tokenIds[i]];
            require(req.status == RequestStatus.Requested, AlreadyProcessed());

            _validateAmount(req.shares, req.maxSlippageBps, usdatAmounts[i], currentSharePrice);

            req.usdatOwed = usdatAmounts[i];
            req.status = RequestStatus.Processed;
            totalUsdat += usdatAmounts[i];
            totalShares += req.shares;

            emit WithdrawalProcessed(tokenIds[i], req.shares, usdatAmounts[i]);
        }

        // Burn the escrowed shares and tSTRC sold
        stakedUSDat.burnQueuedShares(totalShares, totalStrcSold);

        // Mint USDat to this contract for claims
        USDAT.mint(address(this), totalUsdat);
    }

    // ============ Update Slippage ============

    /// @notice Update slippage tolerance for a pending request
    /// @param tokenId The token ID to update
    /// @param newMaxSlippageBps New maximum slippage in basis points
    function updateMaxSlippage(uint256 tokenId, uint256 newMaxSlippageBps) external {
        require(ownerOf(tokenId) == msg.sender, NotOwner());
        require(newMaxSlippageBps <= MAX_SLIPPAGE, InvalidSlippage());
        _requireNotBlacklisted(msg.sender);

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Requested, AlreadyProcessed());

        req.maxSlippageBps = newMaxSlippageBps;

        emit SlippageUpdated(tokenId, newMaxSlippageBps);
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

    /// @notice Claim specific withdrawal requests for a user (called by StakedUSDat)
    /// @param user The user who owns the NFTs and will receive the USDat
    /// @param tokenIds Array of token IDs to claim
    /// @return totalAmount The total amount of USDat claimed
    function claimBatchFor(address user, uint256[] calldata tokenIds)
        external
        nonReentrant
        whenNotPaused
        onlyRole(STAKED_USDAT_ROLE)
        returns (uint256 totalAmount)
    {
        _requireNotBlacklisted(user);
        uint256 len = tokenIds.length;
        require(len > 0, ZeroAmount());

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = tokenIds[i];
            require(ownerOf(tokenId) == user, NotOwner());

            Request storage req = requests[tokenId];
            require(req.status == RequestStatus.Processed, RequestNotProcessed());

            totalAmount += req.usdatOwed;
            req.status = RequestStatus.Claimed;

            _burn(tokenId);

            emit Claimed(tokenId, user, req.usdatOwed);
        }

        IERC20(address(USDAT)).safeTransfer(user, totalAmount);
    }

    /// @notice Claim all processed withdrawals for the caller
    /// @dev Iterates through all NFTs owned by caller - gas cost scales with ownership count
    /// @return totalAmount The total amount of USDat claimed
    function claimAll() external nonReentrant whenNotPaused returns (uint256 totalAmount) {
        _requireNotBlacklisted(msg.sender);
        totalAmount = _claimAllFor(msg.sender);
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
        totalAmount = _claimAllFor(user);
    }

    /// @dev Internal function to claim all processed withdrawals for a user
    /// @param user The user whose NFTs to process and who receives the USDat
    /// @return totalAmount The total amount of USDat claimed
    function _claimAllFor(address user) internal returns (uint256 totalAmount) {
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

        IERC20(address(USDAT)).safeTransfer(user, totalAmount);
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
    function getPending(address user) external view returns (uint256 totalShares, uint256[] memory pendingIds) {
        uint256 balance = balanceOf(user);
        uint256[] memory temp = new uint256[](balance);
        uint256 count = 0;

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            Request storage req = requests[tokenId];
            if (req.status == RequestStatus.Requested) {
                temp[count++] = tokenId;
                totalShares += req.shares;
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

    /// @notice Get the total number of requests created
    /// @dev Use getTotalPendingShares() to get actual pending value
    function getTotalRequestCount() external view returns (uint256) {
        return nextTokenId;
    }

    /// @notice Get total shares waiting to be processed
    function getTotalPendingShares() external view returns (uint256) {
        return IERC20(address(stakedUSDat)).balanceOf(address(this));
    }

    // ============ Compliance Functions ============

    /// @notice Seize a single request for a blacklisted user
    /// @param tokenId The token ID to seize
    /// @param to The address to send the seized funds to
    function seizeRequest(uint256 tokenId, address to) external onlyRole(COMPLIANCE_ROLE) {
        require(to != address(0), ZeroAmount());
        address owner = ownerOf(tokenId);
        require(USDAT.isBlacklisted(owner), NotBlacklisted());
        require(stakedUSDat.isBlacklisted(owner), NotBlacklisted());

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
        require(to != address(0), ZeroAmount());
        require(USDAT.isBlacklisted(user), NotBlacklisted());
        require(stakedUSDat.isBlacklisted(user), NotBlacklisted());

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
        override(ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
