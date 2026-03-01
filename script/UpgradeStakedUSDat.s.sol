// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {StakedUSDat} from "../src/StakedUSDat.sol";
import {IStrcPriceOracle} from "../src/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";

/**
 * @title UpgradeStakedUSDat
 * @notice Upgrades the StakedUSDat proxy to a new implementation
 *
 * This script:
 * 1. Deploys a new StakedUSDat implementation
 * 2. Calls upgradeToAndCall on the proxy
 *
 * Environment variables required:
 * - ADMIN_PRIVATE_KEY: Private key of the DEFAULT_ADMIN_ROLE holder
 * - RPC_URL: RPC endpoint
 *
 * Usage:
 *   forge script script/UpgradeStakedUSDat.s.sol --rpc-url $RPC_URL --broadcast
 */
contract UpgradeStakedUSDat is Script {
    // Deployed contract addresses (Sepolia)
    address constant STRC_ORACLE = 0x9C87dd67355c8Da172D3e2A2cADE1CcD15E23A58;
    address constant WITHDRAWAL_QUEUE = 0x3b2bd22089ED734979BB80A614d812b31B37ece4;
    address constant STAKED_USDAT_PROXY = 0x1383cB4A7f78a9b63b4928f6D4F77221b50f30a4;

    function run() external {
        uint256 adminPrivateKey = vm.envUint("ADMIN_PRIVATE_KEY");
        address admin = vm.addr(adminPrivateKey);

        console.log("=== StakedUSDat Upgrade ===");
        console.log("Admin:", admin);
        console.log("Proxy:", STAKED_USDAT_PROXY);
        console.log("");

        vm.startBroadcast(adminPrivateKey);

        // Step 1: Deploy new implementation
        // Constructor args: (strcOracle, withdrawalQueue) - immutables baked into bytecode
        StakedUSDat newImpl = new StakedUSDat(IStrcPriceOracle(STRC_ORACLE), IWithdrawalQueueERC721(WITHDRAWAL_QUEUE));
        console.log("1. New implementation deployed at:", address(newImpl));

        // Step 2: Upgrade proxy to new implementation
        StakedUSDat proxy = StakedUSDat(STAKED_USDAT_PROXY);
        proxy.upgradeToAndCall(address(newImpl), "");
        console.log("2. Proxy upgraded to new implementation");

        vm.stopBroadcast();

        // Verify
        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("New implementation:", address(newImpl));
    }
}
