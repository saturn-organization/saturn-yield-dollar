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
import {IWithdrawalQueueERC721} from "./interfaces/IWithdrawalQueueERC721.sol";

/**
 * @title WithdrawalQueueERC721
 * @author Saturn
 * @notice Implementation of the IWithdrawalQueueERC721 interface.
 * @dev See {IWithdrawalQueueERC721} for full documentation.
 */
contract WithdrawalQueueERC721 is
    Initializable,
    ERC721EnumerableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    UUPSUpgradeable,
    IWithdrawalQueueERC721
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for the processor
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");

    /// @notice Role identifier for compliance operations
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @notice Role identifier for the StakedUSDat contract
    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    /// @dev The USDat token contract (immutable, stored in implementation bytecode)
    IUSDat public immutable USDAT;

    /// @dev The TokenizedSTRC contract (immutable, stored in implementation bytecode)
    ITokenizedSTRC public immutable TSTRC;

    /// @notice The StakedUSDat contract
    IStakedUSDat public stakedUSDat;

    /// @notice Mapping of token ID to request data
    mapping(uint256 tokenId => Request) public requests;

    /// @notice The next token ID to be minted
    uint256 public nextTokenId;

    /// @notice The number of pending requests
    uint256 public pendingCount;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @custom:oz-upgrades-unsafe-allow constructor
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

    /// @dev Authorizes an upgrade to a new implementation. Only callable by DEFAULT_ADMIN_ROLE.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ Admin Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function setStakedUSDat(address _stakedusdat) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(stakedUSDat) == address(0), StakedUSDatAlreadySet());
        require(_stakedusdat != address(0), ZeroAmount());
        stakedUSDat = IStakedUSDat(_stakedusdat);
        _grantRole(STAKED_USDAT_ROLE, _stakedusdat);
    }

    /// @dev Reverts if the given account is blacklisted in either StakedUSDat or USDat.
    function _requireNotBlacklisted(address account) internal view {
        require(!stakedUSDat.isBlacklisted(account), AddressBlacklisted());
        require(!USDAT.isBlacklisted(account), AddressBlacklisted());
    }

    /// @dev Reverts if the given account is NOT blacklisted in both StakedUSDat and USDat.
    function _requireBlacklisted(address account) internal view {
        require(stakedUSDat.isBlacklisted(account) || USDAT.isBlacklisted(account), NotBlacklisted());
    }

    // ============ Request Creation ============

    /// @inheritdoc IWithdrawalQueueERC721
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

    /// @inheritdoc IWithdrawalQueueERC721
    function updateMinUsdatReceived(uint256 tokenId, uint256 newMinUsdatReceived) external whenNotPaused {
        require(ownerOf(tokenId) == msg.sender, NotOwner());
        _requireNotBlacklisted(msg.sender);
        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Requested || req.status == RequestStatus.InProgress, AlreadyProcessed());

        if (req.status == RequestStatus.InProgress) {
            require(newMinUsdatReceived < req.minUsdatReceived, InvalidInputs());
        }

        req.minUsdatReceived = newMinUsdatReceived;

        emit MinUsdatReceivedUpdated(tokenId, newMinUsdatReceived);
    }

    // ============ Processing Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function lockRequests(uint256[] calldata tokenIds) external onlyRole(PROCESSOR_ROLE) {
        uint256 count = tokenIds.length;
        require(count > 0, InvalidInputs());

        for (uint256 i = 0; i < count; i++) {
            Request storage req = requests[tokenIds[i]];
            require(req.status == RequestStatus.Requested, AlreadyProcessed());
            req.status = RequestStatus.InProgress;
        }

        emit RequestsLocked(tokenIds);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function unlockRequests(uint256[] calldata tokenIds) external onlyRole(PROCESSOR_ROLE) {
        uint256 count = tokenIds.length;
        require(count > 0, InvalidInputs());

        for (uint256 i = 0; i < count; i++) {
            Request storage req = requests[tokenIds[i]];
            require(req.status == RequestStatus.InProgress, RequestNotLocked());
            req.status = RequestStatus.Requested;
        }

        emit RequestsUnlocked(tokenIds);
    }

    /// @dev Validates that usdatAmount meets the user's minimum requirement.
    function _validateAmount(uint256 usdatAmount, uint256 minUsdatReceived) internal pure {
        require(usdatAmount >= minUsdatReceived, SlippageExceeded());
    }

    /// @dev Checks if a value is within ±toleranceBps of an expected value.
    function _isWithinTolerance(uint256 value, uint256 expected) internal view returns (bool) {
        uint256 toleranceBps = stakedUSDat.toleranceBps();
        uint256 minExpected = Math.mulDiv(expected, BPS_DENOMINATOR - toleranceBps, BPS_DENOMINATOR);
        uint256 maxExpected = Math.mulDiv(expected, BPS_DENOMINATOR + toleranceBps, BPS_DENOMINATOR);
        return value >= minExpected && value <= maxExpected;
    }

    /// @dev Validates that totalUsdatReceived and totalStrcSold are consistent with oracle prices.
    function _validateTotals(
        uint256 totalUsdatReceived,
        uint256 totalStrcSold,
        uint256 executionPrice,
        uint256 totalShares
    ) internal view {
        uint256 strcBalance = TSTRC.balanceOf(address(stakedUSDat));
        uint256 unvestedAmount = stakedUSDat.getUnvestedAmount();
        uint256 vestedBalance = strcBalance - unvestedAmount;
        require(totalStrcSold <= vestedBalance, ExceedsVestedBalance());

        uint256 expectedUsdat = Math.mulDiv(totalStrcSold, executionPrice, 1e8);
        require(_isWithinTolerance(totalUsdatReceived, expectedUsdat), ExecutionPriceMismatch());

        (uint256 oraclePrice,) = TSTRC.getPrice();
        require(_isWithinTolerance(executionPrice, oraclePrice), OraclePriceMismatch());

        uint256 expectedShareValue = stakedUSDat.previewRedeem(totalShares);
        require(_isWithinTolerance(totalUsdatReceived, expectedShareValue), ExecutionPriceMismatch());
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function processRequests(
        uint256[] calldata tokenIds,
        uint256 totalUsdatReceived,
        uint256 totalStrcSold,
        uint256 executionPrice
    ) external nonReentrant onlyRole(PROCESSOR_ROLE) {
        uint256 count = tokenIds.length;
        require(count > 0, InvalidInputs());

        uint256 totalShares = 0;
        for (uint256 i = 0; i < count; i++) {
            totalShares += requests[tokenIds[i]].shares;
        }

        _validateTotals(totalUsdatReceived, totalStrcSold, executionPrice, totalShares);

        uint256 totalUsdat = 0;
        for (uint256 i = 0; i < count; i++) {
            Request storage req = requests[tokenIds[i]];
            require(req.status == RequestStatus.InProgress, RequestNotLocked());

            uint256 usdatAmount = Math.mulDiv(totalUsdatReceived, req.shares, totalShares, Math.Rounding.Floor);

            _validateAmount(usdatAmount, req.minUsdatReceived);

            req.usdatOwed = usdatAmount;
            req.status = RequestStatus.Processed;
            totalUsdat += usdatAmount;

            emit WithdrawalProcessed(tokenIds[i], req.shares, usdatAmount);
        }

        require(totalUsdat <= totalUsdatReceived, ExecutionPriceMismatch());

        pendingCount -= count;

        stakedUSDat.burnQueuedShares(totalShares, totalStrcSold);
        USDAT.mint(address(this), totalUsdatReceived);
        uint256 dust = totalUsdatReceived - totalUsdat;
        if (dust > 0) {
            IERC20(address(USDAT)).approve(address(stakedUSDat), dust);
            stakedUSDat.collectDust(dust);
        }
    }

    // ============ Claiming Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function claim(uint256 tokenId) external nonReentrant whenNotPaused returns (uint256 amount) {
        _requireNotBlacklisted(msg.sender);
        require(ownerOf(tokenId) == msg.sender, NotOwner());

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Processed, RequestNotProcessed());

        amount = req.usdatOwed;
        req.status = RequestStatus.Claimed;

        _burn(tokenId);

        IERC20(address(USDAT)).safeTransfer(msg.sender, amount);

        emit Claimed(tokenId, msg.sender, amount);
    }

    /// @inheritdoc IWithdrawalQueueERC721
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

    /// @inheritdoc IWithdrawalQueueERC721
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

    /// @inheritdoc IWithdrawalQueueERC721
    function claimAll() external nonReentrant whenNotPaused returns (uint256 totalAmount) {
        _requireNotBlacklisted(msg.sender);
        totalAmount = _claimAllFor(msg.sender);
    }

    /// @inheritdoc IWithdrawalQueueERC721
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

    /// @dev Claims all processed withdrawals for a user.
    function _claimAllFor(address user) internal returns (uint256 totalAmount) {
        uint256 balance = balanceOf(user);

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

        for (uint256 i = 0; i < claimCount; i++) {
            requests[toClaim[i]].status = RequestStatus.Claimed;
            emit Claimed(toClaim[i], user, requests[toClaim[i]].usdatOwed);
            _burn(toClaim[i]);
        }

        IERC20(address(USDAT)).safeTransfer(user, totalAmount);
    }

    // ============ View Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function getMyRequests() external view returns (uint256[] memory tokenIds) {
        return _getTokensOf(msg.sender);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function getUserRequests(address user) external view returns (uint256[] memory tokenIds) {
        return _getTokensOf(user);
    }

    /// @dev Returns all token IDs owned by an address.
    function _getTokensOf(address user) internal view returns (uint256[] memory tokenIds) {
        uint256 balance = balanceOf(user);
        tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(user, i);
        }
    }

    /// @inheritdoc IWithdrawalQueueERC721
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

    /// @inheritdoc IWithdrawalQueueERC721
    function getPending(address user) external view returns (uint256 totalShares, uint256[] memory pendingIds) {
        uint256 balance = balanceOf(user);
        uint256[] memory temp = new uint256[](balance);
        uint256 count = 0;

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            Request storage req = requests[tokenId];
            if (req.status == RequestStatus.Requested || req.status == RequestStatus.InProgress) {
                temp[count++] = tokenId;
                totalShares += req.shares;
            }
        }

        pendingIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            pendingIds[i] = temp[i];
        }
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function getRequest(uint256 tokenId) external view returns (Request memory) {
        return requests[tokenId];
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function getStatus(uint256 tokenId) external view returns (RequestStatus) {
        return requests[tokenId].status;
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function isClaimable(uint256 tokenId) external view returns (bool) {
        return requests[tokenId].status == RequestStatus.Processed;
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function getPendingCount() external view returns (uint256) {
        return pendingCount;
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function getTotalPendingShares() external view returns (uint256) {
        return IERC20(address(stakedUSDat)).balanceOf(address(this));
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function getTotalRequests() external view returns (uint256) {
        return nextTokenId;
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function getPendingIdsInRange(uint256 start, uint256 end) external view returns (uint256[] memory pendingIds) {
        require(start < end, InvalidInputs());
        if (end > nextTokenId) {
            end = nextTokenId;
        }

        uint256[] memory temp = new uint256[](end - start);
        uint256 count = 0;

        for (uint256 i = start; i < end; i++) {
            RequestStatus status = requests[i].status;
            if (status == RequestStatus.Requested || status == RequestStatus.InProgress) {
                temp[count++] = i;
            }
        }

        pendingIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            pendingIds[i] = temp[i];
        }
    }

    // ============ Compliance Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function seizeRequests(uint256[] calldata tokenIds, address to) external nonReentrant onlyRole(COMPLIANCE_ROLE) {
        require(to != address(0), ZeroAmount());
        _requireNotBlacklisted(to);

        uint256 len = tokenIds.length;
        require(len > 0, ZeroAmount());

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = tokenIds[i];
            address owner = ownerOf(tokenId);
            _requireBlacklisted(owner);

            Request storage req = requests[tokenId];
            require(req.status == RequestStatus.Requested || req.status == RequestStatus.InProgress, AlreadyProcessed());

            _transfer(owner, to, tokenId);

            emit RequestSeized(tokenId, owner, to);
        }
    }

    /// @inheritdoc IWithdrawalQueueERC721
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
            _requireBlacklisted(owner);

            Request storage req = requests[tokenId];
            require(req.status == RequestStatus.Processed, RequestNotProcessed());

            totalUsdatSeized += req.usdatOwed;
            req.status = RequestStatus.Claimed;

            _burn(tokenId);

            emit FundsSeized(tokenId, owner, req.usdatOwed, to);
        }

        IERC20(address(USDAT)).safeTransfer(to, totalUsdatSeized);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function pause() external onlyRole(COMPLIANCE_ROLE) {
        _pause();
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============ Required Overrides ============

    /// @dev Override to check blacklist on transfers.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        if (from != address(0) && to != address(0)) {
            require(address(stakedUSDat) != address(0), StakedUSDatNotSet());
            if (hasRole(COMPLIANCE_ROLE, msg.sender)) {
                _requireBlacklisted(from);
                _requireNotBlacklisted(to);
            } else {
                _requireNotBlacklisted(from);
                _requireNotBlacklisted(to);
            }
        }

        return super._update(to, tokenId, auth);
    }

    /// @dev Override required by Solidity for multiple inheritance.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
