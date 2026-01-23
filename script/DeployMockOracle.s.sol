// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockOracle} from "./MockOracle.sol";

/// @title DeployMockOracle
/// @notice Deploys a mock Chainlink oracle for testing
/// @dev DO NOT use in production - this is for testnet deployments only
contract DeployMockOracleScript is Script {
    function run() external {
        // Default price: $100 with 8 decimals
        int256 initialPrice = vm.envOr("ORACLE_PRICE", int256(100e8));

        console.log("=== Mock Oracle Deployment ===");
        console.log("Initial Price:", uint256(initialPrice) / 1e8, "USD");

        vm.startBroadcast();

        MockOracle oracle = new MockOracle(initialPrice);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("MockOracle deployed at:", address(oracle));
        console.log("");
        console.log("Add this to your .env:");
        console.log("ORACLE=%s", address(oracle));
    }
}
