// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IAccountingModule} from "../../../src/v2/interfaces/modules/IAccountingModule.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ITradableModule} from "../../../src/v2/interfaces/modules/ITradableModule.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {BoundMirrorModuleMock, V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract FixedModuleUSDatMock is ERC20 {
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

contract FixedAccountingModuleMock is IAccountingModule, BoundMirrorModuleMock {
    error PricingFailed();

    uint256 private _balance;
    uint256 private _recognizedValue;
    bool private _pricingFails;

    constructor(address vault) BoundMirrorModuleMock(vault) {}

    function configure(uint256 newBalance, uint256 newRecognizedValue, bool pricingFails) external {
        _balance = newBalance;
        _recognizedValue = newRecognizedValue;
        _pricingFails = pricingFails;
    }

    /// @inheritdoc IAccountingModule
    function recognizedValue() external view returns (uint256) {
        if (_balance == 0) return 0;
        if (_pricingFails) revert PricingFailed();
        return _recognizedValue;
    }

    /// @inheritdoc IAccountingModule
    function balance() external view returns (uint256) {
        return _balance;
    }
}

contract FixedTradableModuleMock is ITradableModule {
    error PricingFailed();

    address public immutable VAULT;
    address public immutable ASSET;
    uint256 private _balance;
    uint256 private _recognizedValue;
    bool private _pricingFails;

    constructor(address vault, address asset_) {
        VAULT = vault;
        ASSET = asset_;
    }

    function configure(uint256 newBalance, uint256 newRecognizedValue, bool pricingFails) external {
        _balance = newBalance;
        _recognizedValue = newRecognizedValue;
        _pricingFails = pricingFails;
    }

    /// @inheritdoc IAccountingModule
    function recognizedValue() external view returns (uint256) {
        if (_balance == 0) return 0;
        if (_pricingFails) revert PricingFailed();
        return _recognizedValue;
    }

    /// @inheritdoc IAccountingModule
    function balance() external view returns (uint256) {
        return _balance;
    }

    /// @inheritdoc ITradableModule
    function asset() external view returns (address) {
        return ASSET;
    }

    /// @inheritdoc ITradableModule
    function getPrice() external pure returns (uint256) {
        return 1e8;
    }

    /// @inheritdoc ITradableModule
    function buy(uint256) external pure {}

    /// @inheritdoc ITradableModule
    function sell(uint256) external pure {}
}

contract StakedUSDatFixedModuleAccountingTest is Test {
    uint256 private constant CASH = 37_000_003;
    uint256 private constant MIRROR_VALUE = 11_000_007;
    uint256 private constant STRCON_VALUE = 52_000_011;
    FixedModuleUSDatMock private usdat;
    FixedAccountingModuleMock private mirror;
    FixedTradableModuleMock private strcon;
    StakedUSDat private vault;

    function setUp() public {
        usdat = new FixedModuleUSDatMock();
        vault = _deployVault();
        mirror = new FixedAccountingModuleMock(address(vault));
        strcon = new FixedTradableModuleMock(address(vault), address(usdat));

        _initializeV2(vault, mirror, strcon);
        vault.grantRole(vault.MARKET_MODE_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.PAUSER_ROLE(), address(this));

        usdat.mint(address(this), CASH);
        usdat.approve(address(vault), CASH);
    }

    function test_initializeV2_BindsFixedModulesAndCannotRebind() public {
        assertEq(address(vault.strcMirrorModule()), address(mirror));
        assertEq(address(vault.strconModule()), address(strcon));

        FixedAccountingModuleMock replacementMirror = new FixedAccountingModuleMock(address(vault));
        FixedTradableModuleMock replacementStrcon = new FixedTradableModuleMock(address(vault), address(usdat));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initializeV2(vault, replacementMirror, replacementStrcon);

        assertEq(address(vault.strcMirrorModule()), address(mirror));
        assertEq(address(vault.strconModule()), address(strcon));
    }

    function test_initializeV2_RejectsInvalidModulesWithoutConsumingVersion() public {
        StakedUSDat freshVault = _deployVault();
        FixedAccountingModuleMock freshMirror = new FixedAccountingModuleMock(address(freshVault));
        FixedTradableModuleMock freshStrcon = new FixedTradableModuleMock(address(freshVault), address(usdat));

        vm.expectRevert();
        _initializeV2(freshVault, IAccountingModule(address(0)), freshStrcon);

        vm.expectRevert();
        _initializeV2(freshVault, freshMirror, ITradableModule(makeAddr("codelessModule")));

        _initializeV2(freshVault, freshMirror, freshStrcon);

        assertEq(address(freshVault.strcMirrorModule()), address(freshMirror));
        assertEq(address(freshVault.strconModule()), address(freshStrcon));
    }

    function test_totalAssets_AddsCashAndBothFixedModuleValuesExactly() public {
        _depositCash();
        mirror.configure(1e18, MIRROR_VALUE, false);
        strcon.configure(2e18, STRCON_VALUE, false);

        assertEq(vault.totalAssets(), CASH + MIRROR_VALUE + STRCON_VALUE);
    }

    function test_totalAssets_ZeroBalanceModulesBypassFailedPricing() public {
        _depositCash();
        mirror.configure(0, type(uint256).max, true);
        strcon.configure(0, type(uint256).max, true);

        assertEq(vault.totalAssets(), CASH);
    }

    function test_totalAssets_RevertsWhenMirrorPricingFails() public {
        mirror.configure(1, MIRROR_VALUE, true);

        vm.expectRevert(FixedAccountingModuleMock.PricingFailed.selector);
        vault.totalAssets();
    }

    function test_totalAssets_RevertsWhenStrconPricingFails() public {
        strcon.configure(1, STRCON_VALUE, true);

        vm.expectRevert(FixedTradableModuleMock.PricingFailed.selector);
        vault.totalAssets();
    }

    function test_maxDepositAndMaxMint_ReturnMaximumWhenPricingIsHealthy() public {
        mirror.configure(1, MIRROR_VALUE, false);
        strcon.configure(1, STRCON_VALUE, false);

        assertEq(vault.maxDeposit(address(this)), type(uint256).max);
        assertEq(vault.maxMint(address(this)), type(uint256).max);

        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);

        assertEq(vault.maxDeposit(address(this)), type(uint256).max);
        assertEq(vault.maxMint(address(this)), type(uint256).max);
    }

    function test_maxDepositAndMaxMint_ReturnZeroWhenMirrorPricingFails() public {
        mirror.configure(1, MIRROR_VALUE, true);

        assertEq(vault.maxDeposit(address(this)), 0);
        assertEq(vault.maxMint(address(this)), 0);
    }

    function test_maxDepositAndMaxMint_ReturnZeroWhenStrconPricingFails() public {
        strcon.configure(1, STRCON_VALUE, true);

        assertEq(vault.maxDeposit(address(this)), 0);
        assertEq(vault.maxMint(address(this)), 0);
    }

    function test_maxDepositAndMaxMint_ShortCircuitWhilePaused() public {
        mirror.configure(1, MIRROR_VALUE, false);
        strcon.configure(1, STRCON_VALUE, false);
        vault.pause();

        vm.record();
        assertEq(vault.maxDeposit(address(this)), 0);
        assertEq(vault.maxMint(address(this)), 0);
        _assertModulesWereNotRead();
    }

    function test_maxDepositAndMaxMint_ShortCircuitWhileRestricted() public {
        mirror.configure(1, MIRROR_VALUE, false);
        strcon.configure(1, STRCON_VALUE, false);
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);

        vm.record();
        assertEq(vault.maxDeposit(address(this)), 0);
        assertEq(vault.maxMint(address(this)), 0);
        _assertModulesWereNotRead();
    }

    function test_totalAssets_IgnoresUnboundThirdModule() public {
        FixedAccountingModuleMock thirdModule = new FixedAccountingModuleMock(address(vault));
        thirdModule.configure(1, type(uint128).max, false);
        mirror.configure(1, MIRROR_VALUE, false);
        strcon.configure(1, STRCON_VALUE, false);

        assertEq(vault.totalAssets(), MIRROR_VALUE + STRCON_VALUE);
    }

    function test_NoModuleSettersRegistryOrAllocationAbi() public {
        _assertMissingSelector(abi.encodeWithSignature("setStrcMirrorModule(address)", address(mirror)));
        _assertMissingSelector(abi.encodeWithSignature("setStrconModule(address)", address(strcon)));
        _assertMissingSelector(abi.encodeWithSignature("getModules()"));
        _assertMissingSelector(abi.encodeWithSignature("registerModule(address,uint16)", address(mirror), 10_000));
        _assertMissingSelector(abi.encodeWithSignature("deregisterModule(address)", address(mirror)));
        _assertMissingSelector(abi.encodeWithSignature("moduleConfig(address)", address(mirror)));
        _assertMissingSelector(abi.encodeWithSignature("setMaxWeight(address,uint16)", address(mirror), 10_000));
        _assertMissingSelector(abi.encodeWithSignature("minCashBufferBps()"));
        _assertMissingSelector(abi.encodeWithSignature("setMinCashBuffer(uint16)", 1_000));
        _assertMissingSelector(abi.encodeWithSignature("MAX_MODULES()"));
    }

    function _deployVault() private returns (StakedUSDat deployedVault) {
        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(makeAddr("fixedModuleWithdrawalQueue")));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        return StakedUSDat(address(proxy));
    }

    function _initializeV2(StakedUSDat target, IAccountingModule strcMirrorModule, ITradableModule strconModule)
        private
    {
        V2InitializationHelper.initialize(target, address(strcMirrorModule), address(strconModule), 5, 10, 25);
    }

    function _depositCash() private {
        vault.deposit(CASH, address(this));
    }

    function _assertModulesWereNotRead() private view {
        (bytes32[] memory mirrorReads,) = vm.accesses(address(mirror));
        (bytes32[] memory strconReads,) = vm.accesses(address(strcon));
        assertEq(mirrorReads.length, 0);
        assertEq(strconReads.length, 0);
    }

    function _assertMissingSelector(bytes memory callData) private {
        (bool success,) = address(vault).call(callData);
        assertFalse(success);
    }
}
