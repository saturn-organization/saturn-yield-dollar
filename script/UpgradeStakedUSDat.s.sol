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
 * - RPC_URL: RPC endpoint
 *
 * Usage (with Fireblocks):
 *   source .env && fireblocks-json-rpc --http -- forge script script/UpgradeStakedUSDat.s.sol \
 *     --sender $ADMIN --slow --broadcast --unlocked --rpc-url {}
 *
 * Usage (with private key):
 *   source .env && forge script script/UpgradeStakedUSDat.s.sol --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PRIVATE_KEY
 */
contract UpgradeStakedUSDat is Script {
    address constant STRC_ORACLE = 0x5f7eCD0D045c393da6cb6c933c671AC305A871BF;
    address constant WITHDRAWAL_QUEUE = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;
    address constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;

    function run() external {
        console.log("=== StakedUSDat Upgrade ===");
        console.log("Sender:", msg.sender);
        console.log("Proxy:", STAKED_USDAT_PROXY);
        console.log("");

        vm.startBroadcast();

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
