// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IAccountingModule} from "../../../src/v2/interfaces/modules/IAccountingModule.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ITradableModule} from "../../../src/v2/interfaces/modules/ITradableModule.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {BoundMirrorModuleMock, V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract RescueTokenMock is ERC20 {
    uint8 private immutable _TOKEN_DECIMALS;
    mapping(address account => bool frozen) public isFrozen;

    constructor(string memory name_, string memory symbol_, uint8 tokenDecimals_) ERC20(name_, symbol_) {
        _TOKEN_DECIMALS = tokenDecimals_;
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

    function setFrozen(address account, bool frozen) external {
        isFrozen[account] = frozen;
    }
}

contract RescueAccountingModuleMock is IAccountingModule, BoundMirrorModuleMock {
    constructor(address vault) BoundMirrorModuleMock(vault) {}

    function recognizedValue() external pure returns (uint256) {
        return 0;
    }

    function balance() external pure returns (uint256) {
        return 0;
    }
}

contract RescueTradableModuleMock is ITradableModule {
    error PricingRead();

    address public immutable VAULT;
    address public immutable ASSET;
    uint256 public balance;
    bool private _pricingFails;

    constructor(address vault, address asset_) {
        VAULT = vault;
        ASSET = asset_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function setBalance(uint256 newBalance) external {
        balance = newBalance;
    }

    function setPricingFails(bool pricingFails) external {
        _pricingFails = pricingFails;
    }

    function recognizedValue() external view returns (uint256) {
        if (_pricingFails) revert PricingRead();
        return 0;
    }

    function getPrice() external view returns (uint256) {
        if (_pricingFails) revert PricingRead();
        return 0;
    }

    function buy(uint256) external pure {}

    function sell(uint256) external pure {}
}

contract StakedUSDatRescueTest is Test {
    uint256 private constant INITIAL_CASH = 1_000e6;
    uint256 private constant SURPLUS = 50e6;
    uint256 private constant USDAT_EXCESS = 7e6;
    uint256 private constant TRACKED_STRCON = 80e18;
    uint256 private constant STRCON_EXCESS = 3e18;
    uint256 private constant OTHER_EXCESS = 17e18;

    RescueTokenMock private usdat;
    RescueTokenMock private strcon;
    RescueTokenMock private otherToken;
    RescueAccountingModuleMock private mirrorModule;
    RescueTradableModuleMock private strconModule;
    StakedUSDat private vault;

    address private unauthorized = makeAddr("unauthorized");
    address private enforcer = makeAddr("enforcer");
    address private recoveryAddress = makeAddr("recoveryAddress");

    function setUp() public {
        vm.warp(1_000_000);

        usdat = new RescueTokenMock("USDat", "USDat", 6);
        strcon = new RescueTokenMock("STRCon", "STRCon", 18);
        otherToken = new RescueTokenMock("Other", "OTHER", 18);
        vault = _deployVault();
        mirrorModule = new RescueAccountingModuleMock(address(vault));
        strconModule = new RescueTradableModuleMock(address(vault), address(strcon));

        V2InitializationHelper.initialize(vault, address(mirrorModule), address(strconModule), 5, 10, 25);
        vault.grantRole(vault.OPERATOR_ROLE(), address(this));
        vault.grantRole(vault.PAUSER_ROLE(), address(this));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.ENFORCER_ROLE(), address(this));
        vault.setRecoveryAddress(recoveryAddress);

        usdat.mint(address(this), INITIAL_CASH + SURPLUS);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(INITIAL_CASH, address(this));
    }

    function test_rescueTokens_RequiresEnforcerRole() public {
        otherToken.mint(address(vault), OTHER_EXCESS);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.ENFORCER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.rescueTokens(address(otherToken), OTHER_EXCESS);

        assertEq(otherToken.balanceOf(address(vault)), OTHER_EXCESS);
        assertEq(otherToken.balanceOf(recoveryAddress), 0);
    }

    function test_rescueTokens_DefaultAdminWithoutEnforcerRoleCannotRescue() public {
        otherToken.mint(address(vault), OTHER_EXCESS);
        vault.revokeRole(vault.ENFORCER_ROLE(), address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), vault.ENFORCER_ROLE()
            )
        );
        vault.rescueTokens(address(otherToken), OTHER_EXCESS);

        assertEq(otherToken.balanceOf(address(vault)), OTHER_EXCESS);
        assertEq(otherToken.balanceOf(recoveryAddress), 0);
    }

    function test_rescueTokens_EnforcerWithoutDefaultAdminRoleCanRescue() public {
        otherToken.mint(address(vault), OTHER_EXCESS);
        vault.grantRole(vault.ENFORCER_ROLE(), enforcer);

        vm.prank(enforcer);
        vault.rescueTokens(address(otherToken), OTHER_EXCESS);

        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), enforcer));
        assertEq(otherToken.balanceOf(address(vault)), 0);
        assertEq(otherToken.balanceOf(recoveryAddress), OTHER_EXCESS);
    }

    function test_rescueTokens_RescuesExactUntrackedTokenBalanceWithoutChangingAccounting() public {
        otherToken.mint(address(vault), OTHER_EXCESS);
        uint256 navBefore = vault.totalAssets();

        vm.expectRevert(IStakedUSDat.ExceedsRescuable.selector);
        vault.rescueTokens(address(otherToken), OTHER_EXCESS + 1);

        vault.rescueTokens(address(otherToken), OTHER_EXCESS);

        assertEq(otherToken.balanceOf(address(vault)), 0);
        assertEq(otherToken.balanceOf(recoveryAddress), OTHER_EXCESS);
        assertEq(vault.usdatBalance(), INITIAL_CASH);
        assertEq(vault.surplusVestingAmount(), 0);
        assertEq(vault.totalAssets(), navBefore);
    }

    function test_rescueTokens_ProtectsTrackedUSDatAndFullUnsweptSurplus() public {
        vault.transferInSurplus(SURPLUS);
        vm.warp(block.timestamp + vault.surplusVestingPeriod());
        usdat.mint(address(vault), USDAT_EXCESS);
        strconModule.setPricingFails(true);

        vm.expectRevert(IStakedUSDat.ExceedsRescuable.selector);
        vault.rescueTokens(address(usdat), USDAT_EXCESS + 1);

        vault.rescueTokens(address(usdat), USDAT_EXCESS);

        assertEq(usdat.balanceOf(address(vault)), INITIAL_CASH + SURPLUS);
        assertEq(usdat.balanceOf(recoveryAddress), USDAT_EXCESS);
        assertEq(vault.usdatBalance(), INITIAL_CASH);
        assertEq(vault.surplusVestingAmount(), SURPLUS);
    }

    function test_rescueTokens_ProtectsRemainingUnsweptSurplusWithoutDoubleCountingSweptAmount() public {
        vault.transferInSurplus(SURPLUS);
        vm.warp(block.timestamp + vault.surplusVestingPeriod() / 2);

        uint256 unvested = vault.getUnvestedSurplus();
        uint256 vested = SURPLUS - unvested;
        vault.sweep();
        usdat.mint(address(vault), USDAT_EXCESS);

        vm.expectRevert(IStakedUSDat.ExceedsRescuable.selector);
        vault.rescueTokens(address(usdat), USDAT_EXCESS + 1);

        vault.rescueTokens(address(usdat), USDAT_EXCESS);

        assertEq(vault.usdatBalance(), INITIAL_CASH + vested);
        assertEq(vault.surplusVestingAmount(), SURPLUS);
        assertEq(usdat.balanceOf(address(vault)), vault.usdatBalance() + unvested);
        assertEq(usdat.balanceOf(recoveryAddress), USDAT_EXCESS);
    }

    function test_rescueTokens_ProtectsTrackedSTRConWithoutPricing() public {
        strconModule.setBalance(TRACKED_STRCON);
        strcon.mint(address(vault), TRACKED_STRCON + STRCON_EXCESS);
        strconModule.setPricingFails(true);

        vm.expectRevert(IStakedUSDat.ExceedsRescuable.selector);
        vault.rescueTokens(address(strcon), STRCON_EXCESS + 1);

        vault.rescueTokens(address(strcon), STRCON_EXCESS);

        assertEq(strcon.balanceOf(address(vault)), TRACKED_STRCON);
        assertEq(strcon.balanceOf(recoveryAddress), STRCON_EXCESS);
        assertEq(strconModule.balance(), TRACKED_STRCON);
    }

    function test_rescueTokens_FailsClosedOnUSDatCustodyShortfallEvenForZeroAmount() public {
        usdat.burn(address(vault), 1);

        vm.expectRevert(IStakedUSDat.ExceedsRescuable.selector);
        vault.rescueTokens(address(usdat), 0);

        assertEq(usdat.balanceOf(address(vault)), INITIAL_CASH - 1);
        assertEq(vault.usdatBalance(), INITIAL_CASH);
    }

    function test_rescueTokens_FailsClosedOnSTRConCustodyShortfallEvenForZeroAmount() public {
        strconModule.setBalance(TRACKED_STRCON);
        strcon.mint(address(vault), TRACKED_STRCON - 1);
        strconModule.setPricingFails(true);

        vm.expectRevert(IStakedUSDat.ExceedsRescuable.selector);
        vault.rescueTokens(address(strcon), 0);

        assertEq(strcon.balanceOf(address(vault)), TRACKED_STRCON - 1);
        assertEq(strconModule.balance(), TRACKED_STRCON);
    }

    function test_rescueTokens_RemainsCallableWhilePaused() public {
        otherToken.mint(address(vault), OTHER_EXCESS);
        vault.pause();

        vault.rescueTokens(address(otherToken), OTHER_EXCESS);

        assertTrue(vault.paused());
        assertEq(otherToken.balanceOf(recoveryAddress), OTHER_EXCESS);
    }

    function test_rescueTokens_RevalidatesRecoveryAddressAtExecution() public {
        otherToken.mint(address(vault), OTHER_EXCESS);
        usdat.setFrozen(recoveryAddress, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vault.rescueTokens(address(otherToken), OTHER_EXCESS);

        assertEq(otherToken.balanceOf(address(vault)), OTHER_EXCESS);
        assertEq(otherToken.balanceOf(recoveryAddress), 0);
    }

    function _deployVault() private returns (StakedUSDat deployedVault) {
        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(makeAddr("withdrawalQueue")));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        return StakedUSDat(address(proxy));
    }
}
