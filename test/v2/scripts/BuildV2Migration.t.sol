// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {BuildV2Migration} from "../../../script/v2/migrate/BuildV2Migration.s.sol";
import {MigrationConfig} from "../../../script/v2/configs/MigrationConfig.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";

contract BuildV2MigrationHarness is BuildV2Migration {
    function validateDeadline(uint256 deadline, bool forScheduling) external view {
        _validateDeadline(deadline, forScheduling);
    }

    function validateProductionState() external view {
        _validateProductionState(buildOperation());
    }
}

contract MigrationPreflightVaultMock is AccessControl {
    constructor(address timelock, bool parameterManager) {
        _grantRole(parameterManager ? keccak256("PARAMETER_MANAGER_ROLE") : DEFAULT_ADMIN_ROLE, timelock);
    }

    function paused() external pure returns (bool) {
        return true;
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
        assertEq(builder.TIMELOCK_DELAY(), 5 days);
        assertEq(builder.MIGRATION_TIMELOCK_DELAY(), MIGRATION_TIMELOCK_DELAY);
        assertEq(builder.MIGRATION_TIMELOCK_DELAY(), 2 days);
        assertEq(builder.MAX_MIGRATION_TOLERANCE_BPS(), MAX_MIGRATION_TOLERANCE_BPS);
        assertEq(builder.TIMELOCK(), TIMELOCK);
        assertEq(builder.PROPOSER(), PROPOSER);
        assertEq(builder.MIGRATION_TIMELOCK(), MIGRATION_TIMELOCK);
        assertEq(builder.MIGRATION_PROPOSER(), MIGRATION_PROPOSER);
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
        uint256 readyAt = block.timestamp + MIGRATION_TIMELOCK_DELAY;

        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_DEADLINE"));
        harness.validateDeadline(readyAt - 1, true);
        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_DEADLINE"));
        harness.validateDeadline(readyAt, true);
        harness.validateDeadline(readyAt + 1, true);
    }

    function test_validateDeadline_ExecutionUsesOriginalDeadlineAfterTwoDays() public {
        vm.warp(1_800_000_000);
        assertEq(MIGRATION_TIMELOCK_DELAY, 2 days);
        uint256 deadline = block.timestamp + MIGRATION_TIMELOCK_DELAY + 1;
        harness.validateDeadline(deadline, true);

        vm.warp(block.timestamp + MIGRATION_TIMELOCK_DELAY);
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

    function test_validateProductionState_AcceptsParameterManagerWithoutAdmin() public {
        _setUpProductionPreflight(true);
        assertTrue(AccessControl(STAKED_USDAT_PROXY).hasRole(keccak256("PARAMETER_MANAGER_ROLE"), MIGRATION_TIMELOCK));
        assertFalse(AccessControl(STAKED_USDAT_PROXY).hasRole(bytes32(0), MIGRATION_TIMELOCK));

        vm.expectRevert(abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "vault paused"));
        harness.validateProductionState();
    }

    function test_validateProductionState_RejectsAdminWithoutParameterManager() public {
        _setUpProductionPreflight(false);
        assertTrue(AccessControl(STAKED_USDAT_PROXY).hasRole(bytes32(0), MIGRATION_TIMELOCK));
        assertFalse(AccessControl(STAKED_USDAT_PROXY).hasRole(keccak256("PARAMETER_MANAGER_ROLE"), MIGRATION_TIMELOCK));

        vm.expectRevert(
            abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "vault PARAMETER_MANAGER_ROLE")
        );
        harness.validateProductionState();
    }

    function test_buildOperation_PreservesTermsAcrossSchedulingAndExecution() public {
        vm.warp(1_800_000_000);
        uint256 expectedStrcon = 100_000 ether;
        uint256 deadline = block.timestamp + MIGRATION_TIMELOCK_DELAY + 1;
        BuildV2Migration.MigrationOperation memory scheduled =
            builder.buildOperation(expectedStrcon, deadline, MIGRATION_SALT);
        harness.validateDeadline(deadline, true);

        vm.warp(block.timestamp + MIGRATION_TIMELOCK_DELAY);
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

        assertEq(builder.MIGRATION_TIMELOCK(), 0x6F72de4F529a03Bfa883825152656a8c62CBB626);
        assertEq(builder.MIGRATION_PROPOSER(), 0x7A5A4064005584bc727666ec82548A9139d5F21e);
        assertEq(builder.MIGRATION_TIMELOCK_DELAY(), 2 days);
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
                builder.MIGRATION_TIMELOCK_DELAY()
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

    function _setUpProductionPreflight(bool parameterManager) private {
        address[] memory proposers = new address[](1);
        proposers[0] = MIGRATION_PROPOSER;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        deployCodeTo(
            "TimelockController.sol:TimelockController",
            abi.encode(MIGRATION_TIMELOCK_DELAY, proposers, executors, address(0)),
            MIGRATION_TIMELOCK
        );
        deployCodeTo(
            "BuildV2Migration.t.sol:MigrationPreflightVaultMock",
            abi.encode(MIGRATION_TIMELOCK, parameterManager),
            STAKED_USDAT_PROXY
        );
        vm.etch(STRCON, hex"00");
    }
}
