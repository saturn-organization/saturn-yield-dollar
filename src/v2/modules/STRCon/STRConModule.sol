// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IAccountingModule} from "../../interfaces/IAccountingModule.sol";
import {IExchanger} from "../../interfaces/IExchanger.sol";
import {STRConPriceOracle} from "./STRConPriceOracle.sol";

/**
 * @title STRConModule
 * @author Saturn
 * @notice Durable accounting module for Ondo's tokenized STRC (STRCon). Marked to
 * market, no vesting (§2.3); `balance` is a recognized counter under the custody
 * floor `STRCON.balanceOf(vault) >= balance`.
 * @dev buy/sell execute atomically on-chain through a swappable, low-trust exchanger:
 * the module measures delivery as its own balance delta, bounds it by the caller's
 * minimum, and validates the realized end-to-end price against the oracle within
 * toleranceBps. Not upgradeable — a module is replaced by deregistering it, never
 * upgraded; venue changes are exchanger re-points. Access control resolves against
 * the vault's role registry; the module defines no roles of its own.
 */
contract STRConModule is IAccountingModule {
    using SafeERC20 for IERC20;

    // ============ Errors ============

    error NotImplemented();
    error InvalidZeroAddress();
    error NotVault();
    error Unauthorized();
    error SlippageExceeded();
    error OraclePriceMismatch();
    error CustodyFloorBreached();
    error InvalidTolerance();
    error InsufficientBalance();

    // ============ Events ============

    /// @dev Emitted on a vault-driven buy.
    event Bought(uint256 usdatIn, uint256 strconOut);
    /// @dev Emitted on a vault-driven sell.
    event Sold(uint256 strconIn, uint256 usdatOut);
    /// @dev Emitted when the exchanger is re-pointed.
    event ExchangerUpdated(address oldExchanger, address newExchanger);
    /// @dev Emitted when the realized-price tolerance is updated.
    event ToleranceUpdated(uint256 newToleranceBps);

    // ============ Constants ============

    /// @notice Vault admin role id (AccessControl DEFAULT_ADMIN_ROLE)
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Role id on the vault authorized to tune module parameters
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum tolerance (100%)
    uint256 public constant MAX_TOLERANCE_BPS = 10000;

    /// @notice Minimum tolerance (1%)
    uint256 public constant MIN_TOLERANCE_BPS = 100;

    // ============ Immutables ============

    /// @notice The StakedUSDat vault this module accounts for
    address public immutable VAULT;

    /// @notice The USDat token
    IERC20 public immutable USDAT;

    /// @notice The STRCon token (18 decimals), custodied in the vault
    IERC20 public immutable STRCON;

    /// @notice The validated STRCon price oracle (two-feed wrapper)
    STRConPriceOracle public immutable ORACLE;

    // ============ Storage ============

    /// @notice Recognized STRCon quantity (18 decimals) — a counter written only by
    /// authorized flows, never a live balanceOf; the vault's actual holding is a
    /// floor: STRCON.balanceOf(vault) >= balance. Public getter implements
    /// IAccountingModule.balance().
    uint256 public balance;

    /// @notice The swappable USDat <-> STRCon execution route. Low-trust: the module
    /// measures delivery and validates the realized price itself.
    IExchanger public exchanger;

    /// @notice Tolerance in basis points for realized-price validation vs the oracle
    uint256 public toleranceBps;

    // ============ Modifiers ============

    modifier onlyVault() {
        _requireVault();
        _;
    }

    modifier onlyVaultRole(bytes32 role) {
        _requireVaultRole(role);
        _;
    }

    function _requireVault() internal view {
        require(msg.sender == VAULT, NotVault());
    }

    function _requireVaultRole(bytes32 role) internal view {
        require(IAccessControl(VAULT).hasRole(role, msg.sender), Unauthorized());
    }

    constructor(address vault, STRConPriceOracle oracle, IERC20 strcon, IERC20 usdat, IExchanger exchanger_) {
        require(
            vault != address(0) && address(oracle) != address(0) && address(strcon) != address(0)
                && address(usdat) != address(0),
            InvalidZeroAddress()
        );
        VAULT = vault;
        ORACLE = oracle;
        STRCON = strcon;
        USDAT = usdat;

        _setExchanger(exchanger_);

        toleranceBps = 500; // 5% initial; realized route cost measured in §3.2 diligence
    }

    // ============ IAccountingModule ============

    /// @inheritdoc IAccountingModule
    /// @dev Recognized balance at the validated oracle price, floor-rounded. Marked
    /// to market — no vesting. Returns 0 without pricing when balance == 0, so an
    /// empty module never bricks totalAssets() and stays deregistrable under a dead
    /// oracle.
    function recognizedValue() external view returns (uint256) {
        uint256 currentBalance = balance;
        if (currentBalance == 0) return 0;

        (uint256 price, uint8 priceDecimals) = ORACLE.getPrice();

        // balance (18 dec) × price (priceDecimals dec) → USD (6 dec):
        // divide by 10^(18 + priceDecimals − 6)
        return Math.mulDiv(currentBalance, price, 10 ** (12 + uint256(priceDecimals)));
    }

    /// @inheritdoc IAccountingModule
    function asset() external view returns (address) {
        return address(STRCON);
    }

    /// @inheritdoc IAccountingModule
    /// @dev Atomic on-chain acquisition through the exchanger (USDat → USDC → STRCon).
    /// The exchanger is untrusted: delivery is measured as the module's own balance
    /// delta, bounded by minAssetOut, and the realized price must sit within
    /// toleranceBps of the oracle. Recognition happens after delivery.
    function buy(uint256 usdatIn, uint256 minAssetOut, bytes calldata venueData)
        external
        onlyVault
        returns (uint256 assetOut)
    {
        IExchanger route = exchanger;

        // Fund the route: pull the vault's USDat (buyVia grants an exact-amount
        // approval) and let the exchanger draw it.
        USDAT.safeTransferFrom(VAULT, address(this), usdatIn);
        USDAT.forceApprove(address(route), usdatIn);

        uint256 strconBefore = STRCON.balanceOf(address(this));
        route.swapIn(usdatIn, minAssetOut, venueData);
        assetOut = STRCON.balanceOf(address(this)) - strconBefore; // measured, not trusted

        USDAT.forceApprove(address(route), 0);

        require(assetOut >= minAssetOut, SlippageExceeded());
        _checkRealizedPrice(usdatIn, assetOut);

        balance += assetOut;
        STRCON.safeTransfer(VAULT, assetOut);
        require(STRCON.balanceOf(VAULT) >= balance, CustodyFloorBreached());

        emit Bought(usdatIn, assetOut);
    }

    /// @inheritdoc IAccountingModule
    /// @dev Mirror of buy: atomic on-chain close through the exchanger
    /// (STRCon → USDC → USDat). Only recognized balance is sellable; the position is
    /// derecognized before the route runs (conservative — mid-transaction NAV reads
    /// understate, never overstate), and the USDat delta is measured, bounded by
    /// minUsdatOut, and validated against the oracle within toleranceBps.
    function sell(uint256 assetIn, uint256 minUsdatOut, bytes calldata venueData)
        external
        onlyVault
        returns (uint256 usdatOut)
    {
        require(assetIn <= balance, InsufficientBalance());

        IExchanger route = exchanger;

        // Fund the route: pull the vault's STRCon (sellVia grants an exact-amount
        // approval) and derecognize it before any external call.
        STRCON.safeTransferFrom(VAULT, address(this), assetIn);
        balance -= assetIn;
        STRCON.forceApprove(address(route), assetIn);

        uint256 usdatBefore = USDAT.balanceOf(address(this));
        route.swapOut(assetIn, minUsdatOut, venueData);
        usdatOut = USDAT.balanceOf(address(this)) - usdatBefore; // measured, not trusted

        STRCON.forceApprove(address(route), 0);

        require(usdatOut >= minUsdatOut, SlippageExceeded());
        _checkRealizedPrice(usdatOut, assetIn);

        USDAT.safeTransfer(VAULT, usdatOut);
        require(STRCON.balanceOf(VAULT) >= balance, CustodyFloorBreached());

        emit Sold(assetIn, usdatOut);
    }

    // ============ Migration Setter ============

    /// @notice One-shot balance seed at migrate() (§3.3).
    /// @dev Will be vault-only, seed-once (balance == 0), asserting the custody floor.
    function setBalance(uint256) external pure {
        revert NotImplemented();
    }

    // ============ Parameter Setters ============

    /// @notice Re-points the execution route — how conversion venue changes
    /// (a DEX migration, M → PYUSD backing) ship without touching the position.
    /// @dev Caller must hold DEFAULT_ADMIN_ROLE on the vault.
    function setExchanger(IExchanger newExchanger) external onlyVaultRole(DEFAULT_ADMIN_ROLE) {
        _setExchanger(newExchanger);
    }

    /// @notice Updates the tolerance for realized-price validation.
    /// @dev Caller must hold PARAMETER_MANAGER_ROLE on the vault.
    function setTolerance(uint256 newToleranceBps) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        require(newToleranceBps >= MIN_TOLERANCE_BPS && newToleranceBps <= MAX_TOLERANCE_BPS, InvalidTolerance());

        toleranceBps = newToleranceBps;

        emit ToleranceUpdated(newToleranceBps);
    }

    // ============ Internal ============

    function _setExchanger(IExchanger newExchanger) internal {
        require(address(newExchanger) != address(0), InvalidZeroAddress());

        address oldExchanger = address(exchanger);
        exchanger = newExchanger;

        emit ExchangerUpdated(oldExchanger, address(newExchanger));
    }

    /// @dev Requires the realized end-to-end execution (usdatAmount for strconAmount)
    /// to be within toleranceBps of what the oracle price implies. This single check
    /// bounds every hop of whatever route the exchanger took.
    function _checkRealizedPrice(uint256 usdatAmount, uint256 strconAmount) internal view {
        (uint256 oraclePrice, uint8 priceDecimals) = ORACLE.getPrice();

        // usdat (6 dec) → STRCon (18 dec) at price (priceDecimals dec)
        uint256 expectedStrcon = Math.mulDiv(usdatAmount, 10 ** (12 + uint256(priceDecimals)), oraclePrice);
        require(_isWithinTolerance(strconAmount, expectedStrcon), OraclePriceMismatch());
    }

    /// @dev Checks if a value is within ±toleranceBps of an expected value.
    function _isWithinTolerance(uint256 value, uint256 expected) internal view returns (bool) {
        uint256 minExpected = Math.mulDiv(expected, BPS_DENOMINATOR - toleranceBps, BPS_DENOMINATOR);
        uint256 maxExpected = Math.mulDiv(expected, BPS_DENOMINATOR + toleranceBps, BPS_DENOMINATOR);
        return value >= minExpected && value <= maxExpected;
    }
}
