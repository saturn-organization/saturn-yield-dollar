// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {BuildV2Migration} from "./BuildV2Migration.s.sol";
import {MigrationConfig} from "../configs/MigrationConfig.sol";

contract ScheduleV2Migration is Script, MigrationConfig {
    error WrongChain(uint256 chainId);
    error UnauthorizedProposer(address sender);
    error AlreadyScheduled(bytes32 operationId);
    error AlreadyExecuted(bytes32 operationId);
    error OperationNotScheduled(bytes32 operationId);

    function run() external returns (bytes32 operationId) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        TimelockController timelock = TimelockController(payable(TIMELOCK));
        if (!timelock.hasRole(timelock.PROPOSER_ROLE(), msg.sender)) revert UnauthorizedProposer(msg.sender);
        BuildV2Migration.MigrationOperation memory operation = _validatedOperation();
        operationId = operation.operationId;

        if (timelock.isOperationDone(operationId)) revert AlreadyExecuted(operationId);
        if (timelock.isOperationPending(operationId)) revert AlreadyScheduled(operationId);

        vm.startBroadcast(msg.sender);
        timelock.schedule(
            operation.target, operation.value, operation.payload, MIGRATION_PREDECESSOR, MIGRATION_SALT, TIMELOCK_DELAY
        );
        vm.stopBroadcast();

        if (!timelock.isOperationPending(operationId)) revert OperationNotScheduled(operationId);
        console.log("Operation ID:");
        console.logBytes32(operationId);
    }

    function checkScheduled() external returns (bytes32 operationId, uint256 readyAt) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        operationId = new BuildV2Migration().buildOperation().operationId;
        TimelockController timelock = TimelockController(payable(TIMELOCK));
        if (!timelock.isOperationPending(operationId)) revert OperationNotScheduled(operationId);
        readyAt = timelock.getTimestamp(operationId);
        console.log("Confirmed scheduled operation:");
        console.logBytes32(operationId);
        console.log("Ready at (Unix seconds):", readyAt);
    }

    function _validatedOperation() internal virtual returns (BuildV2Migration.MigrationOperation memory) {
        return new BuildV2Migration().run();
    }
}
