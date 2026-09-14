// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {BuildV2Migration} from "../../../script/v2/migrate/BuildV2Migration.s.sol";
import {MigrationConfig} from "../../../script/v2/configs/MigrationConfig.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";

contract BuildV2MigrationHarness is BuildV2Migration {
    function validateDeadline(uint256 deadline, bool forScheduling) external view {
        _validateDeadline(deadline, forScheduling);
    }
}

contract BuildV2MigrationTest is Test, MigrationConfig {
    BuildV2Migration private builder;
    BuildV2MigrationHarness private harness;

    function setUp() public {
        vm.chainId(EXPECTED_CHAIN_ID);
        builder = new BuildV2Migration();
        harness = new BuildV2MigrationHarness();
    }

    function test_configuration_UsesSharedConstants() public view {
        assertEq(builder.EXPECTED_CHAIN_ID(), EXPECTED_CHAIN_ID);
        assertEq(builder.TIMELOCK_DELAY(), TIMELOCK_DELAY);
        assertEq(builder.MAX_MIGRATION_TOLERANCE_BPS(), MAX_MIGRATION_TOLERANCE_BPS);
        assertEq(builder.TIMELOCK(), TIMELOCK);
        assertEq(builder.PROPOSER(), PROPOSER);
        assertEq(builder.STAKED_USDAT_PROXY(), STAKED_USDAT_PROXY);
        assertEq(builder.STRCON(), STRCON);
        assertEq(builder.EXPECTED_STRCON(), EXPECTED_STRCON);
        assertEq(builder.EXPECTED_EXECUTION_VEHICLE(), EXPECTED_EXECUTION_VEHICLE);
        assertEq(builder.EXPECTED_MIGRATION_TOLERANCE_BPS(), EXPECTED_MIGRATION_TOLERANCE_BPS);
        assertEq(builder.MIGRATION_DEADLINE(), MIGRATION_DEADLINE);
        assertEq(builder.MIGRATION_PREDECESSOR(), MIGRATION_PREDECESSOR);
        assertEq(builder.MIGRATION_SALT(), MIGRATION_SALT);
        assertEq(builder.MIGRATION_CONFIGURATION_APPROVED(), MIGRATION_CONFIGURATION_APPROVED);
    }

    function test_run_RevertsOnWrongChain() public {
        vm.chainId(2);
        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.WrongChain.selector, uint256(2)));
        builder.run();
    }

    function test_run_RevertsWhileConfigurationUnapproved() public {
        vm.expectRevert(
            abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_CONFIGURATION_APPROVED")
        );
        builder.run();
    }

    function test_runForExecution_RevertsOnWrongChain() public {
        vm.chainId(EXPECTED_CHAIN_ID + 1);
        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.WrongChain.selector, EXPECTED_CHAIN_ID + 1));
        builder.runForExecution();
    }

    function test_runForExecution_RevertsWhileConfigurationUnapproved() public {
        vm.expectRevert(
            abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_CONFIGURATION_APPROVED")
        );
        builder.runForExecution();
    }

    function test_validateDeadline_SchedulingRequiresTimeBeyondDelay() public {
        vm.warp(1_800_000_000);
        uint256 readyAt = block.timestamp + TIMELOCK_DELAY;

        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_DEADLINE"));
        harness.validateDeadline(readyAt - 1, true);
        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_DEADLINE"));
        harness.validateDeadline(readyAt, true);
        harness.validateDeadline(readyAt + 1, true);
    }

    function test_validateDeadline_ExecutionUsesOriginalDeadlineAfterFiveDays() public {
        vm.warp(1_800_000_000);
        assertEq(TIMELOCK_DELAY, 5 days);
        uint256 deadline = block.timestamp + TIMELOCK_DELAY + 1;
        harness.validateDeadline(deadline, true);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        harness.validateDeadline(deadline, false);
        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_DEADLINE"));
        harness.validateDeadline(deadline, true);
    }

    function test_validateDeadline_ExecutionIncludesDeadlineSecond() public {
        uint256 deadline = 1_800_000_000;
        vm.warp(deadline);

        harness.validateDeadline(deadline, false);
    }

    function test_validateDeadline_ExecutionRejectsExpiredDeadline() public {
        uint256 deadline = 1_800_000_000;
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_DEADLINE"));
        harness.validateDeadline(deadline, false);
    }

    function test_buildOperation_PreservesTermsAcrossSchedulingAndExecution() public {
        vm.warp(1_800_000_000);
        uint256 expectedStrcon = 100_000 ether;
        uint256 deadline = block.timestamp + TIMELOCK_DELAY + 1;
        BuildV2Migration.MigrationOperation memory scheduled =
            builder.buildOperation(expectedStrcon, deadline, MIGRATION_SALT);
        harness.validateDeadline(deadline, true);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        harness.validateDeadline(deadline, false);
        BuildV2Migration.MigrationOperation memory executing =
            builder.buildOperation(expectedStrcon, deadline, MIGRATION_SALT);

        assertEq(scheduled.payload, abi.encodeCall(IStakedUSDat.migrate, (expectedStrcon, deadline)));
        assertEq(executing.payload, scheduled.payload);
        assertEq(executing.operationId, scheduled.operationId);
        assertEq(executing.scheduleCalldata, scheduled.scheduleCalldata);
        assertEq(executing.executeCalldata, scheduled.executeCalldata);
    }

    function test_buildOperation_EncodesExactMigrationTimelockOperation() public view {
        BuildV2Migration.MigrationOperation memory operation = builder.buildOperation();
        bytes memory expectedPayload =
            abi.encodeCall(IStakedUSDat.migrate, (builder.EXPECTED_STRCON(), builder.MIGRATION_DEADLINE()));

        assertEq(builder.TIMELOCK(), 0xfD5782E3BFF366601da3973aE30C583dE4F08A67);
        assertEq(builder.PROPOSER(), 0x610182581C93687Ca03F4a8E7f124f8cEC616820);
        assertEq(operation.target, builder.STAKED_USDAT_PROXY());
        assertEq(operation.value, 0);
        assertEq(operation.payload, expectedPayload);

        bytes memory expectedScheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (
                operation.target,
                operation.value,
                expectedPayload,
                builder.MIGRATION_PREDECESSOR(),
                builder.MIGRATION_SALT(),
                builder.TIMELOCK_DELAY()
            )
        );
        bytes memory expectedExecuteCalldata = abi.encodeCall(
            TimelockController.execute,
            (
                operation.target,
                operation.value,
                expectedPayload,
                builder.MIGRATION_PREDECESSOR(),
                builder.MIGRATION_SALT()
            )
        );

        assertEq(operation.scheduleCalldata, expectedScheduleCalldata);
        assertEq(operation.executeCalldata, expectedExecuteCalldata);
        assertEq(
            operation.operationId,
            keccak256(
                abi.encode(
                    operation.target,
                    operation.value,
                    expectedPayload,
                    builder.MIGRATION_PREDECESSOR(),
                    builder.MIGRATION_SALT()
                )
            )
        );
    }
}
