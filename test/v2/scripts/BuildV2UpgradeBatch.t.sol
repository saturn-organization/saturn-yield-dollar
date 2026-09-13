// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {
    BuildV2UpgradeBatch,
    IUUPSUpgradeable,
    IWithdrawalQueueV2Initializer
} from "../../../script/v2/BuildV2UpgradeBatch.s.sol";
import {UpgradeConfig} from "../../../script/v2/configs/UpgradeConfig.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRCMirrorModule} from "../../../src/v2/interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";

contract BuildV2UpgradeBatchTest is Test, UpgradeConfig {
    BuildV2UpgradeBatch private builder;

    function setUp() public {
        builder = new BuildV2UpgradeBatch();
    }

    function test_configuration_UsesSharedValidationConstants() public view {
        assertEq(builder.EXPECTED_CHAIN_ID(), EXPECTED_CHAIN_ID);
        assertEq(builder.TIMELOCK(), TIMELOCK);
        assertEq(builder.PROPOSER(), PROPOSER);
        assertEq(builder.USDAT(), USDAT);
        assertEq(builder.MAX_FEE_BPS(), MAX_FEE_BPS);
        assertEq(builder.MAX_EXECUTION_TOLERANCE_BPS(), MAX_EXECUTION_TOLERANCE_BPS);
        assertEq(builder.MAX_MIGRATION_TOLERANCE_BPS(), MAX_MIGRATION_TOLERANCE_BPS);
        assertEq(builder.EXPECTED_SCHEDULE_TIMESTAMP(), EXPECTED_SCHEDULE_TIMESTAMP);
        assertEq(builder.EXPECTED_UPGRADE_EXECUTION_TIMESTAMP(), EXPECTED_UPGRADE_EXECUTION_TIMESTAMP);
        assertEq(builder.UPGRADE_CONFIGURATION_APPROVED(), UPGRADE_CONFIGURATION_APPROVED);
    }

    function test_run_RevertsOnWrongChain() public {
        vm.chainId(EXPECTED_CHAIN_ID + 1);

        vm.expectRevert(abi.encodeWithSelector(BuildV2UpgradeBatch.WrongChain.selector, EXPECTED_CHAIN_ID + 1));
        builder.run();
    }

    function test_run_RevertsUntilUpgradeConfigurationApproved() public {
        vm.chainId(EXPECTED_CHAIN_ID);
        assertFalse(UPGRADE_CONFIGURATION_APPROVED);

        vm.expectRevert(
            abi.encodeWithSelector(BuildV2UpgradeBatch.InvalidConfiguration.selector, "UPGRADE_CONFIGURATION_APPROVED")
        );
        builder.run();
    }

    function test_buildBatch_IsDeterministicAndUsesCanonicalTargetOrder() public view {
        BuildV2UpgradeBatch.UpgradeBatch memory first = builder.buildBatch();
        BuildV2UpgradeBatch.UpgradeBatch memory second = builder.buildBatch();

        assertEq(first.targets.length, 2);
        assertEq(first.targets[0], STAKED_USDAT_PROXY);
        assertEq(first.targets[1], WITHDRAWAL_QUEUE_PROXY);
        assertEq(first.values.length, 2);
        assertEq(first.values[0], 0);
        assertEq(first.values[1], 0);
        assertEq(first.payloads.length, 2);

        assertEq(first.targets, second.targets);
        assertEq(first.values, second.values);
        assertEq(first.payloads[0], second.payloads[0]);
        assertEq(first.payloads[1], second.payloads[1]);
        assertEq(first.vaultInitializer, second.vaultInitializer);
        assertEq(first.queueInitializer, second.queueInitializer);
        assertEq(first.scheduleCalldata, second.scheduleCalldata);
        assertEq(first.executeCalldata, second.executeCalldata);
        assertEq(first.operationId, second.operationId);
    }

    function test_buildBatch_EncodesExactInitializersAndNestedUpgrades() public view {
        BuildV2UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch();

        IStakedUSDat.V2Config memory vaultConfig = IStakedUSDat.V2Config({
            strcMirrorModule: ISTRCMirrorModule(STRC_MIRROR_MODULE),
            strconModule: ISTRConModule(STRCON_MODULE),
            executionPolicy: ISTRConExecutionPolicy(EXECUTION_POLICY),
            recoveryAddress: RECOVERY_ADDRESS,
            surplusSource: SURPLUS_SOURCE,
            executionVehicle: EXECUTION_VEHICLE,
            baseRedemptionFeeBps: BASE_REDEMPTION_FEE_BPS,
            elevatedRedemptionFeeBps: ELEVATED_REDEMPTION_FEE_BPS,
            elevatedDepositFeeBps: ELEVATED_DEPOSIT_FEE_BPS,
            executionToleranceBps: EXECUTION_TOLERANCE_BPS,
            migrationToleranceBps: MIGRATION_TOLERANCE_BPS,
            initialExecutionCapacity: INITIAL_EXECUTION_CAPACITY,
            initialExecutionRefillPerDay: INITIAL_EXECUTION_REFILL_PER_DAY
        });
        IStakedUSDat.V2Roles memory vaultRoles = IStakedUSDat.V2Roles({
            parameterManager: VAULT_PARAMETER_MANAGER,
            marketModeManager: VAULT_MARKET_MODE_MANAGER,
            operator: VAULT_OPERATOR,
            surplusManager: VAULT_SURPLUS_MANAGER,
            blacklister: VAULT_BLACKLISTER,
            enforcer: VAULT_ENFORCER,
            pauser: VAULT_PAUSER,
            unpauser: VAULT_UNPAUSER
        });

        bytes memory expectedVaultInitializer = abi.encodeCall(IStakedUSDat.initializeV2, (vaultConfig, vaultRoles));
        bytes memory expectedQueueInitializer = abi.encodeCall(
            IWithdrawalQueueV2Initializer.initializeV2, (QUEUE_OPERATOR, QUEUE_ENFORCER, QUEUE_PAUSER, QUEUE_UNPAUSER)
        );

        assertEq(_selector(batch.vaultInitializer), bytes4(0x4a1cd8c2));
        assertEq(_selector(batch.vaultInitializer), IStakedUSDat.initializeV2.selector);
        assertEq(_selector(batch.queueInitializer), IWithdrawalQueueV2Initializer.initializeV2.selector);
        assertEq(batch.vaultInitializer, expectedVaultInitializer);
        assertEq(batch.queueInitializer, expectedQueueInitializer);

        assertEq(_selector(batch.payloads[0]), IUUPSUpgradeable.upgradeToAndCall.selector);
        assertEq(_selector(batch.payloads[1]), IUUPSUpgradeable.upgradeToAndCall.selector);
        assertEq(
            batch.payloads[0],
            abi.encodeCall(IUUPSUpgradeable.upgradeToAndCall, (STAKED_USDAT_IMPLEMENTATION, expectedVaultInitializer))
        );
        assertEq(
            batch.payloads[1],
            abi.encodeCall(
                IUUPSUpgradeable.upgradeToAndCall, (WITHDRAWAL_QUEUE_IMPLEMENTATION, expectedQueueInitializer)
            )
        );
    }

    function test_buildBatch_EncodesExactTimelockCalls() public view {
        BuildV2UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch();

        bytes memory expectedScheduleCalldata = abi.encodeCall(
            TimelockController.scheduleBatch,
            (batch.targets, batch.values, batch.payloads, UPGRADE_PREDECESSOR, BATCH_SALT, TIMELOCK_DELAY)
        );
        bytes memory expectedExecuteCalldata = abi.encodeCall(
            TimelockController.executeBatch,
            (batch.targets, batch.values, batch.payloads, UPGRADE_PREDECESSOR, BATCH_SALT)
        );

        assertEq(_selector(batch.scheduleCalldata), TimelockController.scheduleBatch.selector);
        assertEq(_selector(batch.executeCalldata), TimelockController.executeBatch.selector);
        assertEq(batch.scheduleCalldata, expectedScheduleCalldata);
        assertEq(batch.executeCalldata, expectedExecuteCalldata);
    }

    function test_buildBatch_UsesExactTimelockOperationId() public view {
        BuildV2UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch();
        bytes32 expectedOperationId =
            keccak256(abi.encode(batch.targets, batch.values, batch.payloads, UPGRADE_PREDECESSOR, BATCH_SALT));

        assertEq(batch.operationId, expectedOperationId);
    }

    function test_buildBatch_PreservesCallerSuppliedRehearsalInputs() public view {
        BuildV2UpgradeBatch.UpgradeBatchInput memory input;
        input.stakedUsdatImplementation = address(0x100);
        input.withdrawalQueueImplementation = address(0x101);
        input.vaultConfig.executionVehicle = address(0x102);
        input.vaultRoles.operator = address(0x103);
        input.queueRoles.operator = address(0x104);
        input.salt = keccak256("rehearsal");

        BuildV2UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch(input);
        bytes memory expectedVaultInitializer =
            abi.encodeCall(IStakedUSDat.initializeV2, (input.vaultConfig, input.vaultRoles));
        bytes memory expectedQueueInitializer = abi.encodeCall(
            IWithdrawalQueueV2Initializer.initializeV2, (input.queueRoles.operator, address(0), address(0), address(0))
        );

        assertEq(batch.targets[0], STAKED_USDAT_PROXY);
        assertEq(batch.targets[1], WITHDRAWAL_QUEUE_PROXY);
        assertEq(batch.vaultInitializer, expectedVaultInitializer);
        assertEq(batch.queueInitializer, expectedQueueInitializer);
        assertEq(
            batch.payloads[0],
            abi.encodeCall(
                IUUPSUpgradeable.upgradeToAndCall, (input.stakedUsdatImplementation, expectedVaultInitializer)
            )
        );
        assertEq(
            batch.payloads[1],
            abi.encodeCall(
                IUUPSUpgradeable.upgradeToAndCall, (input.withdrawalQueueImplementation, expectedQueueInitializer)
            )
        );
        assertEq(
            batch.operationId,
            keccak256(abi.encode(batch.targets, batch.values, batch.payloads, UPGRADE_PREDECESSOR, input.salt))
        );
    }

    function _selector(bytes memory callData) private pure returns (bytes4 selector) {
        require(callData.length >= 4, "calldata shorter than selector");
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }
    }
}
