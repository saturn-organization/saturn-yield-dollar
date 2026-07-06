// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IAccountingModule} from "../../interfaces/IAccountingModule.sol";
import {IStrcPriceOracle} from "../../interfaces/IStrcPriceOracle.sol";

/**
 * @title MirrorSTRC
 * @author Saturn
 * @notice Migration-bridge accounting module: a processor-attested mirror of off-chain
 * STRC holdings, priced through the deployed StrcPriceOracle. Token-less
 * (`asset() == address(0)`), so it has no custody floor. Carries v1's STRC vesting
 * surface; retires when the position migrates to STRCon.
 * @dev Not upgradeable — a module is replaced by deregistering it, never upgraded.
 * Access control is resolved against the vault's role registry; the module defines
 * no roles of its own.
 */
contract MirrorSTRC is IAccountingModule {
    using SafeERC20 for IERC20;

    // ============ Errors ============

    error NotVault();
    error Unauthorized();
    error ZeroAmount();
    error InvalidZeroAddress();
    error AlreadySeeded();
    error StillVesting();
    error RewardsExceedMax();
    error InsufficientVestedBalance();
    error ExecutionPriceMismatch();
    error OraclePriceMismatch();
    error SlippageExceeded();
    error InvalidVestingPeriod();
    error InvalidTolerance();
    error InvalidMaxRewardsBps();

    // ============ Events ============

    /// @dev Emitted when attested STRC rewards enter vesting.
    event RewardsReceived(uint256 strcAmount);
    /// @dev Emitted on a vault-driven buy (USDat out, attested STRC recognized).
    event Bought(uint256 usdatIn, uint256 strcOut, uint256 executionPrice);
    /// @dev Emitted on a vault-driven sell (attested STRC derecognized, USDat in).
    event Sold(uint256 strcIn, uint256 usdatOut, uint256 executionPrice);
    /// @dev Emitted once when the module is seeded from the v1 STRC slots.
    event Seeded(uint256 balance, uint256 vestingAmount, uint256 lastDistributionTimestamp, uint256 vestingPeriod);
    /// @dev Emitted when the vault force-sets the balance (migration only).
    event BalanceSet(uint256 newBalance);
    event VestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event MaxRewardsBpsUpdated(uint256 newMaxBps);
    event ToleranceUpdated(uint256 newToleranceBps);

    // ============ Constants ============

    /// @notice Role id on the vault authorized to push rewards
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role id on the vault authorized to tune module parameters
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum allowed vesting period (90 days)
    uint256 public constant MAX_VESTING_PERIOD = 90 days;

    /// @notice Maximum tolerance (100%)
    uint256 public constant MAX_TOLERANCE_BPS = 10000;

    /// @notice Minimum tolerance (1%)
    uint256 public constant MIN_TOLERANCE_BPS = 100;

    // ============ Immutables ============

    /// @notice The StakedUSDat vault this module accounts for
    address public immutable VAULT;

    /// @notice The deployed StrcPriceOracle (Chainlink wrapper, staleness + bounds)
    IStrcPriceOracle public immutable ORACLE;

    /// @notice The USDat token
    IERC20 public immutable USDAT;

    // ============ Storage ============

    /// @notice Attested off-chain STRC quantity (6 decimals, matches USDat)
    uint256 public balance;

    /// @notice Amount of STRC currently vesting
    uint256 public vestingAmount;

    /// @notice Timestamp of last reward distribution
    uint256 public lastDistributionTimestamp;

    /// @notice Vesting period duration in seconds
    uint256 public vestingPeriod;

    /// @notice Maximum rewards per transfer in basis points of vault totalAssets
    uint256 public maxRewardsBps;

    /// @notice Tolerance in basis points for execution-price validation
    uint256 public toleranceBps;

    /// @notice Whether the one-shot migration seed has run
    bool public seeded;

    // ============ Modifiers ============

    modifier onlyVault() {
        require(msg.sender == VAULT, NotVault());
        _;
    }

    modifier onlyVaultRole(bytes32 role) {
        require(IAccessControl(VAULT).hasRole(role, msg.sender), Unauthorized());
        _;
    }

    constructor(address vault, IStrcPriceOracle oracle, IERC20 usdat) {
        require(
            vault != address(0) && address(oracle) != address(0) && address(usdat) != address(0), InvalidZeroAddress()
        );
        VAULT = vault;
        ORACLE = oracle;
        USDAT = usdat;

        vestingPeriod = 3 days;
        maxRewardsBps = 250; // 2.5% of totalAssets
        toleranceBps = 2000;
    }

    // ============ IAccountingModule ============

    /// @inheritdoc IAccountingModule
    /// @dev Vested attested balance at the oracle price, floor-rounded.
    function recognizedValue() external view returns (uint256) {
        uint256 currentBalance = balance;
        if (currentBalance == 0) return 0;

        (uint256 strcPrice, uint8 priceDecimals) = ORACLE.getPrice();

        return Math.mulDiv(currentBalance - getUnvestedAmount(), strcPrice, 10 ** priceDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc IAccountingModule
    /// @dev Token-less: the position lives off-chain.
    function asset() external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IAccountingModule
    /// @dev venueData: abi.encode(strcAmount, executionPrice, counterparty). The vault's
    /// USDat moves to `counterparty` (Saturn's settlement account) against the attested
    /// off-chain STRC purchase.
    function buy(uint256 usdatIn, uint256 minAssetOut, bytes calldata venueData)
        external
        onlyVault
        returns (uint256 assetOut)
    {
        (uint256 strcAmount, uint256 executionPrice, address counterparty) =
            abi.decode(venueData, (uint256, uint256, address));
        require(counterparty != address(0), InvalidZeroAddress());
        require(strcAmount >= minAssetOut, SlippageExceeded());

        _validateConversion(usdatIn, strcAmount, executionPrice);

        balance += strcAmount;

        USDAT.safeTransferFrom(VAULT, counterparty, usdatIn);

        emit Bought(usdatIn, strcAmount, executionPrice);
        return strcAmount;
    }

    /// @inheritdoc IAccountingModule
    /// @dev venueData: abi.encode(usdatAmount, executionPrice, counterparty). Pulls the
    /// attested USDat proceeds from `counterparty` into the vault. Only vested balance
    /// is sellable.
    function sell(uint256 assetIn, uint256 minUsdatOut, bytes calldata venueData)
        external
        onlyVault
        returns (uint256 usdatOut)
    {
        (uint256 usdatAmount, uint256 executionPrice, address counterparty) =
            abi.decode(venueData, (uint256, uint256, address));
        require(counterparty != address(0), InvalidZeroAddress());
        require(assetIn <= balance - getUnvestedAmount(), InsufficientVestedBalance());
        require(usdatAmount >= minUsdatOut, SlippageExceeded());

        _validateConversion(usdatAmount, assetIn, executionPrice);

        balance -= assetIn;

        USDAT.safeTransferFrom(counterparty, VAULT, usdatAmount);

        emit Sold(assetIn, usdatAmount, executionPrice);
        return usdatAmount;
    }

    // ============ Vesting ============

    /// @notice Returns the amount of STRC that is still vesting.
    /// @dev Rounds up to be conservative (slightly favors protocol over users).
    function getUnvestedAmount() public view returns (uint256) {
        uint256 timeSinceLastDistribution = block.timestamp - lastDistributionTimestamp;

        if (timeSinceLastDistribution >= vestingPeriod) {
            return 0;
        }

        return Math.mulDiv(vestingPeriod - timeSinceLastDistribution, vestingAmount, vestingPeriod, Math.Rounding.Ceil);
    }

    /// @notice Pushes the monthly attested STRC dividend into linear vesting.
    /// @dev One tranche at a time; capped at maxRewardsBps of vault totalAssets.
    /// Caller must hold OPERATOR_ROLE on the vault.
    function transferInRewards(uint256 strcAmount) external onlyVaultRole(OPERATOR_ROLE) {
        require(strcAmount != 0, ZeroAmount());
        require(getUnvestedAmount() == 0, StillVesting());

        uint256 maxRewards = Math.mulDiv(IERC4626(VAULT).totalAssets(), maxRewardsBps, BPS_DENOMINATOR);

        (uint256 strcPrice, uint8 priceDecimals) = ORACLE.getPrice();
        uint256 strcAmountUsd = Math.mulDiv(strcAmount, strcPrice, 10 ** priceDecimals);

        require(strcAmountUsd <= maxRewards, RewardsExceedMax());

        balance += strcAmount;

        vestingAmount = strcAmount;
        lastDistributionTimestamp = block.timestamp;

        emit RewardsReceived(strcAmount);
    }

    // ============ Migration Setters ============

    /// @notice One-shot seed from the v1 STRC slots at the framework upgrade.
    /// @dev Vault-only; bypasses buy/sell.
    function seed(
        uint256 strcBalance,
        uint256 vestingAmount_,
        uint256 lastDistributionTimestamp_,
        uint256 vestingPeriod_
    ) external onlyVault {
        require(!seeded, AlreadySeeded());
        require(vestingPeriod_ > 0 && vestingPeriod_ <= MAX_VESTING_PERIOD, InvalidVestingPeriod());
        seeded = true;

        balance = strcBalance;
        vestingAmount = vestingAmount_;
        lastDistributionTimestamp = lastDistributionTimestamp_;
        vestingPeriod = vestingPeriod_;

        emit Seeded(strcBalance, vestingAmount_, lastDistributionTimestamp_, vestingPeriod_);
    }

    /// @notice Force-sets the attested balance; used as setBalance(0) in migrate().
    /// @dev Vault-only; bypasses buy/sell.
    function setBalance(uint256 newBalance) external onlyVault {
        balance = newBalance;

        emit BalanceSet(newBalance);
    }

    // ============ Parameter Setters ============

    /// @notice Updates the vesting period for reward distributions.
    /// @dev Caller must hold PARAMETER_MANAGER_ROLE on the vault.
    /// Cannot be changed while rewards are still vesting.
    function setVestingPeriod(uint256 newVestingPeriod) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        require(newVestingPeriod > 0 && newVestingPeriod <= MAX_VESTING_PERIOD, InvalidVestingPeriod());
        require(getUnvestedAmount() == 0, StillVesting());

        uint256 oldPeriod = vestingPeriod;
        vestingPeriod = newVestingPeriod;
        vestingAmount = 0;

        emit VestingPeriodUpdated(oldPeriod, newVestingPeriod);
    }

    /// @notice Updates the maximum rewards per transfer as a fraction of vault totalAssets.
    /// @dev Caller must hold PARAMETER_MANAGER_ROLE on the vault.
    function setMaxRewardsBps(uint256 newMaxBps) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        require(newMaxBps > 0, InvalidMaxRewardsBps());

        maxRewardsBps = newMaxBps;

        emit MaxRewardsBpsUpdated(newMaxBps);
    }

    /// @notice Updates the tolerance for execution-price validation.
    /// @dev Caller must hold PARAMETER_MANAGER_ROLE on the vault.
    function setTolerance(uint256 newToleranceBps) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        require(newToleranceBps >= MIN_TOLERANCE_BPS && newToleranceBps <= MAX_TOLERANCE_BPS, InvalidTolerance());

        toleranceBps = newToleranceBps;

        emit ToleranceUpdated(newToleranceBps);
    }

    // ============ Internal ============

    /// @dev Checks if a value is within ±toleranceBps of an expected value.
    function _isWithinTolerance(uint256 value, uint256 expected) internal view returns (bool) {
        uint256 minExpected = Math.mulDiv(expected, BPS_DENOMINATOR - toleranceBps, BPS_DENOMINATOR);
        uint256 maxExpected = Math.mulDiv(expected, BPS_DENOMINATOR + toleranceBps, BPS_DENOMINATOR);
        return value >= minExpected && value <= maxExpected;
    }

    /// @dev Validates that strcAmount matches usdatAmount / executionPrice within tolerance,
    /// and that executionPrice is within tolerance of the oracle.
    function _validateConversion(uint256 usdatAmount, uint256 strcAmount, uint256 executionPrice) internal view {
        (uint256 oraclePrice, uint8 priceDecimals) = ORACLE.getPrice();

        uint256 expectedStrc = Math.mulDiv(usdatAmount, 10 ** priceDecimals, executionPrice);
        require(_isWithinTolerance(strcAmount, expectedStrc), ExecutionPriceMismatch());

        require(_isWithinTolerance(executionPrice, oraclePrice), OraclePriceMismatch());
    }
}
