// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console} from "forge-std/Script.sol";

import {IStakedUSDatEligibleIncomeModule} from "../../src/v3/interfaces/IStakedUSDatEligibleIncomeModule.sol";
import {StakedUSDat} from "../../src/v3/StakedUSDat.sol";
import {TrancheAccountant} from "../../src/v3/TrancheAccountant.sol";

/**
 *  @notice Deploys an immutable V3 instance only from a complete, explicitly approved manifest.
 */
contract DeployTranche is Script {
    // =========================================================================
    // Configuration
    // =========================================================================

    error CodeHashMismatch(address target, bytes32 expected, bytes32 actual);
    error InvalidManifest(string field);
    error WrongChain(uint256 chainId);

    uint256 public constant EXPECTED_CHAIN_ID = 1;
    uint256 public constant WAD = 1e18;

    // =========================================================================
    // Deployment Manifest
    // =========================================================================

    struct Manifest {
        StakedUSDat vault;
        IStakedUSDatEligibleIncomeModule accumulator;
        uint16 alphaBps;
        uint256 preferredCoverageWad;
        uint256 maxBackingValue;
        address pauser;
        address unpauser;
        bytes32 expectedAccountantCodeHash;
        bytes32 expectedSeniorTokenCodeHash;
        bytes32 expectedJuniorTokenCodeHash;
        bool approved;
    }

    // =========================================================================
    // Production Entry Point
    // =========================================================================

    function run() external returns (TrancheAccountant accountant) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 alphaBps = vm.envUint("V3_TRANCHE_ALPHA_BPS");
        if (alphaBps > type(uint16).max) revert InvalidManifest("alphaBps");
        Manifest memory manifest = Manifest({
            vault: StakedUSDat(vm.envAddress("V3_TRANCHE_VAULT")),
            accumulator: IStakedUSDatEligibleIncomeModule(vm.envAddress("V3_TRANCHE_INCOME_ACCUMULATOR")),
            // Safe because the full-width environment value is bounded above before this cast.
            // forge-lint: disable-next-line(unsafe-typecast)
            alphaBps: uint16(alphaBps),
            preferredCoverageWad: vm.envUint("V3_TRANCHE_PREFERRED_COVERAGE_WAD"),
            maxBackingValue: vm.envUint("V3_TRANCHE_MAX_BACKING_VALUE"),
            pauser: vm.envAddress("V3_TRANCHE_PAUSER"),
            unpauser: vm.envAddress("V3_TRANCHE_UNPAUSER"),
            expectedAccountantCodeHash: vm.envBytes32("V3_TRANCHE_EXPECTED_ACCOUNTANT_CODEHASH"),
            expectedSeniorTokenCodeHash: vm.envBytes32("V3_TRANCHE_EXPECTED_SENIOR_TOKEN_CODEHASH"),
            expectedJuniorTokenCodeHash: vm.envBytes32("V3_TRANCHE_EXPECTED_JUNIOR_TOKEN_CODEHASH"),
            approved: vm.envBool("V3_TRANCHE_MANIFEST_APPROVED")
        });
        validateManifest(manifest);
        vm.startBroadcast();
        accountant = deploy(manifest);
        vm.stopBroadcast();
        verify(accountant, manifest);
        _logManifest(accountant, manifest);
    }

    // =========================================================================
    // Deployment and Validation
    // =========================================================================

    function deploy(Manifest memory manifest) public returns (TrancheAccountant accountant) {
        validateManifest(manifest);
        accountant = new TrancheAccountant(
            manifest.vault,
            manifest.accumulator,
            manifest.alphaBps,
            manifest.preferredCoverageWad,
            manifest.maxBackingValue,
            manifest.pauser,
            manifest.unpauser
        );
    }

    function validateManifest(Manifest memory manifest) public view {
        if (!manifest.approved) revert InvalidManifest("approved");
        if (address(manifest.vault) == address(0) || address(manifest.vault).code.length == 0) {
            revert InvalidManifest("vault");
        }
        if (address(manifest.accumulator) == address(0) || address(manifest.accumulator).code.length == 0) {
            revert InvalidManifest("accumulator");
        }
        if (manifest.alphaBps == 0 || manifest.alphaBps > 10_000) revert InvalidManifest("alphaBps");
        if (manifest.preferredCoverageWad <= WAD) revert InvalidManifest("preferredCoverageWad");
        if (manifest.maxBackingValue == 0) revert InvalidManifest("maxBackingValue");
        if (manifest.pauser == address(0)) revert InvalidManifest("pauser");
        if (manifest.unpauser == address(0)) revert InvalidManifest("unpauser");
        if (
            manifest.expectedAccountantCodeHash == bytes32(0) || manifest.expectedSeniorTokenCodeHash == bytes32(0)
                || manifest.expectedJuniorTokenCodeHash == bytes32(0)
        ) revert InvalidManifest("expected code hashes");
        if (manifest.accumulator.VAULT() != address(manifest.vault)) revert InvalidManifest("accumulator vault");
        if (address(manifest.vault.eligibleIncomeModule()) != address(manifest.accumulator)) {
            revert InvalidManifest("vault accumulator");
        }
        if (!manifest.accumulator.isActive()) revert InvalidManifest("accumulator inactive");
    }

    function verify(TrancheAccountant accountant, Manifest memory manifest) public view {
        if (accountant.asset() != address(manifest.vault)) revert InvalidManifest("accountant vault");
        if (accountant.incomeAccumulator() != address(manifest.accumulator)) {
            revert InvalidManifest("accountant accumulator");
        }
        if (accountant.alphaBps() != manifest.alphaBps) revert InvalidManifest("accountant alpha");
        if (accountant.preferredCoverageWad() != manifest.preferredCoverageWad) {
            revert InvalidManifest("accountant coverage");
        }
        if (accountant.maxBackingValue() != manifest.maxBackingValue) revert InvalidManifest("accountant cap");
        if (accountant.PAUSER() != manifest.pauser || accountant.UNPAUSER() != manifest.unpauser) {
            revert InvalidManifest("accountant roles");
        }
        if (accountant.hardPaused()) revert InvalidManifest("unexpected activation");
        if (accountant.backingAssets() != 0) revert InvalidManifest("nonzero backing");
        if (accountant.SENIOR_TOKEN().totalSupply() != 0 || accountant.JUNIOR_TOKEN().totalSupply() != 0) {
            revert InvalidManifest("nonzero supply");
        }
        _requireCodeHash(address(accountant), manifest.expectedAccountantCodeHash);
        _requireCodeHash(address(accountant.SENIOR_TOKEN()), manifest.expectedSeniorTokenCodeHash);
        _requireCodeHash(address(accountant.JUNIOR_TOKEN()), manifest.expectedJuniorTokenCodeHash);
    }

    // =========================================================================
    // Code Hashes and Logging
    // =========================================================================

    function _requireCodeHash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert CodeHashMismatch(target, expected, actual);
    }

    function _logManifest(TrancheAccountant accountant, Manifest memory manifest) private view {
        console.log("V3 tranche accountant", address(accountant));
        console.log("V3 senior token", address(accountant.SENIOR_TOKEN()));
        console.log("V3 junior token", address(accountant.JUNIOR_TOKEN()));
        console.log("V3 alpha bps", manifest.alphaBps);
        console.log("V3 pauser", manifest.pauser);
        console.log("V3 unpauser", manifest.unpauser);
        console.log("Deployment creates zero supply and does not activate issuance or production configuration");
    }
}
