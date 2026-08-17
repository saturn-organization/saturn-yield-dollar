// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {STRConExecutionPolicy} from "../../src/v2/STRConExecutionPolicy.sol";
import {StakedUSDat} from "../../src/v2/StakedUSDat.sol";
import {WithdrawalQueueERC721} from "../../src/v2/WithdrawalQueueERC721.sol";
import {ISTRConExecutionPolicy} from "../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IWithdrawalQueueERC721} from "../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {ISTRConModule} from "../../src/v2/interfaces/modules/ISTRConModule.sol";
import {IPriceOracle} from "../../src/v2/interfaces/oracles/IPriceOracle.sol";
import {ISTRConPriceOracle} from "../../src/v2/interfaces/oracles/ISTRConPriceOracle.sol";
import {IStrcPriceOracle} from "../../src/v2/interfaces/oracles/IStrcPriceOracle.sol";
import {ISyntheticSharesOracle} from "../../src/v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {STRCMirrorModule} from "../../src/v2/modules/MirrorSTRC/STRCMirrorModule.sol";
import {STRConModule} from "../../src/v2/modules/STRCon/STRConModule.sol";
import {STRConPriceOracle} from "../../src/v2/modules/STRCon/STRConPriceOracle.sol";

interface ILiveStakedUSDat {
    function asset() external view returns (address);
    function getStrcOracle() external view returns (address);
    function getWithdrawalQueue() external view returns (address);
}

interface ILiveWithdrawalQueue {
    function USDAT() external view returns (address);
    function STAKED_USDAT() external view returns (address);
}

/**
 * @title DeployV2Dependencies
 * @notice Deploys and verifies the contracts needed before constructing the atomic v2 upgrade batch.
 * @dev This script does not upgrade either proxy, initialize v2, or execute migration.
 *
 * Required environment variables:
 * - V2_ORACLE_INITIAL_DEVIATION_BPS
 * - V2_EXPECTED_TRADE_EXECUTION_LOGIC_CODEHASH
 * - V2_EXPECTED_STRCON_PRICE_ORACLE_CODEHASH
 * - V2_EXPECTED_STRC_MIRROR_MODULE_CODEHASH
 * - V2_EXPECTED_STRCON_MODULE_CODEHASH
 * - V2_EXPECTED_EXECUTION_POLICY_CODEHASH
 * - V2_EXPECTED_WITHDRAWAL_QUEUE_IMPLEMENTATION_CODEHASH
 * - V2_EXPECTED_STAKED_USDAT_IMPLEMENTATION_CODEHASH
 *
 * Forge detects the StakedUSDat link reference and prepends the deterministic
 * STRConTradeExecutionLogic CREATE2 deployment to the broadcast.
 *
 * Usage:
 *   forge script script/v2/DeployV2Dependencies.s.sol:DeployV2Dependencies \
 *     --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
 */
contract DeployV2Dependencies is Script {
    error CodeHashMismatch(address target, bytes32 expected, bytes32 actual);
    error InvalidBinding(string binding);
    error InvalidLibraryLink(address libraryAddress, uint256 references);
    error MissingCode(address target);
    error WrongChain(uint256 actualChainId);

    uint256 private constant MAINNET_CHAIN_ID = 1;

    address private constant USDAT = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address private constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;
    address private constant WITHDRAWAL_QUEUE_PROXY = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;
    address private constant LEGACY_STRC_ORACLE = 0x5f7eCD0D045c393da6cb6c933c671AC305A871BF;

    address private constant STRCON = 0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c;
    address private constant SYNTHETIC_SHARES_ORACLE = 0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6;
    address private constant PRIMARY_FEED = 0xC353ac4b425f818Ad87E228bf816E15c2173AC07;
    address private constant REFERENCE_FEED = 0x67d4Ae9f265270aE123c08D2657536771D19cD91;

    address private constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 private constant TRADE_LOGIC_SALT = bytes32(0);
    string private constant TRADE_LOGIC_ARTIFACT =
        "src/v2/libraries/STRConTradeExecutionLogic.sol:STRConTradeExecutionLogic";

    struct OracleConfig {
        uint256 initialDeviationBps;
    }

    struct ExpectedCodeHashes {
        bytes32 tradeExecutionLogic;
        bytes32 strconPriceOracle;
        bytes32 strcMirrorModule;
        bytes32 strconModule;
        bytes32 executionPolicy;
        bytes32 withdrawalQueueImplementation;
        bytes32 stakedUsdatImplementation;
    }

    struct Deployments {
        address tradeExecutionLogic;
        address strconPriceOracle;
        address strcMirrorModule;
        address strconModule;
        address executionPolicy;
        address withdrawalQueueImplementation;
        address stakedUsdatImplementation;
    }

    function run() external returns (Deployments memory deployed) {
        require(block.chainid == MAINNET_CHAIN_ID, WrongChain(block.chainid));

        OracleConfig memory oracleConfig =
            OracleConfig({initialDeviationBps: vm.envUint("V2_ORACLE_INITIAL_DEVIATION_BPS")});
        ExpectedCodeHashes memory expectedCodeHashes = _loadExpectedCodeHashes();
        address legacyStrcOracle = _validateLiveBindings();

        vm.startBroadcast();
        deployed = _deploy(oracleConfig, legacyStrcOracle, _tradeExecutionLogicAddress());
        vm.stopBroadcast();

        _verifyBindings(deployed, oracleConfig, legacyStrcOracle);
        _logDeploymentManifest(deployed, oracleConfig, legacyStrcOracle);
        _verifyCodeHashes(deployed, expectedCodeHashes);
    }

    /**
     * @notice Runs the production deployment path without broadcast or environment inputs.
     * @dev Used by the pinned mock-fork rehearsal so constructor and dependency changes
     * cannot drift from this script.
     */
    function deployForFork(OracleConfig memory oracleConfig) public returns (Deployments memory deployed) {
        require(block.chainid == MAINNET_CHAIN_ID, WrongChain(block.chainid));
        address legacyStrcOracle = _validateLiveBindings();
        address linkedTradeExecutionLogic = _linkedTradeExecutionLogicAddress();

        _installTradeExecutionLogicForFork(linkedTradeExecutionLogic);
        deployed = _deploy(oracleConfig, legacyStrcOracle, linkedTradeExecutionLogic);
        _verifyBindings(deployed, oracleConfig, legacyStrcOracle);
    }

    function _deploy(OracleConfig memory oracleConfig, address legacyStrcOracle, address tradeExecutionLogic)
        private
        returns (Deployments memory deployed)
    {
        deployed.tradeExecutionLogic = tradeExecutionLogic;
        deployed.strconPriceOracle = address(
            new STRConPriceOracle(
                STAKED_USDAT_PROXY,
                STRCON,
                ISyntheticSharesOracle(SYNTHETIC_SHARES_ORACLE),
                IPriceOracle(PRIMARY_FEED),
                IPriceOracle(REFERENCE_FEED),
                oracleConfig.initialDeviationBps
            )
        );
        deployed.strcMirrorModule =
            address(new STRCMirrorModule(STAKED_USDAT_PROXY, IStrcPriceOracle(legacyStrcOracle)));
        deployed.strconModule =
            address(new STRConModule(STAKED_USDAT_PROXY, STRCON, ISTRConPriceOracle(deployed.strconPriceOracle)));
        deployed.executionPolicy =
            address(new STRConExecutionPolicy(STAKED_USDAT_PROXY, ISTRConModule(deployed.strconModule)));
        deployed.withdrawalQueueImplementation = address(new WithdrawalQueueERC721(USDAT, STAKED_USDAT_PROXY));
        deployed.stakedUsdatImplementation = address(new StakedUSDat(IWithdrawalQueueERC721(WITHDRAWAL_QUEUE_PROXY)));
    }

    /// @dev `forge script` deploys linked libraries automatically. Selecting a fork
    /// removes the test runner's linked-library deployment, so recreate the exact
    /// linked runtime for the fork-only path.
    function _installTradeExecutionLogicForFork(address target) private {
        if (target.code.length != 0) return;

        bytes memory runtimeCode = vm.getDeployedCode(TRADE_LOGIC_ARTIFACT);
        bytes20 encodedTarget = bytes20(target);
        for (uint256 i; i < encodedTarget.length; ++i) {
            runtimeCode[i + 1] = encodedTarget[i];
        }
        vm.etch(target, runtimeCode);
    }

    function _linkedTradeExecutionLogicAddress() private pure returns (address linkedLibrary) {
        bytes memory creationCode = type(StakedUSDat).creationCode;
        for (uint256 i; i + 21 <= creationCode.length; ++i) {
            if (creationCode[i] != bytes1(0x73)) continue;

            bytes20 candidate;
            assembly ("memory-safe") {
                candidate := mload(add(add(creationCode, 0x21), i))
            }

            address candidateAddress = address(candidate);
            if (candidateAddress != address(0) && _countAddressReferences(creationCode, candidateAddress) == 3) {
                return candidateAddress;
            }
        }

        revert InvalidLibraryLink(address(0), 0);
    }

    function _validateLiveBindings() private view returns (address legacyStrcOracle) {
        _requireContract(CREATE2_DEPLOYER);
        _requireContract(USDAT);
        _requireContract(STAKED_USDAT_PROXY);
        _requireContract(WITHDRAWAL_QUEUE_PROXY);
        _requireContract(STRCON);
        _requireContract(SYNTHETIC_SHARES_ORACLE);
        _requireContract(PRIMARY_FEED);
        _requireContract(REFERENCE_FEED);

        ILiveStakedUSDat liveVault = ILiveStakedUSDat(STAKED_USDAT_PROXY);
        require(liveVault.asset() == USDAT, InvalidBinding("live vault asset"));
        require(liveVault.getWithdrawalQueue() == WITHDRAWAL_QUEUE_PROXY, InvalidBinding("live vault withdrawal queue"));

        ILiveWithdrawalQueue liveQueue = ILiveWithdrawalQueue(WITHDRAWAL_QUEUE_PROXY);
        require(liveQueue.USDAT() == USDAT, InvalidBinding("live queue USDat"));
        require(liveQueue.STAKED_USDAT() == STAKED_USDAT_PROXY, InvalidBinding("live queue vault"));

        legacyStrcOracle = liveVault.getStrcOracle();
        require(legacyStrcOracle == LEGACY_STRC_ORACLE, InvalidBinding("legacy STRC oracle"));
        _requireContract(legacyStrcOracle);
    }

    function _verifyBindings(Deployments memory deployed, OracleConfig memory oracleConfig, address legacyStrcOracle)
        private
        view
    {
        _requireContract(deployed.tradeExecutionLogic);
        _requireContract(deployed.strconPriceOracle);
        _requireContract(deployed.strcMirrorModule);
        _requireContract(deployed.strconModule);
        _requireContract(deployed.executionPolicy);
        _requireContract(deployed.withdrawalQueueImplementation);
        _requireContract(deployed.stakedUsdatImplementation);

        STRConPriceOracle priceOracle = STRConPriceOracle(deployed.strconPriceOracle);
        require(priceOracle.VAULT() == STAKED_USDAT_PROXY, InvalidBinding("price oracle vault"));
        require(priceOracle.STRCON() == STRCON, InvalidBinding("price oracle STRCon"));
        require(
            address(priceOracle.syntheticSharesOracle()) == SYNTHETIC_SHARES_ORACLE,
            InvalidBinding("price oracle synthetic shares oracle")
        );
        require(address(priceOracle.primaryFeed()) == PRIMARY_FEED, InvalidBinding("price oracle primary feed"));
        require(address(priceOracle.referenceFeed()) == REFERENCE_FEED, InvalidBinding("price oracle reference feed"));
        require(priceOracle.MAX_DEVIATION_BPS() == 1_000, InvalidBinding("price oracle max deviation"));
        require(
            priceOracle.deviationBps() == oracleConfig.initialDeviationBps,
            InvalidBinding("price oracle initial deviation")
        );
        require(priceOracle.maxApiStaleness() == 26 hours, InvalidBinding("price oracle staleness"));
        require(priceOracle.minPrice() == 20e8, InvalidBinding("price oracle minimum price"));
        require(priceOracle.maxPrice() == 150e8, InvalidBinding("price oracle maximum price"));
        require(priceOracle.decimals() == 8, InvalidBinding("price oracle decimals"));

        STRCMirrorModule mirror = STRCMirrorModule(deployed.strcMirrorModule);
        require(mirror.VAULT() == STAKED_USDAT_PROXY, InvalidBinding("mirror vault"));
        require(address(mirror.ORACLE()) == legacyStrcOracle, InvalidBinding("mirror oracle"));
        require(!mirror.seeded(), InvalidBinding("mirror seeded state"));
        require(!mirror.retired(), InvalidBinding("mirror retired state"));
        require(mirror.balance() == 0, InvalidBinding("mirror balance"));

        STRConModule module = STRConModule(deployed.strconModule);
        require(module.VAULT() == STAKED_USDAT_PROXY, InvalidBinding("STRCon module vault"));
        require(module.ASSET() == STRCON, InvalidBinding("STRCon module asset"));
        require(address(module.oracle()) == deployed.strconPriceOracle, InvalidBinding("STRCon module oracle"));
        require(module.balance() == 0, InvalidBinding("STRCon module balance"));

        STRConExecutionPolicy policy = STRConExecutionPolicy(deployed.executionPolicy);
        require(policy.VAULT() == STAKED_USDAT_PROXY, InvalidBinding("execution policy vault"));
        require(
            address(policy.STRCON_MODULE()) == deployed.strconModule, InvalidBinding("execution policy STRCon module")
        );
        require(policy.executionVehicle() == address(0), InvalidBinding("execution policy vehicle"));
        require(policy.executionToleranceBps() == 0, InvalidBinding("execution policy tolerance"));
        _verifyUninitializedCapacity(ISTRConExecutionPolicy(deployed.executionPolicy));

        WithdrawalQueueERC721 queue = WithdrawalQueueERC721(deployed.withdrawalQueueImplementation);
        require(address(queue.USDAT()) == USDAT, InvalidBinding("queue implementation USDat"));
        require(address(queue.STAKED_USDAT()) == STAKED_USDAT_PROXY, InvalidBinding("queue implementation vault"));

        StakedUSDat vault = StakedUSDat(deployed.stakedUsdatImplementation);
        require(
            vault.getWithdrawalQueue() == WITHDRAWAL_QUEUE_PROXY,
            InvalidBinding("vault implementation withdrawal queue")
        );

        uint256 libraryReferences =
            _countAddressReferences(deployed.stakedUsdatImplementation.code, deployed.tradeExecutionLogic);
        require(libraryReferences == 3, InvalidLibraryLink(deployed.tradeExecutionLogic, libraryReferences));
    }

    function _verifyUninitializedCapacity(ISTRConExecutionPolicy policy) private view {
        (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated) = policy.executionCapacity();
        require(maximum == 0, InvalidBinding("execution policy maximum capacity"));
        require(available == 0, InvalidBinding("execution policy available capacity"));
        require(refillPerDay == 0, InvalidBinding("execution policy refill"));
        require(lastUpdated == 0, InvalidBinding("execution policy last update"));
    }

    function _loadExpectedCodeHashes() private view returns (ExpectedCodeHashes memory expected) {
        expected.tradeExecutionLogic = vm.envBytes32("V2_EXPECTED_TRADE_EXECUTION_LOGIC_CODEHASH");
        expected.strconPriceOracle = vm.envBytes32("V2_EXPECTED_STRCON_PRICE_ORACLE_CODEHASH");
        expected.strcMirrorModule = vm.envBytes32("V2_EXPECTED_STRC_MIRROR_MODULE_CODEHASH");
        expected.strconModule = vm.envBytes32("V2_EXPECTED_STRCON_MODULE_CODEHASH");
        expected.executionPolicy = vm.envBytes32("V2_EXPECTED_EXECUTION_POLICY_CODEHASH");
        expected.withdrawalQueueImplementation = vm.envBytes32("V2_EXPECTED_WITHDRAWAL_QUEUE_IMPLEMENTATION_CODEHASH");
        expected.stakedUsdatImplementation = vm.envBytes32("V2_EXPECTED_STAKED_USDAT_IMPLEMENTATION_CODEHASH");
    }

    function _verifyCodeHashes(Deployments memory deployed, ExpectedCodeHashes memory expected) private view {
        _requireCodeHash(deployed.tradeExecutionLogic, expected.tradeExecutionLogic);
        _requireCodeHash(deployed.strconPriceOracle, expected.strconPriceOracle);
        _requireCodeHash(deployed.strcMirrorModule, expected.strcMirrorModule);
        _requireCodeHash(deployed.strconModule, expected.strconModule);
        _requireCodeHash(deployed.executionPolicy, expected.executionPolicy);
        _requireCodeHash(deployed.withdrawalQueueImplementation, expected.withdrawalQueueImplementation);
        _requireCodeHash(deployed.stakedUsdatImplementation, expected.stakedUsdatImplementation);
    }

    function _tradeExecutionLogicAddress() private view returns (address) {
        bytes memory creationCode = vm.getCode(TRADE_LOGIC_ARTIFACT);
        bytes32 create2Hash =
            keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, TRADE_LOGIC_SALT, keccak256(creationCode)));
        return address(uint160(uint256(create2Hash)));
    }

    function _countAddressReferences(bytes memory runtimeCode, address target)
        private
        pure
        returns (uint256 references)
    {
        if (runtimeCode.length < 20) return 0;

        bytes20 needle = bytes20(target);
        for (uint256 i; i + 20 <= runtimeCode.length; ++i) {
            bytes20 candidate;
            assembly ("memory-safe") {
                candidate := mload(add(add(runtimeCode, 0x20), i))
            }
            if (candidate == needle) ++references;
        }
    }

    function _requireContract(address target) private view {
        require(target.code.length != 0, MissingCode(target));
    }

    function _requireCodeHash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        require(actual == expected, CodeHashMismatch(target, expected, actual));
    }

    function _logDeploymentManifest(
        Deployments memory deployed,
        OracleConfig memory oracleConfig,
        address legacyStrcOracle
    ) private view {
        console.log("=== V2 Dependency Deployment Manifest ===");
        console.log("Legacy STRC oracle:", legacyStrcOracle);
        console.log("Oracle initial deviation bps:", oracleConfig.initialDeviationBps);

        _logDeployment("STRConTradeExecutionLogic", deployed.tradeExecutionLogic);
        _logDeployment("STRConPriceOracle", deployed.strconPriceOracle);
        _logDeployment("STRCMirrorModule", deployed.strcMirrorModule);
        _logDeployment("STRConModule", deployed.strconModule);
        _logDeployment("STRConExecutionPolicy", deployed.executionPolicy);
        _logDeployment("WithdrawalQueueERC721 implementation", deployed.withdrawalQueueImplementation);
        _logDeployment("StakedUSDat implementation", deployed.stakedUsdatImplementation);
    }

    function _logDeployment(string memory name, address target) private view {
        console.log(name, target);
        console.log("Code hash:");
        console.logBytes32(target.codehash);
    }
}
