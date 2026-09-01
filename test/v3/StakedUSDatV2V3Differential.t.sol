// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StakedUSDat as StakedUSDatV2} from "../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConModule} from "../../src/v2/interfaces/modules/ISTRConModule.sol";
import {ISTRConPriceOracle} from "../../src/v2/interfaces/oracles/ISTRConPriceOracle.sol";
import {IWithdrawalQueueERC721} from "../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {StakedUSDat} from "../../src/v3/StakedUSDat.sol";
import {StakedUSDatEligibleIncomeModule} from "../../src/v3/StakedUSDatEligibleIncomeModule.sol";
import {IEligibleIncomeAccounting} from "../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {IEligibleIncomeAdapter} from "../../src/v3/interfaces/IEligibleIncomeAdapter.sol";
import {BoundMirrorModuleMock, V2InitializationHelper} from "../v2/helpers/V2InitializationHelper.sol";

contract DifferentialToken is ERC20 {
    uint8 private immutable _TOKEN_DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _TOKEN_DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _TOKEN_DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function isFrozen(address) external pure returns (bool) {
        return false;
    }
}

contract DifferentialMirror is BoundMirrorModuleMock {
    constructor(address vault) BoundMirrorModuleMock(vault) {}

    function recognizedValue() external pure returns (uint256) {
        return 0;
    }

    function balance() external pure returns (uint256) {
        return 0;
    }
}

contract DifferentialPriceOracle is ISTRConPriceOracle {
    bool public unhealthy;

    function setUnhealthy(bool value) external {
        unhealthy = value;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getPrice() external view returns (uint256) {
        require(!unhealthy, "unhealthy");
        return 100e8;
    }
}

contract DifferentialSTRConModule is ISTRConModule {
    error Unauthorized();

    bytes32 private constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");

    address public immutable override VAULT;
    address public immutable override ASSET;
    ISTRConPriceOracle public override oracle;
    uint256 private _balance;

    constructor(address vault, address asset_, ISTRConPriceOracle oracle_) {
        VAULT = vault;
        ASSET = asset_;
        oracle = oracle_;
    }

    function seed(uint256 amount) external {
        _balance = amount;
    }

    function recognizedValue() external view returns (uint256) {
        return Math.mulDiv(_balance, oracle.getPrice(), 1e20);
    }

    function balance() external view returns (uint256) {
        return _balance;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function getPrice() external view returns (uint256) {
        return oracle.getPrice();
    }

    function buy(uint256 amount) external {
        if (msg.sender != VAULT) revert Unauthorized();
        _balance += amount;
    }

    function sell(uint256 amount) external {
        if (msg.sender != VAULT) revert Unauthorized();
        _balance -= amount;
    }

    function setOracle(address newOracle) external {
        if (!IAccessControl(VAULT).hasRole(PARAMETER_MANAGER_ROLE, msg.sender)) revert Unauthorized();
        oracle = ISTRConPriceOracle(newOracle);
    }
}

contract DifferentialIncomeAdapter is IEligibleIncomeAdapter {
    address public immutable override asset;
    uint256 public index = 1e18;

    constructor(address asset_) {
        asset = asset_;
    }

    function setIndex(uint256 newIndex) external {
        index = newIndex;
    }

    function rawIndex() external view returns (uint256) {
        return index;
    }
}

contract DifferentialWithdrawalQueue {
    uint256 public nextRequestId;

    function addRequest(address, uint256, uint256) external returns (uint256 tokenId) {
        tokenId = nextRequestId++;
    }

    function redeemBatch(IStakedUSDat vault, uint256 shares, uint256 minSharePrice)
        external
        returns (IStakedUSDat.RedemptionResult result, uint256 net)
    {
        vault.beginRedemptionBatch();
        (result, net) = vault.redeemQueuedShares(shares, minSharePrice);
        vault.endRedemptionBatch();
    }
}

contract StakedUSDatDifferentialTest is Test {
    uint256 private constant INITIAL_CASH = 100_000e6;
    uint256 private constant INITIAL_POSITION = 10_000e18;
    uint16 private constant MAX_GROWTH_BPS = 2_000;
    address private constant VEHICLE = address(0x1002);

    struct System {
        StakedUSDatV2 vault;
        DifferentialMirror mirror;
        DifferentialSTRConModule module;
        DifferentialWithdrawalQueue queue;
        DifferentialIncomeAdapter adapter;
        StakedUSDatEligibleIncomeModule incomeModule;
    }

    DifferentialToken private usdat;
    DifferentialToken private strcon;
    System private v2;
    System private v3;
    address private alice = makeAddr("alice");
    address private operator = makeAddr("operator");
    bytes32[19] private preUpgradeSlots;

    function setUp() public {
        vm.warp(1_000_000);
        usdat = new DifferentialToken("USDat", "USDat", 6);
        strcon = new DifferentialToken("STRCon", "STRCon", 18);
        usdat.mint(address(this), 1_000_000e6);
        usdat.mint(VEHICLE, 1_000_000e6);
        strcon.mint(VEHICLE, 1_000_000e18);

        v2 = _deployV2();
        v3 = _deployV2();
        for (uint256 slot; slot < preUpgradeSlots.length; ++slot) {
            preUpgradeSlots[slot] = vm.load(address(v3.vault), bytes32(slot));
        }
        _upgradeToV3(v3);

        vm.startPrank(VEHICLE);
        usdat.approve(address(v2.vault), type(uint256).max);
        usdat.approve(address(v3.vault), type(uint256).max);
        strcon.approve(address(v2.vault), type(uint256).max);
        strcon.approve(address(v3.vault), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Directed Compatibility ============

    function test_populatedUpgradePreservesEveryLinearSlotAndCoreView() public view {
        for (uint256 slot; slot < preUpgradeSlots.length; ++slot) {
            assertEq(vm.load(address(v3.vault), bytes32(slot)), preUpgradeSlots[slot]);
        }
        _assertCoreEquivalent();
        assertEq(address(StakedUSDat(address(v3.vault)).eligibleIncomeModule()), address(v3.incomeModule));
    }

    function test_flatIncomeIndexPreservesDepositTransferAndQueuedRedemptionBehavior() public {
        uint256 assets = 2_500e6;
        usdat.approve(address(v2.vault), assets);
        usdat.approve(address(v3.vault), assets);
        uint256 v2Shares = v2.vault.deposit(assets, address(this));
        uint256 v3Shares = v3.vault.deposit(assets, address(this));
        assertEq(v3Shares, v2Shares);

        uint256 transferShares = 100e18;
        assertEq(v2.vault.transfer(alice, transferShares), v3.vault.transfer(alice, transferShares));
        vm.prank(alice);
        uint256 v2Request = v2.vault.requestRedeem(20e18, 0);
        vm.prank(alice);
        uint256 v3Request = v3.vault.requestRedeem(20e18, 0);
        assertEq(v3Request, v2Request);

        (IStakedUSDat.RedemptionResult v2Result, uint256 v2Net) = v2.queue.redeemBatch(v2.vault, 20e18, 0);
        (IStakedUSDat.RedemptionResult v3Result, uint256 v3Net) = v3.queue.redeemBatch(v3.vault, 20e18, 0);

        assertEq(uint256(v3Result), uint256(v2Result));
        assertEq(v3Net, v2Net);
        assertEq(usdat.balanceOf(address(v3.queue)), usdat.balanceOf(address(v2.queue)));
        _assertCoreEquivalent();
    }

    function test_flatIncomeIndexPreservesBuySellAndSurplusBehavior() public {
        v2.vault.buy(1_000e6, 10e18, VEHICLE, block.timestamp);
        v3.vault.buy(1_000e6, 10e18, VEHICLE, block.timestamp);
        _assertCoreEquivalent();

        v2.vault.sell(5e18, 500e6, VEHICLE, block.timestamp);
        v3.vault.sell(5e18, 500e6, VEHICLE, block.timestamp);
        _assertCoreEquivalent();

        usdat.approve(address(v2.vault), 100e6);
        usdat.approve(address(v3.vault), 100e6);
        v2.vault.transferInSurplus(100e6);
        v3.vault.transferInSurplus(100e6);
        _assertCoreEquivalent();
    }

    function test_incomeMaterializationChangesOnlyTheExternalLedger() public {
        v3.adapter.setIndex(1.1e18);
        uint256 assets = 1_000e6;
        usdat.approve(address(v2.vault), assets);
        usdat.approve(address(v3.vault), assets);

        uint256 v2Shares = v2.vault.deposit(assets, address(this));
        uint256 v3Shares = v3.vault.deposit(assets, address(this));

        assertEq(v3Shares, v2Shares);
        assertGt(v3.incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad, 0);
        _assertCoreEquivalent();
    }

    function test_partialCrystallizationDoesNotPerturbBaseVaultAccounting() public {
        v3.adapter.setIndex(1.1e18);
        v2.vault.sell(1e18, 100e6, VEHICLE, block.timestamp);
        v3.vault.sell(1e18, 100e6, VEHICLE, block.timestamp);

        IEligibleIncomeAccounting.EligibleIncomeState memory state = v3.incomeModule.eligibleIncomeState();
        assertGt(state.eligibleUnitsPerSUSDatShareWad, 0);
        assertEq(state.crystallizationNonce, 1);
        assertGt(state.crystallizedValueOffsetWad, 0);
        _assertCoreEquivalent();
    }

    function test_reviewModeCreatesOnlyTheIntendedIssuanceDivergence() public {
        v3.incomeModule.enterSTRConIncomeReview(keccak256("differential review"));

        assertEq(v2.vault.maxDeposit(alice), type(uint256).max);
        assertEq(v3.vault.maxDeposit(alice), 0);
        assertEq(v2.vault.maxMint(alice), type(uint256).max);
        assertEq(v3.vault.maxMint(alice), 0);

        assertTrue(v2.vault.transfer(alice, 1e18));
        assertTrue(v3.vault.transfer(alice, 1e18));
        assertEq(v3.vault.balanceOf(alice), v2.vault.balanceOf(alice));
        assertEq(v3.vault.totalAssets(), v2.vault.totalAssets());
        assertEq(v3.vault.totalSupply(), v2.vault.totalSupply());
    }

    function test_parameterMediationPreservesFeesAndMarketModes() public {
        v2.vault.setRedemptionFees(20, 30);
        v3.incomeModule
            .configureEligibleIncomeDependency(
                address(v3.vault), abi.encodeCall(IStakedUSDat.setRedemptionFees, (20, 30))
            );
        v2.vault.setElevatedDepositFee(40);
        v3.incomeModule
            .configureEligibleIncomeDependency(
                address(v3.vault), abi.encodeCall(IStakedUSDat.setElevatedDepositFee, (40))
            );
        v2.vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);
        v3.vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);
        _assertCoreEquivalent();

        v2.vault.authorizeRegularMode(uint64(block.timestamp + 1 hours));
        v3.vault.authorizeRegularMode(uint64(block.timestamp + 1 hours));
        _assertCoreEquivalent();
    }

    function test_pauseAndRestrictionBoundariesRemainEquivalent() public {
        v2.vault.pause();
        v3.vault.pause();
        assertEq(v2.vault.maxDeposit(alice), v3.vault.maxDeposit(alice));
        assertEq(v2.vault.maxMint(alice), v3.vault.maxMint(alice));
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        v2.vault.transfer(alice, 1e18);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        v3.vault.transfer(alice, 1e18);

        v2.vault.unpause();
        v3.vault.unpause();
        v2.vault.addToBlacklist(alice);
        v3.vault.addToBlacklist(alice);
        assertEq(v2.vault.maxDeposit(alice), v3.vault.maxDeposit(alice));
        assertEq(v2.vault.isRestricted(alice), v3.vault.isRestricted(alice));
        _assertCoreEquivalent();
    }

    // ============ Fuzzed Compatibility ============

    function testFuzz_flatIndexDepositsRemainEquivalent(uint96 rawAssets) public {
        uint256 assets = bound(uint256(rawAssets), 1e6, 25_000e6);
        usdat.approve(address(v2.vault), assets);
        usdat.approve(address(v3.vault), assets);

        assertEq(v2.vault.previewDeposit(assets), v3.vault.previewDeposit(assets));
        uint256 v2Shares = v2.vault.deposit(assets, address(this));
        uint256 v3Shares = v3.vault.deposit(assets, address(this));
        assertEq(v3Shares, v2Shares);
        _assertCoreEquivalent();
    }

    function testFuzz_flatIndexTransfersAndAllowancesRemainEquivalent(uint96 rawTransfer, uint96 rawDelegated) public {
        uint256 startingBalance = v2.vault.balanceOf(address(this));
        uint256 transferShares = bound(uint256(rawTransfer), 1, startingBalance / 4);
        uint256 delegatedShares = bound(uint256(rawDelegated), 1, startingBalance / 4);

        assertEq(v2.vault.transfer(alice, transferShares), v3.vault.transfer(alice, transferShares));
        assertEq(v2.vault.approve(operator, delegatedShares), v3.vault.approve(operator, delegatedShares));
        assertEq(v2.vault.allowance(address(this), operator), v3.vault.allowance(address(this), operator));

        vm.startPrank(operator);
        assertEq(
            v2.vault.transferFrom(address(this), alice, delegatedShares),
            v3.vault.transferFrom(address(this), alice, delegatedShares)
        );
        vm.stopPrank();

        assertEq(v2.vault.allowance(address(this), operator), v3.vault.allowance(address(this), operator));
        _assertCoreEquivalent();
    }

    function testFuzz_flatIndexQueuedRedemptionsRemainEquivalent(uint96 rawShares) public {
        uint256 shares =
            bound(uint256(rawShares), v2.vault.MIN_REQUEST_SHARES(), v2.vault.balanceOf(address(this)) / 10);
        v2.vault.transfer(alice, shares);
        v3.vault.transfer(alice, shares);

        vm.prank(alice);
        uint256 v2Request = v2.vault.requestRedeem(shares, 0);
        vm.prank(alice);
        uint256 v3Request = v3.vault.requestRedeem(shares, 0);
        assertEq(v3Request, v2Request);

        (IStakedUSDat.RedemptionResult v2Result, uint256 v2Net) = v2.queue.redeemBatch(v2.vault, shares, 0);
        (IStakedUSDat.RedemptionResult v3Result, uint256 v3Net) = v3.queue.redeemBatch(v3.vault, shares, 0);

        assertEq(uint256(v3Result), uint256(v2Result));
        assertEq(v3Net, v2Net);
        assertEq(usdat.balanceOf(address(v3.queue)), usdat.balanceOf(address(v2.queue)));
        _assertCoreEquivalent();
    }

    function testFuzz_mixedIncomeDepositBuySellSequenceRemainsVaultEquivalent(
        uint96 rawAssets,
        uint16 rawGrowthBps,
        uint16 rawBuyUnits,
        uint16 rawSellUnits
    ) public {
        uint256 assets = bound(uint256(rawAssets), 1e6, 25_000e6);
        uint256 growthBps = bound(uint256(rawGrowthBps), 0, MAX_GROWTH_BPS);
        uint256 buyUnits = bound(uint256(rawBuyUnits), 1, 100);
        uint256 sellUnits = bound(uint256(rawSellUnits), 1, buyUnits);
        v3.adapter.setIndex(1e18 + growthBps * 1e14);
        usdat.approve(address(v2.vault), assets);
        usdat.approve(address(v3.vault), assets);

        assertEq(v2.vault.deposit(assets, address(this)), v3.vault.deposit(assets, address(this)));
        v2.vault.buy(buyUnits * 100e6, buyUnits * 1e18, VEHICLE, block.timestamp);
        v3.vault.buy(buyUnits * 100e6, buyUnits * 1e18, VEHICLE, block.timestamp);
        v2.vault.sell(sellUnits * 1e18, sellUnits * 100e6, VEHICLE, block.timestamp);
        v3.vault.sell(sellUnits * 1e18, sellUnits * 100e6, VEHICLE, block.timestamp);

        _assertCoreEquivalent();
    }

    // ============ Helpers ============

    function _deployV2() private returns (System memory system) {
        system.queue = new DifferentialWithdrawalQueue();
        StakedUSDatV2 implementation = new StakedUSDatV2(IWithdrawalQueueERC721(address(system.queue)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDatV2.initialize, (address(this), IERC20(address(usdat))))
        );
        system.vault = StakedUSDatV2(address(proxy));
        system.mirror = new DifferentialMirror(address(system.vault));
        system.module =
            new DifferentialSTRConModule(address(system.vault), address(strcon), new DifferentialPriceOracle());
        V2InitializationHelper.initialize(system.vault, address(system.mirror), address(system.module), 5, 10, 0);

        usdat.approve(address(system.vault), INITIAL_CASH);
        system.vault.deposit(INITIAL_CASH, address(this));
        system.module.seed(INITIAL_POSITION);
        strcon.mint(address(system.vault), INITIAL_POSITION);
        system.mirror.retire();
    }

    function _upgradeToV3(System storage system) private {
        system.adapter = new DifferentialIncomeAdapter(address(strcon));
        system.incomeModule = new StakedUSDatEligibleIncomeModule(address(system.vault), address(this));
        system.vault.grantRole(system.vault.PARAMETER_MANAGER_ROLE(), address(system.incomeModule));
        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(address(system.queue)));
        system.vault
            .upgradeToAndCall(
                address(implementation),
                abi.encodeCall(
                    StakedUSDat.initializeV3,
                    (
                        system.incomeModule,
                        IEligibleIncomeAccounting.EligibleIncomeConfig({
                            adapter: system.adapter,
                            configManager: address(this),
                            maxUnreviewedGrowthBps: MAX_GROWTH_BPS
                        })
                    )
                )
            );
    }

    function _assertCoreEquivalent() private view {
        assertEq(v3.vault.totalAssets(), v2.vault.totalAssets());
        assertEq(v3.vault.totalSupply(), v2.vault.totalSupply());
        assertEq(v3.vault.balanceOf(address(this)), v2.vault.balanceOf(address(this)));
        assertEq(v3.vault.balanceOf(alice), v2.vault.balanceOf(alice));
        assertEq(v3.vault.usdatBalance(), v2.vault.usdatBalance());
        assertEq(v3.module.balance(), v2.module.balance());
        assertEq(strcon.balanceOf(address(v3.vault)), strcon.balanceOf(address(v2.vault)));
        assertEq(v3.vault.previewRedeem(100e18), v2.vault.previewRedeem(100e18));
        assertEq(v3.vault.baseRedemptionFeeBps(), v2.vault.baseRedemptionFeeBps());
        assertEq(v3.vault.elevatedRedemptionFeeBps(), v2.vault.elevatedRedemptionFeeBps());
        assertEq(v3.vault.elevatedDepositFeeBps(), v2.vault.elevatedDepositFeeBps());
        assertEq(v3.vault.depositFeeBps(), v2.vault.depositFeeBps());
        assertEq(v3.vault.redemptionFeeBps(), v2.vault.redemptionFeeBps());
        assertEq(uint256(v3.vault.marketMode()), uint256(v2.vault.marketMode()));
        assertEq(v3.vault.surplusVestingAmount(), v2.vault.surplusVestingAmount());
        assertEq(v3.vault.surplusVestingStartTimestamp(), v2.vault.surplusVestingStartTimestamp());
        assertEq(v3.vault.surplusVestingPeriod(), v2.vault.surplusVestingPeriod());
        assertEq(v3.vault.paused(), v2.vault.paused());
        assertEq(v3.vault.maxDeposit(address(this)), v2.vault.maxDeposit(address(this)));
        assertEq(v3.vault.maxMint(address(this)), v2.vault.maxMint(address(this)));
    }
}
