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
 * @notice Deploys the sUSDat protocol contracts
 *
 * Uses CreateX for deterministic proxy addresses (same across all chains).
 * Implementation contracts use standard CREATE (addresses vary by chain).
 *
 * Deployment order:
 * 1. Compute proxy addresses using CreateX
 * 2. Deploy StrcPriceOracle (CreateX - deterministic)
 * 3. Deploy WithdrawalQueueERC721 impl (CREATE) + proxy (CreateX)
 * 4. Deploy StakedUSDat impl (CREATE) + proxy (CreateX)
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
    string constant SALT_STRC_ORACLE = "StrcPriceOracle.v2";
    string constant SALT_WQ_PROXY = "WithdrawalQueueERC721.proxy.v2";
    string constant SALT_SUSDAT_PROXY = "StakedUSDat.proxy.v2";

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
        address wqProxy;
        address susdatProxy;
    }

    StrcPriceOracle public strcOracle;
    WithdrawalQueueERC721 public wqImpl;
    WithdrawalQueueERC721 public withdrawalQueue;
    StakedUSDat public stakedUsdatImpl;
    StakedUSDat public stakedUsdat;

    function run() external {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        DeployConfig memory cfg = _loadConfig(deployer);
        _logConfig(cfg);

        // Compute deterministic addresses (proxies + oracle only)
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
        addrs.wqProxy = _getCreate3Address(deployer, _computeSalt(deployer, SALT_WQ_PROXY));
        addrs.susdatProxy = _getCreate3Address(deployer, _computeSalt(deployer, SALT_SUSDAT_PROXY));
    }

    function _logPredictedAddresses(DeployedAddresses memory addrs) internal pure {
        console.log("=== Predicted Addresses (CreateX) ===");
        console.log("StrcPriceOracle:", addrs.strcOracle);
        console.log("WithdrawalQueue Proxy:", addrs.wqProxy);
        console.log("StakedUSDat Proxy:", addrs.susdatProxy);
        console.log("");
    }

    function _deploy(DeployConfig memory cfg, DeployedAddresses memory addrs) internal {
        // Step 1: Deploy StrcPriceOracle (CreateX - deterministic)
        strcOracle = StrcPriceOracle(
            CREATEX.deployCreate3(
                _computeSalt(cfg.deployer, SALT_STRC_ORACLE),
                abi.encodePacked(type(StrcPriceOracle).creationCode, abi.encode(cfg.admin, cfg.oracle))
            )
        );
        require(address(strcOracle) == addrs.strcOracle, "StrcPriceOracle address mismatch");
        console.log("1. StrcPriceOracle deployed at:", address(strcOracle));

        // Step 2: Deploy WithdrawalQueueERC721 Implementation (standard CREATE)
        wqImpl = new WithdrawalQueueERC721(cfg.usdat, addrs.susdatProxy);
        console.log("2. WithdrawalQueueERC721 Impl deployed at:", address(wqImpl));

        // Step 3: Deploy WithdrawalQueueERC721 Proxy (CreateX - deterministic)
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

        // Step 4: Deploy StakedUSDat Implementation (standard CREATE)
        stakedUsdatImpl =
            new StakedUSDat(IStrcPriceOracle(address(strcOracle)), IWithdrawalQueueERC721(address(withdrawalQueue)));
        console.log("4. StakedUSDat Impl deployed at:", address(stakedUsdatImpl));

        // Step 5: Deploy StakedUSDat Proxy (CreateX - deterministic)
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
        console.log("WithdrawalQueueERC721 Impl:", address(wqImpl));
        console.log("WithdrawalQueueERC721 Proxy:", address(withdrawalQueue));
        console.log("StakedUSDat Impl:", address(stakedUsdatImpl));
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
