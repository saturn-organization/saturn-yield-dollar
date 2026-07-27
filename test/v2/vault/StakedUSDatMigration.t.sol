// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {StakedUSDat as StakedUSDatV1} from "../../../src/v1/StakedUSDat.sol";
import {IStrcPriceOracle as IStrcPriceOracleV1} from "../../../src/v1/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV1} from "../../../src/v1/interfaces/IWithdrawalQueueERC721.sol";
import {StakedUSDat as StakedUSDatV2} from "../../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IStrcPriceOracle} from "../../../src/v2/interfaces/oracles/IStrcPriceOracle.sol";
import {ISTRCMirrorModule} from "../../../src/v2/interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConPriceOracle} from "../../../src/v2/interfaces/oracles/ISTRConPriceOracle.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV2} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {STRCMirrorModule} from "../../../src/v2/modules/MirrorSTRC/STRCMirrorModule.sol";
import {STRConModule} from "../../../src/v2/modules/STRCon/STRConModule.sol";
import {STRConExecutionPolicy} from "../../../src/v2/STRConExecutionPolicy.sol";

contract MigrationUSDatMock is ERC20 {
    constructor() ERC20("USDat", "USDat") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function isFrozen(address) external pure returns (bool) {
        return false;
    }
}

contract MigrationSTRConMock is ERC20 {
    constructor() ERC20("STRCon", "STRCon") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MigrationLegacyOracleMock {
    uint256 private immutable _PRICE;

    constructor(uint256 price) {
        _PRICE = price;
    }

    function getPrice() external view returns (uint256 price, uint8 decimals_) {
        return (_PRICE, 8);
    }
}

contract MigrationSTRConOracleMock is ISTRConPriceOracle {
    uint256 private immutable _PRICE;

    constructor(uint256 price) {
        _PRICE = price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getPrice() external view returns (uint256) {
        return _PRICE;
    }
}

contract StakedUSDatMigrationTest is Test {
    struct Snapshot {
        uint256 nav;
        uint256 vaultUsdat;
        uint256 trackedUsdat;
        uint256 vaultStrcon;
        uint256 vehicleStrcon;
        uint256 vehicleAllowance;
        uint256 mirrorBalance;
        uint256 strconBalance;
        uint256 shareSupply;
        uint256 holderShares;
        bool mirrorRetired;
        uint128 capacityMaximum;
        uint128 capacityAvailable;
        uint128 capacityRefillPerDay;
        uint64 capacityLastUpdated;
    }

    uint256 private constant ORACLE_PRICE = 100e8;
    uint256 private constant CASH = 1_000e6;
    uint256 private constant MIRROR_REWARD = 200_000;
    uint256 private constant EXACT_STRCON = MIRROR_REWARD * 1e12;
    uint256 private constant UNRECOGNIZED_EXCESS = 7e18;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    MigrationUSDatMock private usdat;
    MigrationSTRConMock private strcon;
    MigrationLegacyOracleMock private legacyOracle;
    MigrationSTRConOracleMock private strconOracle;
    StakedUSDatV2 private vault;
    STRCMirrorModule private mirror;
    STRConModule private strconModule;
    ISTRConExecutionPolicy private executionPolicy;

    address private withdrawalQueue = makeAddr("migrationWithdrawalQueue");
    address private vehicle = makeAddr("migrationExecutionVehicle");
    address private recovery = makeAddr("migrationRecovery");
    address private unauthorized = makeAddr("migrationUnauthorized");

    event MigrationToleranceUpdated(uint16 oldBps, uint16 newBps);

    function setUp() public {
        vm.warp(100 days);

        usdat = new MigrationUSDatMock();
        strcon = new MigrationSTRConMock();
        legacyOracle = new MigrationLegacyOracleMock(ORACLE_PRICE);
        strconOracle = new MigrationSTRConOracleMock(ORACLE_PRICE);

        StakedUSDatV1 vaultV1 = _deployV1();
        address proxy = address(vaultV1);

        usdat.mint(address(this), CASH);
        usdat.approve(proxy, CASH);
        vaultV1.depositWithMinShares(CASH, address(this), 0);
        vaultV1.transferInRewards(MIRROR_REWARD);

        mirror = new STRCMirrorModule(proxy, IStrcPriceOracle(address(legacyOracle)));
        strconModule = new STRConModule(proxy, address(strcon), strconOracle);
        executionPolicy = new STRConExecutionPolicy(proxy, strconModule);
        vault = _upgrade(vaultV1, mirror, strconModule, executionPolicy);
    }

    function test_migrate_RequiresCompletedVestingPreservesNAVAndIsPermanentlyOneShot() public {
        strcon.mint(address(vault), UNRECOGNIZED_EXCESS);
        _fundVehicle(3 * EXACT_STRCON);

        Snapshot memory vestingState = _snapshot();
        vm.expectRevert(STRCMirrorModule.StillVesting.selector);
        vault.migrate(EXACT_STRCON, block.timestamp);
        _assertUnchanged(vestingState);

        _finishVesting();
        Snapshot memory beforeState = _snapshot();

        vault.migrate(EXACT_STRCON, block.timestamp);

        assertTrue(mirror.retired());
        assertEq(mirror.balance(), 0);
        assertEq(mirror.recognizedValue(), 0);
        assertEq(strconModule.balance(), EXACT_STRCON);
        assertEq(vault.totalAssets(), beforeState.nav);
        assertEq(strcon.balanceOf(address(vault)), beforeState.vaultStrcon + EXACT_STRCON);
        assertEq(strcon.balanceOf(vehicle), beforeState.vehicleStrcon - EXACT_STRCON);
        assertEq(strcon.allowance(vehicle, address(vault)), beforeState.vehicleAllowance - EXACT_STRCON);
        assertEq(vault.usdatBalance(), beforeState.trackedUsdat);
        assertEq(usdat.balanceOf(address(vault)), beforeState.vaultUsdat);
        assertEq(vault.totalSupply(), beforeState.shareSupply);
        assertEq(vault.balanceOf(address(this)), beforeState.holderShares);
        assertGe(strcon.balanceOf(address(vault)), strconModule.balance());

        // Even after the recognized STRCon position later reaches zero, the retired
        // fixed mirror permanently prevents a second migration.
        vm.prank(address(vault));
        strconModule.sell(EXACT_STRCON);
        Snapshot memory retiredState = _snapshot();

        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        vault.migrate(EXACT_STRCON, block.timestamp);
        _assertUnchanged(retiredState);
    }

    function test_migrate_EnforcesAdminPauseDeadlineAndNonzeroAmount() public {
        _fundVehicle(EXACT_STRCON);
        Snapshot memory beforeState = _snapshot();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.migrate(EXACT_STRCON, block.timestamp);

        vault.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.migrate(EXACT_STRCON, block.timestamp);
        vault.unpause();

        vm.expectRevert(IStakedUSDat.DeadlineExpired.selector);
        vault.migrate(EXACT_STRCON, block.timestamp - 1);

        vm.expectRevert(IStakedUSDat.ZeroAmount.selector);
        vault.migrate(0, block.timestamp);

        _assertUnchanged(beforeState);
    }

    function test_setMigrationTolerance_EnforcesRoleAndCapAndAllowsCapWhilePaused() public {
        assertEq(vault.migrationToleranceBps(), 0);
        assertEq(vault.MAX_MIGRATION_TOLERANCE_BPS(), 500);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setMigrationTolerance(500);

        vault.pause();
        vm.expectEmit(false, false, false, true, address(vault));
        emit MigrationToleranceUpdated(0, 500);
        vault.setMigrationTolerance(500);
        assertEq(vault.migrationToleranceBps(), 500);

        vm.expectRevert(IStakedUSDat.InvalidMigrationTolerance.selector);
        vault.setMigrationTolerance(501);
        assertEq(vault.migrationToleranceBps(), 500);
        vault.unpause();

        _finishVesting();
        uint256 navBefore = vault.totalAssets();
        uint256 permittedDelta = navBefore * 500 / BPS_DENOMINATOR;
        uint256 targetValue = mirror.recognizedValue() + permittedDelta;
        uint256 delivered = _strconForValue(targetValue);
        _fundVehicle(delivered);

        vault.migrate(delivered, block.timestamp);

        assertEq(vault.totalAssets(), navBefore + permittedDelta);
        assertTrue(mirror.retired());
        assertEq(strconModule.balance(), delivered);
    }

    function test_migrate_RequiresZeroInitialSTRConModuleBalance() public {
        _finishVesting();
        strcon.mint(address(vault), 1);
        vm.prank(address(vault));
        strconModule.buy(1);
        _fundVehicle(EXACT_STRCON);
        Snapshot memory beforeState = _snapshot();

        vm.expectRevert(IStakedUSDat.InvalidModule.selector);
        vault.migrate(EXACT_STRCON, block.timestamp);

        _assertUnchanged(beforeState);
    }

    function test_migrate_NAVMismatchAfterDeliveryAndModuleMutationsRollsBackEverything() public {
        _finishVesting();
        vault.setMigrationTolerance(100);

        uint256 navBefore = vault.totalAssets();
        uint256 permittedDelta = navBefore * 100 / BPS_DENOMINATOR;
        uint256 targetValue = mirror.recognizedValue() - permittedDelta - 1;
        uint256 delivered = _strconForValue(targetValue);
        _fundVehicle(delivered);
        Snapshot memory beforeState = _snapshot();

        vm.expectRevert(IStakedUSDat.MigrationNAVMismatch.selector);
        vault.migrate(delivered, block.timestamp);

        _assertUnchanged(beforeState);
        assertFalse(mirror.retired());
        assertEq(strconModule.balance(), 0);
    }

    function test_migrate_RejectsZeroNAVBeforePullingSTRCon() public {
        StakedUSDatV1 emptyV1 = _deployV1();
        address emptyProxy = address(emptyV1);
        STRCMirrorModule emptyMirror = new STRCMirrorModule(emptyProxy, IStrcPriceOracle(address(legacyOracle)));
        STRConModule emptyStrconModule = new STRConModule(emptyProxy, address(strcon), strconOracle);
        ISTRConExecutionPolicy emptyPolicy = new STRConExecutionPolicy(emptyProxy, emptyStrconModule);
        StakedUSDatV2 emptyVault = _upgrade(emptyV1, emptyMirror, emptyStrconModule, emptyPolicy);

        uint256 vehicleBalanceBefore = strcon.balanceOf(vehicle);
        vm.expectRevert(IStakedUSDat.ZeroNAV.selector);
        emptyVault.migrate(1, block.timestamp);

        assertFalse(emptyMirror.retired());
        assertEq(emptyMirror.balance(), 0);
        assertEq(emptyStrconModule.balance(), 0);
        assertEq(strcon.balanceOf(vehicle), vehicleBalanceBefore);
        assertEq(strcon.balanceOf(address(emptyVault)), 0);
    }

    function _deployV1() private returns (StakedUSDatV1 vaultV1) {
        StakedUSDatV1 implementationV1 =
            new StakedUSDatV1(IStrcPriceOracleV1(address(legacyOracle)), IWithdrawalQueueV1(withdrawalQueue));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementationV1),
            abi.encodeCall(
                StakedUSDatV1.initialize,
                (address(this), address(this), address(this), address(0), IERC20(address(usdat)))
            )
        );
        vaultV1 = StakedUSDatV1(address(proxy));
    }

    function _upgrade(
        StakedUSDatV1 vaultV1,
        STRCMirrorModule targetMirror,
        STRConModule targetStrconModule,
        ISTRConExecutionPolicy targetExecutionPolicy
    ) private returns (StakedUSDatV2 vaultV2) {
        StakedUSDatV2 implementationV2 = new StakedUSDatV2(IWithdrawalQueueV2(withdrawalQueue));
        IStakedUSDat.V2Config memory config = IStakedUSDat.V2Config({
            strcMirrorModule: ISTRCMirrorModule(address(targetMirror)),
            strconModule: targetStrconModule,
            executionPolicy: targetExecutionPolicy,
            recoveryAddress: recovery,
            executionVehicle: vehicle,
            baseRedemptionFeeBps: 5,
            elevatedRedemptionFeeBps: 10,
            elevatedDepositFeeBps: 25,
            executionToleranceBps: 50,
            migrationToleranceBps: 0,
            initialExecutionCapacity: type(uint128).max,
            initialExecutionRefillPerDay: 0
        });
        IStakedUSDat.V2Roles memory roles = IStakedUSDat.V2Roles({
            parameterManager: address(this),
            marketModeManager: address(this),
            operator: address(this),
            blacklister: address(this),
            enforcer: address(this),
            pauser: address(this),
            unpauser: address(this)
        });

        vaultV1.upgradeToAndCall(address(implementationV2), abi.encodeCall(IStakedUSDat.initializeV2, (config, roles)));
        vaultV2 = StakedUSDatV2(address(vaultV1));
    }

    function _finishVesting() private {
        vm.warp(mirror.lastDistributionTimestamp() + mirror.vestingPeriod());
        assertEq(mirror.getUnvestedAmount(), 0);
    }

    function _fundVehicle(uint256 amount) private {
        strcon.mint(vehicle, amount);
        vm.prank(vehicle);
        strcon.approve(address(vault), amount);
    }

    function _strconForValue(uint256 value) private pure returns (uint256) {
        return value * 1e10;
    }

    function _snapshot() private view returns (Snapshot memory state) {
        state.nav = vault.totalAssets();
        state.vaultUsdat = usdat.balanceOf(address(vault));
        state.trackedUsdat = vault.usdatBalance();
        state.vaultStrcon = strcon.balanceOf(address(vault));
        state.vehicleStrcon = strcon.balanceOf(vehicle);
        state.vehicleAllowance = strcon.allowance(vehicle, address(vault));
        state.mirrorBalance = mirror.balance();
        state.strconBalance = strconModule.balance();
        state.shareSupply = vault.totalSupply();
        state.holderShares = vault.balanceOf(address(this));
        state.mirrorRetired = mirror.retired();
        (state.capacityMaximum, state.capacityAvailable, state.capacityRefillPerDay, state.capacityLastUpdated) =
            executionPolicy.executionCapacity();
    }

    function _assertUnchanged(Snapshot memory state) private view {
        assertEq(vault.totalAssets(), state.nav);
        assertEq(usdat.balanceOf(address(vault)), state.vaultUsdat);
        assertEq(vault.usdatBalance(), state.trackedUsdat);
        assertEq(strcon.balanceOf(address(vault)), state.vaultStrcon);
        assertEq(strcon.balanceOf(vehicle), state.vehicleStrcon);
        assertEq(strcon.allowance(vehicle, address(vault)), state.vehicleAllowance);
        assertEq(mirror.balance(), state.mirrorBalance);
        assertEq(strconModule.balance(), state.strconBalance);
        assertEq(vault.totalSupply(), state.shareSupply);
        assertEq(vault.balanceOf(address(this)), state.holderShares);
        assertEq(mirror.retired(), state.mirrorRetired);
        (uint128 capacityMaximum, uint128 capacityAvailable, uint128 capacityRefillPerDay, uint64 capacityLastUpdated) =
            executionPolicy.executionCapacity();
        assertEq(capacityMaximum, state.capacityMaximum);
        assertEq(capacityAvailable, state.capacityAvailable);
        assertEq(capacityRefillPerDay, state.capacityRefillPerDay);
        assertEq(capacityLastUpdated, state.capacityLastUpdated);
    }
}
