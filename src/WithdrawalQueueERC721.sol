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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUSDat} from "./interfaces/IUSDat.sol";
import {IStakedUSDat} from "./interfaces/IStakedUSDat.sol";
import {ITokenizedSTRC} from "./interfaces/ITokenizedSTRC.sol";

/// @title WithdrawalQueueERC721
/// @notice UUPS upgradeable NFT-based withdrawal queue where each request is an ERC721 token
/// @dev Requests are processed in order when possible, but may be skipped if user's slippage check fails
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
        uint256 shares;
        uint256 usdatOwed;
        uint256 timestamp;
        uint256 minUsdatReceived;
        RequestStatus status;
    }

    // Roles
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    // Tokens
    IUSDat public immutable USDAT;
    ITokenizedSTRC public immutable TSTRC;
    IStakedUSDat public stakedUSDat;

    // Queue state
    mapping(uint256 tokenId => Request) public requests;
    uint256 public nextTokenId;
    uint256 public pendingCount;

    // Constants
    uint256 public constant PRICE_TOLERANCE_BPS = 2000; // 20% tolerance in basis points
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MIN_VAULT_USDAT_BPS = 500; // 5% minimum USDat reserve in vault

    // Errors
    error ZeroAmount();
    error NoRequestsToProcess();
    error AlreadyProcessed();
    error NothingToClaim();
    error NotOwner();
    error NotBlacklisted();
    error InvalidInputs();
    error ExecutionPriceMismatch();
    error OraclePriceMismatch();
    error RequestNotProcessed();
    error AddressBlacklisted();
    error StakedUSDatNotSet();
    error StakedUSDatAlreadySet();
    error SlippageExceeded();
    error ExceedsVestedBalance();

    // Events
    event WithdrawalRequested(uint256 indexed tokenId, address indexed user, uint256 shares, uint256 timestamp);
    event WithdrawalProcessed(uint256 indexed tokenId, uint256 shares, uint256 usdatAmount);
    event Claimed(uint256 indexed tokenId, address indexed user, uint256 usdatAmount);
    event FundsSeized(uint256 indexed tokenId, address indexed user, uint256 usdatAmount, address indexed to);
    event RequestSeized(uint256 indexed tokenId, address indexed user, address indexed to);
    event MinUsdatReceivedUpdated(uint256 indexed tokenId, uint256 newMinUsdatReceived);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param usdat USDat contract address
    /// @param tstrc TokenizedSTRC contract address
    constructor(address usdat, address tstrc) {
        require(usdat != address(0) && tstrc != address(0), ZeroAmount());
        USDAT = IUSDat(usdat);
        TSTRC = ITokenizedSTRC(tstrc);
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
    /// @param _stakedusdat The StakedUSDat contract address
    function setStakedUSDat(address _stakedusdat) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(stakedUSDat) == address(0), StakedUSDatAlreadySet());
        require(_stakedusdat != address(0), ZeroAmount());
        stakedUSDat = IStakedUSDat(_stakedusdat);
        _grantRole(STAKED_USDAT_ROLE, _stakedusdat);
    }

    function _requireNotBlacklisted(address account) internal view {
        require(!stakedUSDat.isBlacklisted(account), AddressBlacklisted());
        require(!USDAT.isBlacklisted(account), AddressBlacklisted());
    }

    function requireBlacklisted(address account) internal view {
        require(stakedUSDat.isBlacklisted(account) || USDAT.isBlacklisted(account), NotBlacklisted());
    }

    // ============ Request Creation ============

    /// @notice Called by StakedUSDat to add a withdrawal request
    /// @dev Mints an NFT to the user representing their withdrawal request
    /// @param user The user requesting withdrawal
    /// @param shares The amount of sUSDat shares escrowed
    /// @param minUsdatReceived The minimum amount of USDat the user will accept
    /// @return tokenId The NFT token ID (same as request ID)
    function addRequest(address user, uint256 shares, uint256 minUsdatReceived)
        external
        nonReentrant
        whenNotPaused
        onlyRole(STAKED_USDAT_ROLE)
        returns (uint256 tokenId)
    {
        require(shares != 0, ZeroAmount());

        tokenId = nextTokenId++;
        pendingCount++;

        requests[tokenId] = Request({
            shares: shares,
            usdatOwed: 0,
            timestamp: block.timestamp,
            status: RequestStatus.Requested,
            minUsdatReceived: minUsdatReceived
        });

        _mint(user, tokenId);

        emit WithdrawalRequested(tokenId, user, shares, block.timestamp);
    }

    /// @notice Update the minimum USDat amount for a pending withdrawal request
    /// @param tokenId The token ID of the request to update
    /// @param newMinUsdatReceived The new minimum USDat amount
    function updateMinUsdatReceived(uint256 tokenId, uint256 newMinUsdatReceived) external whenNotPaused {
        require(ownerOf(tokenId) == msg.sender, NotOwner());
        _requireNotBlacklisted(msg.sender);
        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Requested, AlreadyProcessed());

        req.minUsdatReceived = newMinUsdatReceived;

        emit MinUsdatReceivedUpdated(tokenId, newMinUsdatReceived);
    }

    // ============ Processing ============

    function _validateAmount(uint256 usdatAmount, uint256 minUsdatReceived) internal pure {
        require(usdatAmount >= minUsdatReceived, SlippageExceeded());
    }

    /// @notice Checks if a value is within ±PRICE_TOLERANCE_BPS of an expected value
    /// @param value The actual value to check
    /// @param expected The expected value
    /// @return True if value is within tolerance of expected
    function _isWithinTolerance(uint256 value, uint256 expected) internal pure returns (bool) {
        uint256 minExpected = Math.mulDiv(expected, BPS_DENOMINATOR - PRICE_TOLERANCE_BPS, BPS_DENOMINATOR);
        uint256 maxExpected = Math.mulDiv(expected, BPS_DENOMINATOR + PRICE_TOLERANCE_BPS, BPS_DENOMINATOR);
        return value >= minExpected && value <= maxExpected;
    }

    /// @notice Validates that totalUsdatReceived and totalStrcSold are consistent
    /// @dev Checks three things:
    ///      1. totalStrcSold <= vested tSTRC balance (cannot sell unvested rewards)
    ///      2. totalUsdatReceived ≈ totalStrcSold * executionPrice (within tolerance)
    ///      3. executionPrice ≈ oracle price (within tolerance)
    /// @param totalUsdatReceived Amount of USDat received from selling tSTRC
    /// @param totalStrcSold Amount of tSTRC that was sold off-chain
    /// @param executionPrice The price per tSTRC in USDat terms (8 decimals)
    function _validateTotals(uint256 totalUsdatReceived, uint256 totalStrcSold, uint256 executionPrice) internal view {
        // Validate totalStrcSold doesn't exceed vested balance
        uint256 strcBalance = TSTRC.balanceOf(address(stakedUSDat));
        uint256 unvestedAmount = stakedUSDat.getUnvestedAmount();
        uint256 vestedBalance = strcBalance - unvestedAmount;
        require(totalStrcSold <= vestedBalance, ExceedsVestedBalance());

        // Calculate expected USDat from executionPrice (8 decimals)
        uint256 expectedUsdat = Math.mulDiv(totalStrcSold, executionPrice, 1e8);

        // Check totalUsdatReceived is within tolerance of expected
        require(_isWithinTolerance(totalUsdatReceived, expectedUsdat), ExecutionPriceMismatch());

        // Validate executionPrice against oracle price (within tolerance)
        // Oracle price is already in 8 decimals, so compare directly
        (uint256 oraclePrice,) = TSTRC.getPrice();

        require(_isWithinTolerance(executionPrice, oraclePrice), OraclePriceMismatch());
    }

    /// @notice Process a batch of withdrawal requests (non-sequential)
    /// @dev Requests are processed in order when possible, but may be skipped if slippage check fails
    /// @param tokenIds Array of token IDs to process
    /// @param totalUsdatReceived Amount of USDat received from selling tSTRC
    /// @param totalStrcSold Amount of tSTRC that was sold off-chain
    /// @param executionPrice The price per tSTRC in USDat terms (8 decimals) for validation
    function processRequests(
        uint256[] calldata tokenIds,
        uint256 totalUsdatReceived,
        uint256 totalStrcSold,
        uint256 executionPrice
    ) external nonReentrant onlyRole(PROCESSOR_ROLE) {
        // Validate inputs are consistent
        _validateTotals(totalUsdatReceived, totalStrcSold, executionPrice);
        uint256 count = tokenIds.length;
        require(count > 0, InvalidInputs());

        uint256 totalShares = 0;
        for (uint256 i = 0; i < count; i++) {
            totalShares += requests[tokenIds[i]].shares;
        }

        uint256 totalUsdat = 0;
        for (uint256 i = 0; i < count; i++) {
            Request storage req = requests[tokenIds[i]];
            require(req.status == RequestStatus.Requested, AlreadyProcessed());

            // Pro-rata: user gets their share of what was received
            uint256 usdatAmount = Math.mulDiv(totalUsdatReceived, req.shares, totalShares, Math.Rounding.Floor);

            // Validate against user's minimum
            _validateAmount(usdatAmount, req.minUsdatReceived);

            req.usdatOwed = usdatAmount;
            req.status = RequestStatus.Processed;
            totalUsdat += usdatAmount;

            emit WithdrawalProcessed(tokenIds[i], req.shares, usdatAmount);
        }

        require(totalUsdat <= totalUsdatReceived, ExecutionPriceMismatch());

        pendingCount -= count;

        // Burn the escrowed shares and the tSTRC sold off-chain, then mint USDat
        stakedUSDat.burnQueuedShares(totalShares, totalStrcSold);
        USDAT.mint(address(this), totalUsdat);
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
    function claimAllFor(address user)
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

    /// @notice Get the number of pending requests in the queue
    function getPendingCount() external view returns (uint256) {
        return pendingCount;
    }

    /// @notice Get total sUSDat shares waiting to be processed
    function getTotalPendingShares() external view returns (uint256) {
        return IERC20(address(stakedUSDat)).balanceOf(address(this));
    }

    /// @notice Get the total number of requests ever made
    function getTotalRequests() external view returns (uint256) {
        return nextTokenId;
    }

    /// @notice Get pending request IDs within a range
    /// @param start Starting tokenId (inclusive)
    /// @param end Ending tokenId (exclusive)
    /// @return pendingIds Array of pending tokenIds in the range
    function getPendingIdsInRange(uint256 start, uint256 end) external view returns (uint256[] memory pendingIds) {
        require(start < end, InvalidInputs());
        if (end > nextTokenId) {
            end = nextTokenId;
        }

        uint256[] memory temp = new uint256[](end - start);
        uint256 count = 0;

        for (uint256 i = start; i < end; i++) {
            if (requests[i].status == RequestStatus.Requested) {
                temp[count++] = i;
            }
        }

        pendingIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            pendingIds[i] = temp[i];
        }
    }

    // ============ Compliance Functions ============

    /// @notice Seize pending requests from blacklisted holders by transferring NFTs
    /// @dev Only works for Requested status - burns and re-mints to bypass blacklist transfer checks
    /// @param tokenIds Array of token IDs to seize
    /// @param to The address to transfer the NFTs to
    function seizeRequests(uint256[] calldata tokenIds, address to) external nonReentrant onlyRole(COMPLIANCE_ROLE) {
        require(to != address(0), ZeroAmount());
        _requireNotBlacklisted(to);

        uint256 len = tokenIds.length;
        require(len > 0, ZeroAmount());

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = tokenIds[i];
            address owner = ownerOf(tokenId);
            requireBlacklisted(owner);

            Request storage req = requests[tokenId];
            require(req.status == RequestStatus.Requested, AlreadyProcessed());

            _transfer(owner, to, tokenId);

            emit RequestSeized(tokenId, owner, to);
        }
    }

    /// @notice Seize processed requests from blacklisted holders by transferring USDat
    /// @dev Only works for Processed status - burns NFT and transfers USDat to the `to` address
    /// @param tokenIds Array of token IDs to seize
    /// @param to The address to transfer the USDat to
    function seizeBlacklistedFunds(uint256[] calldata tokenIds, address to)
        external
        nonReentrant
        onlyRole(COMPLIANCE_ROLE)
    {
        require(to != address(0), ZeroAmount());
        uint256 len = tokenIds.length;
        require(len > 0, ZeroAmount());

        uint256 totalUsdatSeized = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = tokenIds[i];
            address owner = ownerOf(tokenId);
            requireBlacklisted(owner);

            Request storage req = requests[tokenId];
            require(req.status == RequestStatus.Processed, RequestNotProcessed());

            totalUsdatSeized += req.usdatOwed;
            req.status = RequestStatus.Claimed;

            _burn(tokenId);

            emit FundsSeized(tokenId, owner, req.usdatOwed, to);
        }

        IERC20(address(USDAT)).safeTransfer(to, totalUsdatSeized);
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

        // Only check blacklist for actual transfers (not mint/burn)
        if (from != address(0) && to != address(0)) {
            require(address(stakedUSDat) != address(0), StakedUSDatNotSet());
            // Compliance seizure: from must BE blacklisted, to must NOT be
            if (hasRole(COMPLIANCE_ROLE, msg.sender)) {
                requireBlacklisted(from);
                _requireNotBlacklisted(to);
            } else {
                // Normal transfer: neither can be blacklisted
                _requireNotBlacklisted(from);
                _requireNotBlacklisted(to);
            }
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
