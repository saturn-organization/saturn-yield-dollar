// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StakedUSDat as StakedUSDatV2} from "../../../src/v2/StakedUSDat.sol";
import {StakedUSDat} from "../../../src/v3/StakedUSDat.sol";
import {TrancheAccountant} from "../../../src/v3/TrancheAccountant.sol";
import {TrancheShare} from "../../../src/v3/TrancheShare.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {StakedUSDatEligibleIncomeModule} from "../../../src/v3/StakedUSDatEligibleIncomeModule.sol";
import {V2InitializationHelper} from "../../v2/helpers/V2InitializationHelper.sol";
import {
    IncomeTokenMock,
    IncomeMirrorMock,
    IncomePriceOracleMock,
    IncomeModuleMock,
    IncomeAdapterMock
} from "../helpers/StakedUSDatEligibleIncomeFixture.sol";

contract TrancheAccountantHandler is Test {
    uint256 private constant WAD = 1e18;

    TrancheAccountant public immutable accountant;
    StakedUSDat public immutable vault;
    TrancheShare public immutable senior;
    TrancheShare public immutable junior;
    IncomeAdapterMock public immutable adapter;
    IncomePriceOracleMock public immutable priceOracle;
    address public peer;

    uint256 public calls;
    uint256[13] public attemptedActions;
    uint256[13] public successfulActions;
    uint256[13] public skippedActions;
    int256 public seniorSupplyDelta;
    int256 public juniorSupplyDelta;

    constructor(
        TrancheAccountant accountant_,
        StakedUSDat vault_,
        IncomeAdapterMock adapter_,
        IncomePriceOracleMock priceOracle_
    ) {
        accountant = accountant_;
        vault = vault_;
        senior = accountant_.SENIOR_TOKEN();
        junior = accountant_.JUNIOR_TOKEN();
        adapter = adapter_;
        priceOracle = priceOracle_;
        vault_.approve(address(accountant_), type(uint256).max);
        senior.approve(address(accountant_), type(uint256).max);
        junior.approve(address(accountant_), type(uint256).max);
    }

    // ============ Handler Actions ============

    function setPeer(address peer_) external {
        require(peer == address(0) && peer_ != address(0));
        peer = peer_;
    }

    function depositJunior(uint256 seed) external {
        _recordAttempt(0);
        uint256 balance = vault.balanceOf(address(this));
        uint256 capacity = accountant.maxDepositJunior(address(this));
        uint256 limit = capacity < balance ? capacity : balance;
        limit /= 2;
        if (limit == 0) return _recordSkip(0);
        uint256 assets = 1 + seed % limit;
        if (accountant.previewDepositJunior(assets) == 0) return _recordSkip(0);
        uint256 shares = accountant.depositJunior(assets, address(this), 0, block.timestamp);
        juniorSupplyDelta += int256(shares);
        _recordSuccess(0);
    }

    function depositSenior(uint256 seed) external {
        _recordAttempt(1);
        uint256 capacity = accountant.maxDepositSenior(address(this));
        uint256 available = vault.balanceOf(address(this));
        uint256 limit = capacity < available ? capacity : available;
        limit /= 2;
        if (limit == 0) return _recordSkip(1);
        uint256 assets = 1 + seed % limit;
        if (accountant.previewDepositSenior(assets) == 0) return _recordSkip(1);
        uint256 shares = accountant.depositSenior(assets, address(this), 0, block.timestamp);
        seniorSupplyDelta += int256(shares);
        _recordSuccess(1);
    }

    function mintJunior(uint256 seed) external {
        _recordAttempt(2);
        uint256 balance = vault.balanceOf(address(this));
        uint256 capacity = accountant.maxMintJunior(address(this));
        uint256 affordable = balance == 0 ? 0 : accountant.previewDepositJunior(balance);
        uint256 limit = capacity < affordable ? capacity : affordable;
        limit /= 2;
        if (limit == 0) return _recordSkip(2);
        uint256 shares = 1 + seed % limit;
        accountant.mintJunior(shares, address(this), balance, block.timestamp);
        juniorSupplyDelta += int256(shares);
        _recordSuccess(2);
    }

    function mintSenior(uint256 seed) external {
        _recordAttempt(3);
        uint256 balance = vault.balanceOf(address(this));
        uint256 capacity = accountant.maxMintSenior(address(this));
        uint256 affordable = balance == 0 ? 0 : accountant.previewDepositSenior(balance);
        uint256 limit = capacity < affordable ? capacity : affordable;
        limit /= 2;
        if (limit == 0) return _recordSkip(3);
        uint256 shares = 1 + seed % limit;
        accountant.mintSenior(shares, address(this), balance, block.timestamp);
        seniorSupplyDelta += int256(shares);
        _recordSuccess(3);
    }

    function redeemSenior(uint256 seed) external {
        _recordAttempt(5);
        uint256 available = accountant.maxRedeemSenior(address(this));
        available /= 2;
        if (available == 0) return _recordSkip(5);
        uint256 shares = 1 + seed % available;
        if (accountant.previewRedeemSenior(shares) == 0) return _recordSkip(5);
        accountant.redeemSenior(shares, address(this), address(this), 0, block.timestamp);
        seniorSupplyDelta -= int256(shares);
        _recordSuccess(5);
    }

    function redeemJunior(uint256 seed) external {
        _recordAttempt(4);
        uint256 available = accountant.maxRedeemJunior(address(this));
        available /= 2;
        if (available == 0) return _recordSkip(4);
        uint256 shares = 1 + seed % available;
        if (accountant.previewRedeemJunior(shares) == 0) return _recordSkip(4);
        accountant.redeemJunior(shares, address(this), address(this), 0, block.timestamp);
        juniorSupplyDelta -= int256(shares);
        _recordSuccess(4);
    }

    function withdrawSenior(uint256 seed) external {
        _recordAttempt(7);
        uint256 available = accountant.maxWithdrawSenior(address(this));
        available /= 2;
        if (available == 0) return _recordSkip(7);
        uint256 assets = 1 + seed % available;
        if (accountant.previewWithdrawSenior(assets) == 0) return _recordSkip(7);
        uint256 shares = accountant.withdrawSenior(
            assets, address(this), address(this), senior.balanceOf(address(this)), block.timestamp
        );
        seniorSupplyDelta -= int256(shares);
        _recordSuccess(7);
    }

    function withdrawJunior(uint256 seed) external {
        _recordAttempt(6);
        uint256 available = accountant.maxWithdrawJunior(address(this));
        available /= 2;
        if (available == 0) return _recordSkip(6);
        uint256 assets = 1 + seed % available;
        if (accountant.previewWithdrawJunior(assets) == 0) return _recordSkip(6);
        uint256 shares = accountant.withdrawJunior(
            assets, address(this), address(this), junior.balanceOf(address(this)), block.timestamp
        );
        juniorSupplyDelta -= int256(shares);
        _recordSuccess(6);
    }

    function donate(uint256 seed) external {
        _recordAttempt(8);
        uint256 balance = vault.balanceOf(address(this));
        if (balance == 0) return _recordSkip(8);
        uint256 assets = 1 + seed % balance;
        require(vault.transfer(address(accountant), assets));
        _recordSuccess(8);
    }

    function transferSenior(uint256 seed) external {
        _recordAttempt(10);
        uint256 balance = senior.balanceOf(address(this));
        if (balance == 0) return _recordSkip(10);
        require(senior.transfer(peer, 1 + seed % balance));
        _recordSuccess(10);
    }

    function transferJunior(uint256 seed) external {
        _recordAttempt(9);
        uint256 balance = junior.balanceOf(address(this));
        if (balance == 0) return _recordSkip(9);
        require(junior.transfer(peer, 1 + seed % balance));
        _recordSuccess(9);
    }

    function exitFullStack(uint256 seed) external {
        _recordAttempt(11);
        uint256 seniorSupply = senior.totalSupply();
        uint256 juniorSupply = junior.totalSupply();
        if (seniorSupply == 0 || juniorSupply == 0) return _recordSkip(11);
        uint256 maxSeniorFraction = senior.balanceOf(address(this)) * WAD / seniorSupply;
        uint256 maxJuniorFraction = junior.balanceOf(address(this)) * WAD / juniorSupply;
        uint256 limit = maxSeniorFraction < maxJuniorFraction ? maxSeniorFraction : maxJuniorFraction;
        limit /= 2;
        if (limit == 0) return _recordSkip(11);
        uint256 fraction = 1 + seed % limit;
        (, uint256 seniorShares, uint256 juniorShares) = accountant.exitFullStack(
            fraction, address(this), address(this), type(uint256).max, type(uint256).max, 0, block.timestamp
        );
        seniorSupplyDelta -= int256(seniorShares);
        juniorSupplyDelta -= int256(juniorShares);
        _recordSuccess(11);
    }

    function advanceIncome(uint16 seed) external {
        _recordAttempt(12);
        uint256 growthBps = 1 + uint256(seed) % 500;
        uint256 oldIndex = adapter.index();
        uint256 oldPrice = priceOracle.price();
        adapter.setIndex(oldIndex + oldIndex * growthBps / 10_000);
        priceOracle.setPrice(oldPrice + oldPrice * growthBps / 10_000);
        accountant.syncIncome();
        _recordSuccess(12);
    }

    // ============ Handler Bookkeeping ============

    function _recordAttempt(uint256 action) private {
        ++attemptedActions[action];
    }

    function _recordSuccess(uint256 action) private {
        ++calls;
        ++successfulActions[action];
    }

    function _recordSkip(uint256 action) private {
        ++skippedActions[action];
    }
}

contract TrancheAccountantInvariantTest is StdInvariant, Test {
    uint256 private constant CASH = 100_000e6;
    uint256 private constant POSITION = 10_000e18;

    IncomeTokenMock private usdat;
    IncomeTokenMock private strcon;
    IncomeMirrorMock private mirror;
    IncomePriceOracleMock private priceOracle;
    IncomeModuleMock private strconModule;
    IncomeAdapterMock private adapter;
    StakedUSDat private vault;
    StakedUSDatEligibleIncomeModule private incomeModule;
    TrancheAccountant private accountant;
    TrancheShare private senior;
    TrancheShare private junior;
    TrancheAccountantHandler private handlerA;
    TrancheAccountantHandler private handlerB;
    address private vehicle = makeAddr("vehicle");
    uint256 private trackedVaultShares;
    uint256 private initialSeniorSupply;
    uint256 private initialJuniorSupply;

    // ============ Setup ============

    function setUp() public {
        vm.warp(1_000_000);
        usdat = new IncomeTokenMock("USDat", "USDat", 6);
        strcon = new IncomeTokenMock("STRCon", "STRCon", 18);
        IWithdrawalQueueERC721 queue = IWithdrawalQueueERC721(makeAddr("v3InvariantQueue"));
        StakedUSDatV2 implementation = new StakedUSDatV2(queue);
        StakedUSDatV2 vaultV2 = StakedUSDatV2(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(StakedUSDatV2.initialize, (address(this), IERC20(address(usdat))))
                )
            )
        );
        mirror = new IncomeMirrorMock(address(vaultV2));
        priceOracle = new IncomePriceOracleMock();
        strconModule = new IncomeModuleMock(address(vaultV2), address(strcon), priceOracle);
        V2InitializationHelper.initialize(vaultV2, address(mirror), address(strconModule), 5, 10, 0);
        vaultV2.grantRole(vaultV2.OPERATOR_ROLE(), address(this));

        usdat.mint(address(this), CASH);
        usdat.approve(address(vaultV2), type(uint256).max);
        vaultV2.deposit(CASH, address(this));
        strconModule.seed(POSITION);
        strcon.mint(address(vaultV2), POSITION);
        mirror.retire();

        adapter = new IncomeAdapterMock(address(strcon));
        incomeModule = new StakedUSDatEligibleIncomeModule(address(vaultV2), address(this));
        vaultV2.grantRole(vaultV2.PARAMETER_MANAGER_ROLE(), address(incomeModule));
        StakedUSDat v3Implementation = new StakedUSDat(queue);
        vaultV2.upgradeToAndCall(
            address(v3Implementation),
            abi.encodeCall(
                StakedUSDat.initializeV3,
                (
                    incomeModule,
                    IEligibleIncomeAccounting.EligibleIncomeConfig({
                        adapter: adapter, configManager: address(this), maxUnreviewedGrowthBps: 2_000
                    })
                )
            )
        );
        vault = StakedUSDat(address(vaultV2));

        usdat.mint(vehicle, 2_000_000e6);
        vm.prank(vehicle);
        usdat.approve(address(vault), type(uint256).max);
        incomeModule.configureEligibleIncomeDependency(
            address(vault.executionPolicy()), abi.encodeCall(ISTRConExecutionPolicy.setExecutionVehicle, (vehicle))
        );

        accountant = new TrancheAccountant(vault, incomeModule, 5_000, 1.5e18, 500_000e6, address(this), address(this));
        senior = accountant.SENIOR_TOKEN();
        junior = accountant.JUNIOR_TOKEN();
        vault.approve(address(accountant), type(uint256).max);
        uint256 juniorAssets = vault.balanceOf(address(this)) / 10;
        accountant.depositJunior(juniorAssets, address(this), 0, block.timestamp);
        accountant.depositSenior(juniorAssets * 2, address(this), 0, block.timestamp);
        initialSeniorSupply = senior.totalSupply();
        initialJuniorSupply = junior.totalSupply();

        handlerA = new TrancheAccountantHandler(accountant, vault, adapter, priceOracle);
        handlerB = new TrancheAccountantHandler(accountant, vault, adapter, priceOracle);
        handlerA.setPeer(address(handlerB));
        handlerB.setPeer(address(handlerA));
        require(vault.transfer(address(handlerA), vault.balanceOf(address(this)) / 3));
        require(vault.transfer(address(handlerB), vault.balanceOf(address(this)) / 3));
        require(senior.transfer(address(handlerA), senior.balanceOf(address(this)) / 3));
        require(senior.transfer(address(handlerB), senior.balanceOf(address(this)) / 3));
        require(junior.transfer(address(handlerA), junior.balanceOf(address(this)) / 3));
        require(junior.transfer(address(handlerB), junior.balanceOf(address(this)) / 3));
        trackedVaultShares = vault.balanceOf(address(this)) + vault.balanceOf(address(handlerA))
            + vault.balanceOf(address(handlerB)) + accountant.backingAssets();

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = TrancheAccountantHandler.depositJunior.selector;
        selectors[1] = TrancheAccountantHandler.depositSenior.selector;
        selectors[2] = TrancheAccountantHandler.mintJunior.selector;
        selectors[3] = TrancheAccountantHandler.mintSenior.selector;
        selectors[4] = TrancheAccountantHandler.redeemJunior.selector;
        selectors[5] = TrancheAccountantHandler.redeemSenior.selector;
        selectors[6] = TrancheAccountantHandler.withdrawJunior.selector;
        selectors[7] = TrancheAccountantHandler.withdrawSenior.selector;
        selectors[8] = TrancheAccountantHandler.donate.selector;
        selectors[9] = TrancheAccountantHandler.transferJunior.selector;
        selectors[10] = TrancheAccountantHandler.transferSenior.selector;
        selectors[11] = TrancheAccountantHandler.exitFullStack.selector;
        selectors[12] = TrancheAccountantHandler.advanceIncome.selector;
        targetContract(address(handlerA));
        targetContract(address(handlerB));
        targetSelector(FuzzSelector({addr: address(handlerA), selectors: selectors}));
        targetSelector(FuzzSelector({addr: address(handlerB), selectors: selectors}));
    }

    // ============ Invariant Properties ============

    function invariant_incomeBearingCohortNeverExceedsCustody() public view {
        assertLe(accountant.incomeBearingBackingAssets(), accountant.backingAssets());
    }

    function invariant_vaultSharesAreConservedAcrossAllActors() public view {
        assertEq(
            vault.balanceOf(address(this)) + vault.balanceOf(address(handlerA)) + vault.balanceOf(address(handlerB))
                + accountant.backingAssets(),
            trackedVaultShares
        );
    }

    function invariant_classSuppliesEqualAllHolderBalances() public view {
        assertEq(
            int256(senior.totalSupply()),
            int256(initialSeniorSupply) + handlerA.seniorSupplyDelta() + handlerB.seniorSupplyDelta()
        );
        assertEq(
            int256(junior.totalSupply()),
            int256(initialJuniorSupply) + handlerA.juniorSupplyDelta() + handlerB.juniorSupplyDelta()
        );
        assertEq(
            senior.totalSupply(),
            senior.balanceOf(address(this)) + senior.balanceOf(address(handlerA)) + senior.balanceOf(address(handlerB))
        );
        assertEq(
            junior.totalSupply(),
            junior.balanceOf(address(this)) + junior.balanceOf(address(handlerA)) + junior.balanceOf(address(handlerB))
        );
    }

    function invariant_seniorClaimZeroStateMatchesSeniorSupplyZeroState() public view {
        assertEq(accountant.seniorClaimValue() == 0, senior.totalSupply() == 0);
    }

    function invariant_seniorSupplyAlwaysRequiresJuniorSupply() public view {
        assertTrue(junior.totalSupply() != 0 || senior.totalSupply() == 0);
    }

    function invariant_fullStackPreviewMatchesIndependentProRataBounds() public view {
        _assertFullStackPreviewBounded(1);
        _assertFullStackPreviewBounded(0.5e18);
        _assertFullStackPreviewBounded(1e18);
    }

    // ============ Independent Preview Check ============

    function _assertFullStackPreviewBounded(uint256 fractionWad) private view {
        (uint256 assets, uint256 seniorShares, uint256 juniorShares) = accountant.previewFullStackExit(fractionWad);
        assertEq(assets, Math.mulDiv(accountant.backingAssets(), fractionWad, 1e18));
        assertEq(seniorShares, Math.mulDiv(senior.totalSupply(), fractionWad, 1e18, Math.Rounding.Ceil));
        assertEq(juniorShares, Math.mulDiv(junior.totalSupply(), fractionWad, 1e18, Math.Rounding.Ceil));
        assertLe(assets, accountant.backingAssets());
        assertLe(seniorShares, senior.totalSupply());
        assertLe(juniorShares, junior.totalSupply());
    }

    // ============ Handler Reachability ============

    function test_handlerActions_AllSucceedUnderValidPreconditions() public {
        assertGt(vault.balanceOf(address(handlerA)), 0, "handler has no vault shares");
        assertGt(accountant.maxDepositJunior(address(handlerA)), 0, "handler has no Junior capacity");
        handlerA.depositJunior(type(uint256).max);
        handlerA.depositSenior(type(uint256).max);
        handlerA.mintJunior(type(uint256).max);
        handlerA.mintSenior(type(uint256).max);
        handlerA.redeemJunior(type(uint256).max);
        handlerA.redeemSenior(type(uint256).max);
        handlerA.withdrawJunior(type(uint256).max);
        handlerA.withdrawSenior(type(uint256).max);
        handlerA.donate(type(uint256).max);
        handlerA.transferJunior(type(uint256).max);
        handlerA.transferSenior(type(uint256).max);
        handlerA.exitFullStack(type(uint256).max);
        handlerA.advanceIncome(type(uint16).max);

        for (uint256 action; action < 13; ++action) {
            assertEq(handlerA.attemptedActions(action), 1);
            assertEq(
                handlerA.successfulActions(action), 1, string.concat("handler action failed: ", vm.toString(action))
            );
            assertEq(handlerA.skippedActions(action), 0);
        }
    }
}
