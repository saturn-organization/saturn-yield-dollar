// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockChainlinkOracle} from "../test/mocks/MockChainlinkOracle.sol";

/**
 * @title DeployMockOracle
 * @notice Deploys a MockChainlinkOracle for testnet use
 *
 * The mock oracle returns a fixed price of $100 (100e8).
 * Call the `heartbeat()` function periodically to keep it fresh.
 *
 * Environment variables required:
 * - PRIVATE_KEY: Deployer private key
 * - RPC_URL: RPC endpoint
 *
 * Usage:
 *   forge script script/DeployMockOracle.s.sol --rpc-url $RPC_URL --broadcast
 */
contract DeployMockOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploy Mock Chainlink Oracle ===");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        MockChainlinkOracle oracle = new MockChainlinkOracle();

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("MockChainlinkOracle:", address(oracle));
        console.log("Price:", uint256(oracle.PRICE()) / 1e8, "USD");
        console.log("Decimals:", oracle.DECIMALS());
    }
}
