// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TokenizedSTRC} from "../src/TokenizedSTRC.sol";
import {WithdrawalQueueERC721} from "../src/WithdrawalQueueERC721.sol";
import {StakedUSDat} from "../src/StakedUSDat.sol";
import {ITokenizedSTRC} from "../src/interfaces/ITokenizedSTRC.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";

/**
 * @title DeployScript
 * @notice Deploys the sUSDat protocol contracts
 *
 * Deployment order:
 * 1. TokenizedSTRC - needs oracle address
 * 2. WithdrawalQueueERC721 - needs tSTRC and USDat addresses
 * 3. StakedUSDat Implementation - needs tSTRC and WithdrawalQueueERC721 (immutables)
 * 4. StakedUSDat Proxy - points to implementation, initialized with admin/processor/compliance/usdat
 * 5. WithdrawalQueueERC721.setStakedUSDat - links queue to StakedUSDat (also grants STAKED_USDAT_ROLE)
 *
 * Post-deployment role grants:
 * - TokenizedSTRC: grant STAKED_USDAT_ROLE to StakedUSDat proxy
 * - WithdrawalQueueERC721: grant PROCESSOR_ROLE to processor
 * - WithdrawalQueueERC721: grant COMPLIANCE_ROLE to compliance
 *
 * Manual role grants required on external contracts:
 * - USDat: grant minting role to WithdrawalQueue (for processNext to mint USDat)
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
    WithdrawalQueueERC721 public withdrawalQueue;
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

        // Step 2: Deploy WithdrawalQueueERC721 Implementation and Proxy
        WithdrawalQueueERC721 withdrawalQueueImpl = new WithdrawalQueueERC721(address(tstrc), usdat);
        bytes memory withdrawalQueueInitData = abi.encodeCall(WithdrawalQueueERC721.initialize, (admin));
        ERC1967Proxy withdrawalQueueProxy = new ERC1967Proxy(address(withdrawalQueueImpl), withdrawalQueueInitData);
        withdrawalQueue = WithdrawalQueueERC721(address(withdrawalQueueProxy));
        console.log("2. WithdrawalQueueERC721 Implementation deployed at:", address(withdrawalQueueImpl));
        console.log("   WithdrawalQueueERC721 Proxy deployed at:", address(withdrawalQueue));

        // Step 3: Deploy StakedUSDat Implementation
        stakedUsdatImpl =
            new StakedUSDat(ITokenizedSTRC(address(tstrc)), IWithdrawalQueueERC721(address(withdrawalQueue)));
        console.log("3. StakedUSDat Implementation deployed at:", address(stakedUsdatImpl));

        // Step 4: Deploy StakedUSDat Proxy and initialize
        bytes memory initData = abi.encodeCall(StakedUSDat.initialize, (admin, processor, compliance, IERC20(usdat)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(stakedUsdatImpl), initData);
        stakedUsdat = StakedUSDat(address(proxy));
        console.log("4. StakedUSDat Proxy deployed at:", address(stakedUsdat));

        // Step 5: Grant roles on TokenizedSTRC
        tstrc.grantRole(tstrc.STAKED_USDAT_ROLE(), address(stakedUsdat));
        console.log("5. TokenizedSTRC: Granted STAKED_USDAT_ROLE to StakedUSDat");

        // Step 6: Link WithdrawalQueueERC721 to StakedUSDat (also grants STAKED_USDAT_ROLE)
        withdrawalQueue.setStakedUSDat(address(stakedUsdat));
        console.log("6. WithdrawalQueueERC721: Set StakedUSDat and granted STAKED_USDAT_ROLE");

        // Step 7: Grant PROCESSOR_ROLE on WithdrawalQueueERC721
        withdrawalQueue.grantRole(withdrawalQueue.PROCESSOR_ROLE(), processor);
        console.log("7. WithdrawalQueueERC721: Granted PROCESSOR_ROLE to", processor);

        // Step 8: Grant COMPLIANCE_ROLE on WithdrawalQueueERC721
        withdrawalQueue.grantRole(withdrawalQueue.COMPLIANCE_ROLE(), compliance);
        console.log("8. WithdrawalQueueERC721: Granted COMPLIANCE_ROLE to", compliance);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("TokenizedSTRC:", address(tstrc));
        console.log("WithdrawalQueueERC721:", address(withdrawalQueue));
        console.log("StakedUSDat Implementation:", address(stakedUsdatImpl));
        console.log("StakedUSDat Proxy:", address(stakedUsdat));
    }
}
