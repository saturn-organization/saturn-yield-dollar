// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockChainlinkOracle} from "../test/mocks/MockChainlinkOracle.sol";

/**
 * @title OracleHeartbeat
 * @notice Calls the heartbeat function on MockChainlinkOracle to refresh its timestamp
 *
 * Run this script periodically (e.g., via cron) to keep the oracle fresh
 * and prevent staleness errors in StrcPriceOracle.
 *
 * Environment variables required:
 * - PRIVATE_KEY: Private key with permission to call heartbeat
 * - RPC_URL: RPC endpoint
 * - MOCK_ORACLE: Address of the deployed MockChainlinkOracle
 *
 * Usage:
 *   forge script script/OracleHeartbeat.s.sol --rpc-url $RPC_URL --broadcast
 *
 * Cron example (every 12 hours):
 *   0 0,12 * * * cd /path/to/project && source .env && forge script script/OracleHeartbeat.s.sol --rpc-url $RPC_URL --broadcast
 */
contract OracleHeartbeat is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(privateKey);
        address oracleAddress = vm.envAddress("ORACLE");

        console.log("=== Oracle Heartbeat ===");
        console.log("Caller:", caller);
        console.log("Oracle:", oracleAddress);

        MockChainlinkOracle oracle = MockChainlinkOracle(oracleAddress);

        uint256 oldTimestamp = oracle.updatedAt();
        console.log("Previous timestamp:", oldTimestamp);

        vm.startBroadcast(privateKey);

        oracle.heartbeat();

        vm.stopBroadcast();

        uint256 newTimestamp = oracle.updatedAt();
        console.log("New timestamp:", newTimestamp);
        console.log("");
        console.log("=== Heartbeat Complete ===");
    }
}
