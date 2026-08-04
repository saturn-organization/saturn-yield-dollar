// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IUSDat} from "./interfaces/IUSDat.sol";
import {IStakedUSDat} from "./interfaces/IStakedUSDat.sol";
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

    /// @notice Role identifier for the operator (processRequests)
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role identifier for enforcement actions against blacklisted holders
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    /// @notice Role identifier for pausing (cannot unpause)
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role identifier for unpausing (cannot pause)
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    /// @dev The USDat token contract (immutable, stored in implementation bytecode)
    IUSDat public immutable USDAT;

    /// @dev The StakedUSDat contract (immutable, stored in implementation bytecode)
    IStakedUSDat public immutable STAKED_USDAT;

    /// @notice Mapping of token ID to request data
    mapping(uint256 tokenId => Request) public requests;

    /// @notice The next token ID to be minted
    uint256 public nextTokenId;

    /// @dev Retired v1 slot; do not reuse.
    /// @custom:oz-renamed-from pendingCount
    // The double-underscore prefix marks retired storage slots.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 private __deprecatedPendingCount;

    /// @dev Contract-relationship gate: immutable address check, deliberately not a
    /// grantable role.
    // forge-lint: disable-next-line(mixed-case-function)
    modifier onlyStakedUSDat() {
        _requireStakedUSDat();
        _;
    }

    /// @dev Lifts an active pause for the duration of the call (enforcement actions
    /// work while paused).
    // Pre-call pause state must remain available after the modified function runs.
    modifier whileUnpaused() {
        bool wasPaused = paused();
        if (wasPaused) _unpause();
        _;
        if (wasPaused) _pause();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _requireStakedUSDat() internal view {
        require(msg.sender == address(STAKED_USDAT), OperationNotAllowed());
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address usdat, address stakedUsdat) {
        require(usdat != address(0) && stakedUsdat != address(0), ZeroAmount());
        USDAT = IUSDat(usdat);
        STAKED_USDAT = IStakedUSDat(stakedUsdat);
        _disableInitializers();
    }

    /// @notice Initializes the contract (called once via proxy)
    /// @dev Grants only DEFAULT_ADMIN_ROLE; the admin grants the operational roles (§2.8)
    /// after deployment.
    /// @param admin The default admin of the contract
    function initialize(address admin) external initializer {
        require(admin != address(0), ZeroAmount());

        __ERC721_init("Saturn Withdrawal Request", "sWR");
        __ERC721Enumerable_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice v1 → v2 migration reinitializer (§3.1), executed atomically inside
    /// upgradeToAndCall.
    /// @dev Grants the §2.8 roles (new role ids, nothing carries over from v1).
    /// Existing requests are deliberately untouched: the v1 minUsdatReceived slot
    /// is reinterpreted in place as the net-of-fee minSharePrice without numeric
    /// conversion.
    /// @param operator The OPERATOR_ROLE holder (processRequests).
    /// @param enforcer The ENFORCER_ROLE holder (seizeRequest, seize).
    /// @param pauser The PAUSER_ROLE holder.
    /// @param unpauser The UNPAUSER_ROLE holder.
    function initializeV2(address operator, address enforcer, address pauser, address unpauser)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        reinitializer(2)
    {
        require(
            operator != address(0) && enforcer != address(0) && pauser != address(0) && unpauser != address(0),
            ZeroAmount()
        );

        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(ENFORCER_ROLE, enforcer);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(UNPAUSER_ROLE, unpauser);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function resetLegacyInProgressRequest(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.InProgress, RequestNotInProgress());
        req.status = RequestStatus.Requested;

        emit LegacyInProgressRequestReset(tokenId);
    }

    /// @dev Authorizes an upgrade to a new implementation. Only callable by DEFAULT_ADMIN_ROLE.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev Reverts if the given account is blacklisted in either StakedUSDat or USDat.
    function _requireNotBlacklisted(address account) internal view {
        require(!STAKED_USDAT.isBlacklisted(account), AddressBlacklisted());
        require(!USDAT.isFrozen(account), AddressBlacklisted());
    }

    /// @dev Reverts if the given account is NOT blacklisted in both StakedUSDat and USDat.
    function _requireBlacklisted(address account) internal view {
        require(STAKED_USDAT.isBlacklisted(account) || USDAT.isFrozen(account), NotBlacklisted());
    }

    /// @dev Returns the current nonzero recovery address if it is not restricted.
    function _validatedRecoveryAddress() internal view returns (address recovery) {
        recovery = STAKED_USDAT.recoveryAddress();
        require(recovery != address(0), ZeroAmount());
        _requireNotBlacklisted(recovery);
    }

    // ============ Request Creation ============

    /// @inheritdoc IWithdrawalQueueERC721
    function addRequest(address user, uint256 shares, uint256 minSharePrice)
        external
        nonReentrant
        whenNotPaused
        onlyStakedUSDat
        returns (uint256 tokenId)
    {
        require(shares != 0, ZeroAmount());
        _requireNotBlacklisted(user);

        tokenId = nextTokenId++;

        requests[tokenId] = Request({
            shares: shares,
            usdatOwed: 0,
            timestamp: block.timestamp,
            status: RequestStatus.Requested,
            minSharePrice: minSharePrice
        });

        _safeMint(user, tokenId);

        emit WithdrawalRequested(tokenId, user, shares, block.timestamp);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function updateMinSharePrice(uint256 tokenId, uint256 newMinSharePrice) external whenNotPaused {
        require(ownerOf(tokenId) == msg.sender, NotOwner());
        _requireNotBlacklisted(msg.sender);

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Requested, RequestNotOpen());

        req.minSharePrice = newMinSharePrice;

        emit MinSharePriceUpdated(tokenId, newMinSharePrice);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function cancelRequest(uint256 tokenId) external nonReentrant whenNotPaused {
        address owner = ownerOf(tokenId);
        require(owner == msg.sender, NotOwner());
        _requireNotBlacklisted(owner);

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Requested, RequestNotOpen());

        uint256 shares = req.shares;
        req.status = RequestStatus.Cancelled;
        _burn(tokenId);

        IERC20(address(STAKED_USDAT)).safeTransfer(owner, shares);

        emit RequestCancelled(tokenId, owner, shares);
    }

    // ============ Processing Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    /// @dev Each request settles completely or remains unchanged. Expected limit and
    /// liquidity failures do not stop the batch; any invalid entry reverts the whole
    /// transaction, including earlier settlements.
    function processRequests(uint256[] calldata tokenIds) external nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        uint256 count = tokenIds.length;

        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            Request storage req = requests[tokenId];
            require(req.status == RequestStatus.Requested, RequestNotOpen());

            (IStakedUSDat.RedemptionResult result, uint256 usdat) =
                STAKED_USDAT.redeemQueuedShares(req.shares, req.minSharePrice);
            if (result == IStakedUSDat.RedemptionResult.BelowLimit) continue;
            if (result == IStakedUSDat.RedemptionResult.InsufficientLiquidity) continue;

            req.usdatOwed = usdat;
            req.status = RequestStatus.Processed;

            emit WithdrawalProcessed(tokenId, req.shares, usdat);
        }
    }

    // ============ Claiming Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function claim(uint256 tokenId) external nonReentrant whenNotPaused returns (uint256 amount) {
        address owner = ownerOf(tokenId);
        require(owner == msg.sender, NotOwner());
        _requireNotBlacklisted(owner);

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Processed, RequestNotProcessed());

        amount = req.usdatOwed;
        req.status = RequestStatus.Claimed;
        _burn(tokenId);

        IERC20(address(USDAT)).safeTransfer(owner, amount);

        emit Claimed(tokenId, owner, amount);
    }

    // ============ View Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function getUserRequests(address user) external view returns (uint256[] memory tokenIds) {
        uint256 balance = balanceOf(user);
        tokenIds = new uint256[](balance);

        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(user, i);
        }
    }

    // ============ Compliance Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function seizeRequest(uint256 tokenId) external nonReentrant onlyRole(ENFORCER_ROLE) whileUnpaused {
        address owner = ownerOf(tokenId);
        _requireBlacklisted(owner);

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Requested, RequestNotOpen());

        address to = _validatedRecoveryAddress();

        // The request record travels unchanged with the token.
        _transfer(owner, to, tokenId);

        emit RequestSeized(tokenId, owner, to);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function seize(uint256 tokenId) external nonReentrant onlyRole(ENFORCER_ROLE) whileUnpaused {
        address owner = ownerOf(tokenId);
        _requireBlacklisted(owner);

        Request storage req = requests[tokenId];
        require(req.status == RequestStatus.Processed, RequestNotProcessed());

        address to = _validatedRecoveryAddress();

        uint256 amount = req.usdatOwed;
        req.status = RequestStatus.Claimed;
        _burn(tokenId);

        IERC20(address(USDAT)).safeTransfer(to, amount);

        emit FundsSeized(tokenId, owner, amount, to);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    // ============ Required Overrides ============

    /// @dev Applies queue restrictions to ordinary owner/approved-operator transfers.
    /// Enforcement uses the separately authorized and validated seizure functions.
    function transferFrom(address from, address to, uint256 tokenId) public override(ERC721Upgradeable, IERC721) {
        _requireNotBlacklisted(from);
        _requireNotBlacklisted(to);

        super.transferFrom(from, to, tokenId);
    }

    /// @dev Blocks all token movements while the queue is paused.
    function _update(address to, uint256 tokenId, address auth) internal override whenNotPaused returns (address) {
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
