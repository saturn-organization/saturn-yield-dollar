// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {WithdrawalQueueERC721} from "../src/WithdrawalQueueERC721.sol";

/**
 * @title UpgradeWithdrawalQueueERC721
 * @notice Upgrades the WithdrawalQueueERC721 proxy to a new implementation
 *
 * This script:
 * 1. Deploys a new WithdrawalQueueERC721 implementation
 * 2. Calls upgradeToAndCall on the proxy
 *
 * Environment variables required:
 * - RPC_URL: RPC endpoint
 *
 * Usage (with Fireblocks):
 *   source .env && fireblocks-json-rpc --http -- forge script script/UpgradeWithdrawalQueueERC721.s.sol \
 *     --sender $ADMIN --slow --broadcast --unlocked --rpc-url {}
 *
 * Usage (with private key):
 *   source .env && forge script script/UpgradeWithdrawalQueueERC721.s.sol --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PRIVATE_KEY
 */
contract UpgradeWithdrawalQueueERC721 is Script {
    // Deployed contract addresses (Sepolia)
    address constant USDAT = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;
    address constant WITHDRAWAL_QUEUE_PROXY = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;

    function run() external {
        console.log("=== WithdrawalQueueERC721 Upgrade ===");
        console.log("Sender:", msg.sender);
        console.log("Proxy:", WITHDRAWAL_QUEUE_PROXY);
        console.log("");

        vm.startBroadcast();

        // Step 1: Deploy new implementation
        // Constructor args: (usdat, stakedUsdat) - immutables baked into bytecode
        WithdrawalQueueERC721 newImpl = new WithdrawalQueueERC721(USDAT, STAKED_USDAT_PROXY);
        console.log("1. New implementation deployed at:", address(newImpl));

        // Step 2: Upgrade proxy to new implementation
        WithdrawalQueueERC721 proxy = WithdrawalQueueERC721(WITHDRAWAL_QUEUE_PROXY);
        proxy.upgradeToAndCall(address(newImpl), "");
        console.log("2. Proxy upgraded to new implementation");

        vm.stopBroadcast();

        // Verify
        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("New implementation:", address(newImpl));
    }
}
