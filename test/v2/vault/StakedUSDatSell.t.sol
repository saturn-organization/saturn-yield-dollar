// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IAccountingModule} from "../../../src/v2/interfaces/modules/IAccountingModule.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ITradableModule} from "../../../src/v2/interfaces/modules/ITradableModule.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {BoundMirrorModuleMock, V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract SellTokenMock is ERC20 {
    enum TransferBehavior {
        STANDARD,
        RECIPIENT_SHORTFALL,
        REVERT_TRANSFER
    }

    error ConfiguredTransferFailure();
    error ConservativeOrderViolated();

    uint8 private immutable _tokenDecimals;
    TransferBehavior private _behavior;
    address private _affectedSender;
    uint256 private _shortfall;

    bool private _checkOutboundOrder;
    address private _orderVault;
    IAccountingModule private _orderModule;
    uint256 private _expectedTrackedUsdat;
    uint256 private _expectedModuleBalance;

    uint256 public trackedUsdatObservedAtTransfer;
    uint256 public moduleBalanceObservedAtTransfer;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
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

    function expectOutboundOrder(address vault, IAccountingModule module, uint256 trackedUsdat, uint256 moduleBalance)
        external
    {
        _checkOutboundOrder = true;
        _orderVault = vault;
        _orderModule = module;
        _expectedTrackedUsdat = trackedUsdat;
        _expectedModuleBalance = moduleBalance;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (_checkOutboundOrder && from == _orderVault) {
            uint256 trackedUsdat = IStakedUSDat(_orderVault).usdatBalance();
            uint256 moduleBalance = _orderModule.balance();

            if (trackedUsdat != _expectedTrackedUsdat || moduleBalance != _expectedModuleBalance) {
                revert ConservativeOrderViolated();
            }

            trackedUsdatObservedAtTransfer = trackedUsdat;
            moduleBalanceObservedAtTransfer = moduleBalance;
        }

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

contract SellMirrorModuleMock is IAccountingModule, BoundMirrorModuleMock {
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

contract SellTradableModuleMock is ITradableModule {
    error NotVault();
    error OracleFailed();
    error InsufficientBalance();
    error ConservativeOrderViolated();

    address private immutable _VAULT;
    address private immutable _ASSET;
    address private immutable _USDAT;

    uint256 private _balance;
    uint256 private _price;
    bool private _priceFails;

    bool private _checkConservativeOrder;
    uint256 private _expectedTrackedUsdatAtSell;
    uint256 private _expectedUsdatCustodyAtSell;
    uint256 private _expectedAssetCustodyAtSell;

    uint256 public lastSellAmount;
    uint256 public trackedUsdatObservedAtSell;
    uint256 public usdatCustodyObservedAtSell;
    uint256 public assetCustodyObservedAtSell;

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

    function seedTrackedBalance(uint256 newBalance) external {
        _balance = newBalance;
    }

    function expectConservativeOrder(uint256 trackedUsdatAtSell, uint256 usdatCustodyAtSell, uint256 assetCustodyAtSell)
        external
    {
        _checkConservativeOrder = true;
        _expectedTrackedUsdatAtSell = trackedUsdatAtSell;
        _expectedUsdatCustodyAtSell = usdatCustodyAtSell;
        _expectedAssetCustodyAtSell = assetCustodyAtSell;
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
        _balance += assetReceived;
    }

    function sell(uint256 assetDelivered) external {
        if (msg.sender != _VAULT) revert NotVault();
        if (assetDelivered > _balance) revert InsufficientBalance();

        uint256 trackedUsdat = IStakedUSDat(_VAULT).usdatBalance();
        uint256 usdatCustody = IERC20(_USDAT).balanceOf(_VAULT);
        uint256 assetCustody = IERC20(_ASSET).balanceOf(_VAULT);

        if (
            _checkConservativeOrder
                && (trackedUsdat != _expectedTrackedUsdatAtSell
                    || usdatCustody != _expectedUsdatCustodyAtSell
                    || assetCustody != _expectedAssetCustodyAtSell)
        ) {
            revert ConservativeOrderViolated();
        }

        lastSellAmount = assetDelivered;
        trackedUsdatObservedAtSell = trackedUsdat;
        usdatCustodyObservedAtSell = usdatCustody;
        assetCustodyObservedAtSell = assetCustody;
        _balance -= assetDelivered;
    }
}

contract StakedUSDatSellTest is Test {
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
    }

    uint256 private constant ORACLE_PRICE = 100e8;
    uint256 private constant CASH = 100_000e6;
    uint256 private constant VEHICLE_CASH = 100_000e6;
    uint256 private constant POSITION = 10_000e18;
    uint256 private constant AMOUNT_IN = 100e18;
    uint256 private constant BOUNDARY_AMOUNT_OUT = 9_500_000_000;
    uint256 private constant FAVORABLE_AMOUNT_OUT = 10_100_000_000;

    SellTokenMock private usdat;
    SellTokenMock private strcon;
    SellMirrorModuleMock private mirror;
    SellTradableModuleMock private module;
    StakedUSDat private vault;

    address private vehicle = makeAddr("executionVehicle");
    address private unauthorized = makeAddr("unauthorized");

    event AssetSold(
        address indexed module,
        address indexed vehicle,
        uint256 assetDelivered,
        uint256 usdatReceived,
        uint256 oraclePrice
    );

    function setUp() public {
        vm.warp(1_000_000);

        usdat = new SellTokenMock("USDat", "USDat", 6);
        strcon = new SellTokenMock("STRCon", "STRCon", 18);

        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(makeAddr("sellWithdrawalQueue")));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        vault = StakedUSDat(address(proxy));

        mirror = new SellMirrorModuleMock(address(vault));
        module = new SellTradableModuleMock(address(vault), address(strcon), address(usdat), ORACLE_PRICE);
        V2InitializationHelper.initialize(vault, address(mirror), address(module), 5, 10, 25);

        vault.grantRole(vault.OPERATOR_ROLE(), address(this));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.MARKET_MODE_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.PAUSER_ROLE(), address(this));
        vault.grantRole(vault.UNPAUSER_ROLE(), address(this));
        vault.setExecutionVehicle(vehicle);
        vault.setExecutionTolerance(500);

        usdat.mint(address(this), CASH);
        usdat.approve(address(vault), CASH);
        vault.deposit(CASH, address(this));

        module.seedTrackedBalance(POSITION);
        strcon.mint(address(vault), POSITION);

        usdat.mint(vehicle, VEHICLE_CASH);
        vm.prank(vehicle);
        usdat.approve(address(vault), VEHICLE_CASH);
    }

    function test_sell_SettlesExactDeltasConservativelyAndEmitsAtInclusiveDeadline() public {
        uint256 activeSurplus = 10e6;
        usdat.mint(address(this), activeSurplus);
        usdat.approve(address(vault), activeSurplus);
        vault.transferInSurplus(activeSurplus);
        Snapshot memory beforeState = _snapshot(vehicle);

        module.expectConservativeOrder(
            beforeState.trackedUsdat, beforeState.vaultUsdat + BOUNDARY_AMOUNT_OUT, beforeState.vaultStrcon
        );
        strcon.expectOutboundOrder(
            address(vault),
            module,
            beforeState.trackedUsdat + BOUNDARY_AMOUNT_OUT,
            beforeState.moduleBalance - AMOUNT_IN
        );

        vm.expectEmit(true, true, false, true, address(vault));
        emit AssetSold(address(module), vehicle, AMOUNT_IN, BOUNDARY_AMOUNT_OUT, ORACLE_PRICE);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        assertEq(usdat.balanceOf(address(vault)), beforeState.vaultUsdat + BOUNDARY_AMOUNT_OUT);
        assertEq(vault.usdatBalance(), beforeState.trackedUsdat + BOUNDARY_AMOUNT_OUT);
        assertEq(usdat.balanceOf(vehicle), beforeState.vehicleUsdat - BOUNDARY_AMOUNT_OUT);
        assertEq(usdat.allowance(vehicle, address(vault)), beforeState.vehicleAllowance - BOUNDARY_AMOUNT_OUT);

        assertEq(strcon.balanceOf(address(vault)), beforeState.vaultStrcon - AMOUNT_IN);
        assertEq(module.balance(), beforeState.moduleBalance - AMOUNT_IN);
        assertEq(strcon.balanceOf(vehicle), beforeState.vehicleStrcon + AMOUNT_IN);
        assertEq(strcon.allowance(address(vault), vehicle), 0);

        assertGe(usdat.balanceOf(address(vault)), vault.usdatBalance() + vault.surplusVestingAmount());
        assertGe(strcon.balanceOf(address(vault)), module.balance());
        assertEq(usdat.balanceOf(address(vault)) - vault.usdatBalance(), activeSurplus);

        assertEq(module.lastSellAmount(), AMOUNT_IN);
        assertEq(module.trackedUsdatObservedAtSell(), beforeState.trackedUsdat);
        assertEq(module.usdatCustodyObservedAtSell(), beforeState.vaultUsdat + BOUNDARY_AMOUNT_OUT);
        assertEq(module.assetCustodyObservedAtSell(), beforeState.vaultStrcon);
        assertEq(strcon.trackedUsdatObservedAtTransfer(), beforeState.trackedUsdat + BOUNDARY_AMOUNT_OUT);
        assertEq(strcon.moduleBalanceObservedAtTransfer(), beforeState.moduleBalance - AMOUNT_IN);

        assertEq(vault.balanceOf(address(this)), beforeState.shareBalance);
        assertEq(vault.totalSupply(), beforeState.shareSupply);
    }

    function testFuzz_sell_ValidAmountsPreserveAccountingAndCustodyInvariants(uint96 rawAmountIn) public {
        uint256 amountIn = bound(uint256(rawAmountIn), 1e18, 500e18);
        uint256 amountOut = Math.mulDiv(amountIn, ORACLE_PRICE, 1e20, Math.Rounding.Ceil);
        vault.setExecutionTolerance(0);

        Snapshot memory beforeState = _snapshot(vehicle);
        _sell(amountIn, amountOut, block.timestamp);

        assertEq(usdat.balanceOf(address(vault)), beforeState.vaultUsdat + amountOut);
        assertEq(vault.usdatBalance(), beforeState.trackedUsdat + amountOut);
        assertEq(usdat.balanceOf(vehicle), beforeState.vehicleUsdat - amountOut);
        assertEq(strcon.balanceOf(address(vault)), beforeState.vaultStrcon - amountIn);
        assertEq(module.balance(), beforeState.moduleBalance - amountIn);
        assertEq(strcon.balanceOf(vehicle), beforeState.vehicleStrcon + amountIn);
        assertGe(usdat.balanceOf(address(vault)), vault.usdatBalance() + vault.surplusVestingAmount());
        assertGe(strcon.balanceOf(address(vault)), module.balance());
        assertEq(vault.balanceOf(address(this)), beforeState.shareBalance);
        assertEq(vault.totalSupply(), beforeState.shareSupply);
    }

    function test_sell_AllowsFavorablePriceInElevatedMode() public {
        vault.setExecutionTolerance(0);
        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);

        _sell(AMOUNT_IN, FAVORABLE_AMOUNT_OUT, block.timestamp + 1);

        assertEq(vault.usdatBalance(), CASH + FAVORABLE_AMOUNT_OUT);
        assertEq(module.balance(), POSITION - AMOUNT_IN);
    }

    function test_sell_RejectsFirstPriceUnitBelowBoundaryAndRollsBack() public {
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.ExecutionPriceMismatch.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT - 1, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_sell_FloorRoundsRealizedPriceAgainstVault() public {
        Snapshot memory beforeState = _snapshot(vehicle);

        // The exact quotient is below 95e8 but would round up to the boundary.
        // The required floor must reject it.
        vm.expectRevert(IStakedUSDat.ExecutionPriceMismatch.selector);
        _sell(AMOUNT_IN + 1, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_sell_CeilRoundsMinimumPriceAgainstVault() public {
        module.setPrice(ORACLE_PRICE + 1);
        vault.setExecutionTolerance(1);

        uint256 roundedUpMinimum = 9_999_000_001;
        _sell(AMOUNT_IN, roundedUpMinimum, block.timestamp);

        Snapshot memory afterBoundary = _snapshot(vehicle);
        vm.expectRevert(IStakedUSDat.ExecutionPriceMismatch.selector);
        _sell(AMOUNT_IN, roundedUpMinimum - 1, block.timestamp);
        _assertUnchanged(afterBoundary, vehicle);
    }

    function test_sell_RejectsUnrecognizedExcessSTRCon() public {
        module.seedTrackedBalance(AMOUNT_IN - 1);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(SellTradableModuleMock.InsufficientBalance.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_sell_RejectsVehicleThatDoesNotApproveFullUSDatDelivery() public {
        vm.prank(vehicle);
        usdat.approve(address(vault), BOUNDARY_AMOUNT_OUT - 1);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(vault),
                BOUNDARY_AMOUNT_OUT - 1,
                BOUNDARY_AMOUNT_OUT
            )
        );
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_sell_RejectsInexactInboundUSDatAndRollsBackAllowance() public {
        usdat.configureTransferBehavior(SellTokenMock.TransferBehavior.RECIPIENT_SHORTFALL, vehicle, 1);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.InvalidAssetDelta.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_sell_LateSTRConTransferFailureRollsBackEveryLeg() public {
        strcon.configureTransferBehavior(SellTokenMock.TransferBehavior.REVERT_TRANSFER, address(vault), 0);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(SellTokenMock.ConfiguredTransferFailure.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
        assertEq(module.lastSellAmount(), 0);
    }

    function test_sell_FailsClosedOnOracleAndMirrorPricingFailures() public {
        module.setPriceFails(true);
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(SellTradableModuleMock.OracleFailed.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
        module.setPriceFails(false);
        mirror.configure(1, true);

        vm.expectRevert(SellMirrorModuleMock.PricingFailed.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_sell_RejectsEitherPreexistingCustodyShortfall() public {
        strcon.burn(address(vault), 1);
        Snapshot memory strconShortfallState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.CustodyShortfall.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(strconShortfallState, vehicle);

        strcon.mint(address(vault), 1);
        usdat.burn(address(vault), 1);
        Snapshot memory usdatShortfallState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.CustodyShortfall.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        _assertUnchanged(usdatShortfallState, vehicle);
    }

    function test_sell_EnforcesRolePauseRestrictedAndDeadlineGuards() public {
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);
        _assertUnchanged(beforeState, vehicle);

        vault.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);
        vault.unpause();
        _assertUnchanged(beforeState, vehicle);

        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);
        vm.expectRevert(IStakedUSDat.MarketRestricted.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);
        vault.authorizeRegularMode(uint64(block.timestamp + 8 hours));
        _assertUnchanged(beforeState, vehicle);

        vm.expectRevert(IStakedUSDat.DeadlineExpired.selector);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp - 1);
        _assertUnchanged(beforeState, vehicle);
    }

    function test_sell_RejectsEitherZeroAmount() public {
        Snapshot memory beforeState = _snapshot(vehicle);

        vm.expectRevert(IStakedUSDat.ZeroAmount.selector);
        _sell(0, BOUNDARY_AMOUNT_OUT, block.timestamp);

        vm.expectRevert(IStakedUSDat.ZeroAmount.selector);
        _sell(AMOUNT_IN, 0, block.timestamp);

        _assertUnchanged(beforeState, vehicle);
    }

    function test_sell_UsesCurrentVehiclePriceAndTolerance() public {
        address replacementVehicle = makeAddr("replacementVehicle");
        usdat.mint(replacementVehicle, VEHICLE_CASH);
        vm.prank(replacementVehicle);
        usdat.approve(address(vault), VEHICLE_CASH);

        module.setPrice(110e8);
        vault.setExecutionTolerance(0);

        uint256 oldVehicleUsdat = usdat.balanceOf(vehicle);
        uint256 oldVehicleStrcon = strcon.balanceOf(vehicle);

        vault.setExecutionVehicle(replacementVehicle);
        module.setPrice(ORACLE_PRICE);
        vault.setExecutionTolerance(500);

        Snapshot memory beforeState = _snapshot(replacementVehicle);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AssetSold(address(module), replacementVehicle, AMOUNT_IN, BOUNDARY_AMOUNT_OUT, ORACLE_PRICE);
        _sell(AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp);

        assertEq(usdat.balanceOf(replacementVehicle), beforeState.vehicleUsdat - BOUNDARY_AMOUNT_OUT);
        assertEq(strcon.balanceOf(replacementVehicle), beforeState.vehicleStrcon + AMOUNT_IN);
        assertEq(usdat.balanceOf(vehicle), oldVehicleUsdat);
        assertEq(strcon.balanceOf(vehicle), oldVehicleStrcon);
    }

    function test_sell_HasNoCallerSelectedModuleAbi() public {
        Snapshot memory beforeState = _snapshot(vehicle);
        bytes memory callData = abi.encodeWithSignature(
            "sell(address,uint256,uint256,uint256)", address(module), AMOUNT_IN, BOUNDARY_AMOUNT_OUT, block.timestamp
        );

        (bool success, bytes memory returnData) = address(vault).call(callData);

        assertFalse(success);
        assertEq(returnData.length, 0);
        _assertUnchanged(beforeState, vehicle);
    }

    function _sell(uint256 amountIn, uint256 amountOut, uint256 deadline) private {
        vault.sell(amountIn, amountOut, deadline);
    }

    function _snapshot(address currentVehicle) private view returns (Snapshot memory state) {
        state.vaultUsdat = usdat.balanceOf(address(vault));
        state.trackedUsdat = vault.usdatBalance();
        state.vehicleUsdat = usdat.balanceOf(currentVehicle);
        state.vaultStrcon = strcon.balanceOf(address(vault));
        state.vehicleStrcon = strcon.balanceOf(currentVehicle);
        state.moduleBalance = module.balance();
        state.vehicleAllowance = usdat.allowance(currentVehicle, address(vault));
        state.shareBalance = vault.balanceOf(address(this));
        state.shareSupply = vault.totalSupply();
        state.surplusAmount = vault.surplusVestingAmount();
        state.surplusStart = vault.surplusVestingStartTimestamp();
    }

    function _assertUnchanged(Snapshot memory state, address currentVehicle) private view {
        assertEq(usdat.balanceOf(address(vault)), state.vaultUsdat);
        assertEq(vault.usdatBalance(), state.trackedUsdat);
        assertEq(usdat.balanceOf(currentVehicle), state.vehicleUsdat);
        assertEq(strcon.balanceOf(address(vault)), state.vaultStrcon);
        assertEq(strcon.balanceOf(currentVehicle), state.vehicleStrcon);
        assertEq(module.balance(), state.moduleBalance);
        assertEq(usdat.allowance(currentVehicle, address(vault)), state.vehicleAllowance);
        assertEq(vault.balanceOf(address(this)), state.shareBalance);
        assertEq(vault.totalSupply(), state.shareSupply);
        assertEq(vault.surplusVestingAmount(), state.surplusAmount);
        assertEq(vault.surplusVestingStartTimestamp(), state.surplusStart);
    }
}
