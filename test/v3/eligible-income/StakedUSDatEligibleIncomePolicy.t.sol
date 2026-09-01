// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../helpers/StakedUSDatEligibleIncomeFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";

contract StakedUSDatEligibleIncomePolicyTest is StakedUSDatEligibleIncomeFixture {
    // ============ Review Lifecycle ============

    function test_resumeReviewMaterializesAdmissibleIncomeAndReactivates() public {
        bytes32 evidence = keccak256("review complete");
        incomeModule.enterSTRConIncomeReview(keccak256("review"));
        adapter.setIndex(1.1e18);
        uint256 expected = Math.mulDiv(POSITION, 0.1e18, vault.totalSupply(), Math.Rounding.Floor);

        incomeModule.resumeSTRConIncome(evidence);

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(uint256(state.state), uint256(IEligibleIncomeAccounting.IncomeState.Active));
        assertEq(state.eligibleUnitsPerSUSDatShareWad, expected);
        assertEq(state.liveUnitsOffsetWad, expected);
        assertEq(state.lastResolutionEvidence, evidence);
    }

    function test_resumeReviewRejectsActiveStateWithoutMutation() public {
        IEligibleIncomeAccounting.EligibleIncomeState memory beforeState = incomeModule.eligibleIncomeState();

        vm.expectRevert(IEligibleIncomeAccounting.EligibleIncomeNotInReview.selector);
        incomeModule.resumeSTRConIncome(keccak256("invalid resume"));

        IEligibleIncomeAccounting.EligibleIncomeState memory afterState = incomeModule.eligibleIncomeState();
        assertEq(uint256(afterState.state), uint256(beforeState.state));
        assertEq(afterState.lastResolutionEvidence, beforeState.lastResolutionEvidence);
        assertEq(afterState.eligibleUnitsPerSUSDatShareWad, beforeState.eligibleUnitsPerSUSDatShareWad);
    }

    // ============ Configuration Bounds ============

    function test_setMaxGrowthMaterializesUnderOldBoundBeforeApplyingNewBound() public {
        adapter.setIndex(1.1e18);
        uint256 expected = Math.mulDiv(POSITION, 0.1e18, vault.totalSupply(), Math.Rounding.Floor);

        incomeModule.setSTRConMaxUnreviewedGrowthBps(500);

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.eligibleUnitsPerSUSDatShareWad, expected);
        assertEq(state.lastAcceptedRawIndex, 1.1e18);
        assertEq(state.maxUnreviewedGrowthBps, 500);

        adapter.setIndex(1.16e18);
        vm.expectRevert(IEligibleIncomeAccounting.EligibleIncomeGrowthTooLarge.selector);
        incomeModule.previewSTRConEligibleUnitsPerShareWad();
    }

    function test_setMaxGrowthRejectsAboveBpsAndRollsBackMaterialization() public {
        adapter.setIndex(1.1e18);
        IEligibleIncomeAccounting.EligibleIncomeState memory beforeState = incomeModule.eligibleIncomeState();

        vm.expectRevert(IEligibleIncomeAccounting.EligibleIncomeGrowthTooLarge.selector);
        incomeModule.setSTRConMaxUnreviewedGrowthBps(10_001);

        IEligibleIncomeAccounting.EligibleIncomeState memory afterState = incomeModule.eligibleIncomeState();
        assertEq(afterState.maxUnreviewedGrowthBps, beforeState.maxUnreviewedGrowthBps);
        assertEq(afterState.lastAcceptedRawIndex, beforeState.lastAcceptedRawIndex);
        assertEq(afterState.lastEligibleUnitIndexWad, beforeState.lastEligibleUnitIndexWad);
        assertEq(afterState.eligibleUnitsPerSUSDatShareWad, beforeState.eligibleUnitsPerSUSDatShareWad);
    }

    function test_setConfigManagerRejectsUnauthorizedAndZeroWithoutMutation() public {
        vm.prank(alice);
        vm.expectRevert(StakedUSDatEligibleIncomeModule.Unauthorized.selector);
        incomeModule.setConfigManager(alice);

        vm.expectRevert(StakedUSDatEligibleIncomeModule.InvalidConfiguration.selector);
        incomeModule.setConfigManager(address(0));

        assertEq(incomeModule.configManager(), address(this));
    }

    function test_setConfigManagerTransfersAuthorityExactly() public {
        incomeModule.setConfigManager(alice);
        assertEq(incomeModule.configManager(), alice);

        vm.expectRevert(StakedUSDatEligibleIncomeModule.Unauthorized.selector);
        incomeModule.enterSTRConIncomeReview(keccak256("old manager"));

        vm.prank(alice);
        incomeModule.enterSTRConIncomeReview(keccak256("new manager"));
        assertEq(
            uint256(incomeModule.eligibleIncomeState().state), uint256(IEligibleIncomeAccounting.IncomeState.Review)
        );
    }

    // ============ Dependency Mediation ============

    function test_dependencyMediationRejectsShortData() public {
        vm.expectRevert(StakedUSDatEligibleIncomeModule.InvalidConfiguration.selector);
        incomeModule.configureEligibleIncomeDependency(address(module), hex"010203");
    }

    function test_dependencyMediationRejectsWrongTarget() public {
        IncomePriceOracleMock replacement = new IncomePriceOracleMock();
        vm.expectRevert(StakedUSDatEligibleIncomeModule.InvalidConfiguration.selector);
        incomeModule.configureEligibleIncomeDependency(
            alice, abi.encodeCall(IncomeModuleMock.setOracle, (address(replacement)))
        );
    }

    function test_dependencyMediationRejectsUnapprovedSelector() public {
        vm.expectRevert(StakedUSDatEligibleIncomeModule.InvalidConfiguration.selector);
        incomeModule.configureEligibleIncomeDependency(
            address(module), abi.encodeWithSelector(bytes4(keccak256("unapproved()")))
        );
    }

    // ============ Fail-Closed Accounting ============

    function test_largeOrUnhealthyIndexFailsClosedForIssuance() public {
        usdat.mint(alice, 2_000e6);
        vm.prank(alice);
        usdat.approve(address(vault), type(uint256).max);

        adapter.setIndex(1.3e18);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", alice, 1_000e6, 0)
        );
        vault.deposit(1_000e6, alice);

        adapter.setIndex(1e18);
        adapter.setUnhealthy(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxMint(address,uint256,uint256)", alice, 1e18, 0));
        vault.mint(1e18, alice);
    }

    function test_accountingFailsClosedOnNavOrCustodyHealthButReviewEntryStillWorks() public {
        adapter.setIndex(1.1e18);
        IncomePriceOracleMock priceOracle = IncomePriceOracleMock(address(module.oracle()));
        priceOracle.setUnhealthy(true);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "unhealthy"));
        incomeModule.materializeSTRConEligibleIncome();
        incomeModule.enterSTRConIncomeReview(keccak256("unhealthy nav"));
        assertEq(incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, 0);

        priceOracle.setUnhealthy(false);
        incomeModule.resolveNeutralSTRConStructuralAdjustment(1e18, keccak256("nav restored"));
        vm.prank(address(vault));
        assertTrue(strcon.transfer(alice, 1e18));
        adapter.setIndex(1.2e18);
        vm.expectRevert(IEligibleIncomeAccounting.EligibleIncomeCustodyShortfall.selector);
        incomeModule.materializeSTRConEligibleIncome();
    }

    // ============ Structural Review ============

    function test_neutralStructuralAdjustmentDoesNotCreateIncome() public {
        incomeModule.enterSTRConIncomeReview(keccak256("advance notice"));
        adapter.setIndex(2e18);
        incomeModule.resolveNeutralSTRConStructuralAdjustment(2e18, keccak256("2-for-1 split"));

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(uint256(state.state), uint256(IEligibleIncomeAccounting.IncomeState.Active));
        assertEq(state.eligibleUnitsPerSUSDatShareWad, 0);
        assertEq(state.lastEligibleUnitIndexWad, 1e18);
        assertEq(state.cumulativeStructuralAdjustmentFactorWad, 2e18);
    }

    function test_reviewBlocksIssuanceButKeepsOrdinaryTransfersLive() public {
        incomeModule.enterSTRConIncomeReview(keccak256("review"));
        usdat.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdat.approve(address(vault), type(uint256).max);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", alice, 1_000e6, 0)
        );
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertTrue(vault.transfer(alice, 1e18));
        assertEq(vault.balanceOf(alice), 1e18);
    }

    function test_structuralResolutionPreservesReviewedPreEventIncome() public {
        incomeModule.enterSTRConIncomeReview(keccak256("surprise"));
        adapter.setIndex(2.1e18);
        uint256 expected = Math.mulDiv(POSITION, 0.05e18, vault.totalSupply());

        incomeModule.resolveNeutralSTRConStructuralAdjustment(2e18, keccak256("split plus prior income"));

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.lastEligibleUnitIndexWad, 1.05e18);
        assertEq(state.eligibleUnitsPerSUSDatShareWad, expected);
        assertEq(state.liveUnitsOffsetWad, expected);
    }

    // ============ Authority Mediation ============

    function test_oldParameterManagerCannotBypassVaultMediation() public {
        IncomePriceOracleMock replacement = new IncomePriceOracleMock();
        ISTRConExecutionPolicy policy = vault.executionPolicy();

        vm.prank(oldParameterManager);
        vm.expectRevert(IncomeModuleMock.Unauthorized.selector);
        module.setOracle(address(replacement));

        vm.prank(oldParameterManager);
        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        policy.setExecutionVehicle(makeAddr("bypass"));

        bytes32 parameterManagerRole = vault.PARAMETER_MANAGER_ROLE();
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", oldParameterManager, parameterManagerRole
            )
        );
        vm.prank(oldParameterManager);
        vault.setRedemptionFees(0, 0);

        _setModuleOracle(address(replacement));
        _setVehicle(vehicle);
        assertEq(address(module.oracle()), address(replacement));
        assertEq(vault.executionPolicy().executionVehicle(), vehicle);
        assertFalse(vault.hasRole(vault.PARAMETER_MANAGER_ROLE(), oldParameterManager));
        assertTrue(vault.hasRole(vault.PARAMETER_MANAGER_ROLE(), address(incomeModule)));
    }

    // ============ Exposure Changes ============

    function test_partialSaleCrystallizesProRataAtActualExecutionValue() public {
        adapter.setIndex(1.1e18);
        incomeModule.materializeSTRConEligibleIncome();

        uint256 delivered = POSITION / 4;
        uint256 received = 250_000e6;
        _setVehicle(vehicle);
        vault.sell(delivered, received, vehicle, block.timestamp);

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.liveUnitScaleWad, 0.75e18);
        assertEq(
            state.liveUnitsOffsetWad,
            Math.mulDiv(state.eligibleUnitsPerSUSDatShareWad, 0.75e18, 1e18, Math.Rounding.Floor)
        );
        assertEq(state.crystallizedValueScaleWad, 25e18);
        assertGt(state.crystallizedValueOffsetWad, 0);
        assertEq(state.crystallizationNonce, 1);
        assertEq(module.balance(), POSITION - delivered);
    }

    function test_incomeAfterPartialSaleIsNotDoubleReducedByPriorCrystallization() public {
        adapter.setIndex(1.1e18);
        incomeModule.materializeSTRConEligibleIncome();
        uint256 firstIncrement = incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad;

        uint256 delivered = POSITION / 4;
        _setVehicle(vehicle);
        vault.sell(delivered, 250_000e6, vehicle, block.timestamp);
        uint256 liveAfterSale = incomeModule.eligibleIncomeState().liveUnitsOffsetWad;

        adapter.setIndex(1.2e18);
        incomeModule.materializeSTRConEligibleIncome();
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        uint256 secondIncrement = state.eligibleUnitsPerSUSDatShareWad - firstIncrement;

        assertEq(state.liveUnitsOffsetWad, liveAfterSale + secondIncrement);
        assertEq(secondIncrement, Math.mulDiv(POSITION - delivered, 0.1e18, vault.totalSupply()));
    }

    function test_failedExposureTransitionRollsBackPreTradeMaterialization() public {
        _setVehicle(vehicle);
        adapter.setIndex(1.1e18);

        IEligibleIncomeAccounting.EligibleIncomeState memory beforeState = incomeModule.eligibleIncomeState();
        uint256 exposureBefore = module.balance();
        uint256 cashBefore = vault.usdatBalance();

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionVehicleMismatch.selector);
        vault.sell(1e18, 100e6, makeAddr("wrongVehicle"), block.timestamp);

        IEligibleIncomeAccounting.EligibleIncomeState memory afterState = incomeModule.eligibleIncomeState();
        assertEq(afterState.lastAcceptedRawIndex, beforeState.lastAcceptedRawIndex);
        assertEq(afterState.lastEligibleUnitIndexWad, beforeState.lastEligibleUnitIndexWad);
        assertEq(afterState.eligibleUnitsPerSUSDatShareWad, beforeState.eligibleUnitsPerSUSDatShareWad);
        assertEq(afterState.crystallizationNonce, beforeState.crystallizationNonce);
        assertEq(module.balance(), exposureBefore);
        assertEq(vault.usdatBalance(), cashBefore);
    }

    function test_reviewModeBlocksExposureReductionBeforeSettlement() public {
        _setVehicle(vehicle);
        incomeModule.enterSTRConIncomeReview(keccak256("blocked sale"));

        uint256 exposureBefore = module.balance();
        uint256 vehicleBalanceBefore = strcon.balanceOf(vehicle);
        vm.expectRevert(IEligibleIncomeAccounting.EligibleIncomeNotActive.selector);
        vault.sell(1e18, 100e6, vehicle, block.timestamp);

        assertEq(module.balance(), exposureBefore);
        assertEq(strcon.balanceOf(vehicle), vehicleBalanceBefore);
        assertEq(incomeModule.eligibleIncomeState().crystallizationNonce, 0);
    }

    function test_directModuleExposureMutationCannotBypassVaultHooks() public {
        vm.expectRevert(IncomeModuleMock.Unauthorized.selector);
        module.buy(1e18);
        vm.expectRevert(IncomeModuleMock.Unauthorized.selector);
        module.sell(1e18);

        assertEq(module.balance(), POSITION);
    }
}
