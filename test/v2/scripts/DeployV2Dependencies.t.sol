// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DependenciesConfig} from "../../../script/v2/configs/DependenciesConfig.sol";
import {
    DeployV2Dependencies,
    ILiveStakedUSDat,
    ILiveWithdrawalQueue
} from "../../../script/v2/DeployV2Dependencies.s.sol";
import {IPriceOracle} from "../../../src/v2/interfaces/oracles/IPriceOracle.sol";
import {ISyntheticSharesOracle} from "../../../src/v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {STRConPriceOracle} from "../../../src/v2/modules/STRCon/STRConPriceOracle.sol";

contract DeployV2DependenciesHarness is DeployV2Dependencies {
    function verifyDeploymentAddresses(Deployments memory deployed) external pure {
        _verifyDeploymentAddresses(deployed);
    }

    function loadExpectedCodeHashes() external pure returns (ExpectedCodeHashes memory) {
        return _loadExpectedCodeHashes();
    }
}

contract DeployV2DependenciesTest is Test, DependenciesConfig {
    DeployV2DependenciesHarness private deployer;

    function setUp() public {
        vm.chainId(EXPECTED_CHAIN_ID);
        deployer = new DeployV2DependenciesHarness();
    }

    function test_configuration_UsesSharedConstants() public view {
        assertEq(deployer.EXPECTED_CHAIN_ID(), EXPECTED_CHAIN_ID);
        assertEq(deployer.USDAT(), USDAT);
        assertEq(deployer.STAKED_USDAT_PROXY(), STAKED_USDAT_PROXY);
        assertEq(deployer.WITHDRAWAL_QUEUE_PROXY(), WITHDRAWAL_QUEUE_PROXY);
        assertEq(deployer.LEGACY_STRC_ORACLE(), LEGACY_STRC_ORACLE);
        assertEq(deployer.STRCON(), STRCON);
        assertEq(deployer.SYNTHETIC_SHARES_ORACLE(), SYNTHETIC_SHARES_ORACLE);
        assertEq(deployer.PRIMARY_FEED(), PRIMARY_FEED);
        assertEq(deployer.REFERENCE_FEED(), REFERENCE_FEED);
        assertEq(deployer.V2_ORACLE_INITIAL_DEVIATION_BPS(), V2_ORACLE_INITIAL_DEVIATION_BPS);
        assertEq(deployer.CREATE2_DEPLOYER(), CREATE2_DEPLOYER);
        assertEq(deployer.TRADE_LOGIC_SALT(), TRADE_LOGIC_SALT);
    }

    function test_loadExpectedCodeHashes_UsesSharedConstants() public view {
        DeployV2Dependencies.ExpectedCodeHashes memory expected = deployer.loadExpectedCodeHashes();
        assertEq(expected.tradeExecutionLogic, V2_EXPECTED_TRADE_EXECUTION_LOGIC_CODEHASH);
        assertEq(expected.strconPriceOracle, V2_EXPECTED_STRCON_PRICE_ORACLE_CODEHASH);
        assertEq(expected.strcMirrorModule, V2_EXPECTED_STRC_MIRROR_MODULE_CODEHASH);
        assertEq(expected.strconModule, V2_EXPECTED_STRCON_MODULE_CODEHASH);
        assertEq(expected.executionPolicy, V2_EXPECTED_EXECUTION_POLICY_CODEHASH);
        assertEq(expected.withdrawalQueueImplementation, V2_EXPECTED_WITHDRAWAL_QUEUE_IMPLEMENTATION_CODEHASH);
        assertEq(expected.stakedUsdatImplementation, V2_EXPECTED_STAKED_USDAT_IMPLEMENTATION_CODEHASH);
    }

    function test_verifyDeploymentAddresses_AcceptsReviewedPlan() public view {
        deployer.verifyDeploymentAddresses(_expectedDeployments());
    }

    function test_verifyDeploymentAddresses_RejectsWrongTradeExecutionLogic() public {
        DeployV2Dependencies.Deployments memory deployed = _expectedDeployments();
        deployed.tradeExecutionLogic = address(0xBAD);
        _expectAddressMismatch(deployed, "STRConTradeExecutionLogic", EXPECTED_TRADE_EXECUTION_LOGIC);
    }

    function test_verifyDeploymentAddresses_RejectsWrongPriceOracle() public {
        DeployV2Dependencies.Deployments memory deployed = _expectedDeployments();
        deployed.strconPriceOracle = address(0xBAD);
        _expectAddressMismatch(deployed, "STRConPriceOracle", EXPECTED_STRCON_PRICE_ORACLE);
    }

    function test_verifyDeploymentAddresses_RejectsWrongMirrorModule() public {
        DeployV2Dependencies.Deployments memory deployed = _expectedDeployments();
        deployed.strcMirrorModule = address(0xBAD);
        _expectAddressMismatch(deployed, "STRCMirrorModule", EXPECTED_STRC_MIRROR_MODULE);
    }

    function test_verifyDeploymentAddresses_RejectsWrongSTRConModule() public {
        DeployV2Dependencies.Deployments memory deployed = _expectedDeployments();
        deployed.strconModule = address(0xBAD);
        _expectAddressMismatch(deployed, "STRConModule", EXPECTED_STRCON_MODULE);
    }

    function test_verifyDeploymentAddresses_RejectsWrongExecutionPolicy() public {
        DeployV2Dependencies.Deployments memory deployed = _expectedDeployments();
        deployed.executionPolicy = address(0xBAD);
        _expectAddressMismatch(deployed, "STRConExecutionPolicy", EXPECTED_EXECUTION_POLICY);
    }

    function test_verifyDeploymentAddresses_RejectsWrongQueueImplementation() public {
        DeployV2Dependencies.Deployments memory deployed = _expectedDeployments();
        deployed.withdrawalQueueImplementation = address(0xBAD);
        _expectAddressMismatch(
            deployed, "WithdrawalQueueERC721 implementation", EXPECTED_WITHDRAWAL_QUEUE_IMPLEMENTATION
        );
    }

    function test_verifyDeploymentAddresses_RejectsWrongVaultImplementation() public {
        DeployV2Dependencies.Deployments memory deployed = _expectedDeployments();
        deployed.stakedUsdatImplementation = address(0xBAD);
        _expectAddressMismatch(deployed, "StakedUSDat implementation", EXPECTED_STAKED_USDAT_IMPLEMENTATION);
    }

    function test_run_RevertsOnWrongChain() public {
        vm.chainId(2);
        vm.expectRevert(abi.encodeWithSelector(DeployV2Dependencies.WrongChain.selector, uint256(2)));
        deployer.run();
    }

    function test_run_RejectsUnplannedDeploymentAddressesBeforeCodeHashChecks() public {
        _mockLiveBindings();

        vm.expectPartialRevert(DeployV2Dependencies.DeploymentAddressMismatch.selector);
        deployer.run();
    }

    function test_deployForFork_RevertsOnWrongChain() public {
        vm.chainId(2);
        vm.expectRevert(abi.encodeWithSelector(DeployV2Dependencies.WrongChain.selector, uint256(2)));
        deployer.deployForFork(
            DeployV2Dependencies.OracleConfig({initialDeviationBps: V2_ORACLE_INITIAL_DEVIATION_BPS})
        );
    }

    function test_deployForFork_UsesSharedBindingsAndPreservesOverride() public {
        _mockLiveBindings();
        uint256 firstNonce = vm.getNonce(address(deployer));

        // This path also runs the script's constructor-binding and three-library-link checks.
        DeployV2Dependencies.Deployments memory deployed =
            deployer.deployForFork(DeployV2Dependencies.OracleConfig({initialDeviationBps: 250}));

        assertEq(deployed.strconPriceOracle, vm.computeCreateAddress(address(deployer), firstNonce));
        assertEq(deployed.strcMirrorModule, vm.computeCreateAddress(address(deployer), firstNonce + 1));
        assertEq(deployed.strconModule, vm.computeCreateAddress(address(deployer), firstNonce + 2));
        assertEq(deployed.executionPolicy, vm.computeCreateAddress(address(deployer), firstNonce + 3));
        assertEq(deployed.withdrawalQueueImplementation, vm.computeCreateAddress(address(deployer), firstNonce + 4));
        assertEq(deployed.stakedUsdatImplementation, vm.computeCreateAddress(address(deployer), firstNonce + 5));
        assertEq(vm.getNonce(address(deployer)), firstNonce + 6);
        assertGt(deployed.tradeExecutionLogic.code.length, 0);

        STRConPriceOracle oracle = STRConPriceOracle(deployed.strconPriceOracle);
        assertEq(oracle.deviationBps(), 250);
        assertEq(oracle.getPrice(), 100e8);
        assertEq(oracle.VAULT(), STAKED_USDAT_PROXY);
        assertEq(address(oracle.primaryFeed()), PRIMARY_FEED);
        assertEq(address(oracle.referenceFeed()), REFERENCE_FEED);
    }

    function _expectedDeployments() private pure returns (DeployV2Dependencies.Deployments memory) {
        return DeployV2Dependencies.Deployments({
            tradeExecutionLogic: EXPECTED_TRADE_EXECUTION_LOGIC,
            strconPriceOracle: EXPECTED_STRCON_PRICE_ORACLE,
            strcMirrorModule: EXPECTED_STRC_MIRROR_MODULE,
            strconModule: EXPECTED_STRCON_MODULE,
            executionPolicy: EXPECTED_EXECUTION_POLICY,
            withdrawalQueueImplementation: EXPECTED_WITHDRAWAL_QUEUE_IMPLEMENTATION,
            stakedUsdatImplementation: EXPECTED_STAKED_USDAT_IMPLEMENTATION
        });
    }

    function _expectAddressMismatch(
        DeployV2Dependencies.Deployments memory deployed,
        string memory contractName,
        address expected
    ) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployV2Dependencies.DeploymentAddressMismatch.selector, contractName, expected, address(0xBAD)
            )
        );
        deployer.verifyDeploymentAddresses(deployed);
    }

    function _mockLiveBindings() private {
        vm.warp(1_800_000_000);
        address[9] memory existingContracts = [
            CREATE2_DEPLOYER,
            USDAT,
            STAKED_USDAT_PROXY,
            WITHDRAWAL_QUEUE_PROXY,
            STRCON,
            SYNTHETIC_SHARES_ORACLE,
            PRIMARY_FEED,
            REFERENCE_FEED,
            LEGACY_STRC_ORACLE
        ];
        for (uint256 i; i < existingContracts.length; ++i) {
            vm.etch(existingContracts[i], hex"00");
        }

        vm.mockCall(STAKED_USDAT_PROXY, abi.encodeCall(ILiveStakedUSDat.asset, ()), abi.encode(USDAT));
        vm.mockCall(
            STAKED_USDAT_PROXY,
            abi.encodeCall(ILiveStakedUSDat.getWithdrawalQueue, ()),
            abi.encode(WITHDRAWAL_QUEUE_PROXY)
        );
        vm.mockCall(
            STAKED_USDAT_PROXY, abi.encodeCall(ILiveStakedUSDat.getStrcOracle, ()), abi.encode(LEGACY_STRC_ORACLE)
        );
        vm.mockCall(WITHDRAWAL_QUEUE_PROXY, abi.encodeCall(ILiveWithdrawalQueue.USDAT, ()), abi.encode(USDAT));
        vm.mockCall(
            WITHDRAWAL_QUEUE_PROXY,
            abi.encodeCall(ILiveWithdrawalQueue.STAKED_USDAT, ()),
            abi.encode(STAKED_USDAT_PROXY)
        );
        vm.mockCall(
            SYNTHETIC_SHARES_ORACLE,
            abi.encodeCall(ISyntheticSharesOracle.getSValue, (STRCON)),
            abi.encode(uint256(1e18), false)
        );
        _mockPriceFeed(PRIMARY_FEED);
        _mockPriceFeed(REFERENCE_FEED);
    }

    function _mockPriceFeed(address feed) private {
        vm.mockCall(feed, abi.encodeCall(IPriceOracle.decimals, ()), abi.encode(uint8(8)));
        vm.mockCall(
            feed,
            abi.encodeCall(IPriceOracle.latestRoundData, ()),
            abi.encode(uint80(1), int256(100e8), block.timestamp, block.timestamp, uint80(1))
        );
    }
}
