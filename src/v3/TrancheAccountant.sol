// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {StakedUSDat} from "./StakedUSDat.sol";
import {IStakedUSDat} from "../v2/interfaces/IStakedUSDat.sol";
import {IEligibleIncomeAccounting} from "./interfaces/IEligibleIncomeAccounting.sol";
import {IStakedUSDatEligibleIncomeModule} from "./interfaces/IStakedUSDatEligibleIncomeModule.sol";
import {TrancheShare} from "./TrancheShare.sol";

/// @notice Non-upgradeable sUSDat-backed accountant with independent Senior and Junior share classes.
/// @dev Local production candidate. It is not a deployment or activation artifact.
contract TrancheAccountant is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant VALUE_SCALE = 1e12; // USDat 6 decimals -> class shares 18 decimals.

    enum OperatingState {
        HealthyPreferred,
        HealthyBelowPreferred,
        Impaired,
        SourceUnhealthy,
        HardPaused
    }

    error InvalidConfiguration();
    error InvalidAmount();
    error ExpiredDeadline();
    error SlippageExceeded();
    error CapacityExceeded();
    error SourceUnhealthy();
    error SeniorImpaired();
    error JuniorWiped();
    error RestrictedAccount(address account);
    error UnauthorizedPause();
    error UnsafeTransfer();

    event IncomeSynchronized(uint256 seniorLiveUnitsWad, uint256 seniorCrystallizedValue, uint256 seniorClaimValue);
    event SeniorDeposit(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        uint256 backingValue,
        uint256 seniorClaimValue,
        uint256 coverageWad
    );
    event SeniorWithdraw(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        uint256 backingValue,
        uint256 seniorClaimValue,
        uint256 coverageWad
    );
    event JuniorDeposit(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        uint256 backingValue,
        uint256 seniorClaimValue,
        uint256 coverageWad
    );
    event JuniorWithdraw(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        uint256 backingValue,
        uint256 seniorClaimValue,
        uint256 coverageWad
    );
    event FullStackExit(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 fractionWad,
        uint256 assets,
        uint256 seniorShares,
        uint256 juniorShares
    );
    event HardPauseChanged(bool paused);

    StakedUSDat public immutable VAULT;
    IStakedUSDatEligibleIncomeModule public immutable INCOME_ACCUMULATOR;
    TrancheShare public immutable SENIOR_TOKEN;
    TrancheShare public immutable JUNIOR_TOKEN;
    uint16 public immutable ALPHA_BPS;
    uint256 public immutable PREFERRED_COVERAGE_WAD;
    uint256 public immutable MAX_BACKING_VALUE;
    address public immutable PAUSER;
    address public immutable UNPAUSER;

    bool public hardPaused;

    /// @notice Backing that has crossed the current income checkpoint.
    /// @dev May temporarily be below actual custody after an unsolicited sUSDat transfer.
    uint256 public incomeBearingBackingAssets;
    uint256 public baseSeniorClaimValue;
    uint256 public seniorLiveUnitsWad;
    uint256 public crystallizedSeniorValue;

    uint256 public checkpointLiveScaleWad;
    uint256 public checkpointLiveOffsetWad;
    uint256 public checkpointCrystallizedScaleWad;
    uint256 public checkpointCrystallizedOffsetWad;
    uint256 public checkpointCrystallizationNonce;

    // ============ Initialization ============

    constructor(
        StakedUSDat vault_,
        IStakedUSDatEligibleIncomeModule accumulator_,
        uint16 alphaBps_,
        uint256 preferredCoverageWad_,
        uint256 maxBackingValue_,
        address pauser_,
        address unpauser_
    ) {
        if (
            address(vault_) == address(0) || address(accumulator_) == address(0) || alphaBps_ > BPS
                || preferredCoverageWad_ <= WAD || maxBackingValue_ == 0 || pauser_ == address(0)
                || unpauser_ == address(0) || accumulator_.VAULT() != address(vault_)
                || address(vault_.eligibleIncomeModule()) != address(accumulator_)
        ) revert InvalidConfiguration();

        IEligibleIncomeAccounting.EligibleIncomeState memory state = accumulator_.eligibleIncomeState();
        if (state.liveUnitScaleWad == 0) revert InvalidConfiguration();

        VAULT = vault_;
        INCOME_ACCUMULATOR = accumulator_;
        ALPHA_BPS = alphaBps_;
        PREFERRED_COVERAGE_WAD = preferredCoverageWad_;
        MAX_BACKING_VALUE = maxBackingValue_;
        PAUSER = pauser_;
        UNPAUSER = unpauser_;
        SENIOR_TOKEN = new TrancheShare("Saturn Senior sUSDat", "sr-sUSDat", address(this));
        JUNIOR_TOKEN = new TrancheShare("Saturn Junior sUSDat", "jr-sUSDat", address(this));
        _writeCheckpoint(state);
    }

    // ============ Modifiers ============

    modifier beforeDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert ExpiredDeadline();
        _;
    }

    // ============ Configuration Views ============

    function asset() external view returns (address) {
        return address(VAULT);
    }

    function seniorToken() external view returns (address) {
        return address(SENIOR_TOKEN);
    }

    function juniorToken() external view returns (address) {
        return address(JUNIOR_TOKEN);
    }

    function incomeAccumulator() external view returns (address) {
        return address(INCOME_ACCUMULATOR);
    }

    function alphaBps() external view returns (uint256) {
        return ALPHA_BPS;
    }

    function preferredCoverageWad() external view returns (uint256) {
        return PREFERRED_COVERAGE_WAD;
    }

    function maxBackingValue() external view returns (uint256) {
        return MAX_BACKING_VALUE;
    }

    function isRestricted(address account) public view returns (bool) {
        return VAULT.isRestricted(account);
    }

    // ============ Pause Controls ============

    function pause() external {
        if (msg.sender != PAUSER) revert UnauthorizedPause();
        hardPaused = true;
        emit HardPauseChanged(true);
    }

    function unpause() external {
        if (msg.sender != UNPAUSER) revert UnauthorizedPause();
        hardPaused = false;
        emit HardPauseChanged(false);
    }

    // ============ Accounting Views ============

    function backingAssets() public view returns (uint256) {
        return VAULT.balanceOf(address(this));
    }

    function backingValue() public view returns (uint256) {
        return VAULT.convertToAssets(backingAssets());
    }

    function seniorClaimValue() public view returns (uint256) {
        uint256 liveValue = Math.mulDiv(seniorLiveUnitsWad, VAULT.strconModule().getPrice(), 1e20);
        return baseSeniorClaimValue + crystallizedSeniorValue + liveValue;
    }

    function markedSeniorValue() public view returns (uint256) {
        return Math.min(backingValue(), seniorClaimValue());
    }

    function juniorResidualValue() public view returns (uint256) {
        return backingValue() - markedSeniorValue();
    }

    function coverageWad() public view returns (uint256) {
        return _coverage(backingValue(), seniorClaimValue());
    }

    function operatingState() public view returns (OperatingState) {
        if (hardPaused) return OperatingState.HardPaused;
        if (VAULT.paused() || VAULT.marketMode() == IStakedUSDat.MarketMode.Restricted) {
            return OperatingState.SourceUnhealthy;
        }
        try INCOME_ACCUMULATOR.canAccount() returns (bool canAccount) {
            if (!canAccount) return OperatingState.SourceUnhealthy;
        } catch {
            return OperatingState.SourceUnhealthy;
        }
        try this.currentValues() returns (uint256 backing, uint256 claim) {
            if (backing < claim) return OperatingState.Impaired;
            return _coverage(backing, claim) >= PREFERRED_COVERAGE_WAD
                ? OperatingState.HealthyPreferred
                : OperatingState.HealthyBelowPreferred;
        } catch {
            return OperatingState.SourceUnhealthy;
        }
    }

    function currentValues() external view returns (uint256 backing, uint256 claim) {
        return (backingValue(), seniorClaimValue());
    }

    // ============ Income Synchronization ============

    function syncIncome() external nonReentrant returns (uint256 newLiveUnitsWad, uint256 newCrystallizedValue) {
        _requireSourceHealthy();
        return _syncIncome();
    }

    // ============ Senior Operations ============

    function depositSenior(uint256 assets, address receiver, uint256 minShares, uint256 deadline)
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 shares)
    {
        _requireParticipants(msg.sender, receiver, msg.sender);
        _requireSourceHealthy();
        _syncIncome();
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        _requireHealthy(backing, claim);
        uint256 value = VAULT.convertToAssets(assets);
        if (assets == 0 || value == 0 || value > _seniorDepositCapacity(backing, claim)) revert CapacityExceeded();

        uint256 supply = SENIOR_TOKEN.totalSupply();
        shares = supply == 0 ? value * VALUE_SCALE : Math.mulDiv(value, supply, claim);
        if (shares == 0 || shares < minShares) revert SlippageExceeded();

        _pullAssets(assets);
        incomeBearingBackingAssets += assets;
        baseSeniorClaimValue += value;
        SENIOR_TOKEN.mint(receiver, shares);
        _emitSeniorDeposit(receiver, assets, shares);
    }

    function mintSenior(uint256 shares, address receiver, uint256 maxAssets, uint256 deadline)
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 assets)
    {
        _requireParticipants(msg.sender, receiver, msg.sender);
        _requireSourceHealthy();
        _syncIncome();
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        _requireHealthy(backing, claim);
        if (shares == 0) revert InvalidAmount();
        uint256 supply = SENIOR_TOKEN.totalSupply();
        uint256 value =
            supply == 0 ? Math.ceilDiv(shares, VALUE_SCALE) : Math.mulDiv(shares, claim, supply, Math.Rounding.Ceil);
        assets = _sharesForValueUp(value);
        uint256 actualBackingValue = VAULT.convertToAssets(assets);
        if (value > _seniorDepositCapacity(backing, claim) || actualBackingValue > _remainingBackingCapacity(backing)) {
            revert CapacityExceeded();
        }
        if (assets == 0 || assets > maxAssets) revert SlippageExceeded();

        _pullAssets(assets);
        incomeBearingBackingAssets += assets;
        baseSeniorClaimValue += value;
        SENIOR_TOKEN.mint(receiver, shares);
        _emitSeniorDeposit(receiver, assets, shares);
    }

    function redeemSenior(uint256 shares, address receiver, address owner, uint256 minAssets, uint256 deadline)
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 assets)
    {
        _requireParticipants(msg.sender, receiver, owner);
        _requireSourceHealthy();
        _syncIncome();
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        _requireHealthy(backing, claim);
        uint256 supply = SENIOR_TOKEN.totalSupply();
        if (shares == 0 || shares > SENIOR_TOKEN.balanceOf(owner)) revert InvalidAmount();
        uint256 value = Math.mulDiv(shares, claim, supply);
        assets = VAULT.convertToShares(value);
        if (assets == 0 || assets < minAssets) revert SlippageExceeded();

        _burnClass(SENIOR_TOKEN, owner, shares);
        _scaleSeniorBucketsByShares(supply - shares, supply);
        incomeBearingBackingAssets -= assets;
        _pushAssets(receiver, assets);
        _emitSeniorWithdraw(owner, receiver, assets, shares);
    }

    function withdrawSenior(uint256 assets, address receiver, address owner, uint256 maxShares, uint256 deadline)
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 shares)
    {
        _requireParticipants(msg.sender, receiver, owner);
        _requireSourceHealthy();
        _syncIncome();
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        _requireHealthy(backing, claim);
        uint256 supply = SENIOR_TOKEN.totalSupply();
        uint256 value = VAULT.convertToAssets(assets);
        shares = Math.mulDiv(value, supply, claim, Math.Rounding.Ceil);
        if (assets == 0 || shares == 0 || shares > maxShares || shares > SENIOR_TOKEN.balanceOf(owner)) {
            revert SlippageExceeded();
        }

        _burnClass(SENIOR_TOKEN, owner, shares);
        _scaleSeniorBucketsByShares(supply - shares, supply);
        incomeBearingBackingAssets -= assets;
        _pushAssets(receiver, assets);
        _emitSeniorWithdraw(owner, receiver, assets, shares);
    }

    // ============ Junior Operations ============

    function depositJunior(uint256 assets, address receiver, uint256 minShares, uint256 deadline)
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 shares)
    {
        _requireParticipants(msg.sender, receiver, msg.sender);
        _requireSourceHealthy();
        _syncIncome();
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        _requireHealthy(backing, claim);
        uint256 residual = backing - claim;
        uint256 supply = JUNIOR_TOKEN.totalSupply();
        if (supply != 0 && residual == 0) revert JuniorWiped();
        if (supply == 0 && SENIOR_TOKEN.totalSupply() != 0) revert JuniorWiped();
        uint256 value = VAULT.convertToAssets(assets);
        if (value > _remainingBackingCapacity(backing)) revert CapacityExceeded();
        shares = supply == 0 ? value * VALUE_SCALE : Math.mulDiv(value, supply, residual);
        if (assets == 0 || value == 0 || shares == 0 || shares < minShares) revert SlippageExceeded();

        _pullAssets(assets);
        incomeBearingBackingAssets += assets;
        JUNIOR_TOKEN.mint(receiver, shares);
        _emitJuniorDeposit(receiver, assets, shares);
    }

    function mintJunior(uint256 shares, address receiver, uint256 maxAssets, uint256 deadline)
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 assets)
    {
        _requireParticipants(msg.sender, receiver, msg.sender);
        _requireSourceHealthy();
        _syncIncome();
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        _requireHealthy(backing, claim);
        uint256 residual = backing - claim;
        uint256 supply = JUNIOR_TOKEN.totalSupply();
        if (supply != 0 && residual == 0) revert JuniorWiped();
        if (supply == 0 && SENIOR_TOKEN.totalSupply() != 0) revert JuniorWiped();
        if (shares == 0) revert InvalidAmount();
        uint256 value =
            supply == 0 ? Math.ceilDiv(shares, VALUE_SCALE) : Math.mulDiv(shares, residual, supply, Math.Rounding.Ceil);
        assets = _sharesForValueUp(value);
        if (
            value > _remainingBackingCapacity(backing)
                || VAULT.convertToAssets(assets) > _remainingBackingCapacity(backing)
        ) revert CapacityExceeded();
        if (assets == 0 || assets > maxAssets) revert SlippageExceeded();

        _pullAssets(assets);
        incomeBearingBackingAssets += assets;
        JUNIOR_TOKEN.mint(receiver, shares);
        _emitJuniorDeposit(receiver, assets, shares);
    }

    function redeemJunior(uint256 shares, address receiver, address owner, uint256 minAssets, uint256 deadline)
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 assets)
    {
        _requireParticipants(msg.sender, receiver, owner);
        _requireSourceHealthy();
        _syncIncome();
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        _requireHealthy(backing, claim);
        uint256 supply = JUNIOR_TOKEN.totalSupply();
        if (shares == 0 || shares > JUNIOR_TOKEN.balanceOf(owner)) revert InvalidAmount();
        uint256 value = Math.mulDiv(shares, backing - claim, supply);
        if (value > _juniorRedemptionCapacity(backing, claim)) revert CapacityExceeded();
        assets = VAULT.convertToShares(value);
        if (assets == 0 || assets < minAssets) revert SlippageExceeded();

        _burnClass(JUNIOR_TOKEN, owner, shares);
        incomeBearingBackingAssets -= assets;
        _pushAssets(receiver, assets);
        _emitJuniorWithdraw(owner, receiver, assets, shares);
    }

    function withdrawJunior(uint256 assets, address receiver, address owner, uint256 maxShares, uint256 deadline)
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 shares)
    {
        _requireParticipants(msg.sender, receiver, owner);
        _requireSourceHealthy();
        _syncIncome();
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        _requireHealthy(backing, claim);
        uint256 value = VAULT.convertToAssets(assets);
        if (value > _juniorRedemptionCapacity(backing, claim)) revert CapacityExceeded();
        uint256 supply = JUNIOR_TOKEN.totalSupply();
        shares = Math.mulDiv(value, supply, backing - claim, Math.Rounding.Ceil);
        if (assets == 0 || shares == 0 || shares > maxShares || shares > JUNIOR_TOKEN.balanceOf(owner)) {
            revert SlippageExceeded();
        }

        _burnClass(JUNIOR_TOKEN, owner, shares);
        incomeBearingBackingAssets -= assets;
        _pushAssets(receiver, assets);
        _emitJuniorWithdraw(owner, receiver, assets, shares);
    }

    // ============ Full-Stack Exit ============

    function exitFullStack(
        uint256 fractionWad,
        address receiver,
        address owner,
        uint256 maxSeniorShares,
        uint256 maxJuniorShares,
        uint256 minAssets,
        uint256 deadline
    )
        external
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 assets, uint256 seniorShares, uint256 juniorShares)
    {
        _requireParticipants(msg.sender, receiver, owner);
        if (hardPaused) revert SourceUnhealthy();
        if (fractionWad == 0 || fractionWad > WAD) revert InvalidAmount();
        uint256 seniorSupply = SENIOR_TOKEN.totalSupply();
        uint256 juniorSupply = JUNIOR_TOKEN.totalSupply();
        if (seniorSupply == 0 || juniorSupply == 0) revert InvalidAmount();

        seniorShares = Math.mulDiv(seniorSupply, fractionWad, WAD, Math.Rounding.Ceil);
        juniorShares = Math.mulDiv(juniorSupply, fractionWad, WAD, Math.Rounding.Ceil);
        if (
            seniorShares > maxSeniorShares || juniorShares > maxJuniorShares
                || seniorShares > SENIOR_TOKEN.balanceOf(owner) || juniorShares > JUNIOR_TOKEN.balanceOf(owner)
        ) revert SlippageExceeded();
        if (fractionWad != WAD && (seniorShares == seniorSupply || juniorShares == juniorSupply)) {
            revert InvalidAmount();
        }

        assets = Math.mulDiv(backingAssets(), fractionWad, WAD);
        if (assets == 0 || assets < minAssets) revert SlippageExceeded();
        _burnClass(SENIOR_TOKEN, owner, seniorShares);
        _burnClass(JUNIOR_TOKEN, owner, juniorShares);
        _scaleSeniorBuckets(WAD - fractionWad, WAD);
        incomeBearingBackingAssets = Math.mulDiv(incomeBearingBackingAssets, WAD - fractionWad, WAD);
        _pushAssets(receiver, assets);
        _emitFullStackExit(owner, receiver, fractionWad, assets, seniorShares, juniorShares);
    }

    // ============ Capacity Views ============

    function seniorDepositCapacityValue() public view returns (uint256) {
        if (operatingState() != OperatingState.HealthyPreferred || JUNIOR_TOKEN.totalSupply() == 0) return 0;
        return _seniorDepositCapacity(backingValue(), seniorClaimValue());
    }

    function juniorRedemptionCapacityValue() public view returns (uint256) {
        OperatingState state = operatingState();
        if (state != OperatingState.HealthyPreferred) return 0;
        return _juniorRedemptionCapacity(backingValue(), seniorClaimValue());
    }

    // ============ Previews ============

    function previewDepositSenior(uint256 assets) public view returns (uint256) {
        uint256 value = VAULT.convertToAssets(assets);
        uint256 supply = SENIOR_TOKEN.totalSupply();
        uint256 claim = seniorClaimValue();
        return supply == 0 ? value * VALUE_SCALE : Math.mulDiv(value, supply, claim);
    }

    function previewMintSenior(uint256 shares) public view returns (uint256) {
        uint256 supply = SENIOR_TOKEN.totalSupply();
        uint256 value = supply == 0
            ? Math.ceilDiv(shares, VALUE_SCALE)
            : Math.mulDiv(shares, seniorClaimValue(), supply, Math.Rounding.Ceil);
        return _sharesForValueUp(value);
    }

    function previewRedeemSenior(uint256 shares) public view returns (uint256) {
        uint256 value = Math.mulDiv(shares, seniorClaimValue(), SENIOR_TOKEN.totalSupply());
        return VAULT.convertToShares(value);
    }

    function previewWithdrawSenior(uint256 assets) public view returns (uint256) {
        return
            Math.mulDiv(
                VAULT.convertToAssets(assets), SENIOR_TOKEN.totalSupply(), seniorClaimValue(), Math.Rounding.Ceil
            );
    }

    function previewDepositJunior(uint256 assets) public view returns (uint256) {
        uint256 value = VAULT.convertToAssets(assets);
        uint256 supply = JUNIOR_TOKEN.totalSupply();
        if (supply == 0) return value * VALUE_SCALE;
        return Math.mulDiv(value, supply, juniorResidualValue());
    }

    function previewMintJunior(uint256 shares) public view returns (uint256) {
        uint256 supply = JUNIOR_TOKEN.totalSupply();
        uint256 value = supply == 0
            ? Math.ceilDiv(shares, VALUE_SCALE)
            : Math.mulDiv(shares, juniorResidualValue(), supply, Math.Rounding.Ceil);
        return _sharesForValueUp(value);
    }

    function previewRedeemJunior(uint256 shares) public view returns (uint256) {
        uint256 value = Math.mulDiv(shares, juniorResidualValue(), JUNIOR_TOKEN.totalSupply());
        return VAULT.convertToShares(value);
    }

    function previewWithdrawJunior(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(
            VAULT.convertToAssets(assets), JUNIOR_TOKEN.totalSupply(), juniorResidualValue(), Math.Rounding.Ceil
        );
    }

    function previewFullStackExit(uint256 fractionWad)
        external
        view
        returns (uint256 assets, uint256 seniorShares, uint256 juniorShares)
    {
        if (fractionWad > WAD) revert InvalidAmount();
        assets = Math.mulDiv(backingAssets(), fractionWad, WAD);
        seniorShares = Math.mulDiv(SENIOR_TOKEN.totalSupply(), fractionWad, WAD, Math.Rounding.Ceil);
        juniorShares = Math.mulDiv(JUNIOR_TOKEN.totalSupply(), fractionWad, WAD, Math.Rounding.Ceil);
    }

    // ============ Maximums ============

    function maxDepositSenior(address receiver) external view returns (uint256) {
        if (receiver == address(0) || isRestricted(receiver)) return 0;
        return _valueToSharesDown(seniorDepositCapacityValue());
    }

    function maxMintSenior(address receiver) external view returns (uint256) {
        if (receiver == address(0) || isRestricted(receiver)) return 0;
        uint256 capacity = seniorDepositCapacityValue();
        if (capacity == 0) return 0;
        uint256 supply = SENIOR_TOKEN.totalSupply();
        uint256 claim = seniorClaimValue();
        return supply == 0 ? capacity * VALUE_SCALE : Math.mulDiv(capacity, supply, claim);
    }

    function maxRedeemSenior(address owner) external view returns (uint256) {
        OperatingState state = operatingState();
        return isRestricted(owner)
            || (state != OperatingState.HealthyPreferred && state != OperatingState.HealthyBelowPreferred)
            ? 0
            : SENIOR_TOKEN.balanceOf(owner);
    }

    function maxWithdrawSenior(address owner) external view returns (uint256) {
        uint256 shares = this.maxRedeemSenior(owner);
        return shares == 0 ? 0 : previewRedeemSenior(shares);
    }

    function maxDepositJunior(address receiver) external view returns (uint256) {
        OperatingState state = operatingState();
        if (
            receiver == address(0) || isRestricted(receiver)
                || (state != OperatingState.HealthyPreferred && state != OperatingState.HealthyBelowPreferred)
        ) return 0;
        if (JUNIOR_TOKEN.totalSupply() == 0 && SENIOR_TOKEN.totalSupply() != 0) return 0;
        if (JUNIOR_TOKEN.totalSupply() != 0 && juniorResidualValue() == 0) return 0;
        return _valueToSharesDown(_remainingBackingCapacity(backingValue()));
    }

    function maxMintJunior(address receiver) external view returns (uint256) {
        uint256 assets = this.maxDepositJunior(receiver);
        return assets == 0 ? 0 : previewDepositJunior(assets);
    }

    function maxRedeemJunior(address owner) external view returns (uint256) {
        if (isRestricted(owner)) return 0;
        uint256 capacity = juniorRedemptionCapacityValue();
        if (capacity == 0) return 0;
        uint256 residual = juniorResidualValue();
        return residual == 0
            ? 0
            : Math.min(JUNIOR_TOKEN.balanceOf(owner), Math.mulDiv(capacity, JUNIOR_TOKEN.totalSupply(), residual));
    }

    function maxWithdrawJunior(address owner) external view returns (uint256) {
        uint256 shares = this.maxRedeemJunior(owner);
        return shares == 0 ? 0 : previewRedeemJunior(shares);
    }

    // ============ Internal Accounting ============

    function _syncIncome() private returns (uint256 newLiveUnitsWad, uint256 newCrystallizedValue) {
        uint256 cohortBacking = incomeBearingBackingAssets;
        if (backingAssets() < cohortBacking) revert UnsafeTransfer();
        VAULT.sweep();
        INCOME_ACCUMULATOR.materializeSTRConEligibleIncome();
        IEligibleIncomeAccounting.EligibleIncomeState memory current = INCOME_ACCUMULATOR.eligibleIncomeState();
        uint256 oldScale = checkpointLiveScaleWad;
        if (oldScale == 0 || current.liveUnitScaleWad > oldScale) revert SourceUnhealthy();
        uint256 crystallizedScaleIncrease = current.crystallizedValueScaleWad - checkpointCrystallizedScaleWad;

        if (seniorLiveUnitsWad != 0) {
            uint256 existingCrystallizedWad = Math.mulDiv(seniorLiveUnitsWad, crystallizedScaleIncrease, oldScale);
            seniorLiveUnitsWad = Math.mulDiv(seniorLiveUnitsWad, current.liveUnitScaleWad, oldScale);
            newCrystallizedValue = existingCrystallizedWad / VALUE_SCALE;
            crystallizedSeniorValue += newCrystallizedValue;
        }

        uint256 historicalLive = Math.mulDiv(current.liveUnitScaleWad, checkpointLiveOffsetWad, oldScale);
        uint256 relativeLivePerShareWad = current.liveUnitsOffsetWad - historicalLive;
        uint256 historicalCrystallized = Math.mulDiv(crystallizedScaleIncrease, checkpointLiveOffsetWad, oldScale);
        uint256 relativeCrystallizedPerShareWad =
            current.crystallizedValueOffsetWad - checkpointCrystallizedOffsetWad - historicalCrystallized;

        if (SENIOR_TOKEN.totalSupply() != 0) {
            uint256 newLiveUnits = Math.mulDiv(cohortBacking, relativeLivePerShareWad, WAD);
            newLiveUnitsWad = Math.mulDiv(newLiveUnits, ALPHA_BPS, BPS);
            seniorLiveUnitsWad += newLiveUnitsWad;

            uint256 newCrystallizedWad = Math.mulDiv(cohortBacking, relativeCrystallizedPerShareWad, WAD);
            uint256 allocatedValue = Math.mulDiv(newCrystallizedWad, ALPHA_BPS, BPS) / VALUE_SCALE;
            newCrystallizedValue += allocatedValue;
            crystallizedSeniorValue += allocatedValue;
        }

        _writeCheckpoint(current);
        incomeBearingBackingAssets = backingAssets();
        emit IncomeSynchronized(newLiveUnitsWad, newCrystallizedValue, seniorClaimValue());
    }

    function _writeCheckpoint(IEligibleIncomeAccounting.EligibleIncomeState memory state) private {
        checkpointLiveScaleWad = state.liveUnitScaleWad;
        checkpointLiveOffsetWad = state.liveUnitsOffsetWad;
        checkpointCrystallizedScaleWad = state.crystallizedValueScaleWad;
        checkpointCrystallizedOffsetWad = state.crystallizedValueOffsetWad;
        checkpointCrystallizationNonce = state.crystallizationNonce;
    }

    function _seniorDepositCapacity(uint256 backing, uint256 claim) private view returns (uint256) {
        if (JUNIOR_TOKEN.totalSupply() == 0 || backing < claim) return 0;
        uint256 required = Math.mulDiv(PREFERRED_COVERAGE_WAD, claim, WAD, Math.Rounding.Ceil);
        if (backing <= required) return 0;
        return Math.min(
            Math.mulDiv(backing - required, WAD, PREFERRED_COVERAGE_WAD - WAD), _remainingBackingCapacity(backing)
        );
    }

    function _remainingBackingCapacity(uint256 backing) private view returns (uint256) {
        return backing >= MAX_BACKING_VALUE ? 0 : MAX_BACKING_VALUE - backing;
    }

    function _juniorRedemptionCapacity(uint256 backing, uint256 claim) private view returns (uint256) {
        if (backing < claim) return 0;
        uint256 required = Math.mulDiv(PREFERRED_COVERAGE_WAD, claim, WAD, Math.Rounding.Ceil);
        return backing > required ? backing - required : 0;
    }

    function _coverage(uint256 backing, uint256 claim) private pure returns (uint256) {
        return claim == 0 ? type(uint256).max : Math.mulDiv(backing, WAD, claim);
    }

    function _requireSourceHealthy() private view {
        if (
            hardPaused || VAULT.paused() || VAULT.marketMode() == IStakedUSDat.MarketMode.Restricted
                || !INCOME_ACCUMULATOR.canAccount()
        ) revert SourceUnhealthy();
    }

    function _requireHealthy(uint256 backing, uint256 claim) private pure {
        if (backing < claim) revert SeniorImpaired();
    }

    function _requireParticipants(address caller, address receiver, address owner) private view {
        if (caller == address(0) || receiver == address(0) || owner == address(0)) revert InvalidAmount();
        if (isRestricted(caller)) revert RestrictedAccount(caller);
        if (isRestricted(receiver)) revert RestrictedAccount(receiver);
        if (owner != address(0) && isRestricted(owner)) revert RestrictedAccount(owner);
    }

    function _sharesForValueUp(uint256 value) private view returns (uint256 shares) {
        shares = VAULT.convertToShares(value);
        if (VAULT.convertToAssets(shares) < value) ++shares;
    }

    // ============ Asset Conversions and Transfers ============

    function _valueToSharesDown(uint256 value) private view returns (uint256) {
        return value == 0 ? 0 : VAULT.convertToShares(value);
    }

    function _pullAssets(uint256 assets) private {
        uint256 beforeBalance = backingAssets();
        IERC20(address(VAULT)).safeTransferFrom(msg.sender, address(this), assets);
        if (backingAssets() != beforeBalance + assets) revert UnsafeTransfer();
    }

    function _pushAssets(address receiver, uint256 assets) private {
        uint256 beforeBalance = backingAssets();
        IERC20(address(VAULT)).safeTransfer(receiver, assets);
        if (backingAssets() + assets != beforeBalance) revert UnsafeTransfer();
    }

    function _burnClass(TrancheShare token, address owner, uint256 shares) private {
        if (msg.sender == owner) {
            token.burn(owner, shares);
        } else {
            IERC20(address(token)).safeTransferFrom(owner, address(this), shares);
            token.burn(address(this), shares);
        }
    }

    // ============ Claim Scaling ============

    function _scaleSeniorBucketsByShares(uint256 remainingShares, uint256 oldShares) private {
        _scaleSeniorBuckets(remainingShares, oldShares);
    }

    function _scaleSeniorBuckets(uint256 numerator, uint256 denominator) private {
        baseSeniorClaimValue = Math.mulDiv(baseSeniorClaimValue, numerator, denominator);
        seniorLiveUnitsWad = Math.mulDiv(seniorLiveUnitsWad, numerator, denominator);
        crystallizedSeniorValue = Math.mulDiv(crystallizedSeniorValue, numerator, denominator);
    }

    // ============ Event Helpers ============

    function _emitSeniorDeposit(address receiver, uint256 assets, uint256 shares) private {
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        emit SeniorDeposit(msg.sender, receiver, assets, shares, backing, claim, _coverage(backing, claim));
    }

    function _emitSeniorWithdraw(address owner, address receiver, uint256 assets, uint256 shares) private {
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        emit SeniorWithdraw(msg.sender, owner, receiver, assets, shares, backing, claim, _coverage(backing, claim));
    }

    function _emitJuniorDeposit(address receiver, uint256 assets, uint256 shares) private {
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        emit JuniorDeposit(msg.sender, receiver, assets, shares, backing, claim, _coverage(backing, claim));
    }

    function _emitJuniorWithdraw(address owner, address receiver, uint256 assets, uint256 shares) private {
        uint256 backing = backingValue();
        uint256 claim = seniorClaimValue();
        emit JuniorWithdraw(msg.sender, owner, receiver, assets, shares, backing, claim, _coverage(backing, claim));
    }

    function _emitFullStackExit(
        address owner,
        address receiver,
        uint256 fractionWad,
        uint256 assets,
        uint256 seniorShares,
        uint256 juniorShares
    ) private {
        emit FullStackExit(msg.sender, owner, receiver, fractionWad, assets, seniorShares, juniorShares);
    }
}
