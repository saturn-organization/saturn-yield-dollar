// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TokenizedSTRC} from "../src/TokenizedSTRC.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";
import {StakedUSDat} from "../src/StakedUSDat.sol";

/**
 * @title DeployScript
 * @notice Deploys the sUSDat protocol contracts
 *
 * Deployment order:
 * 1. TokenizedSTRC - needs oracle address
 * 2. WithdrawalQueue - needs tSTRC and USDat addresses
 * 3. StakedUSDat Implementation - needs tSTRC and WithdrawalQueue (immutables)
 * 4. StakedUSDat Proxy - points to implementation, initialized with admin/processor/compliance/usdat
 *
 * Post-deployment role grants:
 * - TokenizedSTRC: grant STAKED_USDAT_ROLE to StakedUSDat proxy
 * - WithdrawalQueue: grant STAKED_USDAT_ROLE to StakedUSDat proxy
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
    TokenizedSTRC public tstrc;
    WithdrawalQueue public withdrawalQueue;
    StakedUSDat public stakedUsdatImpl;
    StakedUSDat public stakedUsdat; // proxy

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

        // Step 1: Deploy TokenizedSTRC
        tstrc = new TokenizedSTRC(admin, oracle);
        console.log("1. TokenizedSTRC deployed at:", address(tstrc));

        // Step 2: Deploy WithdrawalQueue
        withdrawalQueue = new WithdrawalQueue(address(tstrc), usdat, admin);
        console.log("2. WithdrawalQueue deployed at:", address(withdrawalQueue));

        // Step 3: Deploy StakedUSDat Implementation
        stakedUsdatImpl = new StakedUSDat(tstrc, withdrawalQueue);
        console.log("3. StakedUSDat Implementation deployed at:", address(stakedUsdatImpl));

        // Step 4: Deploy StakedUSDat Proxy and initialize
        bytes memory initData = abi.encodeCall(StakedUSDat.initialize, (admin, processor, compliance, IERC20(usdat)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(stakedUsdatImpl), initData);
        stakedUsdat = StakedUSDat(address(proxy));
        console.log("4. StakedUSDat Proxy deployed at:", address(stakedUsdat));

        // Step 5: Grant roles on TokenizedSTRC
        tstrc.grantRole(tstrc.STAKED_USDAT_ROLE(), address(stakedUsdat));
        console.log("5. TokenizedSTRC: Granted STAKED_USDAT_ROLE to StakedUSDat");

        // Step 6: Grant roles on WithdrawalQueue
        withdrawalQueue.grantRole(withdrawalQueue.STAKED_USDAT_ROLE(), address(stakedUsdat));
        console.log("6. WithdrawalQueue: Granted STAKED_USDAT_ROLE to StakedUSDat");

        withdrawalQueue.grantRole(withdrawalQueue.PROCESSOR_ROLE(), processor);
        console.log("7. WithdrawalQueue: Granted PROCESSOR_ROLE to", processor);

        withdrawalQueue.grantRole(withdrawalQueue.COMPLIANCE_ROLE(), compliance);
        console.log("8. WithdrawalQueue: Granted COMPLIANCE_ROLE to", compliance);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("TokenizedSTRC:", address(tstrc));
        console.log("WithdrawalQueue:", address(withdrawalQueue));
        console.log("StakedUSDat Implementation:", address(stakedUsdatImpl));
        console.log("StakedUSDat Proxy:", address(stakedUsdat));
    }
}
