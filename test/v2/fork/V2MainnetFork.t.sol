// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {StakedUSDat as StakedUSDatV1} from "../../../src/v1/StakedUSDat.sol";
import {WithdrawalQueueERC721 as WithdrawalQueueV1} from "../../../src/v1/WithdrawalQueueERC721.sol";
import {BuildV2Migration} from "../../../script/v2/BuildV2Migration.s.sol";
import {BuildV2UpgradeBatch} from "../../../script/v2/BuildV2UpgradeBatch.s.sol";
import {DeployV2Dependencies} from "../../../script/v2/DeployV2Dependencies.s.sol";
import {STRConExecutionPolicy} from "../../../src/v2/STRConExecutionPolicy.sol";
import {StakedUSDat as StakedUSDatV2} from "../../../src/v2/StakedUSDat.sol";
import {WithdrawalQueueERC721 as WithdrawalQueueV2} from "../../../src/v2/WithdrawalQueueERC721.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRCMirrorModule} from "../../../src/v2/interfaces/modules/ISTRCMirrorModule.sol";
import {IPriceOracle} from "../../../src/v2/interfaces/oracles/IPriceOracle.sol";
import {STRCMirrorModule} from "../../../src/v2/modules/MirrorSTRC/STRCMirrorModule.sol";
import {STRConModule} from "../../../src/v2/modules/STRCon/STRConModule.sol";
import {STRConPriceOracle} from "../../../src/v2/modules/STRCon/STRConPriceOracle.sol";

interface ILegacyOracleBinding {
    function getOracle() external view returns (address);
}

/**
 * @title V2MockMainnetForkTest
 * @notice End-to-end rehearsal against pinned live v1 state.
 * @dev Future v2 contracts, configuration, roles, and STRCon inventory are created
 * only inside the fork. This is not the production-manifest replay.
 *
 * Run with:
 * RUN_V2_MOCK_FORK=true forge test --match-path test/v2/fork/V2MainnetFork.t.sol -vvv
 */
contract V2MockMainnetForkTest is Test {
    error ExternalCallFailed(address target, bytes reason);
    error InvalidLegacyRequest(uint256 tokenId, uint256 status);

    uint256 private constant PINNED_MAINNET_BLOCK = 25_627_322;
    uint256 private constant MAINNET_CHAIN_ID = 1;
    uint256 private constant TIMELOCK_DELAY = 5 days;
    uint256 private constant REQUEST_WORDS = 5;
    uint256 private constant REQUESTED_STATUS = 1;
    uint256 private constant IN_PROGRESS_STATUS = 2;
    uint256 private constant PROCESSED_STATUS = 3;
    uint256 private constant CLAIMED_STATUS = 4;

    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private constant USDAT = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address private constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;
    address private constant WITHDRAWAL_QUEUE_PROXY = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;
    address private constant LEGACY_STRC_ORACLE = 0x5f7eCD0D045c393da6cb6c933c671AC305A871BF;
    address private constant STRCON = 0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c;

    address private constant TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;
    address private constant PROPOSER = 0x610182581C93687Ca03F4a8E7f124f8cEC616820;

    address private constant SYNTHETIC_SHARES_ORACLE = 0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6;
    address private constant PRIMARY_FEED = 0xC353ac4b425f818Ad87E228bf816E15c2173AC07;
    address private constant REFERENCE_FEED = 0x67d4Ae9f265270aE123c08D2657536771D19cD91;

    address private constant V1_STAKED_USDAT_IMPLEMENTATION = 0x2005E0CA201a37694125fF267ae57872bEA0a0Ce;
    address private constant V1_WITHDRAWAL_QUEUE_IMPLEMENTATION = 0x256fA0ba1b6dFB50EE883955c5a99D3C1b017Fd5;
    bytes32 private constant V1_STAKED_USDAT_CODEHASH =
        0x555fcdfcc7e072b39cb27f6a0f4619c376a0d6b1f6d2b8d60216d5beaca8d2a2;
    bytes32 private constant V1_WITHDRAWAL_QUEUE_CODEHASH =
        0x4bbdf6f68aaefdf98290c5662e7bb0c9d566ffa1e0abff19a5332cf81246ffe1;

    address private constant PARAMETER_MANAGER = address(0x1001);
    address private constant MARKET_MODE_MANAGER = address(0x1002);
    address private constant OPERATOR = address(0x1003);
    address private constant BLACKLISTER = address(0x1004);
    address private constant ENFORCER = address(0x1005);
    address private constant PAUSER = address(0x1006);
    address private constant UNPAUSER = address(0x1007);
    address private constant RECOVERY_ADDRESS = address(0x1008);
    address private constant EXECUTION_VEHICLE = address(0x1009);
    address private constant EXECUTOR = address(0x1010);
    address private constant SURPLUS_SOURCE = address(0x1011);
    address private constant SURPLUS_MANAGER = address(0x1012);

    uint16 private constant BASE_REDEMPTION_FEE_BPS = 5;
    uint16 private constant ELEVATED_REDEMPTION_FEE_BPS = 10;
    uint16 private constant ELEVATED_DEPOSIT_FEE_BPS = 10;
    uint16 private constant EXECUTION_TOLERANCE_BPS = 50;
    uint16 private constant MIGRATION_TOLERANCE_BPS = 500;
    uint128 private constant EXECUTION_CAPACITY = 1_000_000e6;
    uint128 private constant EXECUTION_REFILL_PER_DAY = 100_000e6;
    uint256 private constant ORACLE_DEVIATION_BPS = 500;
    uint256 private constant MAX_MIRROR_REWARDS_BPS = 500;

    bytes32 private constant UPGRADE_SALT = keccak256("SATURN_V2_MOCK_FORK_UPGRADE");
    bytes32 private constant MIGRATION_SALT = keccak256("SATURN_V2_MOCK_FORK_MIGRATION");

    struct OracleRound {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint80 answeredInRound;
    }

    struct VaultSnapshot {
        bytes32[10] legacySlots;
        uint256 totalAssets;
        uint256 assetsPerShare;
        uint256 sharesPerUsdat;
        uint256 unvestedStrc;
        uint256 totalSupply;
        uint256 usdatCustody;
        uint256 queueShares;
        bytes32 domainSeparator;
        bool paused;
    }

    struct QueueSnapshot {
        bytes32[] requestWords;
        address[] owners;
        address[] approvals;
        bool[] exists;
        uint256[] enumeration;
        uint256 nextTokenId;
        uint256 pendingCount;
        uint256 totalSupply;
        uint256 usdatCustody;
        uint256 shareCustody;
        bool paused;
    }

    struct DeploymentCodeHashes {
        bytes32 tradeExecutionLogic;
        bytes32 priceOracle;
        bytes32 mirror;
        bytes32 module;
        bytes32 policy;
        bytes32 vaultImplementation;
        bytes32 queueImplementation;
    }

    struct MigrationSnapshot {
        QueueSnapshot queue;
        uint256 expectedStrcon;
        uint256 modulePrice;
        uint256 nav;
        uint256 mirrorValue;
        uint256 usdatBalance;
        uint256 usdatCustody;
        uint256 supply;
        uint256 vaultStrcon;
        uint256 vehicleStrcon;
    }

    StakedUSDatV1 private _vaultV1;
    WithdrawalQueueV1 private _queueV1;
    StakedUSDatV2 private _vaultV2;
    WithdrawalQueueV2 private _queueV2;
    TimelockController private _timelock;

    DeployV2Dependencies private _dependencyDeployer;
    BuildV2UpgradeBatch private _upgradeBuilder;
    BuildV2Migration private _migrationBuilder;

    address private _tradeExecutionLogic;
    STRConPriceOracle private _priceOracle;
    STRCMirrorModule private _mirror;
    STRConModule private _module;
    STRConExecutionPolicy private _policy;
    StakedUSDatV2 private _vaultImplementation;
    WithdrawalQueueV2 private _queueImplementation;

    address private _legacyFeed;
    OracleRound private _legacyRound;
    OracleRound private _primaryRound;
    OracleRound private _referenceRound;
    DeploymentCodeHashes private _codeHashes;

    function test_mockMainnetFork_ExecutesFullV2UpgradeAndMigration() public {
        if (!vm.envOr("RUN_V2_MOCK_FORK", false)) {
            vm.skip(true, "set RUN_V2_MOCK_FORK=true to run the pinned mainnet rehearsal");
            return;
        }
        require(vm.envExists("RPC_URL"), "RPC_URL is required");

        vm.createSelectFork(vm.envString("RPC_URL"), PINNED_MAINNET_BLOCK);

        _bindAndValidateLiveV1();
        _captureOracleRounds();
        _deployV2Dependencies();
        _assertUninitializedBindings();
        _upgradeBothProxies();
        _migrateMirrorToStrCon();
    }

    function _bindAndValidateLiveV1() private {
        assertEq(block.chainid, MAINNET_CHAIN_ID);

        _vaultV1 = StakedUSDatV1(STAKED_USDAT_PROXY);
        _queueV1 = WithdrawalQueueV1(WITHDRAWAL_QUEUE_PROXY);
        _timelock = TimelockController(payable(TIMELOCK));

        assertEq(address(_vaultV1.asset()), USDAT);
        assertEq(_vaultV1.getWithdrawalQueue(), WITHDRAWAL_QUEUE_PROXY);
        assertEq(_vaultV1.getStrcOracle(), LEGACY_STRC_ORACLE);
        assertLe(_vaultV1.maxRewardsBps(), MAX_MIRROR_REWARDS_BPS);
        assertEq(address(_queueV1.USDAT()), USDAT);
        assertEq(address(_queueV1.STAKED_USDAT()), STAKED_USDAT_PROXY);

        assertEq(_implementationOf(STAKED_USDAT_PROXY), V1_STAKED_USDAT_IMPLEMENTATION);
        assertEq(_implementationOf(WITHDRAWAL_QUEUE_PROXY), V1_WITHDRAWAL_QUEUE_IMPLEMENTATION);
        assertEq(V1_STAKED_USDAT_IMPLEMENTATION.codehash, V1_STAKED_USDAT_CODEHASH);
        assertEq(V1_WITHDRAWAL_QUEUE_IMPLEMENTATION.codehash, V1_WITHDRAWAL_QUEUE_CODEHASH);

        assertEq(_timelock.getMinDelay(), TIMELOCK_DELAY);
        assertTrue(_timelock.hasRole(_timelock.PROPOSER_ROLE(), PROPOSER));
        assertTrue(_timelock.hasRole(_timelock.EXECUTOR_ROLE(), address(0)));
        assertTrue(IAccessControl(STAKED_USDAT_PROXY).hasRole(bytes32(0), TIMELOCK));
        assertTrue(IAccessControl(WITHDRAWAL_QUEUE_PROXY).hasRole(bytes32(0), TIMELOCK));

        for (uint256 slot = 10; slot <= 18; ++slot) {
            assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(slot)), bytes32(0));
        }
    }

    function _captureOracleRounds() private {
        _legacyFeed = ILegacyOracleBinding(LEGACY_STRC_ORACLE).getOracle();
        _legacyRound = _readRound(_legacyFeed);
        _primaryRound = _readRound(PRIMARY_FEED);
        _referenceRound = _readRound(REFERENCE_FEED);
    }

    function _deployV2Dependencies() private {
        _dependencyDeployer = new DeployV2Dependencies();
        _upgradeBuilder = new BuildV2UpgradeBatch();
        _migrationBuilder = new BuildV2Migration();

        DeployV2Dependencies.Deployments memory deployed = _dependencyDeployer.deployForFork(
            DeployV2Dependencies.OracleConfig({initialDeviationBps: ORACLE_DEVIATION_BPS})
        );

        _tradeExecutionLogic = deployed.tradeExecutionLogic;
        _priceOracle = STRConPriceOracle(deployed.strconPriceOracle);
        _mirror = STRCMirrorModule(deployed.strcMirrorModule);
        _module = STRConModule(deployed.strconModule);
        _policy = STRConExecutionPolicy(deployed.executionPolicy);
        _vaultImplementation = StakedUSDatV2(deployed.stakedUsdatImplementation);
        _queueImplementation = WithdrawalQueueV2(deployed.withdrawalQueueImplementation);

        _codeHashes = DeploymentCodeHashes({
            tradeExecutionLogic: _tradeExecutionLogic.codehash,
            priceOracle: address(_priceOracle).codehash,
            mirror: address(_mirror).codehash,
            module: address(_module).codehash,
            policy: address(_policy).codehash,
            vaultImplementation: address(_vaultImplementation).codehash,
            queueImplementation: address(_queueImplementation).codehash
        });

        assertEq(_upgradeBuilder.TIMELOCK(), TIMELOCK);
        assertEq(_upgradeBuilder.PROPOSER(), PROPOSER);
        assertEq(_migrationBuilder.TIMELOCK(), TIMELOCK);
        assertEq(_migrationBuilder.PROPOSER(), PROPOSER);
    }

    function _assertUninitializedBindings() private view {
        assertEq(_priceOracle.VAULT(), STAKED_USDAT_PROXY);
        assertEq(_priceOracle.STRCON(), STRCON);
        assertEq(address(_priceOracle.syntheticSharesOracle()), SYNTHETIC_SHARES_ORACLE);
        assertEq(address(_priceOracle.primaryFeed()), PRIMARY_FEED);
        assertEq(address(_priceOracle.referenceFeed()), REFERENCE_FEED);
        assertEq(_priceOracle.decimals(), 8);
        assertEq(_priceOracle.MAX_DEVIATION_BPS(), 1_000);
        assertEq(_priceOracle.deviationBps(), ORACLE_DEVIATION_BPS);
        assertGt(_priceOracle.getPrice(), 0);

        assertEq(_mirror.VAULT(), STAKED_USDAT_PROXY);
        assertEq(address(_mirror.ORACLE()), LEGACY_STRC_ORACLE);
        assertFalse(_mirror.seeded());
        assertFalse(_mirror.retired());
        assertEq(_mirror.balance(), 0);

        assertEq(_module.VAULT(), STAKED_USDAT_PROXY);
        assertEq(_module.ASSET(), STRCON);
        assertEq(address(_module.oracle()), address(_priceOracle));
        assertEq(_module.balance(), 0);

        assertEq(_policy.VAULT(), STAKED_USDAT_PROXY);
        assertEq(address(_policy.STRCON_MODULE()), address(_module));
        assertEq(_policy.executionVehicle(), address(0));

        assertEq(_vaultImplementation.getWithdrawalQueue(), WITHDRAWAL_QUEUE_PROXY);
        assertEq(address(_queueImplementation.USDAT()), USDAT);
        assertEq(address(_queueImplementation.STAKED_USDAT()), STAKED_USDAT_PROXY);
        _assertDeploymentCodeHashes();
    }

    function _upgradeBothProxies() private {
        IStakedUSDat.V2Config memory config = IStakedUSDat.V2Config({
            strcMirrorModule: ISTRCMirrorModule(address(_mirror)),
            strconModule: _module,
            executionPolicy: _policy,
            recoveryAddress: RECOVERY_ADDRESS,
            surplusSource: SURPLUS_SOURCE,
            executionVehicle: EXECUTION_VEHICLE,
            baseRedemptionFeeBps: BASE_REDEMPTION_FEE_BPS,
            elevatedRedemptionFeeBps: ELEVATED_REDEMPTION_FEE_BPS,
            elevatedDepositFeeBps: ELEVATED_DEPOSIT_FEE_BPS,
            executionToleranceBps: EXECUTION_TOLERANCE_BPS,
            migrationToleranceBps: MIGRATION_TOLERANCE_BPS,
            initialExecutionCapacity: EXECUTION_CAPACITY,
            initialExecutionRefillPerDay: EXECUTION_REFILL_PER_DAY
        });
        IStakedUSDat.V2Roles memory roles = IStakedUSDat.V2Roles({
            parameterManager: PARAMETER_MANAGER,
            marketModeManager: MARKET_MODE_MANAGER,
            operator: OPERATOR,
            surplusManager: SURPLUS_MANAGER,
            blacklister: BLACKLISTER,
            enforcer: ENFORCER,
            pauser: PAUSER,
            unpauser: UNPAUSER
        });

        BuildV2UpgradeBatch.UpgradeBatch memory batch = _upgradeBuilder.buildBatch(
            BuildV2UpgradeBatch.UpgradeBatchInput({
                stakedUsdatImplementation: address(_vaultImplementation),
                withdrawalQueueImplementation: address(_queueImplementation),
                vaultConfig: config,
                vaultRoles: roles,
                queueRoles: BuildV2UpgradeBatch.QueueRoles({
                    operator: OPERATOR, enforcer: ENFORCER, pauser: PAUSER, unpauser: UNPAUSER
                }),
                salt: UPGRADE_SALT
            })
        );
        assertEq(batch.targets[0], STAKED_USDAT_PROXY);
        assertEq(batch.targets[1], WITHDRAWAL_QUEUE_PROXY);

        uint256 scheduledAt = block.timestamp;
        _callAs(PROPOSER, TIMELOCK, batch.scheduleCalldata);
        assertEq(_timelock.getTimestamp(batch.operationId), scheduledAt + TIMELOCK_DELAY);

        vm.warp(scheduledAt + TIMELOCK_DELAY);
        _refreshOracleRounds();

        VaultSnapshot memory vaultBefore = _snapshotVaultV1();
        QueueSnapshot memory queueBefore = _snapshotQueueV1();

        _callAs(EXECUTOR, TIMELOCK, batch.executeCalldata);
        assertTrue(_timelock.isOperationDone(batch.operationId));

        _vaultV2 = StakedUSDatV2(STAKED_USDAT_PROXY);
        _queueV2 = WithdrawalQueueV2(WITHDRAWAL_QUEUE_PROXY);

        _assertVaultUpgrade(vaultBefore);
        _assertQueueUnchanged(queueBefore);
        _assertV2Roles();
        _resetLegacyInProgressRequestsIfAny(queueBefore);
        _assertDeploymentCodeHashes();
    }

    function _migrateMirrorToStrCon() private {
        uint256 vestingEnd = _mirror.lastDistributionTimestamp() + _mirror.vestingPeriod();
        if (block.timestamp < vestingEnd) {
            vm.warp(vestingEnd);
            _refreshOracleRounds();
        }
        assertEq(_mirror.getUnvestedAmount(), 0);

        uint256 mirrorValue = _mirror.recognizedValue();
        uint256 modulePrice = _module.getPrice();
        uint256 expectedStrcon = Math.mulDiv(mirrorValue, 1e20, modulePrice, Math.Rounding.Ceil);
        assertGt(expectedStrcon, 0);

        deal(STRCON, EXECUTION_VEHICLE, expectedStrcon);
        vm.prank(EXECUTION_VEHICLE);
        IERC20(STRCON).approve(STAKED_USDAT_PROXY, expectedStrcon);

        BuildV2Migration.MigrationOperation memory operation = _scheduleMigration(expectedStrcon);
        MigrationSnapshot memory before_ = _snapshotMigration(expectedStrcon);

        _callAs(EXECUTOR, TIMELOCK, operation.executeCalldata);
        assertTrue(_timelock.isOperationDone(operation.operationId));
        _assertMigration(before_);

        vm.prank(TIMELOCK);
        vm.expectRevert(IStakedUSDat.InvalidModule.selector);
        _vaultV2.migrate(expectedStrcon, block.timestamp);
    }

    function _scheduleMigration(uint256 expectedStrcon)
        private
        returns (BuildV2Migration.MigrationOperation memory operation)
    {
        uint256 deadline = block.timestamp + TIMELOCK_DELAY + 1 days;
        operation = _migrationBuilder.buildOperation(expectedStrcon, deadline, MIGRATION_SALT);
        assertEq(operation.target, STAKED_USDAT_PROXY);

        uint256 scheduledAt = block.timestamp;
        _callAs(PROPOSER, TIMELOCK, operation.scheduleCalldata);
        assertEq(_timelock.getTimestamp(operation.operationId), scheduledAt + TIMELOCK_DELAY);

        vm.warp(scheduledAt + TIMELOCK_DELAY);
        _refreshOracleRounds();
    }

    function _snapshotMigration(uint256 expectedStrcon) private view returns (MigrationSnapshot memory snapshot) {
        snapshot.queue = _snapshotQueueV2();
        snapshot.expectedStrcon = expectedStrcon;
        snapshot.modulePrice = _module.getPrice();
        snapshot.nav = _vaultV2.totalAssets();
        snapshot.mirrorValue = _mirror.recognizedValue();
        snapshot.usdatBalance = _vaultV2.usdatBalance();
        snapshot.usdatCustody = IERC20(USDAT).balanceOf(STAKED_USDAT_PROXY);
        snapshot.supply = _vaultV2.totalSupply();
        snapshot.vaultStrcon = IERC20(STRCON).balanceOf(STAKED_USDAT_PROXY);
        snapshot.vehicleStrcon = IERC20(STRCON).balanceOf(EXECUTION_VEHICLE);
    }

    function _assertMigration(MigrationSnapshot memory before_) private view {
        assertTrue(_mirror.retired());
        assertEq(_mirror.balance(), 0);
        assertEq(_mirror.getUnvestedAmount(), 0);
        assertEq(_mirror.recognizedValue(), 0);
        assertEq(_module.balance(), before_.expectedStrcon);
        assertEq(IERC20(STRCON).balanceOf(STAKED_USDAT_PROXY) - before_.vaultStrcon, before_.expectedStrcon);
        assertEq(before_.vehicleStrcon - IERC20(STRCON).balanceOf(EXECUTION_VEHICLE), before_.expectedStrcon);
        assertEq(IERC20(STRCON).allowance(EXECUTION_VEHICLE, STAKED_USDAT_PROXY), 0);

        uint256 moduleValue = Math.mulDiv(before_.expectedStrcon, before_.modulePrice, 1e20, Math.Rounding.Floor);
        uint256 expectedNavAfter = before_.nav - before_.mirrorValue + moduleValue;
        uint256 navAfter = _vaultV2.totalAssets();
        uint256 navDelta = navAfter >= before_.nav ? navAfter - before_.nav : before_.nav - navAfter;

        assertEq(navAfter, expectedNavAfter);
        assertLe(navDelta, Math.mulDiv(before_.nav, MIGRATION_TOLERANCE_BPS, 10_000));
        assertEq(_vaultV2.usdatBalance(), before_.usdatBalance);
        assertEq(IERC20(USDAT).balanceOf(STAKED_USDAT_PROXY), before_.usdatCustody);
        assertEq(_vaultV2.totalSupply(), before_.supply);

        _assertQueueUnchanged(before_.queue);
        _assertV2Roles();
        _assertDeploymentCodeHashes();
    }

    function _snapshotVaultV1() private view returns (VaultSnapshot memory snapshot) {
        for (uint256 slot; slot < snapshot.legacySlots.length; ++slot) {
            snapshot.legacySlots[slot] = vm.load(STAKED_USDAT_PROXY, bytes32(slot));
        }

        snapshot.totalAssets = _vaultV1.totalAssets();
        snapshot.assetsPerShare = _vaultV1.convertToAssets(1e18);
        snapshot.sharesPerUsdat = _vaultV1.convertToShares(1e6);
        snapshot.unvestedStrc = _vaultV1.getUnvestedAmount();
        snapshot.totalSupply = _vaultV1.totalSupply();
        snapshot.usdatCustody = IERC20(USDAT).balanceOf(STAKED_USDAT_PROXY);
        snapshot.queueShares = _vaultV1.balanceOf(WITHDRAWAL_QUEUE_PROXY);
        snapshot.domainSeparator = _vaultV1.DOMAIN_SEPARATOR();
        snapshot.paused = _vaultV1.paused();
    }

    function _assertVaultUpgrade(VaultSnapshot memory before_) private view {
        assertEq(_implementationOf(STAKED_USDAT_PROXY), address(_vaultImplementation));
        assertEq(_vaultV2.totalAssets(), before_.totalAssets);
        assertEq(_vaultV2.convertToAssets(1e18), before_.assetsPerShare);
        assertEq(_vaultV2.convertToShares(1e6), before_.sharesPerUsdat);
        assertEq(_vaultV2.totalSupply(), before_.totalSupply);
        assertEq(IERC20(USDAT).balanceOf(STAKED_USDAT_PROXY), before_.usdatCustody);
        assertEq(_vaultV2.balanceOf(WITHDRAWAL_QUEUE_PROXY), before_.queueShares);
        assertEq(_vaultV2.DOMAIN_SEPARATOR(), before_.domainSeparator);
        assertEq(_vaultV2.paused(), before_.paused);
        assertEq(_vaultV2.asset(), USDAT);
        assertEq(_vaultV2.getWithdrawalQueue(), WITHDRAWAL_QUEUE_PROXY);

        for (uint256 slot; slot < before_.legacySlots.length; ++slot) {
            bytes32 expected = slot == 5 ? bytes32(uint256(ELEVATED_DEPOSIT_FEE_BPS)) : before_.legacySlots[slot];
            assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(slot)), expected);
        }

        assertEq(_mirror.balance(), uint256(before_.legacySlots[8]));
        assertEq(_mirror.vestingAmount(), uint256(before_.legacySlots[1]));
        assertEq(_mirror.lastDistributionTimestamp(), uint256(before_.legacySlots[2]));
        assertEq(_mirror.vestingPeriod(), uint256(before_.legacySlots[3]));
        assertEq(_mirror.MAX_REWARDS_BPS(), MAX_MIRROR_REWARDS_BPS);
        assertEq(_mirror.maxRewardsBps(), uint256(before_.legacySlots[9]));
        assertLe(_mirror.maxRewardsBps(), _mirror.MAX_REWARDS_BPS());
        assertEq(_mirror.getUnvestedAmount(), before_.unvestedStrc);
        assertTrue(_mirror.seeded());
        assertFalse(_mirror.retired());

        assertEq(address(_vaultV2.strcMirrorModule()), address(_mirror));
        assertEq(address(_vaultV2.strconModule()), address(_module));
        assertEq(address(_vaultV2.executionPolicy()), address(_policy));
        assertEq(_vaultV2.recoveryAddress(), RECOVERY_ADDRESS);
        assertEq(_vaultV2.surplusSource(), SURPLUS_SOURCE);
        assertEq(_vaultV2.baseRedemptionFeeBps(), BASE_REDEMPTION_FEE_BPS);
        assertEq(_vaultV2.elevatedRedemptionFeeBps(), ELEVATED_REDEMPTION_FEE_BPS);
        assertEq(_vaultV2.elevatedDepositFeeBps(), ELEVATED_DEPOSIT_FEE_BPS);
        assertEq(_vaultV2.migrationToleranceBps(), MIGRATION_TOLERANCE_BPS);
        assertEq(_vaultV2.surplusVestingAmount(), 0);
        assertEq(_vaultV2.surplusVestingStartTimestamp(), 0);
        assertEq(_vaultV2.surplusVestingPeriod(), 3 days);
        assertEq(_vaultV2.regularModeValidUntil(), 0);
        assertEq(uint256(_vaultV2.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));

        assertEq(_policy.executionVehicle(), EXECUTION_VEHICLE);
        assertEq(_policy.executionToleranceBps(), EXECUTION_TOLERANCE_BPS);
        (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated) = _policy.executionCapacity();
        assertEq(maximum, EXECUTION_CAPACITY);
        assertEq(available, EXECUTION_CAPACITY);
        assertEq(refillPerDay, EXECUTION_REFILL_PER_DAY);
        assertEq(lastUpdated, uint64(block.timestamp));

        uint256 expectedSlotTen = uint256(uint160(RECOVERY_ADDRESS))
            | (uint256(IStakedUSDat.MarketMode.Elevated) << 160) | (uint256(BASE_REDEMPTION_FEE_BPS) << 168)
            | (uint256(ELEVATED_REDEMPTION_FEE_BPS) << 184);
        uint256 expectedSlotSeventeen = uint256(uint160(address(_policy))) | (uint256(MIGRATION_TOLERANCE_BPS) << 160);
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(10))), bytes32(expectedSlotTen));
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(11))), bytes32(uint256(uint160(address(_mirror)))));
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(12))), bytes32(uint256(uint160(address(_module)))));
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(13))), bytes32(0));
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(14))), bytes32(0));
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(15))), bytes32(uint256(3 days)));
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(16))), bytes32(uint256(uint160(SURPLUS_SOURCE))));
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(17))), bytes32(expectedSlotSeventeen));
        assertEq(vm.load(STAKED_USDAT_PROXY, bytes32(uint256(18))), bytes32(0));
    }

    function _snapshotQueueV1() private view returns (QueueSnapshot memory snapshot) {
        snapshot.nextTokenId = _queueV1.nextTokenId();
        snapshot.pendingCount = _queueV1.pendingCount();
        snapshot.totalSupply = _queueV1.totalSupply();
        snapshot.usdatCustody = IERC20(USDAT).balanceOf(WITHDRAWAL_QUEUE_PROXY);
        snapshot.shareCustody = IERC20(STAKED_USDAT_PROXY).balanceOf(WITHDRAWAL_QUEUE_PROXY);
        snapshot.paused = _queueV1.paused();
        _fillQueueSnapshot(snapshot);
    }

    function _snapshotQueueV2() private view returns (QueueSnapshot memory snapshot) {
        snapshot.nextTokenId = _queueV2.nextTokenId();
        snapshot.pendingCount = uint256(vm.load(WITHDRAWAL_QUEUE_PROXY, bytes32(uint256(2))));
        snapshot.totalSupply = _queueV2.totalSupply();
        snapshot.usdatCustody = IERC20(USDAT).balanceOf(WITHDRAWAL_QUEUE_PROXY);
        snapshot.shareCustody = IERC20(STAKED_USDAT_PROXY).balanceOf(WITHDRAWAL_QUEUE_PROXY);
        snapshot.paused = _queueV2.paused();
        _fillQueueSnapshot(snapshot);
    }

    function _fillQueueSnapshot(QueueSnapshot memory snapshot) private view {
        snapshot.requestWords = new bytes32[](snapshot.nextTokenId * REQUEST_WORDS);
        snapshot.owners = new address[](snapshot.nextTokenId);
        snapshot.approvals = new address[](snapshot.nextTokenId);
        snapshot.exists = new bool[](snapshot.nextTokenId);
        snapshot.enumeration = new uint256[](snapshot.totalSupply);

        uint256 pending;
        uint256 existing;
        uint256 escrowedShares;
        uint256 claimableUsdat;

        for (uint256 tokenId; tokenId < snapshot.nextTokenId; ++tokenId) {
            bytes32 base = keccak256(abi.encode(tokenId, uint256(0)));
            for (uint256 word; word < REQUEST_WORDS; ++word) {
                snapshot.requestWords[tokenId * REQUEST_WORDS + word] =
                    vm.load(WITHDRAWAL_QUEUE_PROXY, bytes32(uint256(base) + word));
            }

            uint256 shares = uint256(snapshot.requestWords[tokenId * REQUEST_WORDS]);
            uint256 usdatOwed = uint256(snapshot.requestWords[tokenId * REQUEST_WORDS + 1]);
            uint256 status = uint256(snapshot.requestWords[tokenId * REQUEST_WORDS + 4]);
            if (status == 0 || status > CLAIMED_STATUS) revert InvalidLegacyRequest(tokenId, status);

            if (status == REQUESTED_STATUS || status == IN_PROGRESS_STATUS) {
                ++pending;
                escrowedShares += shares;
            } else if (status == PROCESSED_STATUS) {
                claimableUsdat += usdatOwed;
            }

            (bool exists, address owner) = _ownerOf(tokenId);
            snapshot.exists[tokenId] = exists;
            snapshot.owners[tokenId] = owner;
            if (exists) {
                snapshot.approvals[tokenId] = _getApproved(tokenId);
                ++existing;
            }
        }

        for (uint256 index; index < snapshot.totalSupply; ++index) {
            snapshot.enumeration[index] = _tokenByIndex(index);
        }

        assertEq(snapshot.pendingCount, pending);
        assertEq(snapshot.totalSupply, existing);
        assertGe(snapshot.shareCustody, escrowedShares);
        assertGe(snapshot.usdatCustody, claimableUsdat);
    }

    function _assertQueueUnchanged(QueueSnapshot memory before_) private view {
        _assertQueueState(before_, false);
    }

    function _resetLegacyInProgressRequestsIfAny(QueueSnapshot memory before_) private {
        for (uint256 tokenId; tokenId < before_.nextTokenId; ++tokenId) {
            uint256 status = uint256(before_.requestWords[tokenId * REQUEST_WORDS + 4]);
            if (status != IN_PROGRESS_STATUS) continue;

            vm.prank(OPERATOR);
            _queueV2.resetLegacyInProgressRequest(tokenId);
        }

        _assertQueueState(before_, true);
    }

    function _assertQueueState(QueueSnapshot memory before_, bool legacyRequestsReset) private view {
        assertEq(_implementationOf(WITHDRAWAL_QUEUE_PROXY), address(_queueImplementation));
        assertEq(_queueV2.nextTokenId(), before_.nextTokenId);
        assertEq(uint256(vm.load(WITHDRAWAL_QUEUE_PROXY, bytes32(uint256(2)))), before_.pendingCount);
        assertEq(_queueV2.totalSupply(), before_.totalSupply);
        assertEq(IERC20(USDAT).balanceOf(WITHDRAWAL_QUEUE_PROXY), before_.usdatCustody);
        assertEq(IERC20(STAKED_USDAT_PROXY).balanceOf(WITHDRAWAL_QUEUE_PROXY), before_.shareCustody);
        assertEq(_queueV2.paused(), before_.paused);

        for (uint256 tokenId; tokenId < before_.nextTokenId; ++tokenId) {
            bytes32 base = keccak256(abi.encode(tokenId, uint256(0)));
            for (uint256 word; word < REQUEST_WORDS; ++word) {
                bytes32 expected = before_.requestWords[tokenId * REQUEST_WORDS + word];
                if (
                    legacyRequestsReset && word == 4
                        && uint256(before_.requestWords[tokenId * REQUEST_WORDS + 4]) == IN_PROGRESS_STATUS
                ) {
                    expected = bytes32(REQUESTED_STATUS);
                }
                assertEq(vm.load(WITHDRAWAL_QUEUE_PROXY, bytes32(uint256(base) + word)), expected);
            }

            (bool exists, address owner) = _ownerOf(tokenId);
            assertEq(exists, before_.exists[tokenId]);
            assertEq(owner, before_.owners[tokenId]);
            if (exists) assertEq(_getApproved(tokenId), before_.approvals[tokenId]);
        }

        for (uint256 index; index < before_.totalSupply; ++index) {
            assertEq(_queueV2.tokenByIndex(index), before_.enumeration[index]);
        }
    }

    function _assertV2Roles() private view {
        assertTrue(_vaultV2.hasRole(_vaultV2.DEFAULT_ADMIN_ROLE(), TIMELOCK));
        assertTrue(_vaultV2.hasRole(_vaultV2.PARAMETER_MANAGER_ROLE(), PARAMETER_MANAGER));
        assertTrue(_vaultV2.hasRole(_vaultV2.MARKET_MODE_MANAGER_ROLE(), MARKET_MODE_MANAGER));
        assertTrue(_vaultV2.hasRole(_vaultV2.OPERATOR_ROLE(), OPERATOR));
        assertTrue(_vaultV2.hasRole(_vaultV2.SURPLUS_MANAGER_ROLE(), SURPLUS_MANAGER));
        assertTrue(_vaultV2.hasRole(_vaultV2.BLACKLISTER_ROLE(), BLACKLISTER));
        assertTrue(_vaultV2.hasRole(_vaultV2.ENFORCER_ROLE(), ENFORCER));
        assertTrue(_vaultV2.hasRole(_vaultV2.PAUSER_ROLE(), PAUSER));
        assertTrue(_vaultV2.hasRole(_vaultV2.UNPAUSER_ROLE(), UNPAUSER));

        assertTrue(_queueV2.hasRole(_queueV2.DEFAULT_ADMIN_ROLE(), TIMELOCK));
        assertTrue(_queueV2.hasRole(_queueV2.OPERATOR_ROLE(), OPERATOR));
        assertTrue(_queueV2.hasRole(_queueV2.ENFORCER_ROLE(), ENFORCER));
        assertTrue(_queueV2.hasRole(_queueV2.PAUSER_ROLE(), PAUSER));
        assertTrue(_queueV2.hasRole(_queueV2.UNPAUSER_ROLE(), UNPAUSER));
    }

    function _assertDeploymentCodeHashes() private view {
        assertEq(_tradeExecutionLogic.codehash, _codeHashes.tradeExecutionLogic);
        assertEq(address(_priceOracle).codehash, _codeHashes.priceOracle);
        assertEq(address(_mirror).codehash, _codeHashes.mirror);
        assertEq(address(_module).codehash, _codeHashes.module);
        assertEq(address(_policy).codehash, _codeHashes.policy);
        assertEq(address(_vaultImplementation).codehash, _codeHashes.vaultImplementation);
        assertEq(address(_queueImplementation).codehash, _codeHashes.queueImplementation);
        assertNotEq(_codeHashes.tradeExecutionLogic, bytes32(0));
        assertNotEq(_codeHashes.vaultImplementation, bytes32(0));
        assertNotEq(_codeHashes.queueImplementation, bytes32(0));
    }

    function _readRound(address feed) private view returns (OracleRound memory round) {
        (round.roundId, round.answer, round.startedAt,, round.answeredInRound) = IPriceOracle(feed).latestRoundData();
    }

    function _refreshOracleRounds() private {
        _mockFreshRound(_legacyFeed, _legacyRound);
        _mockFreshRound(PRIMARY_FEED, _primaryRound);
        _mockFreshRound(REFERENCE_FEED, _referenceRound);
    }

    function _mockFreshRound(address feed, OracleRound storage round) private {
        vm.mockCall(
            feed,
            abi.encodeCall(IPriceOracle.latestRoundData, ()),
            abi.encode(round.roundId, round.answer, round.startedAt, block.timestamp, round.answeredInRound)
        );
    }

    function _ownerOf(uint256 tokenId) private view returns (bool exists, address owner) {
        (bool success, bytes memory result) =
            WITHDRAWAL_QUEUE_PROXY.staticcall(abi.encodeWithSignature("ownerOf(uint256)", tokenId));
        if (success) {
            exists = true;
            owner = abi.decode(result, (address));
        }
    }

    function _getApproved(uint256 tokenId) private view returns (address approved) {
        (bool success, bytes memory result) =
            WITHDRAWAL_QUEUE_PROXY.staticcall(abi.encodeWithSignature("getApproved(uint256)", tokenId));
        require(success, "getApproved failed");
        approved = abi.decode(result, (address));
    }

    function _tokenByIndex(uint256 index) private view returns (uint256 tokenId) {
        (bool success, bytes memory result) =
            WITHDRAWAL_QUEUE_PROXY.staticcall(abi.encodeWithSignature("tokenByIndex(uint256)", index));
        require(success, "tokenByIndex failed");
        tokenId = abi.decode(result, (uint256));
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _callAs(address caller, address target, bytes memory data) private {
        vm.prank(caller);
        (bool success, bytes memory result) = target.call(data);
        if (!success) revert ExternalCallFailed(target, result);
    }
}
