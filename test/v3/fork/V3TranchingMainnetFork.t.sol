// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {V2MockMainnetForkBase} from "../../v2/fork/V2MainnetFork.t.sol";
import {BuildV3UpgradeBatch} from "../../../script/v3/BuildV3UpgradeBatch.s.sol";
import {DeployTranche} from "../../../script/v3/DeployTranche.s.sol";
import {DeployV3Dependencies} from "../../../script/v3/DeployV3Dependencies.s.sol";
import {ISyntheticSharesOracle} from "../../../src/v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {STRConEligibleIncomeAdapter} from "../../../src/v3/STRConEligibleIncomeAdapter.sol";
import {IStakedUSDatEligibleIncomeModule} from "../../../src/v3/interfaces/IStakedUSDatEligibleIncomeModule.sol";
import {StakedUSDatEligibleIncomeModule} from "../../../src/v3/StakedUSDatEligibleIncomeModule.sol";
import {StakedUSDat} from "../../../src/v3/StakedUSDat.sol";
import {TrancheAccountant} from "../../../src/v3/TrancheAccountant.sol";

/**
 * @notice Pinned populated-state rehearsal of V1 -> V2 -> migration -> unified V3 and tranche binding.
 * @dev All deployments and state changes exist only inside the fork.
 *
 * Run with:
 * RUN_V3_TRANCHE_MOCK_FORK=true RPC_URL=$SATURN_MAINNET_RPC_URL \
 *   forge test --match-path test/v3/fork/V3TranchingMainnetFork.t.sol --disable-block-gas-limit -vvv
 *
 * The flag is test-harness-only: this one Foundry call rehearses multiple separately
 * scheduled governance transactions and therefore intentionally exceeds one block's gas.
 */
contract V3TranchingMockMainnetForkTest is V2MockMainnetForkBase {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint16 private constant MAX_UNREVIEWED_GROWTH_BPS = 2_000;
    uint16 private constant TEST_ALPHA_BPS = 5_000;
    uint256 private constant PREFERRED_COVERAGE_WAD = 1.5e18;
    uint256 private constant MAX_BACKING_VALUE = 500_000e6;
    uint256 private constant TEST_DEPOSIT = 1_000e6;

    struct V3Snapshot {
        bytes32[19] linearSlots;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 usdatCustody;
        uint256 strconCustody;
        uint256 moduleExposure;
        uint256 queueShares;
        uint256 queueUSDat;
        uint256 queueSupply;
        uint256 queueNextTokenId;
        bytes32 domainSeparator;
        bool paused;
    }

    function test_mockMainnetFork_UpgradesPopulatedV2ToV3AndBindsV3() public {
        if (!vm.envOr("RUN_V3_TRANCHE_MOCK_FORK", false)) {
            vm.skip(true, "set RUN_V3_TRANCHE_MOCK_FORK=true to run the pinned V3 rehearsal");
            return;
        }

        _executeFullV2UpgradeAndMigration();

        V3Snapshot memory before_ = _snapshotV3Boundary();
        DeployV3Dependencies dependencyDeployer = new DeployV3Dependencies();
        DeployV3Dependencies.DeploymentInput memory dependencyInput = DeployV3Dependencies.DeploymentInput({
            vault: STAKED_USDAT_PROXY,
            withdrawalQueue: WITHDRAWAL_QUEUE_PROXY,
            strcon: STRCON,
            sharesOracle: ISyntheticSharesOracle(SYNTHETIC_SHARES_ORACLE),
            configManager: TIMELOCK
        });
        DeployV3Dependencies.Deployments memory dependencies = dependencyDeployer.deploy(dependencyInput);
        DeployV3Dependencies.ExpectedCodeHashes memory dependencyHashes = DeployV3Dependencies.ExpectedCodeHashes({
            adapter: address(dependencies.adapter).codehash,
            module: address(dependencies.module).codehash,
            implementation: address(dependencies.implementation).codehash
        });
        dependencyDeployer.verify(dependencies, dependencyInput, dependencyHashes);
        STRConEligibleIncomeAdapter adapter = dependencies.adapter;
        StakedUSDatEligibleIncomeModule incomeModule = dependencies.module;
        StakedUSDat implementation = dependencies.implementation;
        BuildV3UpgradeBatch builder = new BuildV3UpgradeBatch();
        BuildV3UpgradeBatch.UpgradeInput memory input = BuildV3UpgradeBatch.UpgradeInput({
            implementation: address(implementation),
            module: incomeModule,
            adapter: adapter,
            configManager: TIMELOCK,
            maxUnreviewedGrowthBps: MAX_UNREVIEWED_GROWTH_BPS,
            salt: keccak256("SATURN_V3_MOCK_FORK_UPGRADE")
        });
        BuildV3UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch(input);
        assertEq(
            batch.operationId,
            _timelock.hashOperationBatch(batch.targets, batch.values, batch.payloads, builder.PREDECESSOR(), input.salt)
        );

        uint256 scheduledAt = block.timestamp;
        _callAs(builder.PROPOSER(), TIMELOCK, batch.scheduleCalldata);
        assertEq(_timelock.getTimestamp(batch.operationId), scheduledAt + builder.TIMELOCK_DELAY());

        bytes32 implementationBefore = vm.load(STAKED_USDAT_PROXY, IMPLEMENTATION_SLOT);
        assertFalse(vaultHasModuleRole(address(incomeModule)));
        _expectTimelockExecutionRejected(batch, input.salt);
        assertEq(vm.load(STAKED_USDAT_PROXY, IMPLEMENTATION_SLOT), implementationBefore);
        assertFalse(vaultHasModuleRole(address(incomeModule)));

        vm.warp(scheduledAt + builder.TIMELOCK_DELAY());
        _refreshOracleRounds();
        _callAs(address(this), TIMELOCK, batch.executeCalldata);
        assertTrue(_timelock.isOperationDone(batch.operationId));

        bytes32 implementationAfter = vm.load(STAKED_USDAT_PROXY, IMPLEMENTATION_SLOT);
        _expectTimelockExecutionRejected(batch, input.salt);
        assertEq(vm.load(STAKED_USDAT_PROXY, IMPLEMENTATION_SLOT), implementationAfter);

        StakedUSDat vault = StakedUSDat(STAKED_USDAT_PROXY);
        _assertV3Boundary(before_, vault, implementation, incomeModule, adapter);

        DeployTranche trancheDeployer = new DeployTranche();
        DeployTranche.Manifest memory manifest = DeployTranche.Manifest({
            vault: vault,
            accumulator: IStakedUSDatEligibleIncomeModule(address(incomeModule)),
            alphaBps: TEST_ALPHA_BPS,
            preferredCoverageWad: PREFERRED_COVERAGE_WAD,
            maxBackingValue: MAX_BACKING_VALUE,
            pauser: TIMELOCK,
            unpauser: TIMELOCK,
            expectedAccountantCodeHash: bytes32(uint256(1)),
            expectedSeniorTokenCodeHash: bytes32(uint256(1)),
            expectedJuniorTokenCodeHash: bytes32(uint256(1)),
            approved: true
        });
        TrancheAccountant accountant = trancheDeployer.deploy(manifest);
        manifest.expectedAccountantCodeHash = address(accountant).codehash;
        manifest.expectedSeniorTokenCodeHash = address(accountant.SENIOR_TOKEN()).codehash;
        manifest.expectedJuniorTokenCodeHash = address(accountant.JUNIOR_TOKEN()).codehash;
        trancheDeployer.verify(accountant, manifest);
        assertEq(accountant.asset(), STAKED_USDAT_PROXY);
        assertEq(accountant.incomeAccumulator(), address(incomeModule));
        assertEq(accountant.alphaBps(), TEST_ALPHA_BPS);
        assertEq(accountant.preferredCoverageWad(), PREFERRED_COVERAGE_WAD);
        assertEq(accountant.MAX_BACKING_VALUE(), MAX_BACKING_VALUE);
        assertEq(accountant.backingAssets(), 0);
        assertEq(accountant.SENIOR_TOKEN().totalSupply(), 0);
        assertEq(accountant.JUNIOR_TOKEN().totalSupply(), 0);

        _exerciseV3Bootstrap(vault, accountant);
    }

    function _snapshotV3Boundary() private view returns (V3Snapshot memory snapshot) {
        for (uint256 slot; slot < snapshot.linearSlots.length; ++slot) {
            snapshot.linearSlots[slot] = vm.load(STAKED_USDAT_PROXY, bytes32(slot));
        }
        snapshot.totalAssets = _vaultV2.totalAssets();
        snapshot.totalSupply = _vaultV2.totalSupply();
        snapshot.usdatCustody = IERC20(USDAT).balanceOf(STAKED_USDAT_PROXY);
        snapshot.strconCustody = IERC20(STRCON).balanceOf(STAKED_USDAT_PROXY);
        snapshot.moduleExposure = _module.balance();
        snapshot.queueShares = IERC20(STAKED_USDAT_PROXY).balanceOf(WITHDRAWAL_QUEUE_PROXY);
        snapshot.queueUSDat = IERC20(USDAT).balanceOf(WITHDRAWAL_QUEUE_PROXY);
        snapshot.queueSupply = _queueV2.totalSupply();
        snapshot.queueNextTokenId = _queueV2.nextTokenId();
        snapshot.domainSeparator = _vaultV2.DOMAIN_SEPARATOR();
        snapshot.paused = _vaultV2.paused();
    }

    function _assertV3Boundary(
        V3Snapshot memory before_,
        StakedUSDat vault,
        StakedUSDat implementation,
        StakedUSDatEligibleIncomeModule incomeModule,
        STRConEligibleIncomeAdapter adapter
    ) private view {
        assertEq(_implementationAddress(STAKED_USDAT_PROXY), address(implementation));
        for (uint256 slot; slot < before_.linearSlots.length; ++slot) {
            assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(slot)), before_.linearSlots[slot]);
        }
        assertEq(vault.totalAssets(), before_.totalAssets);
        assertEq(vault.totalSupply(), before_.totalSupply);
        assertEq(IERC20(USDAT).balanceOf(STAKED_USDAT_PROXY), before_.usdatCustody);
        assertEq(IERC20(STRCON).balanceOf(STAKED_USDAT_PROXY), before_.strconCustody);
        assertEq(_module.balance(), before_.moduleExposure);
        assertEq(IERC20(STAKED_USDAT_PROXY).balanceOf(WITHDRAWAL_QUEUE_PROXY), before_.queueShares);
        assertEq(IERC20(USDAT).balanceOf(WITHDRAWAL_QUEUE_PROXY), before_.queueUSDat);
        assertEq(_queueV2.totalSupply(), before_.queueSupply);
        assertEq(_queueV2.nextTokenId(), before_.queueNextTokenId);
        assertEq(vault.DOMAIN_SEPARATOR(), before_.domainSeparator);
        assertEq(vault.paused(), before_.paused);
        assertEq(address(vault.eligibleIncomeModule()), address(incomeModule));
        assertTrue(vault.hasRole(vault.PARAMETER_MANAGER_ROLE(), address(incomeModule)));
        assertTrue(incomeModule.isActive());
        assertTrue(incomeModule.canAccount());
        assertEq(incomeModule.configManager(), TIMELOCK);
        assertEq(incomeModule.eligibleIncomeState().adapter, address(adapter));
        assertEq(incomeModule.eligibleIncomeState().asset, STRCON);
        assertGt(adapter.rawIndex(), 0);
    }

    function _exerciseV3Bootstrap(StakedUSDat vault, TrancheAccountant accountant) private {
        deal(USDAT, address(this), TEST_DEPOSIT);
        IERC20(USDAT).approve(STAKED_USDAT_PROXY, TEST_DEPOSIT);
        uint256 shares = vault.deposit(TEST_DEPOSIT, address(this));
        assertGt(shares, 0);
        vault.approve(address(accountant), shares);

        uint256 juniorAssets = shares / 3;
        uint256 seniorAssets = shares - juniorAssets;
        accountant.depositJunior(juniorAssets, address(this), 0, block.timestamp);
        accountant.depositSenior(seniorAssets, address(this), 0, block.timestamp);

        assertEq(accountant.backingAssets(), shares);
        assertGt(accountant.SENIOR_TOKEN().totalSupply(), 0);
        assertGt(accountant.JUNIOR_TOKEN().totalSupply(), 0);
        assertGe(accountant.coverageWad(), PREFERRED_COVERAGE_WAD - 1);
        assertTrue(incomeModuleCanAccount(accountant));
    }

    function incomeModuleCanAccount(TrancheAccountant accountant) private view returns (bool) {
        return accountant.INCOME_ACCUMULATOR().canAccount();
    }

    function vaultHasModuleRole(address module) private view returns (bool) {
        return StakedUSDat(STAKED_USDAT_PROXY).hasRole(StakedUSDat(STAKED_USDAT_PROXY).PARAMETER_MANAGER_ROLE(), module);
    }

    function _expectTimelockExecutionRejected(BuildV3UpgradeBatch.UpgradeBatch memory batch, bytes32 salt) private {
        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                batch.operationId,
                bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready))
            )
        );
        _timelock.executeBatch(batch.targets, batch.values, batch.payloads, bytes32(0), salt);
    }

    function _implementationAddress(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
