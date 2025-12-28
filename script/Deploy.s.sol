// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {tokenizedSTRC} from "../src/tokenizedSTRC.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";
import {StakedUSDat} from "../src/StakedUSDat.sol";

/**
 * @title DeployScript
 * @notice Deploys the sUSDat protocol contracts
 *
 * Deployment order:
 * 1. tokenizedSTRC - needs oracle address
 * 2. WithdrawalQueue - needs tSTRC and USDat addresses
 * 3. StakedUSDat - needs all above + processor and compliance addresses
 *
 * Post-deployment role grants:
 * - tokenizedSTRC: grant STAKED_USDAT_ROLE to StakedUSDat
 * - WithdrawalQueue: grant STAKED_USDAT_ROLE to StakedUSDat
 * - WithdrawalQueue: grant PROCESSOR_ROLE to processor
 * - WithdrawalQueue: grant COMPLIANCE_ROLE to compliance
 *
 * Environment variables required:
 * - USDAT: USDat token address
 * - ORACLE: Price oracle address for STRC
 *
 * Environment variables optional (default to deployer):
 * - ADMIN: Admin address
 * - PROCESSOR: Processor address
 * - COMPLIANCE: Compliance address
 */
contract DeployScript is Script {
    tokenizedSTRC public tstrc;
    WithdrawalQueue public withdrawalQueue;
    StakedUSDat public stakedUsdat;

    function run() external {
        address deployer = msg.sender;
        address admin = vm.envOr("ADMIN", deployer);
        address processor = vm.envOr("PROCESSOR", deployer);
        address compliance = vm.envOr("COMPLIANCE", deployer);
        address usdat = vm.envAddress("USDAT");
        address oracle = vm.envAddress("ORACLE");

        console.log("=== Deployment Configuration ===");
        console.log("Deployer:", deployer);
        console.log("Admin:", admin);
        console.log("Processor:", processor);
        console.log("Compliance:", compliance);
        console.log("USDat:", usdat);
        console.log("Oracle:", oracle);
        console.log("");

        vm.startBroadcast();

        // Step 1: Deploy tokenizedSTRC
        tstrc = new tokenizedSTRC(admin, oracle);
        console.log("1. tokenizedSTRC deployed at:", address(tstrc));

        // Step 2: Deploy WithdrawalQueue
        withdrawalQueue = new WithdrawalQueue(address(tstrc), usdat, admin);
        console.log("2. WithdrawalQueue deployed at:", address(withdrawalQueue));

        // Step 3: Deploy StakedUSDat
        stakedUsdat = new StakedUSDat(admin, processor, compliance, IERC20(usdat), tstrc, withdrawalQueue);
        console.log("3. StakedUSDat deployed at:", address(stakedUsdat));

        // Step 4: Grant roles on tokenizedSTRC
        tstrc.grantRole(tstrc.STAKED_USDAT_ROLE(), address(stakedUsdat));
        console.log("4. tokenizedSTRC: Granted STAKED_USDAT_ROLE to StakedUSDat");

        // Step 5: Grant roles on WithdrawalQueue
        withdrawalQueue.grantRole(withdrawalQueue.STAKED_USDAT_ROLE(), address(stakedUsdat));
        console.log("5. WithdrawalQueue: Granted STAKED_USDAT_ROLE to StakedUSDat");

        withdrawalQueue.grantRole(withdrawalQueue.PROCESSOR_ROLE(), processor);
        console.log("6. WithdrawalQueue: Granted PROCESSOR_ROLE to", processor);

        withdrawalQueue.grantRole(withdrawalQueue.COMPLIANCE_ROLE(), compliance);
        console.log("7. WithdrawalQueue: Granted COMPLIANCE_ROLE to", compliance);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("tokenizedSTRC:", address(tstrc));
        console.log("WithdrawalQueue:", address(withdrawalQueue));
        console.log("StakedUSDat:", address(stakedUsdat));
    }
}
