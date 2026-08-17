// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {
    BuildV2UpgradeBatch,
    IUUPSUpgradeable,
    IWithdrawalQueueV2Initializer
} from "../../../script/v2/BuildV2UpgradeBatch.s.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRCMirrorModule} from "../../../src/v2/interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";

contract BuildV2UpgradeBatchTest is Test {
    BuildV2UpgradeBatch private builder;

    function setUp() public {
        builder = new BuildV2UpgradeBatch();
    }

    function test_buildBatch_IsDeterministicAndUsesCanonicalTargetOrder() public view {
        BuildV2UpgradeBatch.UpgradeBatch memory first = builder.buildBatch();
        BuildV2UpgradeBatch.UpgradeBatch memory second = builder.buildBatch();

        assertEq(first.targets.length, 2);
        assertEq(first.targets[0], builder.STAKED_USDAT_PROXY());
        assertEq(first.targets[1], builder.WITHDRAWAL_QUEUE_PROXY());
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
            strcMirrorModule: ISTRCMirrorModule(builder.STRC_MIRROR_MODULE()),
            strconModule: ISTRConModule(builder.STRCON_MODULE()),
            executionPolicy: ISTRConExecutionPolicy(builder.EXECUTION_POLICY()),
            recoveryAddress: builder.RECOVERY_ADDRESS(),
            surplusSource: builder.SURPLUS_SOURCE(),
            executionVehicle: builder.EXECUTION_VEHICLE(),
            baseRedemptionFeeBps: builder.BASE_REDEMPTION_FEE_BPS(),
            elevatedRedemptionFeeBps: builder.ELEVATED_REDEMPTION_FEE_BPS(),
            elevatedDepositFeeBps: builder.ELEVATED_DEPOSIT_FEE_BPS(),
            executionToleranceBps: builder.EXECUTION_TOLERANCE_BPS(),
            migrationToleranceBps: builder.MIGRATION_TOLERANCE_BPS(),
            initialExecutionCapacity: builder.INITIAL_EXECUTION_CAPACITY(),
            initialExecutionRefillPerDay: builder.INITIAL_EXECUTION_REFILL_PER_DAY()
        });
        IStakedUSDat.V2Roles memory vaultRoles = IStakedUSDat.V2Roles({
            parameterManager: builder.VAULT_PARAMETER_MANAGER(),
            marketModeManager: builder.VAULT_MARKET_MODE_MANAGER(),
            operator: builder.VAULT_OPERATOR(),
            surplusManager: builder.VAULT_SURPLUS_MANAGER(),
            blacklister: builder.VAULT_BLACKLISTER(),
            enforcer: builder.VAULT_ENFORCER(),
            pauser: builder.VAULT_PAUSER(),
            unpauser: builder.VAULT_UNPAUSER()
        });

        bytes memory expectedVaultInitializer = abi.encodeCall(IStakedUSDat.initializeV2, (vaultConfig, vaultRoles));
        bytes memory expectedQueueInitializer = abi.encodeCall(
            IWithdrawalQueueV2Initializer.initializeV2,
            (builder.QUEUE_OPERATOR(), builder.QUEUE_ENFORCER(), builder.QUEUE_PAUSER(), builder.QUEUE_UNPAUSER())
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
            abi.encodeCall(
                IUUPSUpgradeable.upgradeToAndCall, (builder.STAKED_USDAT_IMPLEMENTATION(), expectedVaultInitializer)
            )
        );
        assertEq(
            batch.payloads[1],
            abi.encodeCall(
                IUUPSUpgradeable.upgradeToAndCall, (builder.WITHDRAWAL_QUEUE_IMPLEMENTATION(), expectedQueueInitializer)
            )
        );
    }

    function test_buildBatch_EncodesExactTimelockCalls() public view {
        BuildV2UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch();

        bytes memory expectedScheduleCalldata = abi.encodeCall(
            TimelockController.scheduleBatch,
            (
                batch.targets,
                batch.values,
                batch.payloads,
                builder.PREDECESSOR(),
                builder.BATCH_SALT(),
                builder.TIMELOCK_DELAY()
            )
        );
        bytes memory expectedExecuteCalldata = abi.encodeCall(
            TimelockController.executeBatch,
            (batch.targets, batch.values, batch.payloads, builder.PREDECESSOR(), builder.BATCH_SALT())
        );

        assertEq(_selector(batch.scheduleCalldata), TimelockController.scheduleBatch.selector);
        assertEq(_selector(batch.executeCalldata), TimelockController.executeBatch.selector);
        assertEq(batch.scheduleCalldata, expectedScheduleCalldata);
        assertEq(batch.executeCalldata, expectedExecuteCalldata);
    }

    function test_buildBatch_UsesExactTimelockOperationId() public view {
        BuildV2UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch();
        bytes32 expectedOperationId = keccak256(
            abi.encode(batch.targets, batch.values, batch.payloads, builder.PREDECESSOR(), builder.BATCH_SALT())
        );

        assertEq(batch.operationId, expectedOperationId);
    }

    function _selector(bytes memory callData) private pure returns (bytes4 selector) {
        require(callData.length >= 4, "calldata shorter than selector");
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }
    }
}
