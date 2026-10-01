// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {BuildV2UpgradeBatch} from "./BuildV2UpgradeBatch.s.sol";
import {UpgradeConfig} from "../configs/UpgradeConfig.sol";

contract ExecuteV2Upgrade is Script, UpgradeConfig {
    error WrongChain(uint256 chainId);
    error AlreadyExecuted(bytes32 operationId);
    error OperationNotReady(bytes32 operationId, uint256 readyAt);
    error PredecessorNotDone(bytes32 predecessor);
    error OperationNotExecuted(bytes32 operationId);

    function run() external returns (bytes32 operationId) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        BuildV2UpgradeBatch.UpgradeBatch memory batch = _validatedBatch();
        operationId = batch.operationId;
        TimelockController timelock = TimelockController(payable(TIMELOCK));

        if (timelock.isOperationDone(operationId)) revert AlreadyExecuted(operationId);
        if (!timelock.isOperationReady(operationId)) {
            revert OperationNotReady(operationId, timelock.getTimestamp(operationId));
        }
        if (UPGRADE_PREDECESSOR != bytes32(0) && !timelock.isOperationDone(UPGRADE_PREDECESSOR)) {
            revert PredecessorNotDone(UPGRADE_PREDECESSOR);
        }

        vm.startBroadcast();
        timelock.executeBatch(batch.targets, batch.values, batch.payloads, UPGRADE_PREDECESSOR, BATCH_SALT);
        vm.stopBroadcast();

        if (!timelock.isOperationDone(operationId)) revert OperationNotExecuted(operationId);
        console.log("Operation ID:");
        console.logBytes32(operationId);
    }

    function checkExecuted() external returns (bytes32 operationId) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        operationId = new BuildV2UpgradeBatch().buildBatch().operationId;
        if (!TimelockController(payable(TIMELOCK)).isOperationDone(operationId)) {
            revert OperationNotExecuted(operationId);
        }
        console.log("Confirmed executed operation:");
        console.logBytes32(operationId);
    }

    function _validatedBatch() internal virtual returns (BuildV2UpgradeBatch.UpgradeBatch memory) {
        return new BuildV2UpgradeBatch().run();
    }
}
