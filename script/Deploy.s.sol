// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import {TokenizedSTRC} from "../src/TokenizedSTRC.sol";
import {WithdrawalQueueERC721} from "../src/WithdrawalQueueERC721.sol";
import {StakedUSDat} from "../src/StakedUSDat.sol";
import {ITokenizedSTRC} from "../src/interfaces/ITokenizedSTRC.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";

/**
 * @title DeployScript
 * @notice Deploys the sUSDat protocol contracts using CREATE3 for deterministic addresses
 *
 * CREATE3 ensures the same addresses across all chains regardless of:
 * - Deployer nonce
 * - Contract bytecode
 * - Constructor arguments
 *
 * Deployment order:
 * 1. Compute all addresses using CREATE3
 * 2. Deploy TokenizedSTRC
 * 3. Deploy WithdrawalQueueERC721 (impl + proxy)
 * 4. Deploy StakedUSDat (impl + proxy)
 * 5. Grant roles
 *
 * Environment variables required:
 * - USDAT: USDat token address
 * - ORACLE: Price oracle address for STRC
 *
 * Environment variables optional (default to deployer):
 * - ADMIN: Admin address
 * - PROCESSOR: Processor address
 * - COMPLIANCE: Compliance address
 * - DEPOSIT_FEE_RECIPIENT: Deposit fee recipient address
 */
contract DeployScript is Script {
    // Salts for CREATE3 - change these for different deployments
    bytes32 constant SALT_TSTRC = keccak256("saturn.TokenizedSTRC.v1");
    bytes32 constant SALT_WQ_IMPL = keccak256("saturn.WithdrawalQueueERC721.impl.v1");
    bytes32 constant SALT_WQ_PROXY = keccak256("saturn.WithdrawalQueueERC721.proxy.v1");
    bytes32 constant SALT_SUSDAT_IMPL = keccak256("saturn.StakedUSDat.impl.v1");
    bytes32 constant SALT_SUSDAT_PROXY = keccak256("saturn.StakedUSDat.proxy.v1");

    struct DeployConfig {
        address deployer;
        address admin;
        address processor;
        address compliance;
        address depositFeeRecipient;
        address usdat;
        address oracle;
    }

    struct DeployedAddresses {
        address tstrc;
        address wqImpl;
        address wqProxy;
        address susdatImpl;
        address susdatProxy;
    }

    TokenizedSTRC public tstrc;
    WithdrawalQueueERC721 public withdrawalQueue;
    StakedUSDat public stakedUsdatImpl;
    StakedUSDat public stakedUsdat;

    function run() external {
        DeployConfig memory cfg = _loadConfig();
        _logConfig(cfg);

        // Compute all addresses first
        DeployedAddresses memory addrs = _computeAddresses();
        _logPredictedAddresses(addrs);

        vm.startBroadcast();

        _deploy(cfg, addrs);
        _grantRoles(cfg);

        vm.stopBroadcast();

        _logResults();
    }

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        cfg.deployer = msg.sender;
        cfg.admin = vm.envOr("ADMIN", cfg.deployer);
        cfg.processor = vm.envOr("PROCESSOR", cfg.deployer);
        cfg.compliance = vm.envOr("COMPLIANCE", cfg.deployer);
        cfg.depositFeeRecipient = vm.envOr("DEPOSIT_FEE_RECIPIENT", cfg.deployer);
        cfg.usdat = vm.envAddress("USDAT");
        cfg.oracle = vm.envAddress("ORACLE");
    }

    function _logConfig(DeployConfig memory cfg) internal pure {
        console.log("=== Deployment Configuration ===");
        console.log("Deployer:", cfg.deployer);
        console.log("Admin:", cfg.admin);
        console.log("Processor:", cfg.processor);
        console.log("Compliance:", cfg.compliance);
        console.log("Deposit Fee Recipient:", cfg.depositFeeRecipient);
        console.log("USDat:", cfg.usdat);
        console.log("Oracle:", cfg.oracle);
        console.log("");
    }

    function _computeAddresses() internal view returns (DeployedAddresses memory addrs) {
        addrs.tstrc = CREATE3.predictDeterministicAddress(SALT_TSTRC);
        addrs.wqImpl = CREATE3.predictDeterministicAddress(SALT_WQ_IMPL);
        addrs.wqProxy = CREATE3.predictDeterministicAddress(SALT_WQ_PROXY);
        addrs.susdatImpl = CREATE3.predictDeterministicAddress(SALT_SUSDAT_IMPL);
        addrs.susdatProxy = CREATE3.predictDeterministicAddress(SALT_SUSDAT_PROXY);
    }

    function _logPredictedAddresses(DeployedAddresses memory addrs) internal pure {
        console.log("=== Predicted Addresses (CREATE3) ===");
        console.log("TokenizedSTRC:", addrs.tstrc);
        console.log("WithdrawalQueue Impl:", addrs.wqImpl);
        console.log("WithdrawalQueue Proxy:", addrs.wqProxy);
        console.log("StakedUSDat Impl:", addrs.susdatImpl);
        console.log("StakedUSDat Proxy:", addrs.susdatProxy);
        console.log("");
    }

    function _deploy(DeployConfig memory cfg, DeployedAddresses memory addrs) internal {
        // Step 1: Deploy TokenizedSTRC
        tstrc = TokenizedSTRC(
            CREATE3.deployDeterministic(
                abi.encodePacked(type(TokenizedSTRC).creationCode, abi.encode(cfg.admin, cfg.oracle)), SALT_TSTRC
            )
        );
        require(address(tstrc) == addrs.tstrc, "TokenizedSTRC address mismatch");
        console.log("1. TokenizedSTRC deployed at:", address(tstrc));

        // Step 2: Deploy WithdrawalQueueERC721 Implementation
        WithdrawalQueueERC721 wqImpl = WithdrawalQueueERC721(
            CREATE3.deployDeterministic(
                abi.encodePacked(
                    type(WithdrawalQueueERC721).creationCode, abi.encode(cfg.usdat, address(tstrc), addrs.susdatProxy)
                ),
                SALT_WQ_IMPL
            )
        );
        require(address(wqImpl) == addrs.wqImpl, "WQ impl address mismatch");
        console.log("2. WithdrawalQueueERC721 Impl deployed at:", address(wqImpl));

        // Step 3: Deploy WithdrawalQueueERC721 Proxy
        bytes memory wqInitData = abi.encodeCall(WithdrawalQueueERC721.initialize, (cfg.admin));
        withdrawalQueue = WithdrawalQueueERC721(
            CREATE3.deployDeterministic(
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(wqImpl), wqInitData)),
                SALT_WQ_PROXY
            )
        );
        require(address(withdrawalQueue) == addrs.wqProxy, "WQ proxy address mismatch");
        console.log("3. WithdrawalQueueERC721 Proxy deployed at:", address(withdrawalQueue));

        // Step 4: Deploy StakedUSDat Implementation
        stakedUsdatImpl = StakedUSDat(
            CREATE3.deployDeterministic(
                abi.encodePacked(
                    type(StakedUSDat).creationCode,
                    abi.encode(ITokenizedSTRC(address(tstrc)), IWithdrawalQueueERC721(address(withdrawalQueue)))
                ),
                SALT_SUSDAT_IMPL
            )
        );
        require(address(stakedUsdatImpl) == addrs.susdatImpl, "StakedUSDat impl address mismatch");
        console.log("4. StakedUSDat Impl deployed at:", address(stakedUsdatImpl));

        // Step 5: Deploy StakedUSDat Proxy
        bytes memory susdatInitData = abi.encodeCall(
            StakedUSDat.initialize,
            (cfg.admin, cfg.processor, cfg.compliance, cfg.depositFeeRecipient, IERC20(cfg.usdat))
        );
        stakedUsdat = StakedUSDat(
            CREATE3.deployDeterministic(
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stakedUsdatImpl), susdatInitData)),
                SALT_SUSDAT_PROXY
            )
        );
        require(address(stakedUsdat) == addrs.susdatProxy, "StakedUSDat proxy address mismatch");
        console.log("5. StakedUSDat Proxy deployed at:", address(stakedUsdat));
    }

    function _grantRoles(DeployConfig memory cfg) internal {
        // Grant STAKED_USDAT_ROLE on TokenizedSTRC
        tstrc.grantRole(tstrc.STAKED_USDAT_ROLE(), address(stakedUsdat));
        console.log("6. TokenizedSTRC: Granted STAKED_USDAT_ROLE");

        // Grant roles on WithdrawalQueueERC721
        withdrawalQueue.grantRole(withdrawalQueue.STAKED_USDAT_ROLE(), address(stakedUsdat));
        console.log("7. WithdrawalQueueERC721: Granted STAKED_USDAT_ROLE");

        withdrawalQueue.grantRole(withdrawalQueue.PROCESSOR_ROLE(), cfg.processor);
        console.log("8. WithdrawalQueueERC721: Granted PROCESSOR_ROLE");

        withdrawalQueue.grantRole(withdrawalQueue.COMPLIANCE_ROLE(), cfg.compliance);
        console.log("9. WithdrawalQueueERC721: Granted COMPLIANCE_ROLE");
    }

    function _logResults() internal view {
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("TokenizedSTRC:", address(tstrc));
        console.log("WithdrawalQueueERC721:", address(withdrawalQueue));
        console.log("StakedUSDat Implementation:", address(stakedUsdatImpl));
        console.log("StakedUSDat Proxy:", address(stakedUsdat));
    }

    /// @notice Utility function to get predicted addresses without deploying
    function getAddresses() external view returns (DeployedAddresses memory) {
        return _computeAddresses();
    }
}
