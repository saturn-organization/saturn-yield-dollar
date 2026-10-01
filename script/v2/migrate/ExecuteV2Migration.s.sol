// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {BuildV2Migration} from "./BuildV2Migration.s.sol";
import {MigrationConfig} from "../configs/MigrationConfig.sol";

contract ExecuteV2Migration is Script, MigrationConfig {
    error WrongChain(uint256 chainId);
    error AlreadyExecuted(bytes32 operationId);
    error OperationNotReady(bytes32 operationId, uint256 readyAt);
    error PredecessorNotDone(bytes32 predecessor);
    error OperationNotExecuted(bytes32 operationId);

    function run() external returns (bytes32 operationId) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        BuildV2Migration.MigrationOperation memory operation = _validatedOperation();
        operationId = operation.operationId;
        TimelockController timelock = TimelockController(payable(MIGRATION_TIMELOCK));

        if (timelock.isOperationDone(operationId)) revert AlreadyExecuted(operationId);
        if (!timelock.isOperationReady(operationId)) {
            revert OperationNotReady(operationId, timelock.getTimestamp(operationId));
        }
        if (MIGRATION_PREDECESSOR != bytes32(0) && !timelock.isOperationDone(MIGRATION_PREDECESSOR)) {
            revert PredecessorNotDone(MIGRATION_PREDECESSOR);
        }

        vm.startBroadcast();
        timelock.execute(operation.target, operation.value, operation.payload, MIGRATION_PREDECESSOR, MIGRATION_SALT);
        vm.stopBroadcast();

        if (!timelock.isOperationDone(operationId)) revert OperationNotExecuted(operationId);
        console.log("Operation ID:");
        console.logBytes32(operationId);
    }

    function checkExecuted() external returns (bytes32 operationId) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        operationId = new BuildV2Migration().buildOperation().operationId;
        if (!TimelockController(payable(MIGRATION_TIMELOCK)).isOperationDone(operationId)) {
            revert OperationNotExecuted(operationId);
        }
        console.log("Confirmed executed operation:");
        console.logBytes32(operationId);
    }

    function _validatedOperation() internal virtual returns (BuildV2Migration.MigrationOperation memory) {
        return new BuildV2Migration().runForExecution();
    }
}
