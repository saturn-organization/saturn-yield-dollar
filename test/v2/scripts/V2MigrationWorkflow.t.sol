// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {BuildV2Migration} from "../../../script/v2/migrate/BuildV2Migration.s.sol";
import {ScheduleV2Migration} from "../../../script/v2/migrate/ScheduleV2Migration.s.sol";
import {ExecuteV2Migration} from "../../../script/v2/migrate/ExecuteV2Migration.s.sol";
import {MigrationConfig} from "../../../script/v2/configs/MigrationConfig.sol";

interface IMigrationWorkflow {
    function run() external returns (bytes32);
}

/// @dev Calls scripts as a configured sender without combining prank and broadcast cheatcodes.
contract MigrationWorkflowCaller {
    function run(IMigrationWorkflow script) external returns (bytes32) {
        return script.run();
    }
}

contract ScheduleV2MigrationHarness is ScheduleV2Migration {
    bytes private _operation;

    constructor(BuildV2Migration.MigrationOperation memory operation) {
        _operation = abi.encode(operation);
    }

    function _validatedOperation() internal override returns (BuildV2Migration.MigrationOperation memory) {
        return abi.decode(_operation, (BuildV2Migration.MigrationOperation));
    }
}

contract ExecuteV2MigrationHarness is ExecuteV2Migration {
    bytes private _operation;

    constructor(BuildV2Migration.MigrationOperation memory operation) {
        _operation = abi.encode(operation);
    }

    function setOperation(BuildV2Migration.MigrationOperation memory operation) external {
        _operation = abi.encode(operation);
    }

    function _validatedOperation() internal override returns (BuildV2Migration.MigrationOperation memory) {
        return abi.decode(_operation, (BuildV2Migration.MigrationOperation));
    }
}

contract MigrationWorkflowTarget {
    error MigrationRejected();

    address public immutable ADMIN;
    uint256 public expectedStrcon;
    uint256 public deadline;
    bytes32 public payloadHash;
    uint256 public migrationCount;
    bool public failMigration;

    constructor(address admin) {
        ADMIN = admin;
    }

    function setFailMigration(bool value) external {
        failMigration = value;
    }

    function migrate(uint256 expectedStrcon_, uint256 deadline_) external {
        require(msg.sender == ADMIN, "not timelock");
        expectedStrcon = expectedStrcon_;
        deadline = deadline_;
        payloadHash = keccak256(msg.data);
        ++migrationCount;
        if (failMigration) revert MigrationRejected();
    }
}

contract V2MigrationWorkflowTest is Test, MigrationConfig {
    address private constant DEPLOYER = 0x59Ebb7143dDDd7b045dE7B0bd0F99446143F1624;
    address private constant DEFAULT_BROADCAST_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    TimelockController private timelock;
    MigrationWorkflowTarget private vault;
    ScheduleV2MigrationHarness private scheduler;
    ExecuteV2MigrationHarness private executor;
    BuildV2Migration.MigrationOperation private operation;

    function setUp() public {
        vm.chainId(EXPECTED_CHAIN_ID);
        vm.warp(1_800_000_000);

        address[] memory proposers = new address[](1);
        proposers[0] = PROPOSER;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        deployCodeTo(
            "TimelockController.sol:TimelockController",
            abi.encode(TIMELOCK_DELAY, proposers, executors, address(this)),
            TIMELOCK
        );
        timelock = TimelockController(payable(TIMELOCK));

        deployCodeTo("V2MigrationWorkflow.t.sol:MigrationWorkflowTarget", abi.encode(TIMELOCK), STAKED_USDAT_PROXY);
        vault = MigrationWorkflowTarget(STAKED_USDAT_PROXY);
        vm.etch(PROPOSER, type(MigrationWorkflowCaller).runtimeCode);
        vm.etch(DEPLOYER, type(MigrationWorkflowCaller).runtimeCode);

        operation = new BuildV2Migration().buildOperation();
        scheduler = new ScheduleV2MigrationHarness(operation);
        executor = new ExecuteV2MigrationHarness(operation);
    }

    function test_scheduleAndExecute_UsesExactOperationAndOpenExecutor() public {
        uint256 scheduledAt = block.timestamp;
        assertEq(TIMELOCK_DELAY, 5 days);
        assertEq(
            operation.operationId,
            timelock.hashOperation(
                operation.target, operation.value, operation.payload, MIGRATION_PREDECESSOR, MIGRATION_SALT
            )
        );

        assertEq(_schedule(), operation.operationId);
        assertTrue(timelock.isOperationPending(operation.operationId));
        assertFalse(timelock.isOperationReady(operation.operationId));
        assertEq(vault.migrationCount(), 0);
        (bytes32 scheduledId, uint256 readyAt) = scheduler.checkScheduled();
        assertEq(scheduledId, operation.operationId);
        assertEq(readyAt, scheduledAt + 5 days);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), DEPLOYER));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), DEFAULT_BROADCAST_SENDER));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), DEFAULT_BROADCAST_SENDER));

        vm.warp(readyAt);
        assertEq(_execute(), operation.operationId);
        assertEq(executor.checkExecuted(), operation.operationId);
        assertTrue(timelock.isOperationDone(operation.operationId));
        assertEq(vault.expectedStrcon(), EXPECTED_STRCON);
        assertEq(vault.deadline(), MIGRATION_DEADLINE);
        assertEq(vault.payloadHash(), keccak256(operation.payload));
        assertEq(vault.migrationCount(), 1);
    }

    function test_scheduleAndExecute_ZeroSaltUsesActualReadyTime() public {
        assertEq(MIGRATION_SALT, bytes32(0));
        vm.warp(block.timestamp + 3 days + 17);
        uint256 scheduledAt = block.timestamp;

        assertEq(_schedule(), operation.operationId);
        (, uint256 readyAt) = scheduler.checkScheduled();
        assertEq(readyAt, scheduledAt + TIMELOCK_DELAY);

        vm.warp(readyAt + 2 days);
        assertTrue(timelock.isOperationReady(operation.operationId));
        assertEq(new BuildV2Migration().buildOperation().operationId, operation.operationId);
        assertEq(_execute(), operation.operationId);
        assertEq(executor.checkExecuted(), operation.operationId);
        assertEq(vault.migrationCount(), 1);
    }

    function test_schedule_RejectsWrongSender() public {
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Migration.UnauthorizedProposer.selector, address(this)));
        scheduler.run();
        assertFalse(timelock.isOperation(operation.operationId));
    }

    function test_schedule_AcceptsAnotherAuthorizedProposer() public {
        address alternateProposer = address(0xA11CE);
        vm.etch(alternateProposer, type(MigrationWorkflowCaller).runtimeCode);
        timelock.grantRole(timelock.PROPOSER_ROLE(), alternateProposer);
        timelock.revokeRole(timelock.PROPOSER_ROLE(), PROPOSER);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), alternateProposer));

        assertEq(
            MigrationWorkflowCaller(alternateProposer).run(IMigrationWorkflow(address(scheduler))),
            operation.operationId
        );
        assertTrue(timelock.isOperationPending(operation.operationId));
    }

    function test_schedule_RejectsRepeatWithoutResettingDelay() public {
        _schedule();
        uint256 readyAt = timelock.getTimestamp(operation.operationId);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Migration.AlreadyScheduled.selector, operation.operationId));
        _schedule();
        assertTrue(timelock.isOperationPending(operation.operationId));
        assertEq(timelock.getTimestamp(operation.operationId), readyAt);
    }

    function test_schedule_RestartsDelayAfterCancellation() public {
        _schedule();
        vm.prank(PROPOSER);
        timelock.cancel(operation.operationId);
        vm.warp(block.timestamp + 1 days);

        assertEq(_schedule(), operation.operationId);
        assertTrue(timelock.isOperationPending(operation.operationId));
        assertEq(timelock.getTimestamp(operation.operationId), block.timestamp + TIMELOCK_DELAY);
    }

    function test_schedule_RejectsCompletedOperation() public {
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        _execute();
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Migration.AlreadyExecuted.selector, operation.operationId));
        _schedule();
        assertTrue(timelock.isOperationDone(operation.operationId));
    }

    function test_scripts_RejectWrongChain() public {
        vm.chainId(EXPECTED_CHAIN_ID + 1);
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Migration.WrongChain.selector, EXPECTED_CHAIN_ID + 1));
        _schedule();
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.WrongChain.selector, EXPECTED_CHAIN_ID + 1));
        _execute();
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Migration.WrongChain.selector, EXPECTED_CHAIN_ID + 1));
        scheduler.checkScheduled();
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.WrongChain.selector, EXPECTED_CHAIN_ID + 1));
        executor.checkExecuted();
    }

    function test_productionSchedule_RejectsUnapprovedConfiguration() public {
        ScheduleV2Migration productionScheduler = new ScheduleV2Migration();
        assertFalse(MIGRATION_CONFIGURATION_APPROVED);
        vm.expectRevert(
            abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_CONFIGURATION_APPROVED")
        );
        MigrationWorkflowCaller(PROPOSER).run(IMigrationWorkflow(address(productionScheduler)));
    }

    function test_productionExecute_RejectsUnapprovedConfiguration() public {
        ExecuteV2Migration productionExecutor = new ExecuteV2Migration();
        assertFalse(MIGRATION_CONFIGURATION_APPROVED);
        vm.expectRevert(
            abi.encodeWithSelector(BuildV2Migration.InvalidConfiguration.selector, "MIGRATION_CONFIGURATION_APPROVED")
        );
        MigrationWorkflowCaller(DEPLOYER).run(IMigrationWorkflow(address(productionExecutor)));
    }

    function test_execute_RejectsUnscheduledOperation() public {
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.OperationNotReady.selector, operation.operationId, 0));
        _execute();
        assertFalse(timelock.isOperation(operation.operationId));
        assertEq(vault.migrationCount(), 0);
    }

    function test_execute_RejectsBeforeReady() public {
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecuteV2Migration.OperationNotReady.selector,
                operation.operationId,
                timelock.getTimestamp(operation.operationId)
            )
        );
        _execute();
        assertTrue(timelock.isOperationPending(operation.operationId));
        assertEq(vault.migrationCount(), 0);
    }

    function test_execute_RejectsCancelledOperation() public {
        _schedule();
        vm.prank(PROPOSER);
        timelock.cancel(operation.operationId);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.OperationNotReady.selector, operation.operationId, 0));
        _execute();
        assertFalse(timelock.isOperation(operation.operationId));
        assertEq(vault.migrationCount(), 0);
    }

    function test_execute_RejectsCompletedOperation() public {
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        _execute();
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.AlreadyExecuted.selector, operation.operationId));
        _execute();
        assertTrue(timelock.isOperationDone(operation.operationId));
        assertEq(vault.migrationCount(), 1);
    }

    function test_execute_RejectsWhenPublicExecutionIsRevoked() public {
        _schedule();
        timelock.revokeRole(timelock.EXECUTOR_ROLE(), address(0));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert();
        _execute();
        vm.stopBroadcast();
        assertTrue(timelock.isOperationReady(operation.operationId));
        assertEq(vault.migrationCount(), 0);
    }

    function test_execute_RejectsExpectedAmountDrift() public {
        BuildV2Migration.MigrationOperation memory changed =
            new BuildV2Migration().buildOperation(EXPECTED_STRCON + 1, MIGRATION_DEADLINE, MIGRATION_SALT);
        _assertConfigurationDriftRejected(changed);
    }

    function test_execute_RejectsDeadlineDrift() public {
        BuildV2Migration.MigrationOperation memory changed =
            new BuildV2Migration().buildOperation(EXPECTED_STRCON, MIGRATION_DEADLINE + 1, MIGRATION_SALT);
        _assertConfigurationDriftRejected(changed);
    }

    function test_execute_MigrationFailureRollsBackAndCanBeRetried() public {
        _schedule();
        vault.setFailMigration(true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(MigrationWorkflowTarget.MigrationRejected.selector);
        _execute();
        // A reverted script skips stopBroadcast; a new Forge invocation would start with fresh context.
        vm.stopBroadcast();
        assertEq(vault.payloadHash(), bytes32(0));
        assertEq(vault.migrationCount(), 0);
        assertTrue(timelock.isOperationReady(operation.operationId));

        vault.setFailMigration(false);
        assertEq(_execute(), operation.operationId);
        assertTrue(timelock.isOperationDone(operation.operationId));
        assertEq(vault.payloadHash(), keccak256(operation.payload));
        assertEq(vault.migrationCount(), 1);
    }

    function test_checkScheduled_RejectsUnscheduledCancelledAndCompletedOperation() public {
        vm.expectRevert(
            abi.encodeWithSelector(ScheduleV2Migration.OperationNotScheduled.selector, operation.operationId)
        );
        scheduler.checkScheduled();
        _schedule();
        vm.prank(PROPOSER);
        timelock.cancel(operation.operationId);
        vm.expectRevert(
            abi.encodeWithSelector(ScheduleV2Migration.OperationNotScheduled.selector, operation.operationId)
        );
        scheduler.checkScheduled();
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        _execute();
        vm.expectRevert(
            abi.encodeWithSelector(ScheduleV2Migration.OperationNotScheduled.selector, operation.operationId)
        );
        scheduler.checkScheduled();
    }

    function test_checkExecuted_RejectsUnscheduledPendingAndReadyOperation() public {
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.OperationNotExecuted.selector, operation.operationId));
        executor.checkExecuted();
        _schedule();
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.OperationNotExecuted.selector, operation.operationId));
        executor.checkExecuted();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.OperationNotExecuted.selector, operation.operationId));
        executor.checkExecuted();
        assertEq(vault.migrationCount(), 0);
    }

    function _assertConfigurationDriftRejected(BuildV2Migration.MigrationOperation memory changed) private {
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        assertNotEq(changed.operationId, operation.operationId);
        assertFalse(timelock.isOperation(changed.operationId));
        executor.setOperation(changed);
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Migration.OperationNotReady.selector, changed.operationId, 0));
        _execute();
        assertTrue(timelock.isOperationReady(operation.operationId));
        assertEq(vault.migrationCount(), 0);
    }

    function _schedule() private returns (bytes32) {
        return MigrationWorkflowCaller(PROPOSER).run(IMigrationWorkflow(address(scheduler)));
    }

    function _execute() private returns (bytes32) {
        return MigrationWorkflowCaller(DEPLOYER).run(IMigrationWorkflow(address(executor)));
    }
}
