// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../helpers/StakedUSDatEligibleIncomeFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";

contract StakedUSDatEligibleIncomeAffineTest is StakedUSDatEligibleIncomeFixture {
    function test_multipleIncomeAndSaleEpochsPreserveRelativeConsumerTransform() public {
        adapter.setIndex(1.1e18);
        incomeModule.materializeSTRConEligibleIncome();
        IEligibleIncomeAccounting.EligibleIncomeState memory checkpoint = incomeModule.eligibleIncomeState();

        _setVehicle(vehicle);
        uint256 firstDelivered = POSITION / 5;
        vault.sell(firstDelivered, 200_000e6, vehicle, block.timestamp);

        uint256 preSecondSaleExposure = POSITION - firstDelivered;
        adapter.setIndex(1.2e18);
        uint256 secondIncomeUnits = Math.mulDiv(preSecondSaleExposure, 0.1e18, vault.totalSupply());
        uint256 secondDelivered = preSecondSaleExposure / 4;
        uint256 secondReceived = 200_000e6;
        vault.sell(secondDelivered, secondReceived, vehicle, block.timestamp);

        IEligibleIncomeAccounting.EligibleIncomeState memory current = incomeModule.eligibleIncomeState();
        uint256 historicalLive = Math.mulDiv(
            current.liveUnitScaleWad, checkpoint.liveUnitsOffsetWad, checkpoint.liveUnitScaleWad, Math.Rounding.Floor
        );
        uint256 relativeLive = current.liveUnitsOffsetWad - historicalLive;
        uint256 relativeCrystallized = current.crystallizedValueOffsetWad
            - Math.mulDiv(
                current.crystallizedValueScaleWad - checkpoint.crystallizedValueScaleWad,
                checkpoint.liveUnitsOffsetWad,
                checkpoint.liveUnitScaleWad,
                Math.Rounding.Floor
            );
        uint256 secondSurvivalWad = Math.mulDiv(preSecondSaleExposure - secondDelivered, 1e18, preSecondSaleExposure);
        uint256 secondExecutionWeightWad = Math.mulDiv(secondReceived, 1e30, preSecondSaleExposure);

        assertApproxEqAbs(relativeLive, Math.mulDiv(secondIncomeUnits, secondSurvivalWad, 1e18, Math.Rounding.Floor), 1);
        assertApproxEqAbs(
            relativeCrystallized, Math.mulDiv(secondIncomeUnits, secondExecutionWeightWad, 1e18, Math.Rounding.Floor), 1
        );
        assertEq(current.crystallizationNonce, 2);
    }

    function test_v3ShadowLifecycleMatchesProductionTransitionOrdering() public {
        uint256 expectedEligibleUnits = _shadowDepositAndMaterialize();
        expectedEligibleUnits = _shadowBuyAndMaterialize(expectedEligibleUnits);
        uint256 expectedCashPerShare = _shadowRecognizeFundedSurplus();
        IEligibleIncomeAccounting.EligibleIncomeState memory afterSale =
            _shadowSellAndCrystallize(expectedEligibleUnits, expectedCashPerShare);

        assertTrue(vault.transfer(alice, 1e18));
        IEligibleIncomeAccounting.EligibleIncomeState memory afterTransfer = incomeModule.eligibleIncomeState();
        assertEq(afterTransfer.eligibleUnitsPerSUSDatShareWad, afterSale.eligibleUnitsPerSUSDatShareWad);
        assertEq(afterTransfer.liveUnitsOffsetWad, afterSale.liveUnitsOffsetWad);
        assertEq(afterTransfer.crystallizedValueOffsetWad, afterSale.crystallizedValueOffsetWad);

        incomeModule.enterSTRConIncomeReview(keccak256("shadow split"));
        adapter.setIndex(2.6e18);
        incomeModule.resolveNeutralSTRConStructuralAdjustment(2e18, keccak256("2-for-1 split"));

        IEligibleIncomeAccounting.EligibleIncomeState memory finalState = incomeModule.eligibleIncomeState();
        assertEq(finalState.lastEligibleUnitIndexWad, 1.3e18);
        assertEq(finalState.cumulativeStructuralAdjustmentFactorWad, 2e18);
        assertEq(finalState.eligibleUnitsPerSUSDatShareWad, afterSale.eligibleUnitsPerSUSDatShareWad);
        assertEq(finalState.liveUnitsOffsetWad, afterSale.liveUnitsOffsetWad);
        assertEq(finalState.crystallizedValueOffsetWad, afterSale.crystallizedValueOffsetWad);
        assertEq(uint256(finalState.state), uint256(IEligibleIncomeAccounting.IncomeState.Active));
    }

    function _shadowDepositAndMaterialize() private returns (uint256 expectedEligibleUnits) {
        uint256 oldSupply = vault.totalSupply();
        adapter.setIndex(1.1e18);
        usdat.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        expectedEligibleUnits = Math.mulDiv(POSITION, 0.1e18, oldSupply);
        assertEq(incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, expectedEligibleUnits);
    }

    function _shadowBuyAndMaterialize(uint256 previousEligibleUnits) private returns (uint256 expectedEligibleUnits) {
        uint256 oldExposure = module.balance();
        uint256 oldSupply = vault.totalSupply();
        adapter.setIndex(1.2e18);
        strcon.mint(vehicle, 0.5e18);
        vm.prank(vehicle);
        strcon.approve(address(vault), 0.5e18);
        _setVehicle(vehicle);
        vault.buy(50e6, 0.5e18, vehicle, block.timestamp);

        expectedEligibleUnits = previousEligibleUnits + Math.mulDiv(oldExposure, 0.1e18, oldSupply);
        assertEq(incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, expectedEligibleUnits);
        assertEq(module.balance(), oldExposure + 0.5e18);
    }

    function _shadowRecognizeFundedSurplus() private returns (uint256 expectedCashPerShare) {
        uint256 funded = 100e6;
        usdat.mint(address(this), funded);
        vault.transferInSurplus(funded);
        vm.warp(block.timestamp + vault.surplusVestingPeriod());
        vault.sweep();

        expectedCashPerShare = Math.mulDiv(funded, 1e30, vault.totalSupply());
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.recognizedUSDatPerSUSDatShareWad, expectedCashPerShare);
        assertEq(state.crystallizedValueOffsetWad, expectedCashPerShare);
    }

    function _shadowSellAndCrystallize(uint256 previousEligibleUnits, uint256 expectedCashPerShare)
        private
        returns (IEligibleIncomeAccounting.EligibleIncomeState memory state)
    {
        uint256 oldExposure = module.balance();
        uint256 delivered = 2_500e18;
        uint256 received = 250_000e6;
        adapter.setIndex(1.3e18);
        uint256 thirdIncrement = Math.mulDiv(oldExposure, 0.1e18, vault.totalSupply());
        uint256 liveBeforeCrystallization = previousEligibleUnits + thirdIncrement;
        uint256 survivalWad = Math.mulDiv(oldExposure - delivered, 1e18, oldExposure);
        uint256 executionWeightWad = Math.mulDiv(received, 1e30, oldExposure);
        vault.sell(delivered, received, vehicle, block.timestamp);

        state = incomeModule.eligibleIncomeState();
        assertEq(state.eligibleUnitsPerSUSDatShareWad, previousEligibleUnits + thirdIncrement);
        assertEq(
            state.liveUnitsOffsetWad, Math.mulDiv(liveBeforeCrystallization, survivalWad, 1e18, Math.Rounding.Floor)
        );
        assertEq(
            state.crystallizedValueOffsetWad,
            expectedCashPerShare + Math.mulDiv(executionWeightWad, liveBeforeCrystallization, 1e18, Math.Rounding.Floor)
        );
        assertEq(state.crystallizationNonce, 1);
        assertEq(state.fundedUSDat, 100e6);
        assertEq(state.recognizedUSDat, 100e6);
        assertEq(state.pendingFundedUSDat, 0);
    }

    function testFuzz_materializationMatchesFullPrecisionFloor(uint16 growthBps) public {
        growthBps = uint16(bound(growthBps, 0, MAX_GROWTH_BPS));
        uint256 delta = Math.mulDiv(1e18, growthBps, 10_000);
        adapter.setIndex(1e18 + delta);

        incomeModule.materializeSTRConEligibleIncome();

        uint256 expected = Math.mulDiv(POSITION, delta, vault.totalSupply(), Math.Rounding.Floor);
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.eligibleUnitsPerSUSDatShareWad, expected);
        assertEq(state.liveUnitsOffsetWad, expected);
    }

    function testFuzz_partialCrystallizationPreservesAffineTransition(uint96 rawDelivered) public {
        uint256 delivered = bound(uint256(rawDelivered), 1, POSITION / 1e18 - 1) * 1e18;
        uint256 received = Math.mulDiv(delivered, 100e6, 1e18);
        adapter.setIndex(1.1e18);
        incomeModule.materializeSTRConEligibleIncome();
        IEligibleIncomeAccounting.EligibleIncomeState memory beforeState = incomeModule.eligibleIncomeState();

        _setVehicle(vehicle);
        vault.sell(delivered, received, vehicle, block.timestamp);

        IEligibleIncomeAccounting.EligibleIncomeState memory afterState = incomeModule.eligibleIncomeState();
        uint256 q = Math.mulDiv(POSITION - delivered, 1e18, POSITION);
        uint256 r = Math.mulDiv(received, 1e30, POSITION);
        assertEq(afterState.liveUnitScaleWad, Math.mulDiv(beforeState.liveUnitScaleWad, q, 1e18));
        assertEq(afterState.liveUnitsOffsetWad, Math.mulDiv(beforeState.liveUnitsOffsetWad, q, 1e18));
        assertEq(
            afterState.crystallizedValueScaleWad,
            beforeState.crystallizedValueScaleWad + Math.mulDiv(r, beforeState.liveUnitScaleWad, 1e18)
        );
        assertEq(
            afterState.crystallizedValueOffsetWad,
            beforeState.crystallizedValueOffsetWad + Math.mulDiv(r, beforeState.liveUnitsOffsetWad, 1e18)
        );
    }

    function test_completeExitIsNotAV0Operation() public {
        _setVehicle(vehicle);
        vm.expectRevert(IEligibleIncomeAccounting.FullSTRConExitRequiresReview.selector);
        vault.sell(POSITION, 1_000_000e6, vehicle, block.timestamp);
    }
}
