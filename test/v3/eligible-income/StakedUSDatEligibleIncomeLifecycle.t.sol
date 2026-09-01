// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../helpers/StakedUSDatEligibleIncomeFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";

contract StakedUSDatEligibleIncomeLifecycleTest is StakedUSDatEligibleIncomeFixture {
    function test_materializeBeforeDepositPreventsNewSharesFromCapturingHistoricalIncome() public {
        uint256 oldSupply = vault.totalSupply();
        adapter.setIndex(1.1e18);
        uint256 expectedIncrease = Math.mulDiv(POSITION, 0.1e18, oldSupply);

        usdat.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertEq(incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, expectedIncrease);
        assertGt(vault.totalSupply(), oldSupply);
    }

    function test_transferDoesNotCheckpointButPreviewReadsCurrentIndex() public {
        adapter.setIndex(1.1e18);
        assertTrue(vault.transfer(alice, 1e18));

        assertEq(incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, 0);
        assertGt(incomeModule.previewSTRConEligibleUnitsPerShareWad(), 0);
    }

    function test_redemptionBatchMaterializesBeforeItsSupplyBasis() public {
        adapter.setIndex(1.1e18);
        IEligibleIncomeAccounting.EligibleIncomeState memory state =
            withdrawalQueue.checkpoint(IStakedUSDat(address(vault)), incomeModule);

        assertGt(state.eligibleUnitsPerSUSDatShareWad, 0);
    }

    function test_buyMaterializesUsingPreBuyExposure() public {
        adapter.setIndex(1.1e18);
        uint256 expected = Math.mulDiv(POSITION, 0.1e18, vault.totalSupply());
        strcon.mint(vehicle, 10e18);
        vm.prank(vehicle);
        strcon.approve(address(vault), 10e18);
        _setVehicle(vehicle);

        vault.buy(1_000e6, 10e18, vehicle, block.timestamp);

        assertEq(incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, expected);
        assertEq(module.balance(), POSITION + 10e18);
    }
}
