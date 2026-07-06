// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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
import {IAccountingModule} from "./interfaces/IAccountingModule.sol";
import {IStakedUSDat} from "./interfaces/IStakedUSDat.sol";
import {IERC20PermitExtended} from "./interfaces/IERC20PermitExtended.sol";

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
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Role identifier for the operator (rotations, yield/reward inlets)
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role identifier for module registry management
    bytes32 public constant MODULE_MANAGER_ROLE = keccak256("MODULE_MANAGER_ROLE");

    /// @notice Role identifier for parameter tuning (fees, caps, cash floor)
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");

    /// @notice Role identifier for blacklist add/remove (freeze only, never moves funds)
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");

    /// @notice Role identifier for enforcement actions against blacklisted holders
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    /// @notice Role identifier for pausing (cannot unpause)
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role identifier for unpausing (cannot pause)
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    /// @notice Maximum number of registered modules (keeps totalAssets gas-bounded)
    uint256 public constant MAX_MODULES = 5;

    /// @dev The WithdrawalQueue contract (immutable, stored in implementation bytecode)
    IWithdrawalQueueERC721 private immutable WITHDRAWAL_QUEUE;

    /// @dev Mapping of blacklisted addresses
    mapping(address account => bool isBlacklisted) private _blacklisted;

    /// @dev Retired v1 slot (was vestingAmount); read once by initializeV2 to seed MirrorSTRC
    uint256 private __deprecated_vestingAmount;

    /// @dev Retired v1 slot (was lastDistributionTimestamp); read once by initializeV2 to seed MirrorSTRC
    uint256 private __deprecated_lastDistributionTimestamp;

    /// @dev Retired v1 slot (was vestingPeriod); read once by initializeV2 to seed MirrorSTRC
    uint256 private __deprecated_vestingPeriod;

    /// @notice Minimum withdrawal amount (10 USDat, 6 decimals)
    uint256 public constant MIN_WITHDRAWAL = 10e6;

    /// @dev Retired v1 slot (was toleranceBps); do not reuse
    uint256 private __deprecated_toleranceBps;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @dev Retired v1 slot (was depositFeeBps); do not reuse
    uint256 private __deprecated_depositFeeBps;

    /// @notice Address that receives protocol fees
    address public feeRecipient;

    /// @notice Internally tracked USDat balance (6 decimals)
    uint256 public usdatBalance;

    /// @dev Retired v1 slot (was strcBalance); read once by initializeV2 to seed MirrorSTRC
    uint256 private __deprecated_strcBalance;

    /// @dev Retired v1 slot (was maxRewardsBps); do not reuse
    uint256 private __deprecated_maxRewardsBps;

    /// @dev Registered accounting modules; totalAssets() iterates this set
    EnumerableSet.AddressSet private _modules;

    /// @dev Per-module configuration
    mapping(address module => ModuleConfig) private _moduleConfigs;

    /// @notice Global cash floor in basis points of totalAssets (governs rotations and
    /// deposit deployment only; queue processing may draw the buffer to zero)
    uint16 public minCashBufferBps;

    modifier notZero(uint256 amount) {
        _notZero(amount);
        _;
    }

    /// @dev Contract-relationship gate: immutable address check, deliberately not a
    /// grantable role.
    modifier onlyWithdrawalQueue() {
        require(msg.sender == address(WITHDRAWAL_QUEUE), OperationNotAllowed());
        _;
    }

    /// @dev Reverts if the given amount is zero.
    function _notZero(uint256 amount) internal pure {
        require(amount != 0, ZeroAmount());
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
    /// @param protocolFeeRecipient The address that receives protocol fees
    /// @param usdat USDat contract address
    function initialize(address defaultAdmin, address protocolFeeRecipient, IERC20 usdat) external initializer {
        require(defaultAdmin != address(0) && address(usdat) != address(0), InvalidZeroAddress());

        __AccessControl_init();
        __Pausable_init();
        __ERC20_init("Staked USDat", "sUSDat");
        __ERC20Permit_init("Staked USDat");
        __ERC4626_init(usdat);

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        feeRecipient = protocolFeeRecipient;
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

    /// @dev Reverts if the given account is blacklisted.
    function _requireNotBlacklisted(address account) internal view {
        require(!_blacklisted[account], AddressBlacklisted());
    }

    /// @inheritdoc IStakedUSDat
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 amount) public override(ERC20Upgradeable, IERC20) returns (bool) {
        _requireNotBlacklisted(msg.sender);
        _requireNotBlacklisted(to);
        return super.transfer(to, amount);
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 amount)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        _requireNotBlacklisted(from);
        _requireNotBlacklisted(to);
        return super.transferFrom(from, to, amount);
    }

    /// @inheritdoc IStakedUSDat
    function redistributeLockedAmount(address from) external nonReentrant onlyRole(ENFORCER_ROLE) {
        require(_blacklisted[from], AddressNotBlacklisted());
        uint256 amountToDistribute = balanceOf(from);

        require(amountToDistribute > 0, ZeroAmount());
        require(totalSupply() > amountToDistribute, NoRecipientsForRedistribution());

        bool wasPaused = paused();
        if (wasPaused) _unpause();
        _burn(from, amountToDistribute);
        if (wasPaused) _pause();

        emit LockedAmountRedistributed(from, amountToDistribute);
    }

    // ============ ERC4626 Overrides ============

    /// @inheritdoc IERC4626
    /// @dev Idle USDat plus the recognized value of every registered module. Reverts
    /// when any module cannot reliably price — fail-closed for every value-sensitive path.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 total = usdatBalance;

        uint256 count = _modules.length();
        for (uint256 i = 0; i < count; i++) {
            total += IAccountingModule(_modules.at(i)).recognizedValue();
        }

        return total;
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
    /// @dev Returns 0 when paused or when any module cannot price (max* functions must
    /// not revert per ERC4626).
    function maxDeposit(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        try this.totalAssets() returns (uint256) {
            return type(uint256).max;
        } catch {
            return 0;
        }
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 when paused or when any module cannot price (max* functions must
    /// not revert per ERC4626).
    function maxMint(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        try this.totalAssets() returns (uint256) {
            return type(uint256).max;
        } catch {
            return 0;
        }
    }

    /// @inheritdoc IERC4626
    /// @dev Always returns 0 - use requestRedeem instead.
    function maxWithdraw(address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return 0;
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 when paused per ERC4626 spec.
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return paused() ? 0 : balanceOf(owner);
    }

    // ============ Asset Management Functions ============

    /// @inheritdoc IStakedUSDat
    /// @dev Sweeps only untracked excess: vault balance minus the cash leg (when token
    /// is USDat) minus balance() of every module whose asset() == token.
    function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 tracked = token == asset() ? usdatBalance : 0;

        uint256 count = _modules.length();
        for (uint256 i = 0; i < count; i++) {
            IAccountingModule module = IAccountingModule(_modules.at(i));
            if (module.asset() == token) {
                tracked += module.balance();
            }
        }

        require(amount <= IERC20(token).balanceOf(address(this)) - tracked, InsufficientBalance());

        IERC20(token).safeTransfer(to, amount);
    }

    // ============ Module Management ============

    /// @inheritdoc IStakedUSDat
    function registerModule(address module, uint16 maxWeightBps) external onlyRole(MODULE_MANAGER_ROLE) {
        require(module != address(0), InvalidZeroAddress());
        require(maxWeightBps <= BPS_DENOMINATOR, InvalidWeight());
        require(_modules.length() < MAX_MODULES, MaxModulesReached());
        require(_modules.add(module), ModuleAlreadyRegistered());

        _moduleConfigs[module] = ModuleConfig({maxWeightBps: maxWeightBps});

        emit ModuleRegistered(module, maxWeightBps);
    }

    /// @inheritdoc IStakedUSDat
    function setMaxWeight(address module, uint16 maxWeightBps) external onlyRole(MODULE_MANAGER_ROLE) {
        require(_modules.contains(module), ModuleNotRegistered());
        require(maxWeightBps <= BPS_DENOMINATOR, InvalidWeight());

        _moduleConfigs[module].maxWeightBps = maxWeightBps;

        emit ModuleMaxWeightUpdated(module, maxWeightBps);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev Only when balance() == 0 — checked without pricing, so an empty module with
    /// a dead oracle stays removable. Real removal; config cleared.
    function deregisterModule(address module) external onlyRole(MODULE_MANAGER_ROLE) {
        require(_modules.contains(module), ModuleNotRegistered());
        require(IAccountingModule(module).balance() == 0, ModuleBalanceNotZero());

        _modules.remove(module);
        delete _moduleConfigs[module];

        emit ModuleDeregistered(module);
    }

    /// @inheritdoc IStakedUSDat
    function setMinCashBuffer(uint16 newMinCashBufferBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(newMinCashBufferBps <= BPS_DENOMINATOR, InvalidWeight());

        minCashBufferBps = newMinCashBufferBps;

        emit MinCashBufferUpdated(newMinCashBufferBps);
    }

    /// @inheritdoc IStakedUSDat
    function getModules() external view returns (address[] memory) {
        return _modules.values();
    }

    /// @inheritdoc IStakedUSDat
    function moduleConfig(address module) external view returns (ModuleConfig memory) {
        return _moduleConfigs[module];
    }

    // ============ Rotations ============

    /// @inheritdoc IStakedUSDat
    /// @dev Per-call exact-amount approval; the buy may not push the module above its
    /// maxWeightBps or cash below minCashBufferBps.
    function buyVia(address module, uint256 usdatIn, uint256 minAssetOut, bytes calldata venueData)
        external
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        notZero(usdatIn)
        returns (uint256 assetOut)
    {
        require(_modules.contains(module), ModuleNotRegistered());
        require(usdatBalance >= usdatIn, InsufficientBalance());

        usdatBalance -= usdatIn;

        IERC20(asset()).forceApprove(module, usdatIn);
        assetOut = IAccountingModule(module).buy(usdatIn, minAssetOut, venueData);
        IERC20(asset()).forceApprove(module, 0);

        uint256 total = totalAssets();
        uint256 maxModuleValue = Math.mulDiv(total, _moduleConfigs[module].maxWeightBps, BPS_DENOMINATOR);
        require(IAccountingModule(module).recognizedValue() <= maxModuleValue, MaxWeightExceeded());
        require(usdatBalance >= Math.mulDiv(total, minCashBufferBps, BPS_DENOMINATOR), CashBufferBreached());
    }

    /// @inheritdoc IStakedUSDat
    /// @dev Sells are never blocked: no weight or cash-floor checks.
    function sellVia(address module, uint256 assetIn, uint256 minUsdatOut, bytes calldata venueData)
        external
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        notZero(assetIn)
        returns (uint256 usdatOut)
    {
        require(_modules.contains(module), ModuleNotRegistered());

        address moduleAsset = IAccountingModule(module).asset();

        if (moduleAsset != address(0)) {
            IERC20(moduleAsset).forceApprove(module, assetIn);
        }
        usdatOut = IAccountingModule(module).sell(assetIn, minUsdatOut, venueData);
        if (moduleAsset != address(0)) {
            IERC20(moduleAsset).forceApprove(module, 0);
        }

        usdatBalance += usdatOut;
    }

    // ============ Deposit Functions ============

    /// @dev Deposit/mint common workflow with blacklist checks.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        _requireNotBlacklisted(caller);
        _requireNotBlacklisted(receiver);

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
    function requestRedeem(uint256 shares, uint256 minUsdatReceived) external returns (uint256 requestId) {
        uint256 maxShares = maxRedeem(msg.sender);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);

        requestId = _processWithdrawal(msg.sender, msg.sender, assets, shares, minUsdatReceived);
    }

    /// @dev Processes a withdrawal request by escrowing shares in the withdrawal queue.
    function _processWithdrawal(address caller, address owner, uint256 assets, uint256 shares, uint256 minUsdatReceived)
        internal
        nonReentrant
        notZero(assets)
        notZero(shares)
        returns (uint256 requestId)
    {
        _requireNotBlacklisted(caller);
        _requireNotBlacklisted(owner);
        require(assets >= MIN_WITHDRAWAL, WithdrawalTooSmall());

        _transfer(owner, address(WITHDRAWAL_QUEUE), shares);

        requestId = WITHDRAWAL_QUEUE.addRequest(owner, shares, minUsdatReceived);
    }

    // ============ View Functions ============

    /// @inheritdoc IStakedUSDat
    function getWithdrawalQueue() external view returns (address) {
        return address(WITHDRAWAL_QUEUE);
    }

    // ============ Admin Functions ============

    /// @inheritdoc IStakedUSDat
    function setFeeRecipient(address newRecipient) external onlyRole(PARAMETER_MANAGER_ROLE) {
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(newRecipient);
    }

    /// @inheritdoc IStakedUSDat
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IStakedUSDat
    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    /// @dev Blocks all token movements when paused, except burns from blacklisted addresses by DEFAULT_ADMIN_ROLE.
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) whenNotPaused {
        super._update(from, to, value);
    }
}
