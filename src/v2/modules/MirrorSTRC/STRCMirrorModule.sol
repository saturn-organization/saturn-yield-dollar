// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAccountingModule} from "../../interfaces/modules/IAccountingModule.sol";
import {IStrcPriceOracle} from "../../interfaces/oracles/IStrcPriceOracle.sol";

/**
 * @title STRCMirrorModule
 * @author Saturn
 * @notice Tokenless accounting bridge for the STRC position migrated from v1.
 * @dev Preserves v1 vesting and reward-cap accounting. Authorization is resolved
 * against the immutable vault's role registry.
 */
contract STRCMirrorModule is IAccountingModule {
    // ============ Errors ============

    error NotVault();
    error Unauthorized();
    error InvalidZeroAddress();
    error AlreadySeeded();
    error STRCMirrorInactive();
    error ZeroAmount();
    error StillVesting();
    error RewardsExceedMax();
    error InvalidVestingPeriod();
    error InvalidMaxRewardsBps();
    error UnvestedExceedsBalance();

    // ============ Events ============

    event Seeded(
        uint256 balance,
        uint256 vestingAmount,
        uint256 lastDistributionTimestamp,
        uint256 vestingPeriod,
        uint256 maxRewardsBps
    );
    event RewardsReceived(uint256 amount, uint256 newVestingAmount);
    event VestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event MaxRewardsBpsUpdated(uint256 newMaxBps);
    event Retired();

    // ============ Constants ============

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_VESTING_PERIOD = 90 days;

    // ============ Immutables ============

    address public immutable VAULT;
    IStrcPriceOracle public immutable ORACLE;

    // ============ Storage ============

    uint256 private _balance;
    uint256 public vestingAmount;
    uint256 public lastDistributionTimestamp;
    uint256 public vestingPeriod;
    uint256 public maxRewardsBps;
    bool public seeded;
    bool public retired;

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != VAULT) revert NotVault();
        _;
    }

    modifier onlyVaultRole(bytes32 role) {
        if (!IAccessControl(VAULT).hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    modifier whenActive() {
        if (!seeded || retired) revert STRCMirrorInactive();
        _;
    }

    constructor(address vault, IStrcPriceOracle oracle) {
        if (vault == address(0) || address(oracle) == address(0)) revert InvalidZeroAddress();

        VAULT = vault;
        ORACLE = oracle;
    }

    // ============ IAccountingModule ============

    /// @inheritdoc IAccountingModule
    function recognizedValue() external view returns (uint256) {
        uint256 currentBalance = balance();
        if (currentBalance == 0) return 0;

        (uint256 strcPrice, uint8 priceDecimals) = ORACLE.getPrice();
        uint256 vestedBalance = currentBalance - getUnvestedAmount();

        return Math.mulDiv(vestedBalance, strcPrice, 10 ** priceDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc IAccountingModule
    function balance() public view returns (uint256) {
        if (retired) return 0;
        return _balance;
    }

    // ============ Vesting ============

    /// @notice Returns the STRC amount still vesting, rounded up as in v1.
    function getUnvestedAmount() public view returns (uint256) {
        if (!seeded || retired) return 0;
        return _getUnvestedAmount(vestingAmount, lastDistributionTimestamp, vestingPeriod);
    }

    /// @notice Adds a processor-attested STRC reward and begins a new vesting tranche.
    function transferInRewards(uint256 strcAmount) external whenActive onlyVaultRole(OPERATOR_ROLE) {
        if (strcAmount == 0) revert ZeroAmount();
        if (getUnvestedAmount() != 0) revert StillVesting();

        uint256 maxRewards = Math.mulDiv(IERC4626(VAULT).totalAssets(), maxRewardsBps, BPS_DENOMINATOR);
        (uint256 strcPrice, uint8 priceDecimals) = ORACLE.getPrice();
        uint256 rewardValue = Math.mulDiv(strcAmount, strcPrice, 10 ** priceDecimals, Math.Rounding.Floor);

        if (rewardValue > maxRewards) revert RewardsExceedMax();

        _balance += strcAmount;
        vestingAmount = strcAmount;
        lastDistributionTimestamp = block.timestamp;

        emit RewardsReceived(strcAmount, strcAmount);
    }

    // ============ Migration ============

    /// @notice Initializes the five migrated v1 accounting fields exactly once.
    function seed(
        uint256 initialBalance,
        uint256 initialVestingAmount,
        uint256 initialLastDistributionTimestamp,
        uint256 initialVestingPeriod,
        uint256 initialMaxRewardsBps
    ) external onlyVault {
        if (seeded) revert AlreadySeeded();
        if (initialVestingPeriod == 0 || initialVestingPeriod > MAX_VESTING_PERIOD) {
            revert InvalidVestingPeriod();
        }
        if (initialMaxRewardsBps == 0) revert InvalidMaxRewardsBps();

        uint256 initialUnvested =
            _getUnvestedAmount(initialVestingAmount, initialLastDistributionTimestamp, initialVestingPeriod);
        if (initialUnvested > initialBalance) revert UnvestedExceedsBalance();

        _balance = initialBalance;
        vestingAmount = initialVestingAmount;
        lastDistributionTimestamp = initialLastDistributionTimestamp;
        vestingPeriod = initialVestingPeriod;
        maxRewardsBps = initialMaxRewardsBps;
        seeded = true;

        emit Seeded(
            initialBalance,
            initialVestingAmount,
            initialLastDistributionTimestamp,
            initialVestingPeriod,
            initialMaxRewardsBps
        );
    }

    /// @notice Permanently retires the migrated mirror after all rewards vest.
    function retire() external onlyVault whenActive {
        if (getUnvestedAmount() != 0) revert StillVesting();

        _balance = 0;
        retired = true;

        emit Retired();
    }

    // ============ Parameter Setters ============

    /// @notice Updates the vesting period after the current tranche has vested.
    function setVestingPeriod(uint256 newVestingPeriod) external whenActive onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        if (newVestingPeriod == 0 || newVestingPeriod > MAX_VESTING_PERIOD) {
            revert InvalidVestingPeriod();
        }
        if (getUnvestedAmount() != 0) revert StillVesting();

        uint256 oldPeriod = vestingPeriod;
        vestingPeriod = newVestingPeriod;
        vestingAmount = 0;

        emit VestingPeriodUpdated(oldPeriod, newVestingPeriod);
    }

    /// @notice Updates the per-transfer reward cap without imposing an upper bound.
    function setMaxRewardsBps(uint256 newMaxRewardsBps) external whenActive onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        if (newMaxRewardsBps == 0) revert InvalidMaxRewardsBps();

        maxRewardsBps = newMaxRewardsBps;

        emit MaxRewardsBpsUpdated(newMaxRewardsBps);
    }

    // ============ Internal ============

    function _getUnvestedAmount(uint256 amount, uint256 distributionTimestamp, uint256 period)
        private
        view
        returns (uint256)
    {
        uint256 elapsed = block.timestamp - distributionTimestamp;
        if (elapsed >= period) return 0;

        return Math.mulDiv(period - elapsed, amount, period, Math.Rounding.Ceil);
    }
}
