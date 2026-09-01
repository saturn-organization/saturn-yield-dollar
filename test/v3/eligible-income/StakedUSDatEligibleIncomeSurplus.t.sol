// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../helpers/StakedUSDatEligibleIncomeFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {StakedUSDatEligibleIncomeModule} from "../../../src/v3/StakedUSDatEligibleIncomeModule.sol";

contract StakedUSDatEligibleIncomeSurplusTest is StakedUSDatEligibleIncomeFixture {
    function test_v3OrdinaryUSDatDepositCreatesNoEligibleIncome() public {
        uint256 supplyBefore = vault.totalSupply();
        usdat.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertGt(vault.totalSupply(), supplyBefore);
        assertEq(incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, 0);
        assertEq(incomeModule.previewSTRConEligibleUnitsPerShareWad(), 0);
    }

    function test_v3FundedUSDatIsIneligibleUntilVestedAndRecognizedExactlyOnce() public {
        uint256 funded = 100e6;
        usdat.mint(address(this), funded);
        vault.transferInSurplus(funded);

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.fundedUSDat, funded);
        assertEq(state.pendingFundedUSDat, funded);
        assertEq(state.recognizedUSDat, 0);
        assertEq(state.recognizedUSDatPerSUSDatShareWad, 0);
        assertEq(state.crystallizedValueOffsetWad, 0);

        vm.warp(block.timestamp + vault.surplusVestingPeriod());
        uint256 supply = vault.totalSupply();
        uint256 expectedPerShare = Math.mulDiv(funded, 1e30, supply);
        vault.sweep();

        state = incomeModule.eligibleIncomeState();
        assertEq(state.fundedUSDat, funded);
        assertEq(state.pendingFundedUSDat, 0);
        assertEq(state.recognizedUSDat, funded);
        assertEq(state.recognizedUSDatPerSUSDatShareWad, expectedPerShare);
        assertEq(state.crystallizedValueOffsetWad, expectedPerShare);
        assertEq(state.fundedUSDat, state.pendingFundedUSDat + state.recognizedUSDat);

        vault.sweep();
        IEligibleIncomeAccounting.EligibleIncomeState memory afterSecondSweep = incomeModule.eligibleIncomeState();
        assertEq(afterSecondSweep.recognizedUSDat, state.recognizedUSDat);
        assertEq(afterSecondSweep.recognizedUSDatPerSUSDatShareWad, state.recognizedUSDatPerSUSDatShareWad);
    }

    function test_v3DepositRecognizesVestedUSDatAgainstOldSupply() public {
        uint256 funded = 100e6;
        usdat.mint(address(this), funded);
        vault.transferInSurplus(funded);
        vm.warp(block.timestamp + vault.surplusVestingPeriod());

        uint256 oldSupply = vault.totalSupply();
        uint256 expectedPerShare = Math.mulDiv(funded, 1e30, oldSupply);
        usdat.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.recognizedUSDat, funded);
        assertEq(state.recognizedUSDatPerSUSDatShareWad, expectedPerShare);
        assertGt(vault.totalSupply(), oldSupply);
    }

    function test_v3PartialVestingRecognizesOnlyEachNewlyReleasedIncrement() public {
        uint256 funded = 101e6;
        usdat.mint(address(this), funded);
        vault.transferInSurplus(funded);
        uint256 start = block.timestamp;

        vm.warp(start + vault.surplusVestingPeriod() / 3);
        uint256 firstReleased = funded - vault.getUnvestedSurplus();
        vault.sweep();
        IEligibleIncomeAccounting.EligibleIncomeState memory first = incomeModule.eligibleIncomeState();
        assertEq(first.recognizedUSDat, firstReleased);
        assertEq(first.pendingFundedUSDat, funded - firstReleased);

        vm.warp(start + (vault.surplusVestingPeriod() * 2) / 3);
        uint256 totalReleased = funded - vault.getUnvestedSurplus();
        vault.sweep();
        IEligibleIncomeAccounting.EligibleIncomeState memory second = incomeModule.eligibleIncomeState();
        assertEq(second.recognizedUSDat, totalReleased);
        assertEq(second.pendingFundedUSDat, funded - totalReleased);

        vm.warp(start + vault.surplusVestingPeriod());
        vault.sweep();
        IEligibleIncomeAccounting.EligibleIncomeState memory complete = incomeModule.eligibleIncomeState();
        assertEq(complete.recognizedUSDat, funded);
        assertEq(complete.pendingFundedUSDat, 0);
        assertEq(complete.fundedUSDat, complete.recognizedUSDat);
    }

    function test_v3RedemptionBatchRecognizesVestedUSDatAgainstPreBurnSupply() public {
        uint256 funded = 100e6;
        usdat.mint(address(this), funded);
        vault.transferInSurplus(funded);
        vm.warp(block.timestamp + vault.surplusVestingPeriod());

        uint256 oldSupply = vault.totalSupply();
        IEligibleIncomeAccounting.EligibleIncomeState memory state =
            withdrawalQueue.checkpoint(IStakedUSDat(address(vault)), incomeModule);
        assertEq(state.recognizedUSDatPerSUSDatShareWad, Math.mulDiv(funded, 1e30, oldSupply));
    }

    function test_v3RecognizedUSDatIsNotCountedAgainWhenDeployedIntoSTRCon() public {
        uint256 funded = 100e6;
        usdat.mint(address(this), funded);
        vault.transferInSurplus(funded);
        vm.warp(block.timestamp + vault.surplusVestingPeriod());
        vault.sweep();
        IEligibleIncomeAccounting.EligibleIncomeState memory beforeState = incomeModule.eligibleIncomeState();

        strcon.mint(vehicle, 0.5e18);
        vm.prank(vehicle);
        strcon.approve(address(vault), 0.5e18);
        _setVehicle(vehicle);
        vault.buy(50e6, 0.5e18, vehicle, block.timestamp);

        IEligibleIncomeAccounting.EligibleIncomeState memory afterState = incomeModule.eligibleIncomeState();
        assertEq(afterState.recognizedUSDat, beforeState.recognizedUSDat);
        assertEq(afterState.recognizedUSDatPerSUSDatShareWad, beforeState.recognizedUSDatPerSUSDatShareWad);
        assertEq(afterState.crystallizedValueOffsetWad, beforeState.crystallizedValueOffsetWad);
    }

    function test_v3FundedUSDatRecognitionRemainsAvailableDuringSTRConReview() public {
        uint256 funded = 100e6;
        usdat.mint(address(this), funded);
        vault.transferInSurplus(funded);
        incomeModule.enterSTRConIncomeReview(keccak256("review"));
        vm.warp(block.timestamp + vault.surplusVestingPeriod());

        vault.sweep();

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(uint256(state.state), uint256(IEligibleIncomeAccounting.IncomeState.Review));
        assertEq(state.pendingFundedUSDat, 0);
        assertEq(state.recognizedUSDat, funded);
        assertGt(state.recognizedUSDatPerSUSDatShareWad, 0);
    }

    function test_v3FundedUSDatHooksAreVaultOnly() public {
        vm.expectRevert(StakedUSDatEligibleIncomeModule.Unauthorized.selector);
        incomeModule.registerFundedUSDatSurplus(1);
        vm.expectRevert(StakedUSDatEligibleIncomeModule.Unauthorized.selector);
        incomeModule.recognizeFundedUSDatSurplus(1);
    }

    function test_v3UnrecognizedAssetTransferCannotBecomePortfolioBackingOrIncome() public {
        IncomeTokenMock unsupported = new IncomeTokenMock("Unsupported", "UNSUPPORTED", 18);
        uint256 assetsBefore = vault.totalAssets();
        unsupported.mint(address(vault), 1_000_000e18);

        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, 0);
        assertEq(incomeModule.previewSTRConEligibleUnitsPerShareWad(), 0);
    }
}
