// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IAccountingModule} from "../../../src/v2/interfaces/modules/IAccountingModule.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {ITradableModule} from "../../../src/v2/interfaces/modules/ITradableModule.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {BoundMirrorModuleMock, V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract BuyTokenMock is ERC20 {
    enum TransferBehavior {
        STANDARD,
        RECIPIENT_SHORTFALL,
        REVERT_TRANSFER
    }

    error ConfiguredTransferFailure();

    uint8 private immutable _TOKEN_DECIMALS;
    TransferBehavior private _behavior;
    address private _affectedSender;
    uint256 private _shortfall;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _TOKEN_DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _TOKEN_DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function isFrozen(address) external pure returns (bool) {
        return false;
    }

    function configureTransferBehavior(TransferBehavior behavior, address affectedSender, uint256 shortfall) external {
        _behavior = behavior;
        _affectedSender = affectedSender;
        _shortfall = shortfall;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || from != _affectedSender) {
            super._update(from, to, value);
            return;
        }

        if (_behavior == TransferBehavior.REVERT_TRANSFER) revert ConfiguredTransferFailure();

        if (_behavior == TransferBehavior.RECIPIENT_SHORTFALL) {
            uint256 shortfall = _shortfall;
            super._update(from, to, value - shortfall);
            super._update(from, address(0), shortfall);
            return;
        }

        super._update(from, to, value);
    }
}

contract BuyMirrorModuleMock is IAccountingModule, BoundMirrorModuleMock {
    error PricingFailed();

    uint256 private _balance;
    bool private _pricingFails;

    constructor(address vault) BoundMirrorModuleMock(vault) {}

    function configure(uint256 newBalance, bool pricingFails) external {
        _balance = newBalance;
        _pricingFails = pricingFails;
    }

    function recognizedValue() external view returns (uint256) {
        if (_balance == 0) return 0;
        if (_pricingFails) revert PricingFailed();
        return _balance;
    }

    function balance() external view returns (uint256) {
        return _balance;
    }
}

contract BuyTradableModuleMock is ITradableModule {
    error NotVault();
    error OracleFailed();
    error BuyFailed();
    error ConservativeOrderViolated();

    address private immutable _VAULT;
    address private immutable _ASSET;
    address private immutable _USDAT;

    uint256 private _balance;
    uint256 private _price;
    bool private _priceFails;
    bool private _buyFails;

    bool private _checkConservativeOrder;
    uint256 private _expectedTrackedUsdatAtBuy;
    uint256 private _expectedUsdatCustodyAtBuy;
    uint256 private _expectedAssetCustodyAtBuy;

    uint256 public lastBuyAmount;
    uint256 public trackedUsdatObservedAtBuy;
    uint256 public usdatCustodyObservedAtBuy;
    uint256 public assetCustodyObservedAtBuy;

    constructor(address vault_, address asset_, address usdat_, uint256 initialPrice) {
        _VAULT = vault_;
        _ASSET = asset_;
        _USDAT = usdat_;
        _price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function setPriceFails(bool shouldFail) external {
        _priceFails = shouldFail;
    }

    function setBuyFails(bool shouldFail) external {
        _buyFails = shouldFail;
    }

    function seedTrackedBalance(uint256 newBalance) external {
        _balance = newBalance;
    }

    function expectConservativeOrder(uint256 trackedUsdatAtBuy, uint256 usdatCustodyAtBuy, uint256 assetCustodyAtBuy)
        external
    {
        _checkConservativeOrder = true;
        _expectedTrackedUsdatAtBuy = trackedUsdatAtBuy;
        _expectedUsdatCustodyAtBuy = usdatCustodyAtBuy;
        _expectedAssetCustodyAtBuy = assetCustodyAtBuy;
    }

    function recognizedValue() external view returns (uint256) {
        uint256 currentBalance = _balance;
        if (currentBalance == 0) return 0;
        if (_priceFails) revert OracleFailed();
        return Math.mulDiv(currentBalance, _price, 1e20, Math.Rounding.Floor);
    }

    function balance() external view returns (uint256) {
        return _balance;
    }

    function VAULT() external view returns (address) {
        return _VAULT;
    }

    function ASSET() external view returns (address) {
        return _ASSET;
    }

    function asset() external view returns (address) {
        return _ASSET;
    }

    function getPrice() external view returns (uint256) {
        if (_priceFails) revert OracleFailed();
        return _price;
    }

    function buy(uint256 assetReceived) external {
        if (msg.sender != _VAULT) revert NotVault();
        if (_buyFails) revert BuyFailed();

        uint256 trackedUsdat = IStakedUSDat(_VAULT).usdatBalance();
        uint256 usdatCustody = IERC20(_USDAT).balanceOf(_VAULT);
        uint256 assetCustody = IERC20(_ASSET).balanceOf(_VAULT);

        if (
            _checkConservativeOrder
                && (trackedUsdat != _expectedTrackedUsdatAtBuy
                    || usdatCustody != _expectedUsdatCustodyAtBuy
                    || assetCustody != _expectedAssetCustodyAtBuy)
        ) {
            revert ConservativeOrderViolated();
        }

        lastBuyAmount = assetReceived;
        trackedUsdatObservedAtBuy = trackedUsdat;
        usdatCustodyObservedAtBuy = usdatCustody;
        assetCustodyObservedAtBuy = assetCustody;
        _balance += assetReceived;
    }

    function sell(uint256 assetDelivered) external {
        if (msg.sender != _VAULT) revert NotVault();
        _balance -= assetDelivered;
    }
}

contract StakedUSDatBuyTest is Test {
    struct Snapshot {
        uint256 vaultUsdat;
        uint256 trackedUsdat;
        uint256 vehicleUsdat;
        uint256 vaultStrcon;
        uint256 vehicleStrcon;
        uint256 moduleBalance;
        uint256 vehicleAllowance;
        uint256 shareBalance;
        uint256 shareSupply;
        uint256 surplusAmount;
        uint256 surplusStart;
        uint256 surplusSwept;
        uint128 capacityMaximum;
        uint128 capacityAvailable;
        uint128 capacityRefillPerDay;
        uint64 capacityLastUpdated;
    }

    uint256 private constant ORACLE_PRICE = 100e8;
    uint256 private constant CASH = 100_000e6;
    uint256 private constant VEHICLE_INVENTORY = 10_000e18;
    uint256 private constant AMOUNT_OUT = 100e18;
    uint128 private constant BOUNDARY_AMOUNT_IN = 10_500_000_000;
    uint256 private constant FAVORABLE_AMOUNT_IN = 9_900_000_000;
    uint256 private constant SURPLUS_SWEPT_SLOT = 18;

    BuyTokenMock private usdat;
    BuyTokenMock private strcon;
    BuyMirrorModuleMock private mirror;
    BuyTradableModuleMock private module;
    StakedUSDat private vault;
    ISTRConExecutionPolicy private policy;

    address private vehicle = makeAddr("executionVehicle");
    address private unauthorized = makeAddr("unauthorized");

    event AssetBought(
        address indexed module, address indexed vehicle, uint256 usdatPaid, uint256 assetReceived, uint256 oraclePrice
    );

    function setUp() public {
        vm.warp(1_000_000);

        usdat = new BuyTokenMock("USDat", "USDat", 6);
        strcon = new BuyTokenMock("STRCon", "STRCon", 18);

        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(makeAddr("buyWithdrawalQueue")));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        vault = StakedUSDat(address(proxy));

        mirror = new BuyMirrorModuleMock(address(vault));
        module = new BuyTradableModuleMock(address(vault), address(strcon), address(usdat), ORACLE_PRICE);
        V2InitializationHelper.initialize(vault, address(mirror), address(module), 5, 10, 25);
        policy = vault.executionPolicy();

        vault.grantRole(vault.OPERATOR_ROLE(), address(this));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.MARKET_MODE_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.PAUSER_ROLE(), address(this));
        vault.grantRole(vault.UNPAUSER_ROLE(), address(this));
        policy.setExecutionVehicle(vehicle);
        policy.setExecutionTolerance(500);

        usdat.mint(address(this), CASH);
        usdat.approve(address(vault), CASH);
        vault.deposit(CASH, address(this));

        strcon.mint(vehicle, VEHICLE_INVENTORY);
        vm.prank(vehicle);
        strcon.approve(address(vault), VEHICLE_INVENTORY);
    }

    function test_executionCapacity_InitializesFullyAvailable() public view {
        (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated) = policy.executionCapacity();

        assertEq(maximum, type(uint128).max);
        assertEq(available, maximum);
        assertEq(refillPerDay, 0);
        assertEq(lastUpdated, uint64(block.timestamp));
    }

    function test_buy_ConsumesGreaterOfActualUSDatAndCeilOracleNotional() public {
        policy.setExecutionCapacity(30_000e6, 0);

        vault.buy(FAVORABLE_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);
        (, uint128 afterFavorable,,) = policy.executionCapacity();
        assertEq(afterFavorable, 20_000e6);

        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);
        (, uint128 afterAdverse,,) = policy.executionCapacity();
        assertEq(afterAdverse, 9_500e6);
    }

    function test_buy_CeilRoundsOracleNotionalAgainstAvailableCapacity() public {
        policy.setExecutionCapacity(200e6, 0);

        vault.buy(100e6, 1e18 + 1, vehicle, block.timestamp);

        (, uint128 available,,) = policy.executionCapacity();
        assertEq(available, 99_999_999);
    }

    function test_buyAndSell_ConsumeOneSharedCapacityWithoutRefund() public {
        policy.setExecutionCapacity(25_000e6, 0);

        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);
        (, uint128 afterBuy,,) = policy.executionCapacity();
        assertEq(afterBuy, 14_500e6);

        vm.prank(vehicle);
        usdat.approve(address(vault), 9_500e6);
        vault.sell(AMOUNT_OUT, 9_500e6, vehicle, block.timestamp);

        (, uint128 afterSell,,) = policy.executionCapacity();
        assertEq(afterSell, 4_500e6);
    }

    function test_executionCapacity_RefillsLinearlyAtExactBoundary() public {
        policy.setExecutionCapacity(BOUNDARY_AMOUNT_IN, 8_640e6);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        (, uint128 availableAtEmpty,,) = policy.executionCapacity();
        assertEq(availableAtEmpty, 0);

        vm.warp(block.timestamp + 999);
        Snapshot memory beforeFailure = _snapshot(vehicle);
        vm.expectRevert(ISTRConExecutionPolicy.ExecutionCapacityExceeded.selector);
        vault.buy(100e6, 1e18, vehicle, block.timestamp);
        _assertUnchanged(beforeFailure, vehicle);

        (, uint128 availableBeforeBoundary,,) = policy.executionCapacity();
        assertEq(availableBeforeBoundary, 99_900_000);

        vm.warp(block.timestamp + 1);
        vault.buy(100e6, 1e18, vehicle, block.timestamp);

        (, uint128 availableAfterBoundary,,) = policy.executionCapacity();
        assertEq(availableAfterBoundary, 0);
    }

    function test_buy_InsufficientExecutionCapacityRollsBackEveryLeg() public {
        uint128 availableBefore = BOUNDARY_AMOUNT_IN - 1;
        policy.setExecutionCapacity(availableBefore, 0);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionCapacityExceeded.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
        (, uint128 availableAfter,,) = policy.executionCapacity();
        assertEq(availableAfter, availableBefore);
    }

    function test_buy_LaterFailureRollsBackConsumedExecutionCapacity() public {
        policy.setExecutionCapacity(BOUNDARY_AMOUNT_IN, 0);
        usdat.configureTransferBehavior(BuyTokenMock.TransferBehavior.REVERT_TRANSFER, address(vault), 0);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(BuyTokenMock.ConfiguredTransferFailure.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
        (, uint128 availableAfter,,) = policy.executionCapacity();
        assertEq(availableAfter, BOUNDARY_AMOUNT_IN);
    }

    function test_buy_RejectsExecutionVehicleChangedAfterApproval() public {
        address approvedVehicle = vehicle;
        address replacementVehicle = makeAddr("replacementVehicle");
        policy.setExecutionCapacity(BOUNDARY_AMOUNT_IN, 0);
        policy.setExecutionVehicle(replacementVehicle);
        Snapshot memory beforeState = _snapshot(replacementVehicle);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionVehicleMismatch.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, approvedVehicle, block.timestamp);

        _assertUnchanged(beforeState, replacementVehicle);
        assertEq(policy.executionVehicle(), replacementVehicle);
        (, uint128 availableAfter,,) = policy.executionCapacity();
        assertEq(availableAfter, BOUNDARY_AMOUNT_IN);
    }

    function test_setExecutionCapacity_AccruesOldRateThenClampsWithoutTopUp() public {
        policy.setExecutionCapacity(20_000e6, 8_640e6);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        vm.warp(block.timestamp + 1 hours);
        policy.setExecutionCapacity(15_000e6, 4_320e6);

        (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated) = policy.executionCapacity();
        assertEq(maximum, 15_000e6);
        assertEq(available, 9_860e6);
        assertEq(refillPerDay, 4_320e6);
        assertEq(lastUpdated, uint64(block.timestamp));

        policy.setExecutionCapacity(25_000e6, 4_320e6);
        (maximum, available, refillPerDay, lastUpdated) = policy.executionCapacity();
        assertEq(maximum, 25_000e6);
        assertEq(available, 9_860e6);
        assertEq(refillPerDay, 4_320e6);
        assertEq(lastUpdated, uint64(block.timestamp));

        policy.setExecutionCapacity(9_000e6, 4_320e6);
        (maximum, available, refillPerDay, lastUpdated) = policy.executionCapacity();
        assertEq(maximum, 9_000e6);
        assertEq(available, 9_000e6);
        assertEq(refillPerDay, 4_320e6);
        assertEq(lastUpdated, uint64(block.timestamp));
    }

    function test_setExecutionCapacity_ZeroDisablesTradingAndReenableDoesNotTopUp() public {
        policy.setExecutionCapacity(0, 0);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionCapacityExceeded.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);
        _assertUnchanged(beforeState, vehicle);

        policy.setExecutionCapacity(BOUNDARY_AMOUNT_IN, 0);
        Snapshot memory reenabledState = _snapshot(vehicle);
        vm.expectRevert(ISTRConExecutionPolicy.ExecutionCapacityExceeded.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);
        _assertUnchanged(reenabledState, vehicle);
    }

    function test_buy_SettlesExactDeltasConservativelyAndEmitsAtInclusiveDeadline() public {
        uint256 unrecognizedExcess = 7e18;
        strcon.mint(address(vault), unrecognizedExcess);
        Snapshot memory beforeState = _snapshot(vehicle);

        module.expectConservativeOrder(
            beforeState.trackedUsdat - BOUNDARY_AMOUNT_IN, beforeState.vaultUsdat, beforeState.vaultStrcon + AMOUNT_OUT
        );

        vm.expectEmit(true, true, false, true, address(vault));
        emit AssetBought(address(module), vehicle, BOUNDARY_AMOUNT_IN, AMOUNT_OUT, ORACLE_PRICE);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        assertEq(usdat.balanceOf(address(vault)), beforeState.vaultUsdat - BOUNDARY_AMOUNT_IN);
        assertEq(vault.usdatBalance(), beforeState.trackedUsdat - BOUNDARY_AMOUNT_IN);
        assertEq(usdat.balanceOf(vehicle), beforeState.vehicleUsdat + BOUNDARY_AMOUNT_IN);

        assertEq(strcon.balanceOf(address(vault)), beforeState.vaultStrcon + AMOUNT_OUT);
        assertEq(module.balance(), beforeState.moduleBalance + AMOUNT_OUT);
        assertEq(strcon.balanceOf(vehicle), beforeState.vehicleStrcon - AMOUNT_OUT);
        assertEq(strcon.balanceOf(address(vault)) - module.balance(), unrecognizedExcess);
        assertGe(usdat.balanceOf(address(vault)), vault.usdatBalance() + _remainingSurplus());
        assertGe(strcon.balanceOf(address(vault)), module.balance());

        assertEq(module.lastBuyAmount(), AMOUNT_OUT);
        assertEq(module.trackedUsdatObservedAtBuy(), beforeState.trackedUsdat - BOUNDARY_AMOUNT_IN);
        assertEq(module.usdatCustodyObservedAtBuy(), beforeState.vaultUsdat);
        assertEq(module.assetCustodyObservedAtBuy(), beforeState.vaultStrcon + AMOUNT_OUT);

        assertEq(vault.balanceOf(address(this)), beforeState.shareBalance);
        assertEq(vault.totalSupply(), beforeState.shareSupply);
    }

    function testFuzz_buy_ValidAmountsPreserveAccountingAndCustodyInvariants(uint96 rawAmountOut) public {
        uint256 amountOut = bound(uint256(rawAmountOut), 1e18, 500e18);
        uint256 amountIn = Math.mulDiv(amountOut, ORACLE_PRICE, 1e20, Math.Rounding.Floor);
        policy.setExecutionTolerance(0);

        Snapshot memory beforeState = _snapshot(vehicle);
        vault.buy(amountIn, amountOut, vehicle, block.timestamp);

        assertEq(usdat.balanceOf(address(vault)), beforeState.vaultUsdat - amountIn);
        assertEq(vault.usdatBalance(), beforeState.trackedUsdat - amountIn);
        assertEq(strcon.balanceOf(address(vault)), beforeState.vaultStrcon + amountOut);
        assertEq(module.balance(), beforeState.moduleBalance + amountOut);
        assertGe(usdat.balanceOf(address(vault)), vault.usdatBalance() + _remainingSurplus());
        assertGe(strcon.balanceOf(address(vault)), module.balance());
        assertEq(vault.balanceOf(address(this)), beforeState.shareBalance);
        assertEq(vault.totalSupply(), beforeState.shareSupply);
    }

    function test_buy_AllowsFavorablePriceInElevatedMode() public {
        policy.setExecutionTolerance(0);
        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);

        vault.buy(FAVORABLE_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp + 1);

        assertEq(vault.usdatBalance(), CASH - FAVORABLE_AMOUNT_IN);
        assertEq(module.balance(), AMOUNT_OUT);
    }

    function test_buy_PartiallySweepsVestedSurplusAndProtectsRemainingSurplus() public {
        uint256 surplus = 30e6;
        usdat.mint(address(this), surplus);
        usdat.approve(address(vault), surplus);
        vault.transferInSurplus(surplus);

        vm.warp(block.timestamp + 1 days);
        uint256 unvested = vault.getUnvestedSurplus();
        uint256 released = surplus - unvested;

        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        assertEq(vault.usdatBalance(), CASH + released - BOUNDARY_AMOUNT_IN);
        assertEq(_surplusSwept(), released);
        assertEq(_remainingSurplus(), unvested);
        assertEq(usdat.balanceOf(address(vault)), vault.usdatBalance() + unvested);
    }

    function test_buy_RejectsFirstPriceUnitAboveBoundaryAndRollsBack() public {
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionPriceMismatch.selector);
        vault.buy(BOUNDARY_AMOUNT_IN + 1, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_buy_CeilRoundsRealizedPriceAgainstVault() public {
        Snapshot memory beforeState = _snapshot(vehicle);

        // The exact quotient is below 105e8 + 1 but above 105e8. Floor would
        // accept it at the boundary; the required ceil must reject it.
        vm.expectRevert(ISTRConExecutionPolicy.ExecutionPriceMismatch.selector);
        vault.buy(BOUNDARY_AMOUNT_IN + 1, AMOUNT_OUT + 1, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_buy_FloorRoundsMaximumPriceAgainstVault() public {
        module.setPrice(ORACLE_PRICE + 1);
        policy.setExecutionTolerance(1);

        uint256 flooredMaximum = 10_001_000_001;
        vault.buy(flooredMaximum, AMOUNT_OUT, vehicle, block.timestamp);

        Snapshot memory afterBoundary = _snapshot(vehicle);
        vm.expectRevert(ISTRConExecutionPolicy.ExecutionPriceMismatch.selector);
        vault.buy(flooredMaximum + 1, AMOUNT_OUT, vehicle, block.timestamp);
        _assertUnchanged(afterBoundary, vehicle);
    }

    function test_buy_RejectsInsufficientTrackedCashDespitePhysicalExcess() public {
        uint256 activeSurplus = 10e6;
        usdat.mint(address(this), activeSurplus);
        usdat.approve(address(vault), activeSurplus);
        vault.transferInSurplus(activeSurplus);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.InsufficientBalance.selector);
        vault.buy(CASH + 1, 2_000e18, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_buy_RejectsInexactInboundSTRConAndRollsBackAllowance() public {
        strcon.configureTransferBehavior(BuyTokenMock.TransferBehavior.RECIPIENT_SHORTFALL, vehicle, 1);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.InvalidAssetDelta.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_buy_LateUSDatTransferFailureRollsBackEveryLeg() public {
        uint256 surplus = 30e6;
        usdat.mint(address(this), surplus);
        usdat.approve(address(vault), surplus);
        vault.transferInSurplus(surplus);
        vm.warp(block.timestamp + 1 days);

        usdat.configureTransferBehavior(BuyTokenMock.TransferBehavior.REVERT_TRANSFER, address(vault), 0);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(BuyTokenMock.ConfiguredTransferFailure.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
        assertEq(module.lastBuyAmount(), 0);
    }

    function test_buy_ModuleFailureRollsBackInboundTransfer() public {
        module.setBuyFails(true);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(BuyTradableModuleMock.BuyFailed.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_buy_FailsClosedOnOracleAndMirrorPricingFailures() public {
        module.setPriceFails(true);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(BuyTradableModuleMock.OracleFailed.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
        module.setPriceFails(false);
        mirror.configure(1, true);

        vm.expectRevert(BuyMirrorModuleMock.PricingFailed.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_buy_RejectsEitherPreexistingCustodyShortfall() public {
        uint256 tracked = 10e18;
        module.seedTrackedBalance(tracked);
        strcon.mint(address(vault), tracked - 1);
        Snapshot memory strconShortfallState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.CustodyShortfall.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(strconShortfallState, vehicle);

        strcon.mint(address(vault), 1);
        usdat.burn(address(vault), 1);
        Snapshot memory usdatShortfallState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.CustodyShortfall.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(usdatShortfallState, vehicle);
    }

    function test_buy_EnforcesRolePauseRestrictedAndDeadlineGuards() public {
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);

        vault.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);
        vault.unpause();
        _assertUnchanged(beforeState, vehicle);

        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);
        vm.expectRevert(IStakedUSDat.MarketRestricted.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp);
        vault.authorizeRegularMode(uint64(block.timestamp + 8 hours));
        _assertUnchanged(beforeState, vehicle);

        vm.expectRevert(IStakedUSDat.DeadlineExpired.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, vehicle, block.timestamp - 1);
        _assertUnchanged(beforeState, vehicle);
    }

    function test_buy_RejectsEitherZeroAmount() public {
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.ZeroAmount.selector);
        vault.buy(0, AMOUNT_OUT, vehicle, block.timestamp);

        vm.expectRevert(IStakedUSDat.ZeroAmount.selector);
        vault.buy(BOUNDARY_AMOUNT_IN, 0, vehicle, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_buy_UsesCurrentVehiclePriceAndTolerance() public {
        address replacementVehicle = makeAddr("replacementVehicle");
        strcon.mint(replacementVehicle, VEHICLE_INVENTORY);
        vm.prank(replacementVehicle);
        strcon.approve(address(vault), VEHICLE_INVENTORY);

        module.setPrice(90e8);
        policy.setExecutionTolerance(0);

        uint256 oldVehicleUsdat = usdat.balanceOf(vehicle);
        uint256 oldVehicleStrcon = strcon.balanceOf(vehicle);

        policy.setExecutionVehicle(replacementVehicle);
        module.setPrice(ORACLE_PRICE);
        policy.setExecutionTolerance(500);

        Snapshot memory beforeState = _snapshot(replacementVehicle);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AssetBought(address(module), replacementVehicle, BOUNDARY_AMOUNT_IN, AMOUNT_OUT, ORACLE_PRICE);
        vault.buy(BOUNDARY_AMOUNT_IN, AMOUNT_OUT, replacementVehicle, block.timestamp);

        assertEq(usdat.balanceOf(replacementVehicle), beforeState.vehicleUsdat + BOUNDARY_AMOUNT_IN);
        assertEq(strcon.balanceOf(replacementVehicle), beforeState.vehicleStrcon - AMOUNT_OUT);
        assertEq(usdat.balanceOf(vehicle), oldVehicleUsdat);
        assertEq(strcon.balanceOf(vehicle), oldVehicleStrcon);
    }

    function test_buy_HasNoCallerSelectedModuleAbi() public {
        Snapshot memory beforeState = _snapshot(vehicle);
        bytes memory callData = abi.encodeWithSignature(
            "buy(address,uint256,uint256,uint256)", address(module), BOUNDARY_AMOUNT_IN, AMOUNT_OUT, block.timestamp
        );

        (bool success, bytes memory returnData) = address(vault).call(callData);

        assertFalse(success);
        assertEq(returnData.length, 0);
        _assertUnchanged(beforeState, vehicle);
    }

    function _snapshot(address currentVehicle) private view returns (Snapshot memory state) {
        state.vaultUsdat = usdat.balanceOf(address(vault));
        state.trackedUsdat = vault.usdatBalance();
        state.vehicleUsdat = usdat.balanceOf(currentVehicle);
        state.vaultStrcon = strcon.balanceOf(address(vault));
        state.vehicleStrcon = strcon.balanceOf(currentVehicle);
        state.moduleBalance = module.balance();
        state.vehicleAllowance = strcon.allowance(currentVehicle, address(vault));
        state.shareBalance = vault.balanceOf(address(this));
        state.shareSupply = vault.totalSupply();
        state.surplusAmount = vault.surplusVestingAmount();
        state.surplusStart = vault.surplusVestingStartTimestamp();
        state.surplusSwept = _surplusSwept();
        (state.capacityMaximum, state.capacityAvailable, state.capacityRefillPerDay, state.capacityLastUpdated) =
            policy.executionCapacity();
    }

    function _assertUnchanged(Snapshot memory state, address currentVehicle) private view {
        assertEq(usdat.balanceOf(address(vault)), state.vaultUsdat);
        assertEq(vault.usdatBalance(), state.trackedUsdat);
        assertEq(usdat.balanceOf(currentVehicle), state.vehicleUsdat);
        assertEq(strcon.balanceOf(address(vault)), state.vaultStrcon);
        assertEq(strcon.balanceOf(currentVehicle), state.vehicleStrcon);
        assertEq(module.balance(), state.moduleBalance);
        assertEq(strcon.allowance(currentVehicle, address(vault)), state.vehicleAllowance);
        assertEq(vault.balanceOf(address(this)), state.shareBalance);
        assertEq(vault.totalSupply(), state.shareSupply);
        assertEq(vault.surplusVestingAmount(), state.surplusAmount);
        assertEq(vault.surplusVestingStartTimestamp(), state.surplusStart);
        assertEq(_surplusSwept(), state.surplusSwept);
        (uint128 capacityMaximum, uint128 capacityAvailable, uint128 capacityRefillPerDay, uint64 capacityLastUpdated) =
            policy.executionCapacity();
        assertEq(capacityMaximum, state.capacityMaximum);
        assertEq(capacityAvailable, state.capacityAvailable);
        assertEq(capacityRefillPerDay, state.capacityRefillPerDay);
        assertEq(capacityLastUpdated, state.capacityLastUpdated);
    }

    function _remainingSurplus() private view returns (uint256) {
        return vault.surplusVestingAmount() - _surplusSwept();
    }

    function _surplusSwept() private view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(SURPLUS_SWEPT_SLOT)));
    }
}
