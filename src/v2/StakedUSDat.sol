// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {IWithdrawalQueueERC721} from "./interfaces/IWithdrawalQueueERC721.sol";
import {IStakedUSDat} from "./interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "./interfaces/ISTRConExecutionPolicy.sol";
import {IUSDat} from "./interfaces/IUSDat.sol";
import {IERC20PermitExtended} from "./interfaces/IERC20PermitExtended.sol";
import {ISTRCMirrorModule} from "./interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "./interfaces/modules/ISTRConModule.sol";
import {STRConTradeExecutionLogic} from "./libraries/STRConTradeExecutionLogic.sol";

/**
 * @title StakedUSDat
 * @author Saturn
 * @notice Implementation of the IStakedUSDat interface.
 * @dev See {IStakedUSDat} for full documentation.
 */
contract StakedUSDat is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    ERC20PermitUpgradeable,
    ERC4626Upgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IStakedUSDat
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for parameter tuning
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");

    /// @notice Role identifier for vault operations that move assets.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role identifier for selecting the current market mode
    bytes32 public constant MARKET_MODE_MANAGER_ROLE = keccak256("MARKET_MODE_MANAGER_ROLE");

    /// @notice Role identifier for blacklist add/remove (freeze only, never moves funds)
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");

    /// @notice Role identifier for enforcement actions against blacklisted holders
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    /// @notice Role identifier for pausing (cannot unpause)
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role identifier for unpausing (cannot pause)
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    /// @dev The WithdrawalQueue contract (immutable, stored in implementation bytecode)
    IWithdrawalQueueERC721 private immutable WITHDRAWAL_QUEUE;

    /// @dev Transaction-scoped queued-redemption price snapshot.
    uint256 private transient _redemptionBatchAssetBasis;
    uint256 private transient _redemptionBatchShareBasis;

    /// @dev Mapping of blacklisted addresses
    mapping(address account => bool isBlacklisted) private _blacklisted;

    /// @dev Retired v1 slot (was vestingAmount); do not reuse
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 private __deprecatedVestingAmount;

    /// @dev Retired v1 slot (was lastDistributionTimestamp); do not reuse
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 private __deprecatedLastDistributionTimestamp;

    /// @dev Retired v1 slot (was vestingPeriod); do not reuse
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 private __deprecatedVestingPeriod;

    /// @notice Minimum redemption request size (10 sUSDat shares, 18 decimals).
    /// Share-denominated so requestRedeem never prices.
    uint256 public constant MIN_REQUEST_SHARES = 10e18;

    /// @notice Basis points denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum redemption fee (5%).
    uint16 public constant MAX_REDEMPTION_FEE_BPS = 500;

    /// @notice Maximum elevated deposit fee (5%).
    uint256 public constant MAX_DEPOSIT_FEE_BPS = 500;

    /// @notice Maximum whole-vault NAV change permitted during migration (5%).
    uint16 public constant MAX_MIGRATION_TOLERANCE_BPS = 500;

    /// @notice Maximum duration of a Regular-mode authorization.
    uint64 public constant MAX_REGULAR_MODE_VALIDITY = 8 hours;

    /// @notice Maximum surplus intake per tranche (5% of pre-transfer NAV).
    uint256 public constant MAX_SURPLUS_BPS = 500;

    /// @notice Maximum surplus vesting period.
    uint256 public constant MAX_SURPLUS_VESTING_PERIOD = 7 days;

    /// @dev Retired v1 slot (was toleranceBps); do not reuse
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 private __deprecatedToleranceBps;

    /// @inheritdoc IStakedUSDat
    /// @custom:oz-renamed-from depositFeeBps
    uint256 public override elevatedDepositFeeBps;

    /// @dev Retired v1 slot (was feeRecipient); reserved and unused
    // forge-lint: disable-next-line(mixed-case-variable)
    address private __deprecatedFeeRecipient;

    /// @notice Internally tracked USDat balance (6 decimals)
    uint256 public usdatBalance;

    /// @dev Retired v1 slot (was strcBalance); do not reuse
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 private __deprecatedStrcBalance;

    /// @dev Retired v1 slot (was maxRewardsBps); do not reuse
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 private __deprecatedMaxRewardsBps;

    /// @notice Canonical destination for seized shares and withdrawal requests
    address public recoveryAddress;

    /// @dev Configured mode before applying Regular-mode expiry.
    /// @custom:oz-renamed-from marketMode
    MarketMode private _configuredMarketMode;

    /// @inheritdoc IStakedUSDat
    uint16 public override baseRedemptionFeeBps;

    /// @inheritdoc IStakedUSDat
    uint16 public override elevatedRedemptionFeeBps;

    /// @inheritdoc IStakedUSDat
    ISTRCMirrorModule public override strcMirrorModule;

    /// @inheritdoc IStakedUSDat
    ISTRConModule public override strconModule;

    /// @inheritdoc IStakedUSDat
    uint256 public override surplusVestingAmount;

    /// @inheritdoc IStakedUSDat
    uint256 public override surplusVestingStartTimestamp;

    /// @inheritdoc IStakedUSDat
    uint256 public override surplusVestingPeriod;

    /// @inheritdoc IStakedUSDat
    ISTRConExecutionPolicy public override executionPolicy;

    /// @inheritdoc IStakedUSDat
    uint16 public migrationToleranceBps;

    /// @inheritdoc IStakedUSDat
    uint64 public override regularModeValidUntil;

    /// @dev Portion of the active surplus tranche already folded into usdatBalance.
    uint256 private _surplusSwept;

    modifier notZero(uint256 amount) {
        _notZero(amount);
        _;
    }

    modifier whenNotRestrictedMarketMode() {
        _requireNotRestrictedMarketMode();
        _;
    }

    /// @dev Contract-relationship gate: immutable address check, deliberately not a
    /// grantable role.
    modifier onlyWithdrawalQueue() {
        _requireWithdrawalQueue();
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

    /// @dev Reverts if the given amount is zero.
    function _notZero(uint256 amount) internal pure {
        require(amount != 0, ZeroAmount());
    }

    function _requireNotRestrictedMarketMode() internal view {
        require(marketMode() != MarketMode.Restricted, MarketRestricted());
    }

    function _requireWithdrawalQueue() internal view {
        require(msg.sender == address(WITHDRAWAL_QUEUE), OperationNotAllowed());
    }

    /// @dev Reverts once the caller-supplied execution deadline has passed.
    function _requireUnexpiredDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, DeadlineExpired());
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IWithdrawalQueueERC721 withdrawalQueue) {
        require(address(withdrawalQueue) != address(0), InvalidZeroAddress());
        WITHDRAWAL_QUEUE = withdrawalQueue;
        _disableInitializers();
    }

    /// @notice Initializes the contract (called once via proxy)
    /// @dev Grants only DEFAULT_ADMIN_ROLE; the admin grants the operational roles (§2.8)
    /// after deployment.
    /// @param defaultAdmin The default admin of the contract
    /// @param usdat USDat contract address
    function initialize(address defaultAdmin, IERC20 usdat) external initializer {
        require(defaultAdmin != address(0) && address(usdat) != address(0), InvalidZeroAddress());

        __AccessControl_init();
        __Pausable_init();
        __ERC20_init("Staked USDat", "sUSDat");
        __ERC20Permit_init("Staked USDat");
        __ERC4626_init(usdat);

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
    }

    /// @inheritdoc IStakedUSDat
    function initializeV2(V2Config calldata config, V2Roles calldata roles)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        reinitializer(2)
    {
        _validateV2Modules(config);

        config.strcMirrorModule
            .seed(
                __deprecatedStrcBalance,
                __deprecatedVestingAmount,
                __deprecatedLastDistributionTimestamp,
                __deprecatedVestingPeriod,
                __deprecatedMaxRewardsBps
            );

        strcMirrorModule = config.strcMirrorModule;
        strconModule = config.strconModule;
        executionPolicy = config.executionPolicy;
        _setRecoveryAddress(config.recoveryAddress);
        _setRedemptionFees(config.baseRedemptionFeeBps, config.elevatedRedemptionFeeBps);
        _setElevatedDepositFee(config.elevatedDepositFeeBps);
        _setMigrationTolerance(config.migrationToleranceBps);
        surplusVestingPeriod = 3 days;
        _configuredMarketMode = MarketMode.Elevated;
        regularModeValidUntil = 0;
        config.executionPolicy
            .initialize(
                config.executionVehicle,
                config.executionToleranceBps,
                config.initialExecutionCapacity,
                config.initialExecutionRefillPerDay
            );

        _grantV2Role(PARAMETER_MANAGER_ROLE, roles.parameterManager);
        _grantV2Role(MARKET_MODE_MANAGER_ROLE, roles.marketModeManager);
        _grantV2Role(OPERATOR_ROLE, roles.operator);
        _grantV2Role(BLACKLISTER_ROLE, roles.blacklister);
        _grantV2Role(ENFORCER_ROLE, roles.enforcer);
        _grantV2Role(PAUSER_ROLE, roles.pauser);
        _grantV2Role(UNPAUSER_ROLE, roles.unpauser);
    }

    function _grantV2Role(bytes32 role, address holder) private {
        require(holder != address(0), InvalidZeroAddress());
        _grantRole(role, holder);
    }

    /// @dev Validates the fixed module bindings, which have no reusable setters.
    function _validateV2Modules(V2Config calldata config) private view {
        require(
            config.strcMirrorModule.VAULT() == address(this) && config.strconModule.VAULT() == address(this)
                && config.strconModule.balance() == 0 && config.executionPolicy.VAULT() == address(this)
                && address(config.executionPolicy.STRCON_MODULE()) == address(config.strconModule),
            InvalidModule()
        );
    }

    /// @dev Authorizes an upgrade to a new implementation. Only callable by DEFAULT_ADMIN_ROLE.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ Blacklist Functions ============

    /// @inheritdoc IStakedUSDat
    function addToBlacklist(address target) external onlyRole(BLACKLISTER_ROLE) {
        require(!hasRole(DEFAULT_ADMIN_ROLE, target), CannotBlacklistAdmin());
        require(!_blacklisted[target], AddressBlacklisted());
        _blacklisted[target] = true;
        emit Blacklisted(target);
    }

    /// @inheritdoc IStakedUSDat
    function removeFromBlacklist(address target) external onlyRole(BLACKLISTER_ROLE) {
        require(_blacklisted[target], AddressNotBlacklisted());
        _blacklisted[target] = false;
        emit UnBlacklisted(target);
    }

    /// @dev Reverts if the given account is blacklisted on sUSDat or frozen on USDat.
    function _requireNotRestricted(address account) internal view {
        require(!isRestricted(account), AddressBlacklisted());
    }

    /// @inheritdoc IStakedUSDat
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    /// @inheritdoc IStakedUSDat
    function isRestricted(address account) public view returns (bool) {
        return _blacklisted[account] || IUSDat(asset()).isFrozen(account);
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 amount) public override(ERC20Upgradeable, IERC20) returns (bool) {
        _requireNotRestricted(msg.sender);
        _requireNotRestricted(to);
        return super.transfer(to, amount);
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 amount)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        _requireNotRestricted(msg.sender);
        _requireNotRestricted(from);
        _requireNotRestricted(to);
        return super.transferFrom(from, to, amount);
    }

    // ============ ERC4626 Overrides ============

    /// @inheritdoc IERC4626
    /// @dev Adds cash, vested surplus, and both fixed module values.
    /// Module pricing failures deliberately propagate.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 vestedSurplus = _unsweptSurplus() - getUnvestedSurplus();
        return usdatBalance + vestedSurplus + strcMirrorModule.recognizedValue() + strconModule.recognizedValue();
    }

    /// @inheritdoc IStakedUSDat
    function getUnvestedSurplus() public view returns (uint256) {
        uint256 amount = surplusVestingAmount;
        if (amount == 0) return 0;

        uint256 period = surplusVestingPeriod;
        uint256 elapsed = block.timestamp - surplusVestingStartTimestamp;
        if (elapsed >= period) return 0;

        return Math.mulDiv(period - elapsed, amount, period, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return 18;
    }

    /// @dev Returns a non-zero offset to protect against ERC4626 inflation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    /// @inheritdoc IERC4626
    /// @dev Applies the mode-derived fee to gross assets, rounding the fee up.
    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 feeBps = depositFeeBps();
        if (feeBps == 0) return super.previewDeposit(assets);

        uint256 fee = Math.mulDiv(assets, feeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        return super.previewDeposit(assets - fee);
    }

    /// @inheritdoc IERC4626
    /// @dev Grosses up the net assets required for the requested shares.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 netAssets = super.previewMint(shares);
        uint256 feeBps = depositFeeBps();
        if (feeBps == 0) return netAssets;

        return Math.mulDiv(netAssets, BPS_DENOMINATOR, BPS_DENOMINATOR - feeBps, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 when paused, deposits are restricted, or NAV cannot be priced.
    function maxDeposit(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (isRestricted(receiver) || paused() || marketMode() == MarketMode.Restricted) return 0;
        return _canPriceTotalAssets() ? type(uint256).max : 0;
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 when paused, mints are restricted, or NAV cannot be priced.
    function maxMint(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (isRestricted(receiver) || paused() || marketMode() == MarketMode.Restricted) return 0;
        return _canPriceTotalAssets() ? type(uint256).max : 0;
    }

    /// @inheritdoc IERC4626
    /// @dev Always returns 0 - use requestRedeem instead.
    function maxWithdraw(address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return 0;
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 when the owner is restricted or the vault is paused per ERC4626 spec.
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return (isRestricted(owner) || paused()) ? 0 : balanceOf(owner);
    }

    // ============ Surplus Functions ============

    /// @inheritdoc IStakedUSDat
    function transferInSurplus(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        notZero(amount)
    {
        _sweep();
        require(surplusVestingAmount == 0, StillVesting());

        uint256 maximumSurplus = Math.mulDiv(totalAssets(), MAX_SURPLUS_BPS, BPS_DENOMINATOR);
        require(amount <= maximumSurplus, SurplusExceedsMax());

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        surplusVestingAmount = amount;
        surplusVestingStartTimestamp = block.timestamp;

        emit SurplusReceived(amount);
    }

    /// @inheritdoc IStakedUSDat
    function sweep() external nonReentrant {
        _sweep();
    }

    /// @dev Moves newly vested surplus into the spendable USDat balance.
    function _sweep() private {
        uint256 amount = surplusVestingAmount;
        if (amount == 0) return;

        uint256 unvested = getUnvestedSurplus();
        uint256 vested = amount - unvested;
        uint256 releasable = vested - _surplusSwept;

        if (releasable != 0) {
            _surplusSwept = vested;
            usdatBalance += releasable;

            emit SurplusSwept(releasable);
        }

        if (unvested == 0) {
            surplusVestingAmount = 0;
            _surplusSwept = 0;
        }
    }

    /// @dev Returns the portion of the active tranche not yet folded into usdatBalance.
    function _unsweptSurplus() private view returns (uint256) {
        return surplusVestingAmount - _surplusSwept;
    }

    // ============ Migration Functions ============

    /// @inheritdoc IStakedUSDat
    function migrate(uint256 expectedStrcon, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
        notZero(expectedStrcon)
    {
        _requireUnexpiredDeadline(deadline);
        require(strconModule.balance() == 0, InvalidModule());
        STRConTradeExecutionLogic.executeMigration(
            strcMirrorModule, strconModule, executionPolicy.executionVehicle(), expectedStrcon, migrationToleranceBps
        );
    }

    // ============ Rotation Functions ============

    /// @inheritdoc IStakedUSDat
    function buy(uint256 usdatPaid, uint256 assetReceived, address expectedVehicle, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        whenNotRestrictedMarketMode
        onlyRole(OPERATOR_ROLE)
        notZero(usdatPaid)
        notZero(assetReceived)
    {
        _requireUnexpiredDeadline(deadline);
        _sweep();
        require(usdatBalance >= usdatPaid, InsufficientBalance());

        // Rotations fail closed when either fixed module cannot price (§2.2).
        totalAssets();

        usdatBalance -= usdatPaid;
        STRConTradeExecutionLogic.executeBuy(
            executionPolicy,
            IERC20(asset()),
            strconModule,
            expectedVehicle,
            usdatPaid,
            assetReceived,
            usdatBalance,
            _unsweptSurplus()
        );
    }

    /// @inheritdoc IStakedUSDat
    function sell(uint256 assetDelivered, uint256 usdatReceived, address expectedVehicle, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        whenNotRestrictedMarketMode
        onlyRole(OPERATOR_ROLE)
        notZero(assetDelivered)
        notZero(usdatReceived)
    {
        _requireUnexpiredDeadline(deadline);
        _sweep();

        // Rotations fail closed when either fixed module cannot price (§2.2).
        totalAssets();

        usdatBalance += usdatReceived;
        STRConTradeExecutionLogic.executeSell(
            executionPolicy,
            IERC20(asset()),
            strconModule,
            expectedVehicle,
            assetDelivered,
            usdatReceived,
            usdatBalance,
            _unsweptSurplus()
        );
    }

    // ============ Deposit Functions ============

    /// @dev Deposit/mint common workflow with account-restriction checks.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        whenNotRestrictedMarketMode
        notZero(assets)
        notZero(shares)
    {
        _requireNotRestricted(caller);
        _requireNotRestricted(receiver);

        _sweep();
        usdatBalance += assets;

        super._deposit(caller, receiver, assets, shares);
    }

    /// @inheritdoc IStakedUSDat
    function depositWithMinShares(uint256 assets, address receiver, uint256 minShares) public returns (uint256 shares) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        shares = previewDeposit(assets);
        require(shares >= minShares, SlippageExceeded());
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IStakedUSDat
    function mintWithMaxAssets(uint256 shares, address receiver, uint256 maxAssets) public returns (uint256 assets) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }
        assets = previewMint(shares);
        require(assets <= maxAssets, SlippageExceeded());
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev Uses try-catch to handle permit front-running gracefully. If permit fails
    /// (e.g., already used by front-runner), the deposit proceeds if allowance is sufficient.
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares) {
        try IERC20PermitExtended(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s) {} catch {}

        return depositWithMinShares(assets, receiver, minShares);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev Uses try-catch to handle permit front-running gracefully. If permit fails
    /// (e.g., already used by front-runner), the mint proceeds if allowance is sufficient.
    function mintWithPermit(
        uint256 shares,
        address receiver,
        uint256 maxAssets,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 assets) {
        try IERC20PermitExtended(asset()).permit(msg.sender, address(this), maxAssets, deadline, v, r, s) {} catch {}

        return mintWithMaxAssets(shares, receiver, maxAssets);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev EIP-1271 compatible permit for smart contract wallets (e.g., Gnosis Safe, Argent).
    /// Uses try-catch to handle permit front-running gracefully.
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline,
        bytes memory signature
    ) external returns (uint256 shares) {
        try IERC20PermitExtended(asset()).permit(msg.sender, address(this), assets, deadline, signature) {} catch {}

        return depositWithMinShares(assets, receiver, minShares);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev EIP-1271 compatible permit for smart contract wallets (e.g., Gnosis Safe, Argent).
    /// Uses try-catch to handle permit front-running gracefully.
    function mintWithPermit(
        uint256 shares,
        address receiver,
        uint256 maxAssets,
        uint256 deadline,
        bytes memory signature
    ) external returns (uint256 assets) {
        try IERC20PermitExtended(asset()).permit(msg.sender, address(this), maxAssets, deadline, signature) {} catch {}

        return mintWithMaxAssets(shares, receiver, maxAssets);
    }

    // ============ Withdrawal Functions ============

    /// @inheritdoc IERC4626
    /// @dev Returns zero because exact-asset withdrawals are disabled.
    function previewWithdraw(uint256) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return 0;
    }

    /// @inheritdoc IERC4626
    /// @dev Returns the net queued-redemption payout after the active fee.
    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 net) {
        return _quoteQueuedRedemption(shares, totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset());
    }

    /// @inheritdoc IERC4626
    /// @dev Disabled - use requestRedeem instead.
    function withdraw(uint256, address, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert OperationNotAllowed();
    }

    /// @inheritdoc IERC4626
    /// @dev Disabled - use requestRedeem instead.
    function redeem(uint256, address, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert OperationNotAllowed();
    }

    /// @inheritdoc IStakedUSDat
    /// @dev Never prices.
    function requestRedeem(uint256 shares, uint256 minSharePrice) external returns (uint256 requestId) {
        uint256 maxShares = maxRedeem(msg.sender);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxShares);
        }

        requestId = _processWithdrawal(msg.sender, msg.sender, shares, minSharePrice);
    }

    /// @inheritdoc IStakedUSDat
    function beginRedemptionBatch()
        external
        nonReentrant
        onlyWithdrawalQueue
        whenNotPaused
        whenNotRestrictedMarketMode
    {
        require(_redemptionBatchShareBasis == 0, InvalidRedemptionBatch());

        _sweep();
        _redemptionBatchAssetBasis = totalAssets() + 1;
        _redemptionBatchShareBasis = totalSupply() + 10 ** _decimalsOffset();
    }

    /// @dev Processes a withdrawal request by escrowing shares in the withdrawal queue.
    function _processWithdrawal(address caller, address owner, uint256 shares, uint256 minSharePrice)
        internal
        nonReentrant
        returns (uint256 requestId)
    {
        _requireNotRestricted(caller);
        _requireNotRestricted(owner);
        require(shares >= MIN_REQUEST_SHARES, WithdrawalTooSmall());

        _transfer(owner, address(WITHDRAWAL_QUEUE), shares);

        requestId = WITHDRAWAL_QUEUE.addRequest(owner, shares, minSharePrice);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev The queue's single settlement primitive: price, deduct the fee, validate
    /// the net payout per share, burn, and transfer a complete request in one call.
    /// The fee stays in the vault and immediately accrues to the remaining shares.
    function redeemQueuedShares(uint256 shares, uint256 minSharePrice)
        external
        nonReentrant
        onlyWithdrawalQueue
        whenNotPaused
        whenNotRestrictedMarketMode
        notZero(shares)
        returns (RedemptionResult result, uint256 net)
    {
        uint256 shareBasis = _redemptionBatchShareBasis;
        require(shareBasis != 0, InvalidRedemptionBatch());

        net = _quoteQueuedRedemption(shares, _redemptionBatchAssetBasis, shareBasis);

        uint256 netSharePrice = Math.mulDiv(net, 1e18, shares, Math.Rounding.Floor);
        if (netSharePrice < minSharePrice) {
            return (RedemptionResult.BelowLimit, 0);
        }

        if (usdatBalance < net) {
            return (RedemptionResult.InsufficientLiquidity, 0);
        }

        usdatBalance -= net;
        _burn(address(WITHDRAWAL_QUEUE), shares);

        IERC20(asset()).safeTransfer(address(WITHDRAWAL_QUEUE), net);

        return (RedemptionResult.Settled, net);
    }

    /// @inheritdoc IStakedUSDat
    function endRedemptionBatch() external onlyWithdrawalQueue {
        require(_redemptionBatchShareBasis != 0, InvalidRedemptionBatch());

        _redemptionBatchShareBasis = 0;
        _redemptionBatchAssetBasis = 0;
    }

    /// @dev Returns the net payout using one exact ERC4626 conversion basis and the active fee tier.
    function _quoteQueuedRedemption(uint256 shares, uint256 assetBasis, uint256 shareBasis)
        private
        view
        returns (uint256 net)
    {
        uint256 gross = Math.mulDiv(shares, assetBasis, shareBasis, Math.Rounding.Floor);
        uint256 fee = Math.mulDiv(gross, redemptionFeeBps(), BPS_DENOMINATOR, Math.Rounding.Ceil);
        net = gross - fee;
    }

    /// @inheritdoc IStakedUSDat
    function redemptionFeeBps() public view returns (uint16) {
        return marketMode() == MarketMode.Regular ? baseRedemptionFeeBps : elevatedRedemptionFeeBps;
    }

    /// @inheritdoc IStakedUSDat
    function depositFeeBps() public view returns (uint256) {
        return marketMode() == MarketMode.Regular ? 0 : elevatedDepositFeeBps;
    }

    /// @dev Returns whether every fixed NAV leg can currently be priced.
    function _canPriceTotalAssets() private view returns (bool) {
        try this.totalAssets() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IStakedUSDat
    function getWithdrawalQueue() external view returns (address) {
        return address(WITHDRAWAL_QUEUE);
    }

    // ========== Enforcer Functions ==========

    /// @inheritdoc IStakedUSDat
    /// @dev Moves shares from a locally blacklisted holder, no burn, no liquidity needed —
    /// value-preserving enforcement (e.g. court-directed recovery). A USDat freeze alone
    /// does not authorize seizure.
    function seize(address from) external nonReentrant onlyRole(ENFORCER_ROLE) whileUnpaused {
        require(_blacklisted[from], AddressNotBlacklisted());

        uint256 amount = balanceOf(from);
        require(amount > 0, ZeroAmount());

        address to = recoveryAddress;
        _requireValidRecoveryAddress(to);

        _transfer(from, to, amount);

        emit Seized(from, to, amount);
    }

    /// @inheritdoc IStakedUSDat
    function rescueTokens(address token, uint256 amount) external nonReentrant onlyRole(ENFORCER_ROLE) {
        address to = recoveryAddress;
        _requireValidRecoveryAddress(to);

        uint256 protectedBalance;
        if (token == asset()) {
            protectedBalance = usdatBalance + _unsweptSurplus();
        }

        ISTRConModule module = strconModule;
        if (token == module.asset()) {
            protectedBalance += module.balance();
        }

        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        require(actualBalance >= protectedBalance, ExceedsRescuable());
        require(amount <= actualBalance - protectedBalance, ExceedsRescuable());

        IERC20(token).safeTransfer(to, amount);
    }

    // ============ Admin Functions ============

    /// @inheritdoc IStakedUSDat
    function setRecoveryAddress(address newRecoveryAddress) external onlyRole(PARAMETER_MANAGER_ROLE) {
        _setRecoveryAddress(newRecoveryAddress);
    }

    /// @inheritdoc IStakedUSDat
    function setMigrationTolerance(uint16 newBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        _setMigrationTolerance(newBps);
    }

    function _setMigrationTolerance(uint16 newBps) private {
        require(newBps <= MAX_MIGRATION_TOLERANCE_BPS, InvalidMigrationTolerance());
        uint16 oldBps = migrationToleranceBps;
        migrationToleranceBps = newBps;

        emit MigrationToleranceUpdated(oldBps, newBps);
    }

    /// @inheritdoc IStakedUSDat
    function setMarketMode(MarketMode newMode) external onlyRole(MARKET_MODE_MANAGER_ROLE) {
        require(newMode != MarketMode.Regular, InvalidRegularModeAuthorization());

        MarketMode oldMode = marketMode();
        _configuredMarketMode = newMode;
        regularModeValidUntil = 0;

        emit MarketModeChanged(oldMode, newMode);
    }

    /// @inheritdoc IStakedUSDat
    function authorizeRegularMode(uint64 validUntil) external onlyRole(MARKET_MODE_MANAGER_ROLE) {
        _authorizeRegularMode(validUntil);
    }

    /// @dev Installs a fresh bounded Regular-mode authorization.
    function _authorizeRegularMode(uint64 validUntil) private {
        require(
            block.timestamp < validUntil && validUntil <= block.timestamp + MAX_REGULAR_MODE_VALIDITY,
            InvalidRegularModeAuthorization()
        );

        MarketMode oldMode = marketMode();
        _configuredMarketMode = MarketMode.Regular;
        regularModeValidUntil = validUntil;

        emit MarketModeChanged(oldMode, MarketMode.Regular);
        emit RegularModeAuthorized(validUntil);
    }

    /// @inheritdoc IStakedUSDat
    function setRedemptionFees(uint16 baseBps, uint16 elevatedBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        _setRedemptionFees(baseBps, elevatedBps);
    }

    /// @inheritdoc IStakedUSDat
    function setElevatedDepositFee(uint256 newFeeBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        _setElevatedDepositFee(newFeeBps);
    }

    /// @inheritdoc IStakedUSDat
    function setSurplusVestingPeriod(uint256 newPeriod) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(newPeriod != 0 && newPeriod <= MAX_SURPLUS_VESTING_PERIOD, InvalidVestingPeriod());

        _sweep();
        require(surplusVestingAmount == 0, StillVesting());

        uint256 oldPeriod = surplusVestingPeriod;
        surplusVestingPeriod = newPeriod;

        emit SurplusVestingPeriodUpdated(oldPeriod, newPeriod);
    }

    /// @dev Validates and updates both redemption fee tiers.
    function _setRedemptionFees(uint16 baseBps, uint16 elevatedBps) internal {
        require(baseBps <= elevatedBps && elevatedBps <= MAX_REDEMPTION_FEE_BPS, InvalidFee());
        baseRedemptionFeeBps = baseBps;
        elevatedRedemptionFeeBps = elevatedBps;

        emit RedemptionFeesUpdated(baseBps, elevatedBps);
    }

    /// @dev Validates and updates the elevated deposit fee.
    function _setElevatedDepositFee(uint256 newFeeBps) internal {
        require(newFeeBps <= MAX_DEPOSIT_FEE_BPS, InvalidFee());
        elevatedDepositFeeBps = newFeeBps;

        emit DepositFeeUpdated(newFeeBps);
    }

    /// @dev Validates and updates the canonical seizure destination.
    function _setRecoveryAddress(address newRecoveryAddress) internal {
        _requireValidRecoveryAddress(newRecoveryAddress);
        address oldRecoveryAddress = recoveryAddress;
        recoveryAddress = newRecoveryAddress;

        emit RecoveryAddressUpdated(oldRecoveryAddress, newRecoveryAddress);
    }

    /// @dev Reverts unless an address is a valid seizure destination now.
    function _requireValidRecoveryAddress(address account) internal view {
        require(account != address(0), InvalidZeroAddress());
        _requireNotRestricted(account);
    }

    /// @inheritdoc IStakedUSDat
    function marketMode() public view returns (MarketMode) {
        MarketMode configuredMode = _configuredMarketMode;
        if (configuredMode == MarketMode.Regular && block.timestamp >= regularModeValidUntil) {
            return MarketMode.Elevated;
        }
        return configuredMode;
    }

    /// @inheritdoc IStakedUSDat
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IStakedUSDat
    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    /// @dev Blocks all token movements when paused, except enforcement actions executed through whileUnpaused.
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) whenNotPaused {
        super._update(from, to, value);
    }
}
