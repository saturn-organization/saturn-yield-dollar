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
 * - ADMIN_PRIVATE_KEY: Private key of the DEFAULT_ADMIN_ROLE holder
 * - RPC_URL: RPC endpoint
 *
 * Usage:
 *   forge script script/UpgradeWithdrawalQueueERC721.s.sol --rpc-url $RPC_URL --broadcast
 */
contract UpgradeWithdrawalQueueERC721 is Script {
    // Deployed contract addresses (Sepolia)
    address constant USDAT = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant STAKED_USDAT_PROXY = 0x1383cB4A7f78a9b63b4928f6D4F77221b50f30a4;
    address constant WITHDRAWAL_QUEUE_PROXY = 0x3b2bd22089ED734979BB80A614d812b31B37ece4;

    function run() external {
        uint256 adminPrivateKey = vm.envUint("ADMIN_PRIVATE_KEY");
        address admin = vm.addr(adminPrivateKey);

        console.log("=== WithdrawalQueueERC721 Upgrade ===");
        console.log("Admin:", admin);
        console.log("Proxy:", WITHDRAWAL_QUEUE_PROXY);
        console.log("");

        vm.startBroadcast(adminPrivateKey);

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
