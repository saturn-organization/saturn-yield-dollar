// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../helpers/StakedUSDatEligibleIncomeFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StakedUSDat as StakedUSDatV2} from "../../../src/v2/StakedUSDat.sol";
import {StakedUSDat} from "../../../src/v3/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {StakedUSDatEligibleIncomeModule} from "../../../src/v3/StakedUSDatEligibleIncomeModule.sol";

contract StakedUSDatEligibleIncomeInitializationTest is StakedUSDatEligibleIncomeFixture {
    function test_initializeV3StartsAtCurrentIndexWithoutRetroactiveIncomeAndPreservesLinearSlots() public view {
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(uint256(state.state), uint256(IEligibleIncomeAccounting.IncomeState.Active));
        assertEq(state.lastAcceptedRawIndex, 1e18);
        assertEq(state.lastEligibleUnitIndexWad, 1e18);
        assertEq(state.eligibleUnitsPerSUSDatShareWad, 0);
        assertEq(state.cumulativeStructuralAdjustmentFactorWad, 1e18);
        assertEq(state.liveUnitScaleWad, 1e18);
        assertTrue(state.configMediationActive);
        for (uint256 slot; slot < v2LinearSlots.length; ++slot) {
            assertEq(vm.load(address(vault), bytes32(slot)), v2LinearSlots[slot]);
        }
    }

    function test_initializeV3RegistersOnlyStillUnvestedV2Surplus() public {
        IWithdrawalQueueERC721 queue = IWithdrawalQueueERC721(makeAddr("surplusUpgradeQueue"));
        StakedUSDatV2 bootstrap = new StakedUSDatV2(queue);
        StakedUSDatV2 isolated = StakedUSDatV2(
            address(
                new ERC1967Proxy(
                    address(bootstrap),
                    abi.encodeCall(StakedUSDatV2.initialize, (address(this), IERC20(address(usdat))))
                )
            )
        );
        IncomeMirrorMock isolatedMirror = new IncomeMirrorMock(address(isolated));
        IncomeModuleMock isolatedSTRCon =
            new IncomeModuleMock(address(isolated), address(strcon), new IncomePriceOracleMock());
        V2InitializationHelper.initialize(isolated, address(isolatedMirror), address(isolatedSTRCon), 5, 10, 0);

        usdat.mint(address(this), CASH + 100e6);
        usdat.approve(address(isolated), type(uint256).max);
        isolated.deposit(CASH, address(this));
        isolatedSTRCon.seed(POSITION);
        strcon.mint(address(isolated), POSITION);
        isolatedMirror.retire();
        isolated.transferInSurplus(100e6);
        vm.warp(block.timestamp + isolated.surplusVestingPeriod() / 2);
        uint256 stillUnvested = isolated.getUnvestedSurplus();

        IncomeAdapterMock isolatedAdapter = new IncomeAdapterMock(address(strcon));
        StakedUSDatEligibleIncomeModule isolatedIncome =
            new StakedUSDatEligibleIncomeModule(address(isolated), address(this));
        StakedUSDat isolatedV3 = new StakedUSDat(queue);
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 implementationBefore = vm.load(address(isolated), implementationSlot);
        bytes memory initializer = abi.encodeCall(
            StakedUSDat.initializeV3,
            (
                isolatedIncome,
                IEligibleIncomeAccounting.EligibleIncomeConfig({
                    adapter: isolatedAdapter, configManager: address(this), maxUnreviewedGrowthBps: MAX_GROWTH_BPS
                })
            )
        );

        vm.expectRevert(StakedUSDatEligibleIncomeModule.InvalidConfiguration.selector);
        isolated.upgradeToAndCall(address(isolatedV3), initializer);
        assertEq(vm.load(address(isolated), implementationSlot), implementationBefore);

        isolated.grantRole(isolated.PARAMETER_MANAGER_ROLE(), address(isolatedIncome));
        isolated.upgradeToAndCall(address(isolatedV3), initializer);

        IEligibleIncomeAccounting.EligibleIncomeState memory state = isolatedIncome.eligibleIncomeState();
        assertEq(state.fundedUSDat, stillUnvested);
        assertEq(state.pendingFundedUSDat, stillUnvested);
        assertEq(state.recognizedUSDat, 0);
        assertEq(state.recognizedUSDatPerSUSDatShareWad, 0);

        vm.warp(block.timestamp + isolated.surplusVestingPeriod());
        isolated.sweep();
        state = isolatedIncome.eligibleIncomeState();
        assertEq(state.pendingFundedUSDat, 0);
        assertEq(state.recognizedUSDat, stillUnvested);
    }

    function test_steadyStateRuntimeHasReviewGradeHeadroom() public view {
        assertLe(address(v3Implementation).code.length, 23_000);
    }

    function test_v3CurrentMultiplierBasedPortfolioSeriesIsExactlySTRConEligibleIncome() public {
        adapter.setIndex(1.1e18);
        uint256 expected = Math.mulDiv(POSITION, 0.1e18, vault.totalSupply());

        assertEq(incomeModule.previewSTRConEligibleUnitsPerShareWad(), expected);
        incomeModule.materializeSTRConEligibleIncome();

        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.eligibleUnitsPerSUSDatShareWad, expected);
        assertEq(state.liveUnitsOffsetWad, expected);
    }

    function test_historicalLifecycleSelectorsArePermanentlyDisabled() public {
        StakedUSDat steadyState = StakedUSDat(address(vault));
        assertEq(steadyState.MAX_MIGRATION_TOLERANCE_BPS(), 500);
        vm.expectRevert(IStakedUSDat.OperationNotAllowed.selector);
        steadyState.initialize(address(this), IERC20(address(usdat)));

        IStakedUSDat.V2Config memory config;
        IStakedUSDat.V2Roles memory roles;
        vm.expectRevert(IStakedUSDat.OperationNotAllowed.selector);
        steadyState.initializeV2(config, roles);

        vm.expectRevert(IStakedUSDat.OperationNotAllowed.selector);
        steadyState.migrate(1, block.timestamp);

        vm.expectRevert(IStakedUSDat.OperationNotAllowed.selector);
        steadyState.setMigrationTolerance(1);
    }

    function test_vaultBindingAndLedgerInitializationAreOneShot() public {
        assertEq(address(StakedUSDat(address(vault)).eligibleIncomeModule()), address(incomeModule));
        StakedUSDatEligibleIncomeModule replacement = new StakedUSDatEligibleIncomeModule(address(vault), address(this));
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        StakedUSDat(address(vault))
            .initializeV3(
                replacement,
                IEligibleIncomeAccounting.EligibleIncomeConfig({
                    adapter: adapter, configManager: address(this), maxUnreviewedGrowthBps: MAX_GROWTH_BPS
                })
            );

        vm.expectRevert(StakedUSDatEligibleIncomeModule.Unauthorized.selector);
        incomeModule.initializeEligibleIncomeV3(
            IEligibleIncomeAccounting.EligibleIncomeConfig({
                adapter: adapter, configManager: address(this), maxUnreviewedGrowthBps: MAX_GROWTH_BPS
            })
        );
    }

    function test_wrongVaultBindingRevertsTheWholeUpgrade() public {
        IWithdrawalQueueERC721 queue = IWithdrawalQueueERC721(makeAddr("isolatedQueue"));
        StakedUSDatV2 bootstrapImplementation = new StakedUSDatV2(queue);
        ERC1967Proxy isolatedProxy = new ERC1967Proxy(
            address(bootstrapImplementation),
            abi.encodeCall(StakedUSDatV2.initialize, (address(this), IERC20(address(usdat))))
        );
        StakedUSDatV2 isolatedVault = StakedUSDatV2(address(isolatedProxy));
        StakedUSDat isolatedV3 = new StakedUSDat(queue);
        StakedUSDatEligibleIncomeModule wrongModule =
            new StakedUSDatEligibleIncomeModule(makeAddr("wrongVault"), address(this));
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 implementationBefore = vm.load(address(isolatedProxy), implementationSlot);

        vm.expectRevert(IStakedUSDat.InvalidModule.selector);
        isolatedVault.upgradeToAndCall(
            address(isolatedV3),
            abi.encodeCall(
                StakedUSDat.initializeV3,
                (
                    wrongModule,
                    IEligibleIncomeAccounting.EligibleIncomeConfig({
                        adapter: adapter, configManager: address(this), maxUnreviewedGrowthBps: MAX_GROWTH_BPS
                    })
                )
            )
        );

        assertEq(vm.load(address(isolatedProxy), implementationSlot), implementationBefore);
    }
}
