// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {BuildV2UpgradeBatch} from "../../../script/v2/upgrade/BuildV2UpgradeBatch.s.sol";
import {ScheduleV2Upgrade} from "../../../script/v2/upgrade/ScheduleV2Upgrade.s.sol";
import {ExecuteV2Upgrade} from "../../../script/v2/upgrade/ExecuteV2Upgrade.s.sol";
import {UpgradeConfig} from "../../../script/v2/configs/UpgradeConfig.sol";

interface IUpgradeWorkflow {
    function run() external returns (bytes32);
}

/// @dev Calls scripts as a configured sender without combining prank and broadcast cheatcodes.
contract UpgradeWorkflowCaller {
    function run(IUpgradeWorkflow script) external returns (bytes32) {
        return script.run();
    }
}

contract ScheduleV2UpgradeHarness is ScheduleV2Upgrade {
    bytes private _batch;

    constructor(BuildV2UpgradeBatch.UpgradeBatch memory batch) {
        _batch = abi.encode(batch);
    }

    function _validatedBatch() internal override returns (BuildV2UpgradeBatch.UpgradeBatch memory) {
        return abi.decode(_batch, (BuildV2UpgradeBatch.UpgradeBatch));
    }
}

contract ExecuteV2UpgradeHarness is ExecuteV2Upgrade {
    bytes private _batch;

    constructor(BuildV2UpgradeBatch.UpgradeBatch memory batch) {
        _batch = abi.encode(batch);
    }

    function setBatch(BuildV2UpgradeBatch.UpgradeBatch memory batch) external {
        _batch = abi.encode(batch);
    }

    function _validatedBatch() internal override returns (BuildV2UpgradeBatch.UpgradeBatch memory) {
        return abi.decode(_batch, (BuildV2UpgradeBatch.UpgradeBatch));
    }
}

contract UpgradeWorkflowTarget {
    error UpgradeRejected();

    address public immutable ADMIN;
    address public implementation;
    bytes32 public initializerHash;
    uint256 public upgradeCount;
    bool public failUpgrade;

    constructor(address admin) {
        ADMIN = admin;
    }

    function setFailUpgrade(bool value) external {
        failUpgrade = value;
    }

    function upgradeToAndCall(address newImplementation, bytes calldata initializer) external payable {
        require(msg.sender == ADMIN, "not timelock");
        if (failUpgrade) revert UpgradeRejected();

        implementation = newImplementation;
        initializerHash = keccak256(initializer);
        ++upgradeCount;
    }
}

contract V2UpgradeWorkflowTest is Test, UpgradeConfig {
    address private constant DEPLOYER = 0x59Ebb7143dDDd7b045dE7B0bd0F99446143F1624;
    address private constant DEFAULT_BROADCAST_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    TimelockController private timelock;
    UpgradeWorkflowTarget private vault;
    UpgradeWorkflowTarget private queue;
    ScheduleV2UpgradeHarness private scheduler;
    ExecuteV2UpgradeHarness private executor;
    BuildV2UpgradeBatch.UpgradeBatch private batch;

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

        deployCodeTo("V2UpgradeWorkflow.t.sol:UpgradeWorkflowTarget", abi.encode(TIMELOCK), STAKED_USDAT_PROXY);
        deployCodeTo("V2UpgradeWorkflow.t.sol:UpgradeWorkflowTarget", abi.encode(TIMELOCK), WITHDRAWAL_QUEUE_PROXY);
        vault = UpgradeWorkflowTarget(STAKED_USDAT_PROXY);
        queue = UpgradeWorkflowTarget(WITHDRAWAL_QUEUE_PROXY);
        vm.etch(PROPOSER, type(UpgradeWorkflowCaller).runtimeCode);
        vm.etch(DEPLOYER, type(UpgradeWorkflowCaller).runtimeCode);

        batch = new BuildV2UpgradeBatch().buildBatch();
        scheduler = new ScheduleV2UpgradeHarness(batch);
        executor = new ExecuteV2UpgradeHarness(batch);
    }

    function test_scheduleAndExecute_UsesRegeneratedBatchAndOpenExecutor() public {
        uint256 scheduledAt = block.timestamp;

        assertEq(_schedule(), batch.operationId);
        assertTrue(timelock.isOperationPending(batch.operationId));
        assertFalse(timelock.isOperationReady(batch.operationId));
        assertEq(timelock.getTimestamp(batch.operationId), scheduledAt + TIMELOCK_DELAY);
        assertEq(vault.upgradeCount(), 0);
        assertEq(queue.upgradeCount(), 0);
        (bytes32 scheduledId, uint256 readyAt) = scheduler.checkScheduled();
        assertEq(scheduledId, batch.operationId);
        assertEq(readyAt, scheduledAt + TIMELOCK_DELAY);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), DEPLOYER));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), DEFAULT_BROADCAST_SENDER));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), DEFAULT_BROADCAST_SENDER));

        vm.warp(scheduledAt + TIMELOCK_DELAY);
        assertEq(_execute(), batch.operationId);
        assertEq(executor.checkExecuted(), batch.operationId);
        assertTrue(timelock.isOperationDone(batch.operationId));
        assertEq(vault.implementation(), STAKED_USDAT_IMPLEMENTATION);
        assertEq(queue.implementation(), WITHDRAWAL_QUEUE_IMPLEMENTATION);
        assertEq(vault.initializerHash(), keccak256(batch.vaultInitializer));
        assertEq(queue.initializerHash(), keccak256(batch.queueInitializer));
        assertEq(vault.upgradeCount(), 1);
        assertEq(queue.upgradeCount(), 1);
    }

    function test_scheduleAndExecute_ZeroSaltUsesActualReadyTime() public {
        assertEq(BATCH_SALT, bytes32(0));
        vm.warp(block.timestamp + 3 days + 17);
        uint256 scheduledAt = block.timestamp;

        assertEq(_schedule(), batch.operationId);
        (, uint256 readyAt) = scheduler.checkScheduled();
        assertEq(readyAt, scheduledAt + TIMELOCK_DELAY);

        vm.warp(readyAt + 2 days);
        assertTrue(timelock.isOperationReady(batch.operationId));
        assertEq(new BuildV2UpgradeBatch().buildBatch().operationId, batch.operationId);
        assertEq(_execute(), batch.operationId);
        assertEq(executor.checkExecuted(), batch.operationId);
        assertEq(vault.upgradeCount(), 1);
        assertEq(queue.upgradeCount(), 1);
    }

    function test_schedule_RejectsWrongSender() public {
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Upgrade.UnauthorizedProposer.selector, address(this)));
        scheduler.run();
        assertFalse(timelock.isOperation(batch.operationId));
    }

    function test_schedule_AcceptsAnotherAuthorizedProposer() public {
        address alternateProposer = address(0xA11CE);
        vm.etch(alternateProposer, type(UpgradeWorkflowCaller).runtimeCode);
        timelock.grantRole(timelock.PROPOSER_ROLE(), alternateProposer);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), alternateProposer));

        assertEq(UpgradeWorkflowCaller(alternateProposer).run(IUpgradeWorkflow(address(scheduler))), batch.operationId);
        assertTrue(timelock.isOperationPending(batch.operationId));
    }

    function test_schedule_RejectsRepeatWithoutResettingDelay() public {
        _schedule();
        uint256 readyAt = timelock.getTimestamp(batch.operationId);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Upgrade.AlreadyScheduled.selector, batch.operationId));
        _schedule();
        assertTrue(timelock.isOperationPending(batch.operationId));
        assertEq(timelock.getTimestamp(batch.operationId), readyAt);
    }

    function test_schedule_RestartsDelayAfterCancellation() public {
        _schedule();
        vm.prank(PROPOSER);
        timelock.cancel(batch.operationId);
        vm.warp(block.timestamp + 1 days);

        assertEq(_schedule(), batch.operationId);
        assertTrue(timelock.isOperationPending(batch.operationId));
        assertEq(timelock.getTimestamp(batch.operationId), block.timestamp + TIMELOCK_DELAY);
    }

    function test_schedule_RejectsCompletedOperation() public {
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        _execute();
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Upgrade.AlreadyExecuted.selector, batch.operationId));
        _schedule();
        assertTrue(timelock.isOperationDone(batch.operationId));
    }

    function test_scripts_RejectWrongChain() public {
        vm.chainId(EXPECTED_CHAIN_ID + 1);
        vm.expectRevert(abi.encodeWithSelector(ScheduleV2Upgrade.WrongChain.selector, EXPECTED_CHAIN_ID + 1));
        _schedule();
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Upgrade.WrongChain.selector, EXPECTED_CHAIN_ID + 1));
        _execute();
    }

    function test_productionSchedule_RejectsUnapprovedConfiguration() public {
        ScheduleV2Upgrade productionScheduler = new ScheduleV2Upgrade();
        assertFalse(UPGRADE_CONFIGURATION_APPROVED);
        vm.expectRevert(
            abi.encodeWithSelector(BuildV2UpgradeBatch.InvalidConfiguration.selector, "UPGRADE_CONFIGURATION_APPROVED")
        );
        UpgradeWorkflowCaller(PROPOSER).run(IUpgradeWorkflow(address(productionScheduler)));
    }

    function test_productionExecute_RejectsUnapprovedConfiguration() public {
        ExecuteV2Upgrade productionExecutor = new ExecuteV2Upgrade();
        assertFalse(UPGRADE_CONFIGURATION_APPROVED);
        vm.expectRevert(
            abi.encodeWithSelector(BuildV2UpgradeBatch.InvalidConfiguration.selector, "UPGRADE_CONFIGURATION_APPROVED")
        );
        UpgradeWorkflowCaller(DEPLOYER).run(IUpgradeWorkflow(address(productionExecutor)));
    }

    function test_execute_RejectsUnscheduledOperation() public {
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Upgrade.OperationNotReady.selector, batch.operationId, 0));
        _execute();
        assertFalse(timelock.isOperation(batch.operationId));
        assertEq(vault.upgradeCount(), 0);
        assertEq(queue.upgradeCount(), 0);
    }

    function test_execute_RejectsBeforeReady() public {
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecuteV2Upgrade.OperationNotReady.selector, batch.operationId, timelock.getTimestamp(batch.operationId)
            )
        );
        _execute();
        assertTrue(timelock.isOperationPending(batch.operationId));
        assertEq(vault.upgradeCount(), 0);
    }

    function test_execute_RejectsCancelledOperation() public {
        _schedule();
        vm.prank(PROPOSER);
        timelock.cancel(batch.operationId);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Upgrade.OperationNotReady.selector, batch.operationId, 0));
        _execute();
        assertFalse(timelock.isOperation(batch.operationId));
        assertEq(vault.upgradeCount(), 0);
    }

    function test_execute_RejectsCompletedOperation() public {
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        _execute();
        vm.expectRevert(abi.encodeWithSelector(ExecuteV2Upgrade.AlreadyExecuted.selector, batch.operationId));
        _execute();
        assertTrue(timelock.isOperationDone(batch.operationId));
        assertEq(vault.upgradeCount(), 1);
        assertEq(queue.upgradeCount(), 1);
    }

    function test_execute_RejectsWhenPublicExecutionIsRevoked() public {
        _schedule();
        timelock.revokeRole(timelock.EXECUTOR_ROLE(), address(0));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert();
        _execute();
        assertTrue(timelock.isOperationReady(batch.operationId));
        assertEq(vault.upgradeCount(), 0);
    }

    function test_execute_RejectsConfigurationDrift() public {
        _schedule();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        BuildV2UpgradeBatch.UpgradeBatchInput memory changed;
        changed.stakedUsdatImplementation = address(0xBAD);
        changed.withdrawalQueueImplementation = WITHDRAWAL_QUEUE_IMPLEMENTATION;
        changed.salt = BATCH_SALT;
        BuildV2UpgradeBatch.UpgradeBatch memory changedBatch = new BuildV2UpgradeBatch().buildBatch(changed);
        assertNotEq(changedBatch.operationId, batch.operationId);
        assertFalse(timelock.isOperation(changedBatch.operationId));
        executor.setBatch(changedBatch);
        vm.expectRevert(
            abi.encodeWithSelector(ExecuteV2Upgrade.OperationNotReady.selector, changedBatch.operationId, 0)
        );
        _execute();
        assertTrue(timelock.isOperationReady(batch.operationId));
        assertEq(vault.upgradeCount(), 0);
    }

    function test_execute_SecondUpgradeFailureRollsBackEntireBatch() public {
        _schedule();
        queue.setFailUpgrade(true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(UpgradeWorkflowTarget.UpgradeRejected.selector);
        _execute();
        // A reverted script skips stopBroadcast; a new Forge invocation would start with fresh context.
        vm.stopBroadcast();
        assertEq(vault.implementation(), address(0));
        assertEq(vault.initializerHash(), bytes32(0));
        assertEq(vault.upgradeCount(), 0);
        assertEq(queue.upgradeCount(), 0);
        assertTrue(timelock.isOperationReady(batch.operationId));

        queue.setFailUpgrade(false);
        _execute();
        assertTrue(timelock.isOperationDone(batch.operationId));
        assertEq(vault.upgradeCount(), 1);
        assertEq(queue.upgradeCount(), 1);
    }

    function _schedule() private returns (bytes32) {
        return UpgradeWorkflowCaller(PROPOSER).run(IUpgradeWorkflow(address(scheduler)));
    }

    function _execute() private returns (bytes32) {
        return UpgradeWorkflowCaller(DEPLOYER).run(IUpgradeWorkflow(address(executor)));
    }
}
