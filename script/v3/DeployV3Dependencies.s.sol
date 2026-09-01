// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console} from "forge-std/Script.sol";

import {IWithdrawalQueueERC721} from "../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {ISyntheticSharesOracle} from "../../src/v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {STRConEligibleIncomeAdapter} from "../../src/v3/STRConEligibleIncomeAdapter.sol";
import {StakedUSDatEligibleIncomeModule} from "../../src/v3/StakedUSDatEligibleIncomeModule.sol";
import {StakedUSDat} from "../../src/v3/StakedUSDat.sol";

interface ILiveV3VaultBinding {
    function getWithdrawalQueue() external view returns (address);
}

interface ILiveV3QueueBinding {
    function STAKED_USDAT() external view returns (address);
}

/**
 * @notice Deploys the V3 adapter, vault-bound income module, and implementation.
 * @dev This script never upgrades the proxy or activates eligible-income accounting.
 */
contract DeployV3Dependencies is Script {
    // =========================================================================
    // Configuration
    // =========================================================================

    error CodeHashMismatch(address target, bytes32 expected, bytes32 actual);
    error InvalidConfiguration(string field);
    error WrongChain(uint256 chainId);

    uint256 public constant EXPECTED_CHAIN_ID = 1;
    address public constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;
    address public constant WITHDRAWAL_QUEUE_PROXY = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;
    address public constant STRCON = 0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c;
    address public constant SYNTHETIC_SHARES_ORACLE = 0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6;

    // =========================================================================
    // Deployment Types
    // =========================================================================

    struct DeploymentInput {
        address vault;
        address withdrawalQueue;
        address strcon;
        ISyntheticSharesOracle sharesOracle;
        address configManager;
    }

    struct ExpectedCodeHashes {
        bytes32 adapter;
        bytes32 module;
        bytes32 implementation;
    }

    struct Deployments {
        STRConEligibleIncomeAdapter adapter;
        StakedUSDatEligibleIncomeModule module;
        StakedUSDat implementation;
    }

    // =========================================================================
    // Production Entry Point
    // =========================================================================

    function run() external returns (Deployments memory deployed) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        DeploymentInput memory input = DeploymentInput({
            vault: STAKED_USDAT_PROXY,
            withdrawalQueue: WITHDRAWAL_QUEUE_PROXY,
            strcon: STRCON,
            sharesOracle: ISyntheticSharesOracle(SYNTHETIC_SHARES_ORACLE),
            configManager: vm.envAddress("V3_CONFIG_MANAGER")
        });
        ExpectedCodeHashes memory expected = ExpectedCodeHashes({
            adapter: vm.envBytes32("V3_EXPECTED_ADAPTER_CODEHASH"),
            module: vm.envBytes32("V3_EXPECTED_MODULE_CODEHASH"),
            implementation: vm.envBytes32("V3_EXPECTED_IMPLEMENTATION_CODEHASH")
        });

        validateInput(input);
        _validateProductionInput(input);
        vm.startBroadcast();
        deployed = deploy(input);
        vm.stopBroadcast();
        verify(deployed, input, expected);
        _logManifest(deployed, input);
    }

    // =========================================================================
    // Deployment and Verification
    // =========================================================================

    function deploy(DeploymentInput memory input) public returns (Deployments memory deployed) {
        validateInput(input);
        deployed.adapter = new STRConEligibleIncomeAdapter(input.strcon, input.sharesOracle);
        deployed.module = new StakedUSDatEligibleIncomeModule(input.vault, input.configManager);
        deployed.implementation = new StakedUSDat(IWithdrawalQueueERC721(input.withdrawalQueue));
    }

    function validateInput(DeploymentInput memory input) public view {
        if (input.vault == address(0)) revert InvalidConfiguration("vault");
        if (input.withdrawalQueue == address(0)) revert InvalidConfiguration("withdrawalQueue");
        if (input.strcon == address(0)) revert InvalidConfiguration("strcon");
        if (address(input.sharesOracle) == address(0)) revert InvalidConfiguration("sharesOracle");
        if (input.configManager == address(0)) revert InvalidConfiguration("configManager");
        if (input.vault.code.length == 0) revert InvalidConfiguration("vault code");
        if (input.withdrawalQueue.code.length == 0) revert InvalidConfiguration("withdrawalQueue code");
        if (input.strcon.code.length == 0) revert InvalidConfiguration("strcon code");
        if (address(input.sharesOracle).code.length == 0) revert InvalidConfiguration("sharesOracle code");
    }

    function verify(Deployments memory deployed, DeploymentInput memory input, ExpectedCodeHashes memory expected)
        public
        view
    {
        if (deployed.adapter.asset() != input.strcon) revert InvalidConfiguration("adapter asset");
        if (address(deployed.adapter.SHARES_ORACLE()) != address(input.sharesOracle)) {
            revert InvalidConfiguration("adapter oracle");
        }
        if (deployed.module.VAULT() != input.vault) revert InvalidConfiguration("module vault");
        if (deployed.module.configManager() != input.configManager) {
            revert InvalidConfiguration("module configManager");
        }
        if (deployed.module.isActive()) revert InvalidConfiguration("module activated");
        if (deployed.implementation.getWithdrawalQueue() != input.withdrawalQueue) {
            revert InvalidConfiguration("implementation queue");
        }
        _requireCodeHash(address(deployed.adapter), expected.adapter);
        _requireCodeHash(address(deployed.module), expected.module);
        _requireCodeHash(address(deployed.implementation), expected.implementation);
    }

    // =========================================================================
    // Production Validation
    // =========================================================================

    function _validateProductionInput(DeploymentInput memory input) private view {
        if (input.vault != STAKED_USDAT_PROXY) revert InvalidConfiguration("production vault");
        if (input.withdrawalQueue != WITHDRAWAL_QUEUE_PROXY) {
            revert InvalidConfiguration("production withdrawalQueue");
        }
        if (input.strcon != STRCON) revert InvalidConfiguration("production strcon");
        if (address(input.sharesOracle) != SYNTHETIC_SHARES_ORACLE) {
            revert InvalidConfiguration("production sharesOracle");
        }
        if (ILiveV3VaultBinding(input.vault).getWithdrawalQueue() != input.withdrawalQueue) {
            revert InvalidConfiguration("live vault queue");
        }
        if (ILiveV3QueueBinding(input.withdrawalQueue).STAKED_USDAT() != input.vault) {
            revert InvalidConfiguration("live queue vault");
        }
    }

    function _requireCodeHash(address target, bytes32 expected) private view {
        if (expected == bytes32(0)) revert InvalidConfiguration("expected code hash");
        bytes32 actual = target.codehash;
        if (actual != expected) revert CodeHashMismatch(target, expected, actual);
    }

    // =========================================================================
    // Logging
    // =========================================================================

    function _logManifest(Deployments memory deployed, DeploymentInput memory input) private view {
        console.log("V3 adapter", address(deployed.adapter));
        console.log("V3 module", address(deployed.module));
        console.log("V3 implementation", address(deployed.implementation));
        console.log("V3 config manager", input.configManager);
        console.logBytes32(address(deployed.adapter).codehash);
        console.logBytes32(address(deployed.module).codehash);
        console.logBytes32(address(deployed.implementation).codehash);
    }
}
