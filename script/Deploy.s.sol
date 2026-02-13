// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StrcPriceOracle} from "../src/StrcPriceOracle.sol";
import {WithdrawalQueueERC721} from "../src/WithdrawalQueueERC721.sol";
import {StakedUSDat} from "../src/StakedUSDat.sol";
import {IStrcPriceOracle} from "../src/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);

    function computeCreate3Address(bytes32 salt) external view returns (address);
}

/**
 * @title DeployScript
 * @notice Deploys the sUSDat protocol contracts using CreateX for deterministic addresses
 *
 * CreateX factory ensures the same addresses across all chains regardless of:
 * - Deployer nonce
 * - Contract bytecode
 * - Constructor arguments
 *
 * Deployment order:
 * 1. Compute all addresses using CreateX
 * 2. Deploy StrcPriceOracle
 * 3. Deploy WithdrawalQueueERC721 (impl + proxy)
 * 4. Deploy StakedUSDat (impl + proxy)
 * 5. Grant roles (if deployer == admin)
 *
 * Environment variables required:
 * - USDAT: USDat token address
 * - ORACLE: Price oracle address for STRC (Chainlink-compatible)
 *
 * Environment variables optional (default to deployer):
 * - ADMIN: Admin address
 * - PROCESSOR: Processor address
 * - COMPLIANCE: Compliance address
 * - DEPOSIT_FEE_RECIPIENT: Deposit fee recipient address
 */
contract DeployScript is Script {
    // ============ Salt Configuration ============
    // Update these strings to deploy new versions of contracts
    string constant SALT_STRC_ORACLE = "StrcPriceOracle";
    string constant SALT_WQ_IMPL = "WithdrawalQueueERC721.impl";
    string constant SALT_WQ_PROXY = "WithdrawalQueueERC721.proxy";
    string constant SALT_SUSDAT_IMPL = "StakedUSDat.impl";
    string constant SALT_SUSDAT_PROXY = "StakedUSDat.proxy";

    // ============ Constants ============
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

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
        address strcOracle;
        address wqImpl;
        address wqProxy;
        address susdatImpl;
        address susdatProxy;
    }

    StrcPriceOracle public strcOracle;
    WithdrawalQueueERC721 public withdrawalQueue;
    StakedUSDat public stakedUsdatImpl;
    StakedUSDat public stakedUsdat;

    function run() external {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        DeployConfig memory cfg = _loadConfig(deployer);
        _logConfig(cfg);

        // Compute all addresses first
        DeployedAddresses memory addrs = _computeAddresses(deployer);
        _logPredictedAddresses(addrs);

        vm.startBroadcast(deployer);

        _deploy(cfg, addrs);

        vm.stopBroadcast();

        _logResults();
    }

    function _loadConfig(address deployer) internal view returns (DeployConfig memory cfg) {
        cfg.deployer = deployer;
        cfg.admin = vm.envOr("ADMIN", deployer);
        cfg.processor = vm.envOr("PROCESSOR", deployer);
        cfg.compliance = vm.envOr("COMPLIANCE", deployer);
        cfg.depositFeeRecipient = vm.envOr("DEPOSIT_FEE_RECIPIENT", deployer);
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

    function _computeAddresses(address deployer) internal view returns (DeployedAddresses memory addrs) {
        addrs.strcOracle = _getCreate3Address(deployer, _computeSalt(deployer, SALT_STRC_ORACLE));
        addrs.wqImpl = _getCreate3Address(deployer, _computeSalt(deployer, SALT_WQ_IMPL));
        addrs.wqProxy = _getCreate3Address(deployer, _computeSalt(deployer, SALT_WQ_PROXY));
        addrs.susdatImpl = _getCreate3Address(deployer, _computeSalt(deployer, SALT_SUSDAT_IMPL));
        addrs.susdatProxy = _getCreate3Address(deployer, _computeSalt(deployer, SALT_SUSDAT_PROXY));
    }

    function _logPredictedAddresses(DeployedAddresses memory addrs) internal pure {
        console.log("=== Predicted Addresses (CreateX) ===");
        console.log("StrcPriceOracle:", addrs.strcOracle);
        console.log("WithdrawalQueue Impl:", addrs.wqImpl);
        console.log("WithdrawalQueue Proxy:", addrs.wqProxy);
        console.log("StakedUSDat Impl:", addrs.susdatImpl);
        console.log("StakedUSDat Proxy:", addrs.susdatProxy);
        console.log("");
    }

    function _deploy(DeployConfig memory cfg, DeployedAddresses memory addrs) internal {
        // Step 1: Deploy StrcPriceOracle
        strcOracle = StrcPriceOracle(
            CREATEX.deployCreate3(
                _computeSalt(cfg.deployer, SALT_STRC_ORACLE),
                abi.encodePacked(type(StrcPriceOracle).creationCode, abi.encode(cfg.admin, cfg.oracle))
            )
        );
        require(address(strcOracle) == addrs.strcOracle, "StrcPriceOracle address mismatch");
        console.log("1. StrcPriceOracle deployed at:", address(strcOracle));

        // Step 2: Deploy WithdrawalQueueERC721 Implementation
        WithdrawalQueueERC721 wqImpl = WithdrawalQueueERC721(
            CREATEX.deployCreate3(
                _computeSalt(cfg.deployer, SALT_WQ_IMPL),
                abi.encodePacked(type(WithdrawalQueueERC721).creationCode, abi.encode(cfg.usdat, addrs.susdatProxy))
            )
        );
        require(address(wqImpl) == addrs.wqImpl, "WQ impl address mismatch");
        console.log("2. WithdrawalQueueERC721 Impl deployed at:", address(wqImpl));

        // Step 3: Deploy WithdrawalQueueERC721 Proxy
        bytes memory wqInitData = abi.encodeCall(
            WithdrawalQueueERC721.initialize, (cfg.admin, addrs.susdatProxy, cfg.processor, cfg.compliance)
        );
        withdrawalQueue = WithdrawalQueueERC721(
            CREATEX.deployCreate3(
                _computeSalt(cfg.deployer, SALT_WQ_PROXY),
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(wqImpl), wqInitData))
            )
        );
        require(address(withdrawalQueue) == addrs.wqProxy, "WQ proxy address mismatch");
        console.log("3. WithdrawalQueueERC721 Proxy deployed at:", address(withdrawalQueue));

        // Step 4: Deploy StakedUSDat Implementation
        stakedUsdatImpl = StakedUSDat(
            CREATEX.deployCreate3(
                _computeSalt(cfg.deployer, SALT_SUSDAT_IMPL),
                abi.encodePacked(
                    type(StakedUSDat).creationCode,
                    abi.encode(IStrcPriceOracle(address(strcOracle)), IWithdrawalQueueERC721(address(withdrawalQueue)))
                )
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
            CREATEX.deployCreate3(
                _computeSalt(cfg.deployer, SALT_SUSDAT_PROXY),
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stakedUsdatImpl), susdatInitData))
            )
        );
        require(address(stakedUsdat) == addrs.susdatProxy, "StakedUSDat proxy address mismatch");
        console.log("5. StakedUSDat Proxy deployed at:", address(stakedUsdat));
    }

    function _logResults() internal view {
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("StrcPriceOracle:", address(strcOracle));
        console.log("WithdrawalQueueERC721:", address(withdrawalQueue));
        console.log("StakedUSDat Implementation:", address(stakedUsdatImpl));
        console.log("StakedUSDat Proxy:", address(stakedUsdat));
    }

    // ============ CreateX Helper Functions ============

    function _computeSalt(address deployer, string memory contractName) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0), bytes11(keccak256(bytes(contractName)))));
    }

    function _computeGuardedSalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return _efficientHash(bytes32(uint256(uint160(deployer))), salt);
    }

    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }

    function _getCreate3Address(address deployer, bytes32 salt) internal view returns (address) {
        return CREATEX.computeCreate3Address(_computeGuardedSalt(deployer, salt));
    }

    /// @notice Utility function to get predicted addresses without deploying
    function getAddresses() external view returns (DeployedAddresses memory) {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        return _computeAddresses(deployer);
    }
}
