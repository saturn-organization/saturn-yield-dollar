// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {DeployTranche} from "../../../script/v3/DeployTranche.s.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {IStakedUSDatEligibleIncomeModule} from "../../../src/v3/interfaces/IStakedUSDatEligibleIncomeModule.sol";
import {StakedUSDat} from "../../../src/v3/StakedUSDat.sol";
import {TrancheAccountant} from "../../../src/v3/TrancheAccountant.sol";

contract TrancheManifestAccumulator {
    address public immutable VAULT;
    bool public active = true;

    constructor(address vault) {
        VAULT = vault;
    }

    function isActive() external view returns (bool) {
        return active;
    }

    function setActive(bool active_) external {
        active = active_;
    }

    function eligibleIncomeState() external pure returns (IEligibleIncomeAccounting.EligibleIncomeState memory state) {
        state.state = IEligibleIncomeAccounting.IncomeState.Active;
        state.liveUnitScaleWad = 1e18;
        state.crystallizedValueScaleWad = 1e18;
    }
}

contract TrancheManifestVault {
    address public module;

    function setModule(address module_) external {
        module = module_;
    }

    function eligibleIncomeModule() external view returns (address) {
        return module;
    }

    function isRestricted(address) external pure returns (bool) {
        return false;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract DeployTrancheTest is Test {
    DeployTranche private deployer;
    TrancheManifestVault private vault;
    TrancheManifestAccumulator private accumulator;
    DeployTranche.Manifest private manifest;

    function setUp() public {
        deployer = new DeployTranche();
        vault = new TrancheManifestVault();
        accumulator = new TrancheManifestAccumulator(address(vault));
        vault.setModule(address(accumulator));
        manifest = DeployTranche.Manifest({
            vault: StakedUSDat(address(vault)),
            accumulator: IStakedUSDatEligibleIncomeModule(address(accumulator)),
            alphaBps: 5_000,
            preferredCoverageWad: 1.5e18,
            maxBackingValue: 500_000e6,
            pauser: makeAddr("pauser"),
            unpauser: makeAddr("unpauser"),
            expectedAccountantCodeHash: bytes32(uint256(1)),
            expectedSeniorTokenCodeHash: bytes32(uint256(1)),
            expectedJuniorTokenCodeHash: bytes32(uint256(1)),
            approved: true
        });
    }

    // ============ Deployment ============

    function test_deploy_VerifiesBindingsAndCreatesNoSupplyOrActivation() public {
        TrancheAccountant accountant = deployer.deploy(manifest);
        manifest.expectedAccountantCodeHash = address(accountant).codehash;
        manifest.expectedSeniorTokenCodeHash = address(accountant.SENIOR_TOKEN()).codehash;
        manifest.expectedJuniorTokenCodeHash = address(accountant.JUNIOR_TOKEN()).codehash;
        deployer.verify(accountant, manifest);

        assertEq(accountant.asset(), address(vault));
        assertEq(accountant.incomeAccumulator(), address(accumulator));
        assertEq(accountant.alphaBps(), manifest.alphaBps);
        assertEq(accountant.PAUSER(), manifest.pauser);
        assertEq(accountant.UNPAUSER(), manifest.unpauser);
        assertFalse(accountant.hardPaused());
        assertEq(accountant.backingAssets(), 0);
        assertEq(accountant.SENIOR_TOKEN().totalSupply(), 0);
        assertEq(accountant.JUNIOR_TOKEN().totalSupply(), 0);
    }

    // ============ Fail-Closed Manifest Validation ============

    function test_validateManifest_RejectsUnapprovedManifest() public {
        manifest.approved = false;
        _expectInvalid("approved");
    }

    function test_validateManifest_RejectsZeroAlpha() public {
        manifest.alphaBps = 0;
        _expectInvalid("alphaBps");
    }

    function test_validateManifest_RejectsAlphaAboveFullParticipation() public {
        manifest.alphaBps = 10_001;
        _expectInvalid("alphaBps");
    }

    function test_validateManifest_RejectsCoverageAtOrBelowParity() public {
        manifest.preferredCoverageWad = 1e18;
        _expectInvalid("preferredCoverageWad");
    }

    function test_validateManifest_RejectsZeroBackingCap() public {
        manifest.maxBackingValue = 0;
        _expectInvalid("maxBackingValue");
    }

    function test_validateManifest_RejectsZeroPauser() public {
        manifest.pauser = address(0);
        _expectInvalid("pauser");
    }

    function test_validateManifest_RejectsZeroUnpauser() public {
        manifest.unpauser = address(0);
        _expectInvalid("unpauser");
    }

    function test_validateManifest_RejectsZeroAndMissingCodeBindings() public {
        DeployTranche.Manifest memory valid = manifest;
        manifest.vault = StakedUSDat(address(0));
        _expectInvalid("vault");
        manifest = valid;
        manifest.vault = StakedUSDat(makeAddr("vaultWithoutCode"));
        _expectInvalid("vault");
        manifest = valid;
        manifest.accumulator = IStakedUSDatEligibleIncomeModule(address(0));
        _expectInvalid("accumulator");
        manifest = valid;
        manifest.accumulator = IStakedUSDatEligibleIncomeModule(makeAddr("accumulatorWithoutCode"));
        _expectInvalid("accumulator");
    }

    function test_validateManifest_RejectsEachZeroExpectedCodeHash() public {
        DeployTranche.Manifest memory valid = manifest;
        manifest.expectedAccountantCodeHash = bytes32(0);
        _expectInvalid("expected code hashes");
        manifest = valid;
        manifest.expectedSeniorTokenCodeHash = bytes32(0);
        _expectInvalid("expected code hashes");
        manifest = valid;
        manifest.expectedJuniorTokenCodeHash = bytes32(0);
        _expectInvalid("expected code hashes");
    }

    function test_validateManifest_RejectsWrongAccumulatorBinding() public {
        TrancheManifestAccumulator wrong = new TrancheManifestAccumulator(makeAddr("wrongVault"));
        manifest.accumulator = IStakedUSDatEligibleIncomeModule(address(wrong));
        vm.expectRevert(abi.encodeWithSelector(DeployTranche.InvalidManifest.selector, "accumulator vault"));
        deployer.validateManifest(manifest);
    }

    function test_validateManifest_RejectsWrongVaultBindingAndInactiveAccumulator() public {
        vault.setModule(makeAddr("wrongAccumulator"));
        _expectInvalid("vault accumulator");

        vault.setModule(address(accumulator));
        accumulator.setActive(false);
        _expectInvalid("accumulator inactive");
    }

    function test_verifyRejectsEachUnapprovedCodeHash() public {
        TrancheAccountant accountant = deployer.deploy(manifest);
        manifest.expectedAccountantCodeHash = address(accountant).codehash;
        manifest.expectedSeniorTokenCodeHash = address(accountant.SENIOR_TOKEN()).codehash;
        manifest.expectedJuniorTokenCodeHash = address(accountant.JUNIOR_TOKEN()).codehash;

        manifest.expectedAccountantCodeHash = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployTranche.CodeHashMismatch.selector,
                address(accountant),
                bytes32(uint256(1)),
                address(accountant).codehash
            )
        );
        deployer.verify(accountant, manifest);
        manifest.expectedAccountantCodeHash = address(accountant).codehash;
        manifest.expectedSeniorTokenCodeHash = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployTranche.CodeHashMismatch.selector,
                address(accountant.SENIOR_TOKEN()),
                bytes32(uint256(1)),
                address(accountant.SENIOR_TOKEN()).codehash
            )
        );
        deployer.verify(accountant, manifest);
        manifest.expectedSeniorTokenCodeHash = address(accountant.SENIOR_TOKEN()).codehash;
        manifest.expectedJuniorTokenCodeHash = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployTranche.CodeHashMismatch.selector,
                address(accountant.JUNIOR_TOKEN()),
                bytes32(uint256(1)),
                address(accountant.JUNIOR_TOKEN()).codehash
            )
        );
        deployer.verify(accountant, manifest);
    }

    function test_runRejectsWrongChainBeforeReadingManifest() public {
        vm.chainId(31337);
        vm.expectRevert(abi.encodeWithSelector(DeployTranche.WrongChain.selector, 31337));
        deployer.run();
    }

    // ============ Helpers ============

    function _expectInvalid(string memory field) private {
        vm.expectRevert(abi.encodeWithSelector(DeployTranche.InvalidManifest.selector, field));
        deployer.validateManifest(manifest);
    }
}
