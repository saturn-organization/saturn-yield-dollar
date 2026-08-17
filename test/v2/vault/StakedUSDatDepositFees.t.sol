// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {STRConExecutionPolicy} from "../../../src/v2/STRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";
import {ZeroAccountingModuleMock, ZeroTradableModuleMock} from "../helpers/FixedModuleMocks.sol";
import {V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract DepositFeeUSDatMock is ERC20 {
    uint256 public eip2612PermitCalls;
    uint256 public eip1271PermitCalls;
    uint256 public lastPermitValue;

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

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        eip2612PermitCalls++;
        lastPermitValue = value;
        _approve(owner, spender, value);
    }

    function permit(address owner, address spender, uint256 value, uint256, bytes calldata) external {
        eip1271PermitCalls++;
        lastPermitValue = value;
        _approve(owner, spender, value);
    }
}

contract StakedUSDatDepositFeesTest is Test {
    uint256 private constant GROSS_ASSETS = 100e6;
    uint256 private constant NET_SHARES = 95e18;
    uint16 private constant ELEVATED_DEPOSIT_FEE_BPS = 500;

    DepositFeeUSDatMock private usdat;
    StakedUSDat private vault;
    ZeroAccountingModuleMock private strcMirrorModule;
    ZeroTradableModuleMock private strconModule;

    address private unauthorized = makeAddr("unauthorized");
    address private legacyFeeRecipient = makeAddr("legacyFeeRecipient");
    address private withdrawalQueue = makeAddr("withdrawalQueue");

    event DepositFeeUpdated(uint256 newFee);

    function setUp() public {
        usdat = new DepositFeeUSDatMock();
        vault = _deployVault();
        strcMirrorModule = new ZeroAccountingModuleMock(address(vault));
        strconModule = new ZeroTradableModuleMock(address(vault));

        V2InitializationHelper.initialize(
            vault, address(strcMirrorModule), address(strconModule), 5, 10, ELEVATED_DEPOSIT_FEE_BPS
        );
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.MARKET_MODE_MANAGER_ROLE(), address(this));

        usdat.mint(address(this), 1_000_000e6);
        usdat.approve(address(vault), type(uint256).max);
    }

    function test_initializeV2_SetsElevatedDepositFeeAndRejectsInvalidFeeWithoutConsumingVersion() public {
        StakedUSDat freshVault = _deployVault();
        ZeroAccountingModuleMock freshMirror = new ZeroAccountingModuleMock(address(freshVault));
        ZeroTradableModuleMock freshStrcon = new ZeroTradableModuleMock(address(freshVault));
        ISTRConExecutionPolicy freshPolicy =
            new STRConExecutionPolicy(address(freshVault), ISTRConModule(address(freshStrcon)));

        vm.expectRevert(IStakedUSDat.InvalidFee.selector);
        V2InitializationHelper.initializeWithPolicy(
            freshVault,
            address(freshMirror),
            ISTRConModule(address(freshStrcon)),
            freshPolicy,
            5,
            10,
            501,
            uint64(block.timestamp + 8 hours),
            type(uint128).max,
            0
        );

        assertEq(freshVault.baseRedemptionFeeBps(), 0);
        assertEq(freshVault.elevatedRedemptionFeeBps(), 0);
        assertEq(freshVault.elevatedDepositFeeBps(), 0);

        V2InitializationHelper.initializeWithPolicy(
            freshVault,
            address(freshMirror),
            ISTRConModule(address(freshStrcon)),
            freshPolicy,
            5,
            10,
            250,
            uint64(block.timestamp + 8 hours),
            type(uint128).max,
            0
        );

        assertEq(freshVault.baseRedemptionFeeBps(), 5);
        assertEq(freshVault.elevatedRedemptionFeeBps(), 10);
        assertEq(freshVault.elevatedDepositFeeBps(), 250);
    }

    function test_depositFeeBps_SelectsTierFromMarketMode() public {
        assertEq(vault.depositFeeBps(), 0);
        assertEq(vault.elevatedDepositFeeBps(), ELEVATED_DEPOSIT_FEE_BPS);

        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);
        assertEq(vault.depositFeeBps(), ELEVATED_DEPOSIT_FEE_BPS);

        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);
        assertEq(vault.depositFeeBps(), ELEVATED_DEPOSIT_FEE_BPS);
    }

    function test_setElevatedDepositFee_RequiresParameterManagerAndEnforcesCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setElevatedDepositFee(250);

        vm.expectEmit(false, false, false, true, address(vault));
        emit DepositFeeUpdated(250);
        vault.setElevatedDepositFee(250);
        assertEq(vault.elevatedDepositFeeBps(), 250);

        vault.setElevatedDepositFee(0);
        assertEq(vault.elevatedDepositFeeBps(), 0);

        vm.expectRevert(IStakedUSDat.InvalidFee.selector);
        vault.setElevatedDepositFee(501);
        assertEq(vault.elevatedDepositFeeBps(), 0);
    }

    function test_previewDeposit_UsesCeilRoundedModeFee() public {
        assertEq(vault.previewDeposit(21), 21e12);

        _setElevatedMode();

        assertEq(vault.previewDeposit(1), 0);
        assertEq(vault.previewDeposit(20), 19e12);
        assertEq(vault.previewDeposit(21), 19e12);
    }

    function test_previewMint_GrossesUpWithCeilRounding() public {
        assertEq(vault.previewMint(20e12), 20);

        _setElevatedMode();

        assertEq(vault.previewMint(1e12), 2);
        assertEq(vault.previewMint(19e12), 20);
        assertEq(vault.previewMint(20e12), 22);
    }

    function test_previews_UseStandardPathWhenConfiguredFeeIsZero() public {
        vault.setElevatedDepositFee(0);
        _setElevatedMode();

        assertEq(vault.depositFeeBps(), 0);
        assertEq(vault.previewDeposit(21), 21e12);
        assertEq(vault.previewMint(20e12), 20);
    }

    function test_deposit_RegularModeChargesNoFee() public {
        uint256 expectedShares = vault.previewDeposit(GROSS_ASSETS);

        uint256 shares = vault.deposit(GROSS_ASSETS, address(this));

        assertEq(expectedShares, 100e18);
        assertEq(shares, expectedShares);
        _assertGrossAccounting(GROSS_ASSETS, expectedShares);
    }

    function test_deposit_ElevatedModeMintsFromNetAndRetainsGross() public {
        _setElevatedMode();
        vm.store(address(vault), bytes32(uint256(6)), bytes32(uint256(uint160(legacyFeeRecipient))));
        uint256 expectedShares = vault.previewDeposit(GROSS_ASSETS);

        uint256 shares = vault.deposit(GROSS_ASSETS, address(this));

        assertEq(expectedShares, NET_SHARES);
        assertEq(shares, expectedShares);
        _assertGrossAccounting(GROSS_ASSETS, expectedShares);
        assertEq(usdat.balanceOf(legacyFeeRecipient), 0);
    }

    function test_mint_ElevatedModePullsAndRetainsGross() public {
        _setElevatedMode();
        uint256 expectedAssets = vault.previewMint(NET_SHARES);

        uint256 assets = vault.mint(NET_SHARES, address(this));

        assertEq(expectedAssets, GROSS_ASSETS);
        assertEq(assets, expectedAssets);
        _assertGrossAccounting(expectedAssets, NET_SHARES);
    }

    function test_depositWithMinShares_UsesFeeAwarePreviewAndSlippageLimit() public {
        _setElevatedMode();
        uint256 expectedShares = vault.previewDeposit(GROSS_ASSETS);

        vm.expectRevert(IStakedUSDat.SlippageExceeded.selector);
        vault.depositWithMinShares(GROSS_ASSETS, address(this), expectedShares + 1);
        _assertNoDeposit();

        uint256 shares = vault.depositWithMinShares(GROSS_ASSETS, address(this), expectedShares);

        assertEq(shares, expectedShares);
        _assertGrossAccounting(GROSS_ASSETS, expectedShares);
    }

    function test_mintWithMaxAssets_UsesFeeAwarePreviewAndSlippageLimit() public {
        _setElevatedMode();
        uint256 expectedAssets = vault.previewMint(NET_SHARES);

        vm.expectRevert(IStakedUSDat.SlippageExceeded.selector);
        vault.mintWithMaxAssets(NET_SHARES, address(this), expectedAssets - 1);
        _assertNoDeposit();

        uint256 assets = vault.mintWithMaxAssets(NET_SHARES, address(this), expectedAssets);

        assertEq(assets, expectedAssets);
        _assertGrossAccounting(expectedAssets, NET_SHARES);
    }

    function test_depositWithEip2612Permit_UsesFeeAwarePreview() public {
        _setElevatedMode();
        usdat.approve(address(vault), 0);
        uint256 expectedShares = vault.previewDeposit(GROSS_ASSETS);

        uint256 shares = vault.depositWithPermit(
            GROSS_ASSETS, address(this), expectedShares, block.timestamp + 1, 0, bytes32(0), bytes32(0)
        );

        assertEq(shares, expectedShares);
        assertEq(usdat.eip2612PermitCalls(), 1);
        assertEq(usdat.lastPermitValue(), GROSS_ASSETS);
        _assertGrossAccounting(GROSS_ASSETS, expectedShares);
    }

    function test_mintWithEip2612Permit_UsesFeeAwarePreview() public {
        _setElevatedMode();
        usdat.approve(address(vault), 0);
        uint256 expectedAssets = vault.previewMint(NET_SHARES);

        uint256 assets = vault.mintWithPermit(
            NET_SHARES, address(this), expectedAssets, block.timestamp + 1, 0, bytes32(0), bytes32(0)
        );

        assertEq(assets, expectedAssets);
        assertEq(usdat.eip2612PermitCalls(), 1);
        assertEq(usdat.lastPermitValue(), expectedAssets);
        _assertGrossAccounting(expectedAssets, NET_SHARES);
    }

    function test_depositWithEip1271Permit_UsesFeeAwarePreview() public {
        _setElevatedMode();
        usdat.approve(address(vault), 0);
        uint256 expectedShares = vault.previewDeposit(GROSS_ASSETS);

        uint256 shares =
            vault.depositWithPermit(GROSS_ASSETS, address(this), expectedShares, block.timestamp + 1, hex"1234");

        assertEq(shares, expectedShares);
        assertEq(usdat.eip1271PermitCalls(), 1);
        assertEq(usdat.lastPermitValue(), GROSS_ASSETS);
        _assertGrossAccounting(GROSS_ASSETS, expectedShares);
    }

    function test_mintWithEip1271Permit_UsesFeeAwarePreview() public {
        _setElevatedMode();
        usdat.approve(address(vault), 0);
        uint256 expectedAssets = vault.previewMint(NET_SHARES);

        uint256 assets = vault.mintWithPermit(NET_SHARES, address(this), expectedAssets, block.timestamp + 1, hex"1234");

        assertEq(assets, expectedAssets);
        assertEq(usdat.eip1271PermitCalls(), 1);
        assertEq(usdat.lastPermitValue(), expectedAssets);
        _assertGrossAccounting(expectedAssets, NET_SHARES);
    }

    function test_restrictedMode_KeepsElevatedPreviewsAndDisablesDepositExecution() public {
        _setElevatedMode();
        uint256 expectedShares = vault.previewDeposit(GROSS_ASSETS);
        uint256 expectedAssets = vault.previewMint(NET_SHARES);

        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);

        assertEq(vault.previewDeposit(GROSS_ASSETS), expectedShares);
        assertEq(vault.previewMint(NET_SHARES), expectedAssets);
        assertEq(vault.maxDeposit(address(this)), 0);
        assertEq(vault.maxMint(address(this)), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, address(this), GROSS_ASSETS, 0
            )
        );
        vault.deposit(GROSS_ASSETS, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, address(this), NET_SHARES, 0)
        );
        vault.mint(NET_SHARES, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, address(this), GROSS_ASSETS, 0
            )
        );
        vault.depositWithMinShares(GROSS_ASSETS, address(this), 0);

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, address(this), NET_SHARES, 0)
        );
        vault.mintWithMaxAssets(NET_SHARES, address(this), type(uint256).max);

        _assertNoDeposit();
    }

    function _deployVault() private returns (StakedUSDat deployedVault) {
        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(withdrawalQueue));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        return StakedUSDat(address(proxy));
    }

    function _setElevatedMode() private {
        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);
    }

    function _assertGrossAccounting(uint256 grossAssets, uint256 shares) private view {
        assertEq(vault.usdatBalance(), grossAssets);
        assertEq(usdat.balanceOf(address(vault)), grossAssets);
        assertEq(vault.balanceOf(address(this)), shares);
        assertEq(vault.totalSupply(), shares);
    }

    function _assertNoDeposit() private view {
        _assertGrossAccounting(0, 0);
    }
}
