// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {DeployV3Dependencies} from "../../../script/v3/DeployV3Dependencies.s.sol";
import {ISyntheticSharesOracle} from "../../../src/v2/interfaces/oracles/ISyntheticSharesOracle.sol";

contract V3DependencyCode {}

contract V3DependencyOracle {
    function getSValue(address) external pure returns (uint256, bool) {
        return (1e18, false);
    }
}

contract DeployV3DependenciesTest is Test {
    DeployV3Dependencies private deployer;
    DeployV3Dependencies.DeploymentInput private input;

    function setUp() public {
        deployer = new DeployV3Dependencies();
        input = DeployV3Dependencies.DeploymentInput({
            vault: address(new V3DependencyCode()),
            withdrawalQueue: address(new V3DependencyCode()),
            strcon: address(new V3DependencyCode()),
            sharesOracle: ISyntheticSharesOracle(address(new V3DependencyOracle())),
            configManager: makeAddr("configManager")
        });
    }

    // ============ Deployment ============

    function test_deploy_UsesExactBindingsAndLeavesModuleInactive() public {
        DeployV3Dependencies.Deployments memory deployed = deployer.deploy(input);
        assertEq(deployed.adapter.asset(), input.strcon);
        assertEq(address(deployed.adapter.SHARES_ORACLE()), address(input.sharesOracle));
        assertEq(deployed.module.VAULT(), input.vault);
        assertEq(deployed.module.configManager(), input.configManager);
        assertFalse(deployed.module.isActive());
        assertEq(deployed.implementation.getWithdrawalQueue(), input.withdrawalQueue);

        DeployV3Dependencies.ExpectedCodeHashes memory expected = DeployV3Dependencies.ExpectedCodeHashes({
            adapter: address(deployed.adapter).codehash,
            module: address(deployed.module).codehash,
            implementation: address(deployed.implementation).codehash
        });
        deployer.verify(deployed, input, expected);
    }

    // ============ Fail-Closed Validation ============

    function test_validateInput_RejectsEveryZeroAddress() public {
        DeployV3Dependencies.DeploymentInput memory valid = input;
        input.vault = address(0);
        _expectInvalid("vault");
        input = valid;
        input.withdrawalQueue = address(0);
        _expectInvalid("withdrawalQueue");
        input = valid;
        input.strcon = address(0);
        _expectInvalid("strcon");
        input = valid;
        input.sharesOracle = ISyntheticSharesOracle(address(0));
        _expectInvalid("sharesOracle");
        input = valid;
        input.configManager = address(0);
        _expectInvalid("configManager");
    }

    function test_validateInput_RejectsEveryMissingCodeBinding() public {
        DeployV3Dependencies.DeploymentInput memory valid = input;
        input.vault = makeAddr("noCode");
        _expectInvalid("vault code");
        input = valid;
        input.withdrawalQueue = makeAddr("noQueueCode");
        _expectInvalid("withdrawalQueue code");
        input = valid;
        input.strcon = makeAddr("noAssetCode");
        _expectInvalid("strcon code");
        input = valid;
        input.sharesOracle = ISyntheticSharesOracle(makeAddr("noOracleCode"));
        _expectInvalid("sharesOracle code");
    }

    function test_verify_RejectsZeroAdapterCodeHash() public {
        DeployV3Dependencies.Deployments memory deployed = deployer.deploy(input);
        DeployV3Dependencies.ExpectedCodeHashes memory expected = _expectedHashes(deployed);
        expected.adapter = bytes32(0);
        vm.expectRevert(
            abi.encodeWithSelector(DeployV3Dependencies.InvalidConfiguration.selector, "expected code hash")
        );
        deployer.verify(deployed, input, expected);
    }

    function test_verify_RejectsZeroModuleCodeHash() public {
        DeployV3Dependencies.Deployments memory deployed = deployer.deploy(input);
        DeployV3Dependencies.ExpectedCodeHashes memory expected = _expectedHashes(deployed);
        expected.module = bytes32(0);
        vm.expectRevert(
            abi.encodeWithSelector(DeployV3Dependencies.InvalidConfiguration.selector, "expected code hash")
        );
        deployer.verify(deployed, input, expected);
    }

    function test_verify_RejectsZeroImplementationCodeHash() public {
        DeployV3Dependencies.Deployments memory deployed = deployer.deploy(input);
        DeployV3Dependencies.ExpectedCodeHashes memory expected = _expectedHashes(deployed);
        expected.implementation = bytes32(0);
        vm.expectRevert(
            abi.encodeWithSelector(DeployV3Dependencies.InvalidConfiguration.selector, "expected code hash")
        );
        deployer.verify(deployed, input, expected);
    }

    function test_verify_RejectsEachMismatchedCodeHash() public {
        DeployV3Dependencies.Deployments memory deployed = deployer.deploy(input);
        DeployV3Dependencies.ExpectedCodeHashes memory expected = _expectedHashes(deployed);

        expected.adapter = bytes32(uint256(1));
        _expectHashMismatch(
            address(deployed.adapter), expected.adapter, address(deployed.adapter).codehash, deployed, expected
        );
        expected = _expectedHashes(deployed);
        expected.module = bytes32(uint256(2));
        _expectHashMismatch(
            address(deployed.module), expected.module, address(deployed.module).codehash, deployed, expected
        );
        expected = _expectedHashes(deployed);
        expected.implementation = bytes32(uint256(3));
        _expectHashMismatch(
            address(deployed.implementation),
            expected.implementation,
            address(deployed.implementation).codehash,
            deployed,
            expected
        );
    }

    function test_runRejectsWrongChainBeforeReadingManifest() public {
        vm.chainId(31337);
        vm.expectRevert(abi.encodeWithSelector(DeployV3Dependencies.WrongChain.selector, 31337));
        deployer.run();
    }

    // ============ Helpers ============

    function _expectInvalid(string memory field) private {
        vm.expectRevert(abi.encodeWithSelector(DeployV3Dependencies.InvalidConfiguration.selector, field));
        deployer.validateInput(input);
    }

    function _expectedHashes(DeployV3Dependencies.Deployments memory deployed)
        private
        view
        returns (DeployV3Dependencies.ExpectedCodeHashes memory)
    {
        return DeployV3Dependencies.ExpectedCodeHashes({
            adapter: address(deployed.adapter).codehash,
            module: address(deployed.module).codehash,
            implementation: address(deployed.implementation).codehash
        });
    }

    function _expectHashMismatch(
        address target,
        bytes32 expectedHash,
        bytes32 actualHash,
        DeployV3Dependencies.Deployments memory deployed,
        DeployV3Dependencies.ExpectedCodeHashes memory expected
    ) private {
        vm.expectRevert(
            abi.encodeWithSelector(DeployV3Dependencies.CodeHashMismatch.selector, target, expectedHash, actualHash)
        );
        deployer.verify(deployed, input, expected);
    }
}
