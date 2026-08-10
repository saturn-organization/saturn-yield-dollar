// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {StakedUSDat as StakedUSDatV1} from "../../../src/v1/StakedUSDat.sol";
import {IStrcPriceOracle as IStrcPriceOracleV1} from "../../../src/v1/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV1} from "../../../src/v1/interfaces/IWithdrawalQueueERC721.sol";
import {StakedUSDat as StakedUSDatV2} from "../../../src/v2/StakedUSDat.sol";
import {STRConExecutionPolicy} from "../../../src/v2/STRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IStrcPriceOracle} from "../../../src/v2/interfaces/oracles/IStrcPriceOracle.sol";
import {ISTRConPriceOracle} from "../../../src/v2/interfaces/oracles/ISTRConPriceOracle.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV2} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {STRCMirrorModule} from "../../../src/v2/modules/MirrorSTRC/STRCMirrorModule.sol";
import {STRConModule} from "../../../src/v2/modules/STRCon/STRConModule.sol";

interface IExpectedStakedUSDatV2Initializer {
    struct V2Config {
        address strcMirrorModule;
        address strconModule;
        address executionPolicy;
        address recoveryAddress;
        address executionVehicle;
        uint16 baseRedemptionFeeBps;
        uint16 elevatedRedemptionFeeBps;
        uint16 elevatedDepositFeeBps;
        uint16 executionToleranceBps;
        uint16 migrationToleranceBps;
        uint128 initialExecutionCapacity;
        uint128 initialExecutionRefillPerDay;
    }

    struct V2Roles {
        address parameterManager;
        address marketModeManager;
        address operator;
        address blacklister;
        address enforcer;
        address pauser;
        address unpauser;
    }

    function initializeV2(V2Config calldata config, V2Roles calldata roles) external;
}

contract ReinitializerUSDatMock is ERC20 {
    mapping(address account => bool frozen) private _frozen;

    constructor() ERC20("USDat", "USDat") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFrozen(address account, bool frozen) external {
        _frozen[account] = frozen;
    }

    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }
}

contract ReinitializerSTRCMock is ERC20 {
    constructor() ERC20("STRCon", "STRCon") {}
}

contract ReinitializerLegacyOracleMock {
    uint256 private immutable _PRICE;

    constructor(uint256 price) {
        _PRICE = price;
    }

    function getPrice() external view returns (uint256 price, uint8 decimals_) {
        return (_PRICE, 8);
    }
}

contract ReinitializerSTRConOracleMock is ISTRConPriceOracle {
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

contract StakedUSDatReinitializerTest is Test {
    uint256 private constant ORACLE_PRICE = 100e8;
    uint256 private constant DEPOSIT = 1_000e6;
    uint256 private constant REWARD = 200_000;

    ReinitializerUSDatMock private usdat;
    ReinitializerSTRCMock private strcon;
    ReinitializerLegacyOracleMock private legacyOracle;
    ReinitializerSTRConOracleMock private strconOracle;

    StakedUSDatV1 private vaultV1;
    StakedUSDatV2 private implementationV2;
    STRCMirrorModule private mirror;
    STRConModule private strconModule;
    ISTRConExecutionPolicy private executionPolicy;

    address private proxy;
    address private withdrawalQueue = makeAddr("withdrawalQueue");
    address private processor = makeAddr("processor");
    address private compliance = makeAddr("compliance");
    address private feeRecipient = makeAddr("feeRecipient");
    address private alice = makeAddr("alice");
    address private spender = makeAddr("spender");
    address private blacklisted = makeAddr("blacklisted");
    address private recovery = makeAddr("recovery");
    address private executionVehicle = makeAddr("executionVehicle");

    IExpectedStakedUSDatV2Initializer.V2Roles private roles;

    function setUp() public {
        vm.warp(100 days);

        usdat = new ReinitializerUSDatMock();
        strcon = new ReinitializerSTRCMock();
        legacyOracle = new ReinitializerLegacyOracleMock(ORACLE_PRICE);
        strconOracle = new ReinitializerSTRConOracleMock(ORACLE_PRICE);

        StakedUSDatV1 implementationV1 =
            new StakedUSDatV1(IStrcPriceOracleV1(address(legacyOracle)), IWithdrawalQueueV1(withdrawalQueue));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(implementationV1),
            abi.encodeCall(
                StakedUSDatV1.initialize, (address(this), processor, compliance, feeRecipient, IERC20(address(usdat)))
            )
        );

        proxy = address(vaultProxy);
        vaultV1 = StakedUSDatV1(proxy);
        implementationV2 = new StakedUSDatV2(IWithdrawalQueueV2(withdrawalQueue));
        mirror = new STRCMirrorModule(proxy, IStrcPriceOracle(address(legacyOracle)));
        strconModule = new STRConModule(proxy, address(strcon), strconOracle);
        executionPolicy = new STRConExecutionPolicy(proxy, strconModule);

        roles = IExpectedStakedUSDatV2Initializer.V2Roles({
            parameterManager: makeAddr("parameterManager"),
            marketModeManager: makeAddr("marketModeManager"),
            operator: makeAddr("operator"),
            blacklister: makeAddr("blacklister"),
            enforcer: makeAddr("enforcer"),
            pauser: makeAddr("pauser"),
            unpauser: makeAddr("unpauser")
        });

        usdat.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdat.approve(proxy, DEPOSIT);
        vaultV1.depositWithMinShares(DEPOSIT, alice, 0);
        vaultV1.approve(spender, 123e18);
        vm.stopPrank();

        vm.prank(compliance);
        vaultV1.addToBlacklist(blacklisted);

        vm.prank(processor);
        vaultV1.transferInRewards(REWARD);
        vm.warp(block.timestamp + 15 days);

        vm.prank(compliance);
        vaultV1.pause();
    }

    function test_initializeV2_AtomicallyPreservesAccountingAndInstallsV2State() public {
        uint256 navBefore = vaultV1.totalAssets();
        uint256 assetsBefore = vaultV1.convertToAssets(123e18);
        uint256 sharesBefore = vaultV1.convertToShares(25e6);
        uint256 unvestedBefore = vaultV1.getUnvestedAmount();
        uint256 supplyBefore = vaultV1.totalSupply();
        uint256 aliceSharesBefore = vaultV1.balanceOf(alice);
        uint256 allowanceBefore = vaultV1.allowance(alice, spender);
        uint256 nonceBefore = vaultV1.nonces(alice);
        bytes32[10] memory legacySlots = _legacySlots();

        _upgrade(_validConfig());

        StakedUSDatV2 vaultV2 = StakedUSDatV2(proxy);

        assertEq(vaultV2.totalAssets(), navBefore);
        assertEq(vaultV2.convertToAssets(123e18), assetsBefore);
        assertEq(vaultV2.convertToShares(25e6), sharesBefore);
        assertEq(mirror.getUnvestedAmount(), unvestedBefore);

        assertEq(mirror.balance(), uint256(legacySlots[8]));
        assertEq(mirror.vestingAmount(), uint256(legacySlots[1]));
        assertEq(mirror.lastDistributionTimestamp(), uint256(legacySlots[2]));
        assertEq(mirror.vestingPeriod(), uint256(legacySlots[3]));
        assertEq(mirror.maxRewardsBps(), uint256(legacySlots[9]));
        assertTrue(mirror.seeded());
        assertFalse(mirror.retired());

        assertEq(address(vaultV2.strcMirrorModule()), address(mirror));
        assertEq(address(vaultV2.strconModule()), address(strconModule));
        ISTRConExecutionPolicy configuredPolicy = vaultV2.executionPolicy();
        assertEq(address(configuredPolicy), address(executionPolicy));
        assertEq(configuredPolicy.VAULT(), proxy);
        assertEq(address(configuredPolicy.STRCON_MODULE()), address(strconModule));
        assertEq(vaultV2.recoveryAddress(), recovery);
        assertEq(configuredPolicy.executionVehicle(), executionVehicle);
        assertEq(vaultV2.baseRedemptionFeeBps(), 5);
        assertEq(vaultV2.elevatedRedemptionFeeBps(), 10);
        assertEq(vaultV2.elevatedDepositFeeBps(), 25);
        assertEq(configuredPolicy.executionToleranceBps(), 50);
        assertEq(vaultV2.migrationToleranceBps(), 50);
        assertEq(vaultV2.regularModeValidUntil(), 0);
        (
            uint128 executionCapacity,
            uint128 availableExecutionCapacity,
            uint128 executionRefillPerDay,
            uint64 executionCapacityLastUpdated
        ) = configuredPolicy.executionCapacity();
        assertEq(executionCapacity, 1_000_000e6);
        assertEq(availableExecutionCapacity, executionCapacity);
        assertEq(executionRefillPerDay, 100_000e6);
        assertEq(executionCapacityLastUpdated, uint64(block.timestamp));
        assertEq(uint256(vaultV2.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));
        assertEq(vaultV2.surplusVestingAmount(), 0);
        assertEq(vaultV2.surplusVestingStartTimestamp(), 0);
        assertEq(vaultV2.surplusVestingPeriod(), 3 days);

        assertTrue(vaultV2.paused());
        assertTrue(vaultV2.isBlacklisted(blacklisted));
        assertEq(vaultV2.usdatBalance(), uint256(legacySlots[7]));
        assertEq(vaultV2.totalSupply(), supplyBefore);
        assertEq(vaultV2.balanceOf(alice), aliceSharesBefore);
        assertEq(vaultV2.allowance(alice, spender), allowanceBefore);
        assertEq(vaultV2.nonces(alice), nonceBefore);
        assertTrue(vaultV2.hasRole(vaultV2.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(vaultV2.hasRole(keccak256("PROCESSOR_ROLE"), processor));
        assertTrue(vaultV2.hasRole(keccak256("COMPLIANCE_ROLE"), compliance));

        assertTrue(vaultV2.hasRole(vaultV2.PARAMETER_MANAGER_ROLE(), roles.parameterManager));
        assertTrue(vaultV2.hasRole(vaultV2.MARKET_MODE_MANAGER_ROLE(), roles.marketModeManager));
        assertTrue(vaultV2.hasRole(vaultV2.OPERATOR_ROLE(), roles.operator));
        assertTrue(vaultV2.hasRole(vaultV2.BLACKLISTER_ROLE(), roles.blacklister));
        assertTrue(vaultV2.hasRole(vaultV2.ENFORCER_ROLE(), roles.enforcer));
        assertTrue(vaultV2.hasRole(vaultV2.PAUSER_ROLE(), roles.pauser));
        assertTrue(vaultV2.hasRole(vaultV2.UNPAUSER_ROLE(), roles.unpauser));

        for (uint256 slot = 0; slot < legacySlots.length; slot++) {
            if (slot == 5) continue;
            assertEq(vm.load(proxy, bytes32(slot)), legacySlots[slot]);
        }
        assertEq(vm.load(proxy, bytes32(uint256(5))), bytes32(uint256(25)));
        assertEq(vm.load(proxy, bytes32(uint256(17))), bytes32(0));
    }

    function test_initializeV2_InvalidInputRollsBackUpgradeAndCanRetry() public {
        IExpectedStakedUSDatV2Initializer.V2Config memory config = _validConfig();
        config.migrationToleranceBps = 501;

        vm.expectRevert(IStakedUSDat.InvalidMigrationTolerance.selector);
        _upgrade(config);

        assertEq(vaultV1.getStrcOracle(), address(legacyOracle));
        assertFalse(mirror.seeded());

        config.migrationToleranceBps = 50;
        config.executionVehicle = address(0);

        vm.expectRevert(IStakedUSDat.InvalidZeroAddress.selector);
        _upgrade(config);

        assertEq(vaultV1.getStrcOracle(), address(legacyOracle));
        assertFalse(mirror.seeded());

        config.executionVehicle = executionVehicle;
        _upgrade(config);

        assertTrue(mirror.seeded());
        assertEq(StakedUSDatV2(proxy).migrationToleranceBps(), 50);
        assertEq(StakedUSDatV2(proxy).executionPolicy().executionVehicle(), executionVehicle);
    }

    function test_initializeV2_StartsElevatedAndRegularRequiresFreshAuthorization() public {
        _upgrade(_validConfig());

        StakedUSDatV2 vaultV2 = StakedUSDatV2(proxy);
        assertTrue(mirror.seeded());
        assertEq(vaultV2.regularModeValidUntil(), 0);
        assertEq(uint256(vaultV2.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));

        uint64 validUntil = uint64(block.timestamp + 8 hours);
        vm.prank(roles.marketModeManager);
        vaultV2.authorizeRegularMode(validUntil);

        assertEq(vaultV2.regularModeValidUntil(), validUntil);
        assertEq(uint256(vaultV2.marketMode()), uint256(IStakedUSDat.MarketMode.Regular));
    }

    function test_initializeV2_RejectsUnauthorizedUpgrade() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        _upgrade(_validConfig());

        assertEq(vaultV1.getStrcOracle(), address(legacyOracle));
        assertFalse(mirror.seeded());
    }

    function test_initializeV2_CanOnlyRunOnce() public {
        IExpectedStakedUSDatV2Initializer.V2Config memory config = _validConfig();
        _upgrade(config);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IExpectedStakedUSDatV2Initializer(proxy).initializeV2(config, roles);
    }

    function _upgrade(IExpectedStakedUSDatV2Initializer.V2Config memory config) private {
        vaultV1.upgradeToAndCall(
            address(implementationV2), abi.encodeCall(IExpectedStakedUSDatV2Initializer.initializeV2, (config, roles))
        );
    }

    function _validConfig() private view returns (IExpectedStakedUSDatV2Initializer.V2Config memory config) {
        config = IExpectedStakedUSDatV2Initializer.V2Config({
            strcMirrorModule: address(mirror),
            strconModule: address(strconModule),
            executionPolicy: address(executionPolicy),
            recoveryAddress: recovery,
            executionVehicle: executionVehicle,
            baseRedemptionFeeBps: 5,
            elevatedRedemptionFeeBps: 10,
            elevatedDepositFeeBps: 25,
            executionToleranceBps: 50,
            migrationToleranceBps: 50,
            initialExecutionCapacity: 1_000_000e6,
            initialExecutionRefillPerDay: 100_000e6
        });
    }

    function _legacySlots() private view returns (bytes32[10] memory slots) {
        for (uint256 slot = 0; slot < slots.length; slot++) {
            slots[slot] = vm.load(proxy, bytes32(slot));
        }
    }
}
