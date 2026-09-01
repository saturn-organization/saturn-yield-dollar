// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Test-only cumulative source. Its index is already expressed in the
/// portfolio accounting convention selected by the harness.
contract PortfolioIncomeSourceMock {
    uint256 public indexWad = 1e18;
    bool public healthy = true;

    function setIndex(uint256 newIndexWad) external {
        indexWad = newIndexWad;
    }

    function setHealthy(bool value) external {
        healthy = value;
    }

    function read() external view returns (uint256) {
        require(healthy && indexWad != 0, "SOURCE_UNHEALTHY");
        return indexWad;
    }
}

/// @dev Fixed-catalog, non-deployable portfolio accumulator. Separate asset
/// records feed one cumulative portfolio index. Only the bound controller can
/// mutate supply, exposure, or source semantics.
contract PortfolioEligibleIncomeAccumulatorModel {
    using Math for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant ASSET_COUNT = 2;

    error Unauthorized();
    error InvalidState();
    error FullExitRequiresReview();

    struct AssetRecord {
        PortfolioIncomeSourceMock source;
        uint256 exposureWad;
        uint256 lastIndexWad;
        uint256 cumulativeUnitsPerShareWad;
        uint256 denominatorRemainder;
        uint256 saleNonce;
        bool approved;
    }

    address public immutable controller;
    uint256 public susdatSupplyWad;
    uint256 public portfolioIncomePerShareWad;
    uint256 public cashIncomePerShareWad;
    uint256 public fundedSurplusWad;
    uint256 public pendingFundedSurplusWad;
    uint256 public recognizedSurplusWad;
    uint256 public cashDenominatorRemainder;
    uint256 public abandonedRemainder;
    AssetRecord[ASSET_COUNT] private _assets;

    modifier onlyController() {
        if (msg.sender != controller) revert Unauthorized();
        _;
    }

    constructor(
        address controller_,
        PortfolioIncomeSourceMock source0,
        PortfolioIncomeSourceMock source1,
        uint256 exposure0Wad,
        uint256 exposure1Wad,
        uint256 supplyWad
    ) {
        require(controller_ != address(0) && supplyWad != 0);
        controller = controller_;
        susdatSupplyWad = supplyWad;
        _assets[0] = AssetRecord({
            source: source0,
            exposureWad: exposure0Wad,
            lastIndexWad: source0.read(),
            cumulativeUnitsPerShareWad: 0,
            denominatorRemainder: 0,
            saleNonce: 0,
            approved: true
        });
        _assets[1] = AssetRecord({
            source: source1,
            exposureWad: exposure1Wad,
            lastIndexWad: source1.read(),
            cumulativeUnitsPerShareWad: 0,
            denominatorRemainder: 0,
            saleNonce: 0,
            approved: true
        });
    }

    function assetRecord(uint256 id) external view returns (AssetRecord memory) {
        return _assets[id];
    }

    function allSourcesHealthy() external view returns (bool) {
        for (uint256 id; id < ASSET_COUNT; ++id) {
            AssetRecord storage record = _assets[id];
            if (!record.approved) continue;
            try record.source.read() returns (uint256 current) {
                if (current < record.lastIndexWad) return false;
            } catch {
                return false;
            }
        }
        return true;
    }

    function settle() public returns (uint256 portfolioIncreaseWad) {
        uint256 supply = susdatSupplyWad;
        if (supply == 0) revert InvalidState();

        for (uint256 id; id < ASSET_COUNT; ++id) {
            AssetRecord storage record = _assets[id];
            if (!record.approved) continue;

            uint256 current = record.source.read();
            if (current < record.lastIndexWad) revert InvalidState();
            uint256 indexIncrease = current - record.lastIndexWad;
            if (indexIncrease == 0) continue;

            uint256 eligibleUnits = Math.mulDiv(record.exposureWad, indexIncrease, WAD);
            uint256 numerator = eligibleUnits * WAD + record.denominatorRemainder;
            uint256 perShareIncrease = numerator / supply;
            record.denominatorRemainder = numerator % supply;
            record.lastIndexWad = current;
            record.cumulativeUnitsPerShareWad += perShareIncrease;
            portfolioIncreaseWad += perShareIncrease;
        }

        portfolioIncomePerShareWad += portfolioIncreaseWad;
    }

    function changeSupply(uint256 newSupplyWad) external onlyController {
        settle();
        if (newSupplyWad == 0) revert InvalidState();
        for (uint256 id; id < ASSET_COUNT; ++id) {
            abandonedRemainder += _assets[id].denominatorRemainder;
            _assets[id].denominatorRemainder = 0;
        }
        abandonedRemainder += cashDenominatorRemainder;
        cashDenominatorRemainder = 0;
        susdatSupplyWad = newSupplyWad;
    }

    /// @dev Models transferInSurplus: prior source income settles, but newly
    /// funded USDat remains unvested and is not yet eligible income.
    function fundUSDatSurplus(uint256 amountWad) external onlyController {
        settle();
        if (amountWad == 0) revert InvalidState();
        fundedSurplusWad += amountWad;
        pendingFundedSurplusWad += amountWad;
    }

    /// @dev Models the eligible-income part of _sweep: only newly vested,
    /// actually funded USDat enters the portfolio series, exactly once.
    function recognizeFundedUSDatSurplus(uint256 amountWad)
        external
        onlyController
        returns (uint256 perShareIncreaseWad)
    {
        settle();
        if (amountWad == 0 || amountWad > pendingFundedSurplusWad) revert InvalidState();

        abandonedRemainder += cashDenominatorRemainder;
        uint256 numerator = amountWad * WAD;
        perShareIncreaseWad = numerator / susdatSupplyWad;
        cashDenominatorRemainder = numerator % susdatSupplyWad;
        pendingFundedSurplusWad -= amountWad;
        recognizedSurplusWad += amountWad;
        cashIncomePerShareWad += perShareIncreaseWad;
        portfolioIncomePerShareWad += perShareIncreaseWad;
    }

    function changeExposure(uint256 id, uint256 newExposureWad) external onlyController {
        settle();
        _assets[id].exposureWad = newExposureWad;
    }

    function setApproved(uint256 id, bool approved) external onlyController {
        settle();
        AssetRecord storage record = _assets[id];
        record.approved = approved;
        record.denominatorRemainder = 0;
        if (approved) record.lastIndexWad = record.source.read();
    }

    function replaceSource(uint256 id, PortfolioIncomeSourceMock newSource) external onlyController {
        settle();
        AssetRecord storage record = _assets[id];
        record.source = newSource;
        record.lastIndexWad = newSource.read();
        record.denominatorRemainder = 0;
    }

    function recordPartialSale(uint256 id, uint256 soldExposureWad)
        external
        onlyController
        returns (uint256 soldFractionWad, uint256 nonce)
    {
        settle();
        AssetRecord storage record = _assets[id];
        uint256 preExposure = record.exposureWad;
        if (soldExposureWad == 0 || soldExposureWad >= preExposure) revert FullExitRequiresReview();
        soldFractionWad = Math.mulDiv(soldExposureWad, WAD, preExposure);
        record.exposureWad = preExposure - soldExposureWad;
        nonce = ++record.saleNonce;
    }
}

/// @dev One fixed portfolio accumulator connected to independent Senior and
/// Junior capital accounts. All values are WAD-scaled model units.
contract PortfolioTrancheIntegrationModel {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant ASSET_COUNT = 2;

    error Closed();
    error InvalidAmount();
    error CapacityExceeded();
    error SeniorImpaired();
    error JuniorWiped();

    struct Init {
        address initialHolder;
        uint256 baseSupplyWad;
        uint256 exposure0Wad;
        uint256 exposure1Wad;
        uint256 initialLockedSUSDatWad;
        uint256 initialBackingValueWad;
        uint256 initialSeniorClaimWad;
        uint256 initialSeniorSupplyWad;
        uint256 initialJuniorSupplyWad;
        uint16 alphaBps;
        uint256 preferredCoverageWad;
        uint256 hardCoverageWad;
    }

    PortfolioEligibleIncomeAccumulatorModel public immutable accumulator;
    uint16 public immutable alphaBps;
    uint256 public immutable preferredCoverageWad;
    uint256 public immutable hardCoverageWad;

    uint256 public lockedSUSDatWad;
    uint256 public backingValueWad;
    uint256 public baseSeniorClaimWad;
    uint256 public crystallizedSeniorValueWad;
    uint256 public seniorSupplyWad;
    uint256 public juniorSupplyWad;
    uint256 public fullStackExitCount;
    uint256[ASSET_COUNT] public liveSeniorUnitsWad;
    uint256[ASSET_COUNT] public lastAssetIncomePerShareWad;
    uint256 public lastCashIncomePerShareWad;
    mapping(address => uint256) public seniorBalanceWad;
    mapping(address => uint256) public juniorBalanceWad;

    constructor(Init memory init, PortfolioIncomeSourceMock source0, PortfolioIncomeSourceMock source1) {
        require(
            init.initialHolder != address(0) && init.initialLockedSUSDatWad != 0
                && init.initialBackingValueWad >= init.initialSeniorClaimWad && init.initialSeniorSupplyWad != 0
                && init.initialJuniorSupplyWad != 0 && init.alphaBps <= BPS && init.preferredCoverageWad > WAD
                && init.hardCoverageWad >= WAD && init.hardCoverageWad < init.preferredCoverageWad
        );
        accumulator = new PortfolioEligibleIncomeAccumulatorModel(
            address(this), source0, source1, init.exposure0Wad, init.exposure1Wad, init.baseSupplyWad
        );
        alphaBps = init.alphaBps;
        preferredCoverageWad = init.preferredCoverageWad;
        hardCoverageWad = init.hardCoverageWad;
        lockedSUSDatWad = init.initialLockedSUSDatWad;
        backingValueWad = init.initialBackingValueWad;
        baseSeniorClaimWad = init.initialSeniorClaimWad;
        seniorSupplyWad = init.initialSeniorSupplyWad;
        juniorSupplyWad = init.initialJuniorSupplyWad;
        seniorBalanceWad[init.initialHolder] = init.initialSeniorSupplyWad;
        juniorBalanceWad[init.initialHolder] = init.initialJuniorSupplyWad;
    }

    function seniorClaimWad() public view returns (uint256 claim) {
        claim = baseSeniorClaimWad + crystallizedSeniorValueWad;
        for (uint256 id; id < ASSET_COUNT; ++id) {
            claim += liveSeniorUnitsWad[id];
        }
    }

    function markedSeniorWad() public view returns (uint256) {
        return Math.min(backingValueWad, seniorClaimWad());
    }

    function juniorResidualWad() public view returns (uint256) {
        return backingValueWad - markedSeniorWad();
    }

    function coverageWad() public view returns (uint256) {
        uint256 claim = seniorClaimWad();
        return claim == 0 ? type(uint256).max : Math.mulDiv(backingValueWad, WAD, claim);
    }

    function seniorNavPerTokenWad() public view returns (uint256) {
        return seniorSupplyWad == 0 ? WAD : Math.mulDiv(markedSeniorWad(), WAD, seniorSupplyWad);
    }

    function juniorNavPerTokenWad() public view returns (uint256) {
        return juniorSupplyWad == 0 ? 0 : Math.mulDiv(juniorResidualWad(), WAD, juniorSupplyWad);
    }

    function juniorRedemptionCapacityWad() public view returns (uint256) {
        uint256 claim = seniorClaimWad();
        if (backingValueWad < claim) return 0;
        uint256 required = Math.mulDiv(preferredCoverageWad, claim, WAD, Math.Rounding.Ceil);
        return backingValueWad > required ? backingValueWad - required : 0;
    }

    function seniorDepositCapacityWad() public view returns (uint256) {
        uint256 claim = seniorClaimWad();
        if (juniorSupplyWad == 0 || backingValueWad < claim) return 0;
        uint256 required = Math.mulDiv(preferredCoverageWad, claim, WAD, Math.Rounding.Ceil);
        if (backingValueWad <= required) return 0;
        return Math.mulDiv(backingValueWad - required, WAD, preferredCoverageWad - WAD);
    }

    function syncPortfolioIncome() public returns (uint256 totalIncomeWad, uint256 seniorIncomeWad) {
        accumulator.settle();
        for (uint256 id; id < ASSET_COUNT; ++id) {
            PortfolioEligibleIncomeAccumulatorModel.AssetRecord memory record = accumulator.assetRecord(id);
            uint256 perShareIncrease = record.cumulativeUnitsPerShareWad - lastAssetIncomePerShareWad[id];
            if (perShareIncrease == 0) continue;
            uint256 income = Math.mulDiv(lockedSUSDatWad, perShareIncrease, WAD);
            uint256 seniorIncome = Math.mulDiv(income, alphaBps, BPS);
            totalIncomeWad += income;
            seniorIncomeWad += seniorIncome;
            liveSeniorUnitsWad[id] += seniorIncome;
            lastAssetIncomePerShareWad[id] = record.cumulativeUnitsPerShareWad;
        }

        uint256 cashPerShareIncrease = accumulator.cashIncomePerShareWad() - lastCashIncomePerShareWad;
        if (cashPerShareIncrease != 0) {
            uint256 cashIncome = Math.mulDiv(lockedSUSDatWad, cashPerShareIncrease, WAD);
            uint256 seniorCashIncome = Math.mulDiv(cashIncome, alphaBps, BPS);
            totalIncomeWad += cashIncome;
            seniorIncomeWad += seniorCashIncome;
            crystallizedSeniorValueWad += seniorCashIncome;
            lastCashIncomePerShareWad = accumulator.cashIncomePerShareWad();
        }
        backingValueWad += totalIncomeWad;
    }

    function fundUSDatSurplus(uint256 amountWad) external {
        syncPortfolioIncome();
        accumulator.fundUSDatSurplus(amountWad);
    }

    function recognizeUSDatSurplus(uint256 amountWad)
        external
        returns (uint256 totalIncomeWad, uint256 seniorIncomeWad)
    {
        accumulator.recognizeFundedUSDatSurplus(amountWad);
        return syncPortfolioIncome();
    }

    function recognizeUSDatSurplusThenChangeSupply(uint256 amountWad, uint256 newSupplyWad) external {
        accumulator.recognizeFundedUSDatSurplus(amountWad);
        syncPortfolioIncome();
        accumulator.changeSupply(newSupplyWad);
    }

    function changeBaseSupply(uint256 newSupplyWad) external {
        syncPortfolioIncome();
        accumulator.changeSupply(newSupplyWad);
    }

    function changeExposure(uint256 id, uint256 newExposureWad) external {
        syncPortfolioIncome();
        accumulator.changeExposure(id, newExposureWad);
    }

    function setAssetApproved(uint256 id, bool approved) external {
        syncPortfolioIncome();
        accumulator.setApproved(id, approved);
        lastAssetIncomePerShareWad[id] = accumulator.assetRecord(id).cumulativeUnitsPerShareWad;
    }

    function replaceAssetSource(uint256 id, PortfolioIncomeSourceMock newSource) external {
        syncPortfolioIncome();
        accumulator.replaceSource(id, newSource);
        lastAssetIncomePerShareWad[id] = accumulator.assetRecord(id).cumulativeUnitsPerShareWad;
    }

    function partialSale(uint256 id, uint256 soldExposureWad)
        external
        returns (uint256 crystallizedWad, uint256 nonce)
    {
        syncPortfolioIncome();
        (uint256 soldFractionWad, uint256 saleNonce) = accumulator.recordPartialSale(id, soldExposureWad);
        crystallizedWad = Math.mulDiv(liveSeniorUnitsWad[id], soldFractionWad, WAD);
        liveSeniorUnitsWad[id] -= crystallizedWad;
        crystallizedSeniorValueWad += crystallizedWad;
        nonce = saleNonce;
    }

    function seniorDeposit(address holder, uint256 susdatSharesWad) external returns (uint256 shares) {
        _requireHealthyAndSync();
        if (susdatSharesWad == 0 || lockedSUSDatWad + susdatSharesWad > accumulator.susdatSupplyWad()) {
            revert InvalidAmount();
        }
        uint256 value = Math.mulDiv(susdatSharesWad, backingValueWad, lockedSUSDatWad);
        if (value > seniorDepositCapacityWad()) revert CapacityExceeded();
        uint256 seniorNav = markedSeniorWad();
        shares = Math.mulDiv(value, seniorSupplyWad, seniorNav);
        if (shares == 0) revert InvalidAmount();
        lockedSUSDatWad += susdatSharesWad;
        backingValueWad += value;
        baseSeniorClaimWad += value;
        seniorSupplyWad += shares;
        seniorBalanceWad[holder] += shares;
    }

    function seniorRedeem(address holder, uint256 shares) external returns (uint256 susdatSharesOutWad) {
        _requireHealthyAndSync();
        uint256 claim = seniorClaimWad();
        if (backingValueWad < claim) revert SeniorImpaired();
        if (shares == 0 || shares > seniorBalanceWad[holder]) revert InvalidAmount();
        uint256 value = Math.mulDiv(shares, claim, seniorSupplyWad);
        susdatSharesOutWad = Math.mulDiv(value, lockedSUSDatWad, backingValueWad);
        if (susdatSharesOutWad == 0) revert InvalidAmount();
        _scaleSeniorClaim(claim - value, claim);
        seniorBalanceWad[holder] -= shares;
        seniorSupplyWad -= shares;
        lockedSUSDatWad -= susdatSharesOutWad;
        backingValueWad -= value;
    }

    function juniorDeposit(address holder, uint256 susdatSharesWad) external returns (uint256 shares) {
        _requireHealthyAndSync();
        uint256 residual = juniorResidualWad();
        if (
            susdatSharesWad == 0 || juniorSupplyWad == 0 || residual == 0
                || lockedSUSDatWad + susdatSharesWad > accumulator.susdatSupplyWad()
        ) revert JuniorWiped();
        uint256 value = Math.mulDiv(susdatSharesWad, backingValueWad, lockedSUSDatWad);
        shares = Math.mulDiv(value, juniorSupplyWad, residual);
        if (shares == 0) revert InvalidAmount();
        lockedSUSDatWad += susdatSharesWad;
        backingValueWad += value;
        juniorSupplyWad += shares;
        juniorBalanceWad[holder] += shares;
    }

    function juniorRedeem(address holder, uint256 shares) external returns (uint256 susdatSharesOutWad) {
        _requireHealthyAndSync();
        if (backingValueWad < seniorClaimWad()) revert SeniorImpaired();
        if (shares == 0 || shares > juniorBalanceWad[holder]) revert InvalidAmount();
        uint256 value = Math.mulDiv(shares, juniorResidualWad(), juniorSupplyWad);
        if (value > juniorRedemptionCapacityWad()) revert CapacityExceeded();
        susdatSharesOutWad = Math.mulDiv(value, lockedSUSDatWad, backingValueWad);
        if (susdatSharesOutWad == 0) revert InvalidAmount();
        juniorBalanceWad[holder] -= shares;
        juniorSupplyWad -= shares;
        lockedSUSDatWad -= susdatSharesOutWad;
        backingValueWad -= value;
    }

    function fullStackExitFraction(address holder, uint256 fractionWad)
        external
        returns (uint256 susdatSharesOutWad, uint256 seniorBurnWad, uint256 juniorBurnWad)
    {
        if (fractionWad == 0 || fractionWad > WAD) revert InvalidAmount();
        seniorBurnWad = Math.mulDiv(seniorSupplyWad, fractionWad, WAD, Math.Rounding.Ceil);
        juniorBurnWad = Math.mulDiv(juniorSupplyWad, fractionWad, WAD, Math.Rounding.Ceil);
        if (seniorBurnWad > seniorBalanceWad[holder] || juniorBurnWad > juniorBalanceWad[holder]) {
            revert InvalidAmount();
        }

        uint256 claim = seniorClaimWad();
        uint256 remainingFractionWad = WAD - fractionWad;
        susdatSharesOutWad = Math.mulDiv(lockedSUSDatWad, fractionWad, WAD);
        uint256 valueOut = Math.mulDiv(backingValueWad, fractionWad, WAD);
        _scaleSeniorClaim(Math.mulDiv(claim, remainingFractionWad, WAD), claim);
        seniorBalanceWad[holder] -= seniorBurnWad;
        juniorBalanceWad[holder] -= juniorBurnWad;
        seniorSupplyWad -= seniorBurnWad;
        juniorSupplyWad -= juniorBurnWad;
        lockedSUSDatWad -= susdatSharesOutWad;
        backingValueWad -= valueOut;
        ++fullStackExitCount;
    }

    function addUnrelatedGain(uint256 valueWad) external {
        backingValueWad += valueWad;
    }

    function applyLoss(uint256 valueWad) external {
        if (valueWad >= backingValueWad) revert InvalidAmount();
        backingValueWad -= valueWad;
    }

    function _requireHealthyAndSync() private {
        if (!accumulator.allSourcesHealthy()) revert Closed();
        syncPortfolioIncome();
    }

    function _scaleSeniorClaim(uint256 targetClaimWad, uint256 oldClaimWad) private {
        if (oldClaimWad == 0) return;
        uint256 scaleWad = Math.mulDiv(targetClaimWad, WAD, oldClaimWad);
        baseSeniorClaimWad = Math.mulDiv(baseSeniorClaimWad, scaleWad, WAD);
        crystallizedSeniorValueWad = Math.mulDiv(crystallizedSeniorValueWad, scaleWad, WAD);
        for (uint256 id; id < ASSET_COUNT; ++id) {
            liveSeniorUnitsWad[id] = Math.mulDiv(liveSeniorUnitsWad[id], scaleWad, WAD);
        }
        uint256 scaled = seniorClaimWad();
        if (scaled < targetClaimWad) baseSeniorClaimWad += targetClaimWad - scaled;
    }
}

contract PortfolioTrancheIntegrationTest is Test {
    uint256 private constant WAD = 1e18;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    PortfolioIncomeSourceMock private strcon;
    PortfolioIncomeSourceMock private sata;
    PortfolioTrancheIntegrationModel private model;

    function setUp() public {
        strcon = new PortfolioIncomeSourceMock();
        sata = new PortfolioIncomeSourceMock();
        model = new PortfolioTrancheIntegrationModel(
            PortfolioTrancheIntegrationModel.Init({
                initialHolder: alice,
                baseSupplyWad: 1_000 * WAD,
                exposure0Wad: 600 * WAD,
                exposure1Wad: 200 * WAD,
                initialLockedSUSDatWad: 100 * WAD,
                initialBackingValueWad: 100 * WAD,
                initialSeniorClaimWad: 70 * WAD,
                initialSeniorSupplyWad: 70 * WAD,
                initialJuniorSupplyWad: 30 * WAD,
                alphaBps: 5_000,
                preferredCoverageWad: 1.5e18,
                hardCoverageWad: 1.1e18
            }),
            strcon,
            sata
        );
    }

    function test_twoAssetsFeedOnePortfolioAndOneCapitalStack() public {
        strcon.setIndex(1.1e18);
        sata.setIndex(1.05e18);

        (uint256 income, uint256 seniorIncome) = model.syncPortfolioIncome();

        assertEq(income, 7 * WAD);
        assertEq(seniorIncome, 3.5e18);
        assertEq(model.backingValueWad(), 107 * WAD);
        assertEq(model.seniorClaimWad(), 73.5e18);
        assertEq(model.juniorResidualWad(), 33.5e18);
        assertEq(model.liveSeniorUnitsWad(0), 3 * WAD);
        assertEq(model.liveSeniorUnitsWad(1), 0.5e18);
    }

    function test_supplyChangeSettlesOldDenominatorAndNewSupplyGetsNoHistory() public {
        strcon.setIndex(1.1e18);
        model.changeBaseSupply(2_000 * WAD);
        uint256 afterOldSupply = model.accumulator().portfolioIncomePerShareWad();
        assertEq(afterOldSupply, 0.06e18);

        strcon.setIndex(1.2e18);
        model.syncPortfolioIncome();
        uint256 afterNewSupply = model.accumulator().portfolioIncomePerShareWad();
        assertEq(afterNewSupply - afterOldSupply, 0.03e18);
    }

    function test_exposureChangeSettlesOldExposureBeforePublishingNewExposure() public {
        strcon.setIndex(1.1e18);
        model.changeExposure(0, 300 * WAD);
        assertEq(model.accumulator().portfolioIncomePerShareWad(), 0.06e18);

        strcon.setIndex(1.2e18);
        model.syncPortfolioIncome();
        assertEq(model.accumulator().portfolioIncomePerShareWad(), 0.09e18);
    }

    function test_partialSaleCrystallizesExactlyOnceAndKeepsClaimConstant() public {
        strcon.setIndex(1.1e18);
        model.syncPortfolioIncome();
        uint256 claimBefore = model.seniorClaimWad();
        uint256 liveBefore = model.liveSeniorUnitsWad(0);

        (uint256 crystallized, uint256 nonce) = model.partialSale(0, 150 * WAD);

        assertEq(nonce, 1);
        assertEq(crystallized, liveBefore / 4);
        assertEq(model.liveSeniorUnitsWad(0), liveBefore - crystallized);
        assertEq(model.crystallizedSeniorValueWad(), crystallized);
        assertEq(model.seniorClaimWad(), claimBefore);
        assertEq(model.accumulator().assetRecord(0).exposureWad, 450 * WAD);
    }

    function test_sourceReplacementSettlesOldSourceAndStartsNewSourceAtCurrentIndex() public {
        strcon.setIndex(1.1e18);
        PortfolioIncomeSourceMock replacement = new PortfolioIncomeSourceMock();
        replacement.setIndex(5e18);

        model.replaceAssetSource(0, replacement);
        uint256 claimAfterOldSource = model.seniorClaimWad();
        model.syncPortfolioIncome();
        assertEq(model.seniorClaimWad(), claimAfterOldSource);

        replacement.setIndex(5.1e18);
        model.syncPortfolioIncome();
        assertGt(model.seniorClaimWad(), claimAfterOldSource);
    }

    function test_unsupportedAssetContributesZeroUntilExplicitlyApproved() public {
        model.setAssetApproved(1, false);
        sata.setIndex(2e18);
        model.syncPortfolioIncome();
        assertEq(model.liveSeniorUnitsWad(1), 0);

        model.setAssetApproved(1, true);
        model.syncPortfolioIncome();
        assertEq(model.liveSeniorUnitsWad(1), 0);
        sata.setIndex(2.1e18);
        model.syncPortfolioIncome();
        assertEq(model.liveSeniorUnitsWad(1), 1 * WAD);
    }

    function test_unhealthySourceClosesOneSidedActionsButNotFullStackExit() public {
        sata.setHealthy(false);
        vm.expectRevert(PortfolioTrancheIntegrationModel.Closed.selector);
        model.juniorDeposit(bob, 1 * WAD);

        (uint256 out,,) = model.fullStackExitFraction(alice, 0.1e18);
        assertEq(out, 10 * WAD);
    }

    function test_fundedUSDatSurplusIsIneligibleUntilRecognizedThroughVesting() public {
        uint256 portfolioBefore = model.accumulator().portfolioIncomePerShareWad();
        uint256 backingBefore = model.backingValueWad();

        model.fundUSDatSurplus(10 * WAD);
        model.syncPortfolioIncome();

        assertEq(model.accumulator().portfolioIncomePerShareWad(), portfolioBefore);
        assertEq(model.accumulator().cashIncomePerShareWad(), 0);
        assertEq(model.accumulator().pendingFundedSurplusWad(), 10 * WAD);
        assertEq(model.backingValueWad(), backingBefore);
    }

    function test_recognizedUSDatSurplusEntersPortfolioAndSeniorClaimExactlyOnce() public {
        model.fundUSDatSurplus(10 * WAD);
        uint256 claimBefore = model.seniorClaimWad();

        (uint256 income, uint256 seniorIncome) = model.recognizeUSDatSurplus(10 * WAD);

        assertEq(model.accumulator().cashIncomePerShareWad(), 0.01e18);
        assertEq(model.accumulator().recognizedSurplusWad(), 10 * WAD);
        assertEq(model.accumulator().pendingFundedSurplusWad(), 0);
        assertEq(income, 1 * WAD);
        assertEq(seniorIncome, 0.5e18);
        assertEq(model.seniorClaimWad() - claimBefore, seniorIncome);
        assertEq(model.crystallizedSeniorValueWad(), seniorIncome);

        model.syncPortfolioIncome();
        assertEq(model.seniorClaimWad() - claimBefore, seniorIncome);
    }

    function test_surplusRecognitionUsesOldSupplyBeforeSupplyChange() public {
        model.fundUSDatSurplus(10 * WAD);
        model.recognizeUSDatSurplusThenChangeSupply(10 * WAD, 2_000 * WAD);
        uint256 firstPerShare = model.accumulator().cashIncomePerShareWad();
        assertEq(firstPerShare, 0.01e18);

        model.fundUSDatSurplus(10 * WAD);
        model.recognizeUSDatSurplus(10 * WAD);
        assertEq(model.accumulator().cashIncomePerShareWad() - firstPerShare, 0.005e18);
    }

    function test_deployingRecognizedUSDatIntoSTRConDoesNotRecognizeItAgain() public {
        model.fundUSDatSurplus(10 * WAD);
        model.recognizeUSDatSurplus(10 * WAD);
        uint256 portfolioBefore = model.accumulator().portfolioIncomePerShareWad();
        uint256 claimBefore = model.seniorClaimWad();
        uint256 exposureBefore = model.accumulator().assetRecord(0).exposureWad;

        model.changeExposure(0, exposureBefore + 10 * WAD);

        assertEq(model.accumulator().portfolioIncomePerShareWad(), portfolioBefore);
        assertEq(model.seniorClaimWad(), claimBefore);
        assertEq(model.accumulator().recognizedSurplusWad(), 10 * WAD);
    }

    function test_sameClassEntryAndExitPreserveNavAndCoverageDirection() public {
        model.addUnrelatedGain(20 * WAD);
        uint256 seniorNavBefore = model.seniorNavPerTokenWad();
        uint256 juniorNavBefore = model.juniorNavPerTokenWad();
        uint256 coverageBefore = model.coverageWad();

        uint256 seniorShares = model.seniorDeposit(bob, 10 * WAD);
        assertApproxEqAbs(model.seniorNavPerTokenWad(), seniorNavBefore, 1);
        uint256 coverageAfterSeniorDeposit = model.coverageWad();
        assertGe(coverageAfterSeniorDeposit, 1.5e18);
        assertLe(coverageAfterSeniorDeposit, coverageBefore);

        uint256 juniorShares = model.juniorDeposit(bob, 5 * WAD);
        assertApproxEqAbs(model.juniorNavPerTokenWad(), juniorNavBefore, 1);
        uint256 coverageAfterJuniorDeposit = model.coverageWad();
        assertGe(coverageAfterJuniorDeposit, coverageAfterSeniorDeposit);

        model.seniorRedeem(bob, seniorShares);
        uint256 coverageAfterSeniorRedeem = model.coverageWad();
        assertGe(coverageAfterSeniorRedeem, coverageAfterJuniorDeposit);

        uint256 juniorNavBeforeRedeem = model.juniorNavPerTokenWad();
        model.juniorRedeem(bob, juniorShares);
        assertApproxEqAbs(model.juniorNavPerTokenWad(), juniorNavBeforeRedeem, 1);
        assertGe(model.coverageWad(), 1.5e18);
        assertLe(model.coverageWad(), coverageAfterSeniorRedeem);
    }

    function test_directAccumulatorMutationIsControllerBound() public {
        PortfolioEligibleIncomeAccumulatorModel accumulator = model.accumulator();
        vm.expectRevert(PortfolioEligibleIncomeAccumulatorModel.Unauthorized.selector);
        accumulator.changeExposure(0, 1);
        vm.expectRevert(PortfolioEligibleIncomeAccumulatorModel.Unauthorized.selector);
        accumulator.changeSupply(1);
    }

    function testFuzz_twoSourceIncomeAlwaysConservesBacking(uint64 strconBps, uint64 sataBps) public {
        uint256 strconGrowth = bound(uint256(strconBps), 0, 2_000);
        uint256 sataGrowth = bound(uint256(sataBps), 0, 2_000);
        strcon.setIndex(WAD + strconGrowth * 1e14);
        sata.setIndex(WAD + sataGrowth * 1e14);

        model.syncPortfolioIncome();

        assertEq(model.markedSeniorWad() + model.juniorResidualWad(), model.backingValueWad());
        assertLe(model.markedSeniorWad(), model.backingValueWad());
        assertEq(
            model.seniorClaimWad(),
            model.baseSeniorClaimWad() + model.crystallizedSeniorValueWad() + model.liveSeniorUnitsWad(0)
                + model.liveSeniorUnitsWad(1)
        );
    }

    function testFuzz_partialSaleNeverDoubleCountsLiveAndCrystallized(uint64 growthBps, uint64 soldBps) public {
        uint256 growth = bound(uint256(growthBps), 1, 2_000);
        uint256 sold = bound(uint256(soldBps), 1, 9_999);
        strcon.setIndex(WAD + growth * 1e14);
        model.syncPortfolioIncome();
        uint256 claimBefore = model.seniorClaimWad();
        uint256 preExposure = model.accumulator().assetRecord(0).exposureWad;
        uint256 soldExposure = Math.mulDiv(preExposure, sold, 10_000);
        if (soldExposure == 0 || soldExposure >= preExposure) return;

        model.partialSale(0, soldExposure);

        assertEq(model.seniorClaimWad(), claimBefore);
        assertEq(
            model.seniorClaimWad(),
            model.baseSeniorClaimWad() + model.crystallizedSeniorValueWad() + model.liveSeniorUnitsWad(0)
                + model.liveSeniorUnitsWad(1)
        );
    }
}

contract V3PortfolioTrancheHandler is Test {
    uint256 private constant WAD = 1e18;
    PortfolioTrancheIntegrationModel public immutable model;
    PortfolioIncomeSourceMock public immutable strcon;
    PortfolioIncomeSourceMock public immutable sata;
    address public immutable holder;
    uint256 public saleCalls;

    constructor(
        PortfolioTrancheIntegrationModel model_,
        PortfolioIncomeSourceMock strcon_,
        PortfolioIncomeSourceMock sata_,
        address holder_
    ) {
        model = model_;
        strcon = strcon_;
        sata = sata_;
        holder = holder_;
    }

    function growIncome(uint64 strconBps, uint64 sataBps) external {
        uint256 s0 = strcon.indexWad();
        uint256 s1 = sata.indexWad();
        strcon.setIndex(s0 + bound(uint256(strconBps), 0, 100) * 1e14);
        sata.setIndex(s1 + bound(uint256(sataBps), 0, 100) * 1e14);
        model.syncPortfolioIncome();
    }

    function fundSurplus(uint64 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, WAD);
        model.fundUSDatSurplus(amount);
    }

    function recognizeSurplus(uint64 rawAmount) external {
        uint256 pending = model.accumulator().pendingFundedSurplusWad();
        if (pending == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, pending);
        model.recognizeUSDatSurplus(amount);
    }

    function addGainOrLoss(uint64 gain, uint64 loss) external {
        uint256 gainWad = bound(uint256(gain), 0, 2 * WAD);
        if (gainWad != 0) model.addUnrelatedGain(gainWad);
        uint256 maxLoss = model.backingValueWad() / 20;
        uint256 lossWad = bound(uint256(loss), 0, maxLoss);
        if (lossWad != 0) model.applyLoss(lossWad);
    }

    function exitFullStack(uint64 fraction) external {
        uint256 maxFraction = 0.01e18;
        uint256 fractionWad = bound(uint256(fraction), 1, maxFraction);
        uint256 seniorRequired = Math.mulDiv(model.seniorSupplyWad(), fractionWad, WAD, Math.Rounding.Ceil);
        uint256 juniorRequired = Math.mulDiv(model.juniorSupplyWad(), fractionWad, WAD, Math.Rounding.Ceil);
        if (seniorRequired <= model.seniorBalanceWad(holder) && juniorRequired <= model.juniorBalanceWad(holder)) {
            model.fullStackExitFraction(holder, fractionWad);
        }
    }

    function sellPartialSTRCon(uint64 soldBps) external {
        uint256 preExposure = model.accumulator().assetRecord(0).exposureWad;
        if (preExposure <= 1e12) return;
        uint256 sold = Math.mulDiv(preExposure, bound(uint256(soldBps), 1, 100), 10_000);
        if (sold != 0 && sold < preExposure) {
            model.partialSale(0, sold);
            ++saleCalls;
        }
    }
}

contract PortfolioTrancheIntegrationInvariantTest is StdInvariant, Test {
    uint256 private constant WAD = 1e18;
    address private holder = makeAddr("holder");
    PortfolioIncomeSourceMock private strcon;
    PortfolioIncomeSourceMock private sata;
    PortfolioTrancheIntegrationModel private model;
    V3PortfolioTrancheHandler private handler;

    function setUp() public {
        strcon = new PortfolioIncomeSourceMock();
        sata = new PortfolioIncomeSourceMock();
        model = new PortfolioTrancheIntegrationModel(
            PortfolioTrancheIntegrationModel.Init({
                initialHolder: holder,
                baseSupplyWad: 1_000 * WAD,
                exposure0Wad: 600 * WAD,
                exposure1Wad: 200 * WAD,
                initialLockedSUSDatWad: 100 * WAD,
                initialBackingValueWad: 120 * WAD,
                initialSeniorClaimWad: 75 * WAD,
                initialSeniorSupplyWad: 75 * WAD,
                initialJuniorSupplyWad: 45 * WAD,
                alphaBps: 5_000,
                preferredCoverageWad: 1.5e18,
                hardCoverageWad: 1.1e18
            }),
            strcon,
            sata
        );
        handler = new V3PortfolioTrancheHandler(model, strcon, sata, holder);
        targetContract(address(handler));
    }

    function invariant_capitalAccountsAlwaysConserveBacking() public view {
        assertEq(model.markedSeniorWad() + model.juniorResidualWad(), model.backingValueWad());
        assertLe(model.markedSeniorWad(), model.backingValueWad());
    }

    function invariant_claimBucketsNeverDoubleCount() public view {
        assertEq(
            model.seniorClaimWad(),
            model.baseSeniorClaimWad() + model.crystallizedSeniorValueWad() + model.liveSeniorUnitsWad(0)
                + model.liveSeniorUnitsWad(1)
        );
    }

    function invariant_backingNeverExceedsBaseSupply() public view {
        assertLe(model.lockedSUSDatWad(), model.accumulator().susdatSupplyWad());
    }

    function invariant_portfolioSeriesEqualsAssetRecordsAndSaleNoncesAreExact() public view {
        PortfolioEligibleIncomeAccumulatorModel.AssetRecord memory strconRecord = model.accumulator().assetRecord(0);
        PortfolioEligibleIncomeAccumulatorModel.AssetRecord memory sataRecord = model.accumulator().assetRecord(1);

        assertEq(
            model.accumulator().portfolioIncomePerShareWad(),
            strconRecord.cumulativeUnitsPerShareWad + sataRecord.cumulativeUnitsPerShareWad
                + model.accumulator().cashIncomePerShareWad()
        );
        assertEq(strconRecord.saleNonce, handler.saleCalls());
        assertEq(sataRecord.saleNonce, 0);
    }

    function invariant_fundedUSDatSurplusIsRecognizedAtMostOnce() public view {
        assertEq(
            model.accumulator().fundedSurplusWad(),
            model.accumulator().pendingFundedSurplusWad() + model.accumulator().recognizedSurplusWad()
        );
        assertLe(model.accumulator().recognizedSurplusWad(), model.accumulator().fundedSurplusWad());
    }
}
