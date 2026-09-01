// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Executable decision models only. These contracts are not production implementations.
contract PairedTrancheStateModel {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    error Closed();
    error InvalidAmount();

    uint16 public immutable alphaBps;
    bool public healthy = true;
    uint256 public backingUnits;
    uint256 public backingValue;
    uint256 public seniorClaim;
    uint256 public pairSupply;
    mapping(address => uint256) public seniorBalance;
    mapping(address => uint256) public juniorBalance;

    constructor(
        address holder,
        uint256 initialBackingUnits,
        uint256 initialBackingValue,
        uint256 initialSeniorClaim,
        uint256 initialPairSupply,
        uint16 alphaBps_
    ) {
        require(
            holder != address(0) && initialBackingUnits != 0 && initialBackingValue >= initialSeniorClaim
                && initialPairSupply != 0 && alphaBps_ <= BPS
        );
        backingUnits = initialBackingUnits;
        backingValue = initialBackingValue;
        seniorClaim = initialSeniorClaim;
        pairSupply = initialPairSupply;
        seniorBalance[holder] = initialPairSupply;
        juniorBalance[holder] = initialPairSupply;
        alphaBps = alphaBps_;
    }

    function markedSenior() public view returns (uint256) {
        return Math.min(backingValue, seniorClaim);
    }

    function juniorResidual() public view returns (uint256) {
        return backingValue - markedSenior();
    }

    function seniorNavPerToken() external view returns (uint256) {
        return Math.mulDiv(markedSenior(), WAD, pairSupply);
    }

    function juniorNavPerToken() external view returns (uint256) {
        return Math.mulDiv(juniorResidual(), WAD, pairSupply);
    }

    function setHealthy(bool value) external {
        healthy = value;
    }

    function eligibleIncome(uint256 value) external {
        backingValue += value;
        if (pairSupply != 0) seniorClaim += Math.mulDiv(value, alphaBps, BPS);
    }

    function unrelatedGain(uint256 value) external {
        backingValue += value;
    }

    function loss(uint256 value) external {
        if (value >= backingValue) revert InvalidAmount();
        backingValue -= value;
    }

    function fullStackDeposit(address holder, uint256 units) external returns (uint256 pairs) {
        if (!healthy) revert Closed();
        if (units == 0 || backingUnits == 0) revert InvalidAmount();
        pairs = Math.mulDiv(units, pairSupply, backingUnits);
        if (pairs == 0) revert InvalidAmount();
        uint256 value = Math.mulDiv(units, backingValue, backingUnits);
        uint256 claim = Math.mulDiv(units, seniorClaim, backingUnits);
        backingUnits += units;
        backingValue += value;
        seniorClaim += claim;
        pairSupply += pairs;
        seniorBalance[holder] += pairs;
        juniorBalance[holder] += pairs;
    }

    function recombine(address holder, uint256 pairs) external returns (uint256 unitsOut) {
        if (pairs == 0 || pairs > seniorBalance[holder] || pairs > juniorBalance[holder]) {
            revert InvalidAmount();
        }
        unitsOut = Math.mulDiv(pairs, backingUnits, pairSupply);
        uint256 valueOut = Math.mulDiv(pairs, backingValue, pairSupply);
        uint256 claimOut = Math.mulDiv(pairs, seniorClaim, pairSupply);
        seniorBalance[holder] -= pairs;
        juniorBalance[holder] -= pairs;
        pairSupply -= pairs;
        backingUnits -= unitsOut;
        backingValue -= valueOut;
        seniorClaim -= claimOut;
    }

    function transferSenior(address from, address to, uint256 amount) external {
        if (amount > seniorBalance[from]) revert InvalidAmount();
        seniorBalance[from] -= amount;
        seniorBalance[to] += amount;
    }

    function transferJunior(address from, address to, uint256 amount) external {
        if (amount > juniorBalance[from]) revert InvalidAmount();
        juniorBalance[from] -= amount;
        juniorBalance[to] += amount;
    }
}

/// @dev One backing pool with two independently supplied capital accounts.
contract IndependentCapitalAccountsStateModel {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    error Closed();
    error InvalidAmount();
    error CapacityExceeded();
    error SeniorImpaired();
    error JuniorEpochRequired();
    error InvalidFullStackRatio();

    uint16 public immutable alphaBps;
    uint256 public immutable preferredCoverageWad;
    uint256 public immutable hardCoverageWad;
    bool public healthy = true;

    uint256 public backingUnits;
    uint256 public backingValue;
    uint256 public seniorClaim;
    uint256 public seniorSupply;
    uint256 public juniorSupply;
    uint256 public juniorEpoch;
    mapping(address => uint256) public seniorBalance;
    mapping(uint256 => mapping(address => uint256)) public juniorBalance;

    constructor(
        address holder,
        uint256 initialBackingUnits,
        uint256 initialBackingValue,
        uint256 initialSeniorClaim,
        uint256 initialSeniorSupply,
        uint256 initialJuniorSupply,
        uint16 alphaBps_,
        uint256 preferredCoverageWad_,
        uint256 hardCoverageWad_
    ) {
        require(
            holder != address(0) && initialBackingUnits != 0 && initialBackingValue >= initialSeniorClaim
                && initialSeniorSupply != 0 && initialJuniorSupply != 0 && alphaBps_ <= BPS
                && preferredCoverageWad_ > WAD && hardCoverageWad_ >= WAD && hardCoverageWad_ < preferredCoverageWad_
        );
        backingUnits = initialBackingUnits;
        backingValue = initialBackingValue;
        seniorClaim = initialSeniorClaim;
        seniorSupply = initialSeniorSupply;
        juniorSupply = initialJuniorSupply;
        seniorBalance[holder] = initialSeniorSupply;
        juniorBalance[0][holder] = initialJuniorSupply;
        alphaBps = alphaBps_;
        preferredCoverageWad = preferredCoverageWad_;
        hardCoverageWad = hardCoverageWad_;
    }

    function markedSenior() public view returns (uint256) {
        return Math.min(backingValue, seniorClaim);
    }

    function juniorResidual() public view returns (uint256) {
        return backingValue - markedSenior();
    }

    function coverageWad() public view returns (uint256) {
        if (seniorClaim == 0) return type(uint256).max;
        return Math.mulDiv(backingValue, WAD, seniorClaim);
    }

    function belowHardCoverage() public view returns (bool) {
        return seniorClaim != 0 && coverageWad() < hardCoverageWad;
    }

    function seniorNavPerToken() public view returns (uint256) {
        if (seniorSupply == 0) return WAD;
        return Math.mulDiv(markedSenior(), WAD, seniorSupply);
    }

    function juniorNavPerToken() public view returns (uint256) {
        if (juniorSupply == 0) return 0;
        return Math.mulDiv(juniorResidual(), WAD, juniorSupply);
    }

    function currentJuniorBalance(address holder) external view returns (uint256) {
        return juniorBalance[juniorEpoch][holder];
    }

    function juniorRedemptionCapacity() public view returns (uint256) {
        if (backingValue < seniorClaim) return 0;
        uint256 required = Math.mulDiv(preferredCoverageWad, seniorClaim, WAD, Math.Rounding.Ceil);
        return backingValue > required ? backingValue - required : 0;
    }

    function seniorDepositCapacity() public view returns (uint256) {
        if (juniorSupply == 0 || backingValue < seniorClaim) return 0;
        uint256 required = Math.mulDiv(preferredCoverageWad, seniorClaim, WAD, Math.Rounding.Ceil);
        if (backingValue <= required) return 0;
        return Math.mulDiv(backingValue - required, WAD, preferredCoverageWad - WAD);
    }

    function setHealthy(bool value) external {
        healthy = value;
    }

    function eligibleIncome(uint256 value) external {
        backingValue += value;
        if (seniorSupply != 0) seniorClaim += Math.mulDiv(value, alphaBps, BPS);
    }

    function unrelatedGain(uint256 value) external {
        backingValue += value;
    }

    function loss(uint256 value) external {
        if (value >= backingValue) revert InvalidAmount();
        backingValue -= value;
    }

    function seniorDeposit(address holder, uint256 units) external returns (uint256 shares) {
        _requireHealthy();
        if (units == 0 || juniorSupply == 0) revert InvalidAmount();
        uint256 value = _valueOfBacking(units);
        if (value > seniorDepositCapacity()) revert CapacityExceeded();
        shares = seniorSupply == 0 ? value : Math.mulDiv(value, seniorSupply, seniorClaim);
        if (shares == 0) revert InvalidAmount();
        backingUnits += units;
        backingValue += value;
        seniorClaim += value;
        seniorSupply += shares;
        seniorBalance[holder] += shares;
    }

    function seniorRedeem(address holder, uint256 shares) external returns (uint256 unitsOut) {
        _requireHealthy();
        if (backingValue < seniorClaim) revert SeniorImpaired();
        if (shares == 0 || shares > seniorBalance[holder]) revert InvalidAmount();
        uint256 value = Math.mulDiv(shares, seniorClaim, seniorSupply);
        unitsOut = Math.mulDiv(value, backingUnits, backingValue);
        if (unitsOut == 0) revert InvalidAmount();
        seniorBalance[holder] -= shares;
        seniorSupply -= shares;
        seniorClaim -= value;
        backingUnits -= unitsOut;
        backingValue -= value;
    }

    function juniorDeposit(address holder, uint256 units) external returns (uint256 shares) {
        _requireHealthy();
        uint256 residual = juniorResidual();
        if (units == 0) revert InvalidAmount();
        if (juniorSupply == 0 || residual == 0) revert JuniorEpochRequired();
        uint256 value = _valueOfBacking(units);
        shares = Math.mulDiv(value, juniorSupply, residual);
        if (shares == 0) revert InvalidAmount();
        backingUnits += units;
        backingValue += value;
        juniorSupply += shares;
        juniorBalance[juniorEpoch][holder] += shares;
    }

    function juniorRedeem(address holder, uint256 shares) external returns (uint256 unitsOut) {
        _requireHealthy();
        if (backingValue < seniorClaim) revert SeniorImpaired();
        if (shares == 0 || shares > juniorBalance[juniorEpoch][holder]) revert InvalidAmount();
        uint256 value = Math.mulDiv(shares, juniorResidual(), juniorSupply);
        if (value > juniorRedemptionCapacity()) revert CapacityExceeded();
        unitsOut = Math.mulDiv(value, backingUnits, backingValue);
        if (unitsOut == 0) revert InvalidAmount();
        juniorBalance[juniorEpoch][holder] -= shares;
        juniorSupply -= shares;
        backingUnits -= unitsOut;
        backingValue -= value;
    }

    function fullStackDeposit(address holder, uint256 units)
        external
        returns (uint256 seniorShares, uint256 juniorShares)
    {
        if (units == 0 || backingUnits == 0 || seniorSupply == 0 || juniorSupply == 0) revert InvalidAmount();
        seniorShares = Math.mulDiv(units, seniorSupply, backingUnits);
        juniorShares = Math.mulDiv(units, juniorSupply, backingUnits);
        if (seniorShares == 0 || juniorShares == 0) revert InvalidAmount();
        uint256 value = Math.mulDiv(units, backingValue, backingUnits);
        uint256 claim = Math.mulDiv(units, seniorClaim, backingUnits);
        backingUnits += units;
        backingValue += value;
        seniorClaim += claim;
        seniorSupply += seniorShares;
        juniorSupply += juniorShares;
        seniorBalance[holder] += seniorShares;
        juniorBalance[juniorEpoch][holder] += juniorShares;
    }

    function fullStackExit(address holder, uint256 seniorShares, uint256 juniorShares)
        external
        returns (uint256 unitsOut)
    {
        if (
            seniorShares == 0 || seniorShares > seniorBalance[holder]
                || juniorShares > juniorBalance[juniorEpoch][holder]
                || seniorShares * juniorSupply != juniorShares * seniorSupply
        ) revert InvalidFullStackRatio();
        unitsOut = Math.mulDiv(seniorShares, backingUnits, seniorSupply);
        uint256 valueOut = Math.mulDiv(seniorShares, backingValue, seniorSupply);
        uint256 claimOut = Math.mulDiv(seniorShares, seniorClaim, seniorSupply);
        seniorBalance[holder] -= seniorShares;
        juniorBalance[juniorEpoch][holder] -= juniorShares;
        seniorSupply -= seniorShares;
        juniorSupply -= juniorShares;
        backingUnits -= unitsOut;
        backingValue -= valueOut;
        seniorClaim -= claimOut;
    }

    /// @dev Conservative integer implementation of a fraction-based full-stack exit.
    /// It rounds both token burns up and custody/value returned down, donating only dust
    /// to remaining holders while remaining independent of live NAV/oracle health.
    function fullStackExitFraction(address holder, uint256 fractionWad)
        external
        returns (uint256 unitsOut, uint256 seniorShares, uint256 juniorShares)
    {
        if (fractionWad == 0 || fractionWad > WAD) revert InvalidAmount();
        seniorShares = Math.mulDiv(seniorSupply, fractionWad, WAD, Math.Rounding.Ceil);
        juniorShares = Math.mulDiv(juniorSupply, fractionWad, WAD, Math.Rounding.Ceil);
        if (seniorShares > seniorBalance[holder] || juniorShares > juniorBalance[juniorEpoch][holder]) {
            revert InvalidAmount();
        }
        unitsOut = Math.mulDiv(backingUnits, fractionWad, WAD, Math.Rounding.Floor);
        uint256 valueOut = Math.mulDiv(backingValue, fractionWad, WAD, Math.Rounding.Floor);
        uint256 claimOut = Math.mulDiv(seniorClaim, fractionWad, WAD, Math.Rounding.Floor);
        seniorBalance[holder] -= seniorShares;
        juniorBalance[juniorEpoch][holder] -= juniorShares;
        seniorSupply -= seniorShares;
        juniorSupply -= juniorShares;
        backingUnits -= unitsOut;
        backingValue -= valueOut;
        seniorClaim -= claimOut;
    }

    /// @dev Models the necessary new-token epoch after old Junior is economically wiped.
    function startJuniorRecapitalizationEpoch() external {
        _requireHealthy();
        if (juniorResidual() != 0 || juniorSupply == 0) revert InvalidAmount();
        ++juniorEpoch;
        juniorSupply = 0;
    }

    /// @dev The recap investor first cures Senior impairment; only the new residual mints new-epoch Junior.
    function recapitalizeJunior(address holder, uint256 units) external returns (uint256 shares) {
        _requireHealthy();
        if (juniorSupply != 0 || juniorResidual() != 0 || seniorSupply == 0 || units == 0) {
            revert InvalidAmount();
        }
        uint256 value = _valueOfBacking(units);
        uint256 deficit = seniorClaim > backingValue ? seniorClaim - backingValue : 0;
        if (value <= deficit) revert InvalidAmount();
        backingUnits += units;
        backingValue += value;
        shares = backingValue - seniorClaim;
        juniorSupply = shares;
        juniorBalance[juniorEpoch][holder] = shares;
    }

    function transferSenior(address from, address to, uint256 amount) external {
        if (amount > seniorBalance[from]) revert InvalidAmount();
        seniorBalance[from] -= amount;
        seniorBalance[to] += amount;
    }

    function transferJunior(address from, address to, uint256 amount) external {
        if (amount > juniorBalance[juniorEpoch][from]) revert InvalidAmount();
        juniorBalance[juniorEpoch][from] -= amount;
        juniorBalance[juniorEpoch][to] += amount;
    }

    function _valueOfBacking(uint256 units) private view returns (uint256) {
        if (backingUnits == 0) return units;
        return Math.mulDiv(units, backingValue, backingUnits);
    }

    function _requireHealthy() private view {
        if (!healthy) revert Closed();
    }
}

contract TrancheArchitectureComparisonTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant C = 1.5e18;
    uint256 private constant HARD_C = 1.2e18;
    uint16 private constant ALPHA_BPS = 4_000;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function test_capacityEquationsMatchWorkedExample() public {
        IndependentCapitalAccountsStateModel seniorCase = _independent(120e18, 75e18, 75e18, 45e18);
        assertEq(seniorCase.juniorRedemptionCapacity(), 7.5e18);
        assertEq(seniorCase.seniorDepositCapacity(), 15e18);

        uint256 seniorPriceBefore = seniorCase.seniorNavPerToken();
        seniorCase.seniorDeposit(ALICE, 15e18);
        assertEq(seniorCase.coverageWad(), C);
        assertEq(seniorCase.seniorNavPerToken(), seniorPriceBefore);

        IndependentCapitalAccountsStateModel juniorCase = _independent(120e18, 75e18, 75e18, 45e18);
        uint256 juniorPriceBefore = juniorCase.juniorNavPerToken();
        juniorCase.juniorRedeem(ALICE, 7.5e18);
        assertEq(juniorCase.coverageWad(), C);
        assertEq(juniorCase.juniorNavPerToken(), juniorPriceBefore);
    }

    function test_sameClassEntryAndExitDoNotMovePerShareNav() public {
        IndependentCapitalAccountsStateModel model = _independent(180e18, 100e18, 100e18, 80e18);
        uint256 seniorPrice = model.seniorNavPerToken();
        uint256 juniorPrice = model.juniorNavPerToken();

        model.seniorDeposit(ALICE, 10e18);
        assertEq(model.seniorNavPerToken(), seniorPrice);
        model.juniorDeposit(ALICE, 10e18);
        assertEq(model.juniorNavPerToken(), juniorPrice);

        uint256 coverageBeforeSeniorExit = model.coverageWad();
        model.seniorRedeem(ALICE, 10e18);
        assertGe(model.coverageWad(), coverageBeforeSeniorExit);

        uint256 coverageBeforeJuniorDeposit = model.coverageWad();
        model.juniorDeposit(ALICE, 5e18);
        assertGe(model.coverageWad(), coverageBeforeJuniorDeposit);
    }

    function test_capacityIsConsumedAtomicallyFirstCome() public {
        IndependentCapitalAccountsStateModel seniorModel = _independent(120e18, 75e18, 75e18, 45e18);
        seniorModel.seniorDeposit(ALICE, 10e18);
        assertEq(seniorModel.seniorDepositCapacity(), 5e18);
        vm.expectRevert(IndependentCapitalAccountsStateModel.CapacityExceeded.selector);
        seniorModel.seniorDeposit(BOB, 6e18);
        seniorModel.seniorDeposit(BOB, 5e18);
        assertEq(seniorModel.coverageWad(), C);

        IndependentCapitalAccountsStateModel juniorModel = _independent(120e18, 75e18, 75e18, 45e18);
        juniorModel.juniorRedeem(ALICE, 5e18);
        assertEq(juniorModel.juniorRedemptionCapacity(), 2.5e18);
        vm.expectRevert(IndependentCapitalAccountsStateModel.CapacityExceeded.selector);
        juniorModel.juniorRedeem(ALICE, 3e18);
        juniorModel.juniorRedeem(ALICE, 2.5e18);
        assertEq(juniorModel.coverageWad(), C);
    }

    function test_transfersDoNotChangeEitherCapitalAccount() public {
        IndependentCapitalAccountsStateModel model = _independent(150e18, 100e18, 100e18, 50e18);
        uint256 value = model.backingValue();
        uint256 claim = model.seniorClaim();
        uint256 residual = model.juniorResidual();

        model.transferSenior(ALICE, BOB, 10e18);
        model.transferJunior(ALICE, BOB, 5e18);
        assertEq(model.backingValue(), value);
        assertEq(model.seniorClaim(), claim);
        assertEq(model.juniorResidual(), residual);
        assertEq(model.seniorBalance(BOB), 10e18);
        assertEq(model.currentJuniorBalance(BOB), 5e18);
    }

    function test_proportionalFullStackExitIsOracleIndependent() public {
        IndependentCapitalAccountsStateModel model = _independent(150e18, 100e18, 100e18, 50e18);
        model.setHealthy(false);

        uint256 unitsOut = model.fullStackExit(ALICE, 10e18, 5e18);
        assertEq(unitsOut, 15e18);
        assertEq(model.backingUnits(), 135e18);
        assertEq(model.backingValue(), 135e18);
        assertEq(model.seniorClaim(), 90e18);
        assertEq(model.seniorSupply(), 90e18);
        assertEq(model.juniorSupply(), 45e18);

        vm.expectRevert(IndependentCapitalAccountsStateModel.Closed.selector);
        model.seniorRedeem(ALICE, 1e18);
        vm.expectRevert(IndependentCapitalAccountsStateModel.Closed.selector);
        model.juniorRedeem(ALICE, 1e18);
    }

    function test_fullStackDepositPreservesBothClassNavsAndCoverage() public {
        IndependentCapitalAccountsStateModel model = _independent(150e18, 100e18, 100e18, 50e18);
        uint256 seniorNav = model.seniorNavPerToken();
        uint256 juniorNav = model.juniorNavPerToken();
        uint256 coverage = model.coverageWad();

        (uint256 seniorShares, uint256 juniorShares) = model.fullStackDeposit(BOB, 15e18);
        assertEq(seniorShares, 10e18);
        assertEq(juniorShares, 5e18);
        assertEq(model.seniorNavPerToken(), seniorNav);
        assertEq(model.juniorNavPerToken(), juniorNav);
        assertEq(model.coverageWad(), coverage);
        assertEq(model.fullStackExit(BOB, seniorShares, juniorShares), 15e18);
    }

    function testFuzz_fractionalFullStackExitRoundsOnlyInFavorOfRemainingBacking(uint64 rawFraction) public {
        uint256 fraction = bound(uint256(rawFraction), 1e9, 0.9e18);
        IndependentCapitalAccountsStateModel model = new IndependentCapitalAccountsStateModel(
            ALICE, 151e18 + 3, 151e18 + 3, 100e18 + 1, 97e18 + 7, 53e18 + 11, ALPHA_BPS, C, HARD_C
        );
        uint256 valueBefore = model.backingValue();
        uint256 seniorNavBefore = model.seniorNavPerToken();
        uint256 juniorNavBefore = model.juniorNavPerToken();
        model.setHealthy(false);

        (uint256 unitsOut,,) = model.fullStackExitFraction(ALICE, fraction);
        assertEq(unitsOut, Math.mulDiv(151e18 + 3, fraction, WAD));
        assertEq(model.markedSenior() + model.juniorResidual(), model.backingValue());
        assertEq(model.backingValue(), valueBefore - Math.mulDiv(valueBefore, fraction, WAD));
        assertGe(model.seniorNavPerToken(), seniorNavBefore);
        assertGe(model.juniorNavPerToken(), juniorNavBefore);
    }

    function test_incomeAndUnrelatedReturnAllocateToTheIntendedAccounts() public {
        IndependentCapitalAccountsStateModel model = _independent(150e18, 100e18, 100e18, 50e18);
        model.eligibleIncome(10e18);
        assertEq(model.backingValue(), 160e18);
        assertEq(model.seniorClaim(), 104e18);
        assertEq(model.juniorResidual(), 56e18);

        model.unrelatedGain(10e18);
        assertEq(model.seniorClaim(), 104e18);
        assertEq(model.juniorResidual(), 66e18);
    }

    function test_hardCoverageIsASeparateLowerSafetyState() public {
        IndependentCapitalAccountsStateModel model = _independent(150e18, 100e18, 100e18, 50e18);
        assertFalse(model.belowHardCoverage());
        model.loss(31e18);
        assertTrue(model.belowHardCoverage());
        assertEq(model.seniorDepositCapacity(), 0);
        assertEq(model.juniorRedemptionCapacity(), 0);

        uint256 coverageBefore = model.coverageWad();
        model.juniorDeposit(ALICE, 20e18);
        assertGt(model.coverageWad(), coverageBefore);
    }

    function test_impairedSeniorCannotRedeemAndJuniorRequiresANewEpoch() public {
        IndependentCapitalAccountsStateModel model = _independent(150e18, 100e18, 100e18, 50e18);
        model.loss(60e18);
        assertEq(model.markedSenior(), 90e18);
        assertEq(model.juniorResidual(), 0);

        vm.expectRevert(IndependentCapitalAccountsStateModel.SeniorImpaired.selector);
        model.seniorRedeem(ALICE, 1e18);
        vm.expectRevert(IndependentCapitalAccountsStateModel.JuniorEpochRequired.selector);
        model.juniorDeposit(ALICE, 20e18);

        assertEq(model.juniorBalance(0, ALICE), 50e18);
        model.startJuniorRecapitalizationEpoch();
        assertEq(model.juniorEpoch(), 1);
        assertEq(model.juniorSupply(), 0);
        vm.expectRevert(IndependentCapitalAccountsStateModel.InvalidAmount.selector);
        model.seniorDeposit(BOB, 1e18);
        uint256 newJunior = model.recapitalizeJunior(BOB, 20e18);
        // After the loss each sUSDat unit is worth 0.60. Twelve value enters,
        // ten cures Senior impairment, and two becomes new-epoch Junior NAV.
        assertEq(newJunior, 2e18);
        assertEq(model.juniorBalance(0, ALICE), 50e18);
        assertEq(model.juniorBalance(1, BOB), 2e18);
        assertEq(model.juniorNavPerToken(), WAD);
    }

    function test_zeroSeniorSupplyRestartsWithoutHistoricalIncome() public {
        IndependentCapitalAccountsStateModel model = _independent(150e18, 100e18, 100e18, 50e18);
        model.seniorRedeem(ALICE, 100e18);
        assertEq(model.seniorSupply(), 0);
        assertEq(model.seniorClaim(), 0);

        model.eligibleIncome(20e18);
        assertEq(model.seniorClaim(), 0);
        uint256 residualBefore = model.juniorResidual();

        uint256 newSenior = model.seniorDeposit(BOB, 10e18);
        // The retained sUSDat appreciated while Senior supply was zero, so ten
        // sUSDat units enter at fourteen value units without capturing history.
        assertEq(newSenior, 14e18);
        assertEq(model.seniorClaim(), 14e18);
        assertEq(model.seniorNavPerToken(), WAD);
        assertEq(model.juniorResidual(), residualBefore);
    }

    function test_pairedModelPreservesEqualSupplyButCoverageFloats() public {
        PairedTrancheStateModel model = new PairedTrancheStateModel(ALICE, 100e18, 100e18, 70e18, 100e18, ALPHA_BPS);
        model.eligibleIncome(10e18);
        uint256 coverageAfterIncome = Math.mulDiv(model.backingValue(), WAD, model.seniorClaim());

        uint256 pairs = model.fullStackDeposit(BOB, 10e18);
        assertEq(pairs, 10e18);
        assertEq(model.pairSupply(), 110e18);
        assertEq(model.seniorBalance(ALICE) + model.seniorBalance(BOB), model.pairSupply());
        assertEq(model.juniorBalance(ALICE) + model.juniorBalance(BOB), model.pairSupply());
        assertEq(Math.mulDiv(model.backingValue(), WAD, model.seniorClaim()), coverageAfterIncome);

        model.setHealthy(false);
        assertEq(model.recombine(BOB, pairs), 10e18);
    }

    function testFuzz_capacityGatesAreConservative(uint96 rawA, uint96 rawQ) public {
        uint256 q = bound(uint256(rawQ), 10e18, 1_000e18);
        uint256 a = bound(uint256(rawA), Math.mulDiv(q, C, WAD), 3_000e18);
        vm.assume(a >= Math.mulDiv(q, C, WAD));
        IndependentCapitalAccountsStateModel model = _independent(a, q, q, a - q);

        uint256 seniorCapacity = model.seniorDepositCapacity();
        if (seniorCapacity != 0) {
            model.seniorDeposit(ALICE, seniorCapacity);
            assertGe(model.coverageWad(), C);
        }

        IndependentCapitalAccountsStateModel juniorModel = _independent(a, q, q, a - q);
        uint256 juniorCapacity = juniorModel.juniorRedemptionCapacity();
        if (juniorCapacity != 0) {
            uint256 shares = Math.mulDiv(juniorCapacity, juniorModel.juniorSupply(), juniorModel.juniorResidual());
            if (shares != 0) juniorModel.juniorRedeem(ALICE, shares);
            assertGe(juniorModel.coverageWad(), C);
        }
    }

    function testFuzz_arbitraryHealthySequencesConserveValue(uint256 seed) public {
        IndependentCapitalAccountsStateModel model = _independent(200e18, 100e18, 100e18, 100e18);
        for (uint256 i; i < 64; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            uint256 operation = random % 7;
            uint256 amount = (1 + ((random >> 8) % 5)) * 1e18;

            if (operation == 0) {
                model.eligibleIncome(amount);
            } else if (operation == 1) {
                model.unrelatedGain(amount);
            } else if (operation == 2) {
                uint256 capacity = model.seniorDepositCapacity();
                uint256 units = Math.mulDiv(capacity, model.backingUnits(), model.backingValue());
                units = Math.min(amount, units);
                if (units != 0) {
                    try model.seniorDeposit(ALICE, units) {} catch {}
                }
            } else if (operation == 3) {
                if (model.juniorResidual() != 0 && model.juniorSupply() != 0) {
                    try model.juniorDeposit(ALICE, amount) {} catch {}
                }
            } else if (operation == 4) {
                uint256 balance = model.seniorBalance(ALICE);
                if (balance > 1e18) {
                    try model.seniorRedeem(ALICE, Math.min(amount, balance / 2)) {} catch {}
                }
            } else if (operation == 5) {
                uint256 capacity = model.juniorRedemptionCapacity();
                uint256 balance = model.currentJuniorBalance(ALICE);
                if (capacity != 0 && balance != 0) {
                    uint256 shares =
                        Math.mulDiv(Math.min(amount, capacity), model.juniorSupply(), model.juniorResidual());
                    shares = Math.min(shares, balance);
                    if (shares != 0) {
                        try model.juniorRedeem(ALICE, shares) {} catch {}
                    }
                }
            } else {
                uint256 residual = model.juniorResidual();
                if (residual > 2e18) model.loss(Math.min(amount, residual / 2));
            }

            assertEq(model.markedSenior() + model.juniorResidual(), model.backingValue());
            assertLe(model.markedSenior(), model.seniorClaim());
        }
    }

    function test_modelSurfaceComparison() public {
        PairedTrancheStateModel paired = new PairedTrancheStateModel(ALICE, 100e18, 100e18, 70e18, 100e18, ALPHA_BPS);
        IndependentCapitalAccountsStateModel independent = _independent(150e18, 100e18, 100e18, 50e18);

        emit log_named_uint("paired model runtime bytes", address(paired).code.length);
        emit log_named_uint("independent model runtime bytes", address(independent).code.length);
        assertGt(address(independent).code.length, address(paired).code.length);
    }

    function _independent(uint256 a, uint256 q, uint256 s, uint256 j)
        private
        returns (IndependentCapitalAccountsStateModel)
    {
        return new IndependentCapitalAccountsStateModel(ALICE, a, a, q, s, j, ALPHA_BPS, C, HARD_C);
    }
}
