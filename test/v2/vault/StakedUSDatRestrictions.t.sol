// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {ZeroAccountingModuleMock, ZeroTradableModuleMock} from "../helpers/FixedModuleMocks.sol";
import {V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract RestrictionsUSDatMock is ERC20 {
    mapping(address account => bool frozen) public isFrozen;

    constructor() ERC20("USDat", "USDat") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFrozen(address account, bool frozen) external {
        isFrozen[account] = frozen;
    }
}

contract RestrictionsWithdrawalQueueMock {
    function addRequest(address, uint256, uint256) external pure returns (uint256) {
        return 1;
    }
}

contract StakedUSDatRestrictionsTest is Test {
    uint256 private constant INITIAL_DEPOSIT = 100e6;

    RestrictionsUSDatMock private usdat;
    StakedUSDat private vault;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private spender = makeAddr("spender");

    function setUp() public {
        usdat = new RestrictionsUSDatMock();
        RestrictionsWithdrawalQueueMock withdrawalQueue = new RestrictionsWithdrawalQueueMock();

        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(address(withdrawalQueue)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        vault = StakedUSDat(address(proxy));

        ZeroAccountingModuleMock strcMirrorModule = new ZeroAccountingModuleMock(address(vault));
        ZeroTradableModuleMock strconModule = new ZeroTradableModuleMock(address(vault));
        V2InitializationHelper.initialize(vault, address(strcMirrorModule), address(strconModule), 0, 0, 0);

        usdat.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();
    }

    function test_transfer_RejectsUSDatFrozenSender() public {
        usdat.setFrozen(alice, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vm.prank(alice);
        // Return value is unreachable because the call must revert.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transfer(bob, 1e18);
    }

    function test_transfer_RejectsUSDatFrozenReceiver() public {
        usdat.setFrozen(bob, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vm.prank(alice);
        // Return value is unreachable because the call must revert.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transfer(bob, 1e18);
    }

    function test_transferFrom_RejectsUSDatFrozenOwner() public {
        vm.prank(alice);
        vault.approve(spender, 1e18);
        usdat.setFrozen(alice, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vm.prank(spender);
        // Return value is unreachable because the call must revert.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transferFrom(alice, bob, 1e18);
    }

    function test_transferFrom_RejectsLocallyBlacklistedOperatorAndPreservesState() public {
        uint256 allowance = 2e18;
        uint256 amount = 1e18;
        vm.prank(alice);
        vault.approve(spender, allowance);
        vault.addToBlacklist(spender);

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        uint256 bobBalanceBefore = vault.balanceOf(bob);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vm.prank(spender);
        // Return value is unreachable because the call must revert.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transferFrom(alice, bob, amount);

        assertEq(vault.allowance(alice, spender), allowance);
        assertEq(vault.balanceOf(alice), aliceBalanceBefore);
        assertEq(vault.balanceOf(bob), bobBalanceBefore);
    }

    function test_transferFrom_RejectsUSDatFrozenOperatorAndPreservesState() public {
        uint256 allowance = 2e18;
        uint256 amount = 1e18;
        vm.prank(alice);
        vault.approve(spender, allowance);
        usdat.setFrozen(spender, true);

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        uint256 bobBalanceBefore = vault.balanceOf(bob);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vm.prank(spender);
        // Return value is unreachable because the call must revert.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transferFrom(alice, bob, amount);

        assertEq(vault.allowance(alice, spender), allowance);
        assertEq(vault.balanceOf(alice), aliceBalanceBefore);
        assertEq(vault.balanceOf(bob), bobBalanceBefore);
    }

    function test_transferFrom_AllowsUnrestrictedApprovedOperator() public {
        uint256 allowance = 2e18;
        uint256 amount = 1e18;
        vm.prank(alice);
        vault.approve(spender, allowance);

        uint256 aliceBalanceBefore = vault.balanceOf(alice);

        vm.prank(spender);
        assertTrue(vault.transferFrom(alice, bob, amount));

        assertEq(vault.allowance(alice, spender), allowance - amount);
        assertEq(vault.balanceOf(alice), aliceBalanceBefore - amount);
        assertEq(vault.balanceOf(bob), amount);
    }

    function test_deposit_RejectsUSDatFrozenCaller() public {
        usdat.setFrozen(alice, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vm.prank(alice);
        vault.deposit(1e6, bob);
    }

    function test_deposit_RejectsUSDatFrozenReceiver() public {
        usdat.setFrozen(bob, true);

        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, bob, 1e6, 0));
        vm.prank(alice);
        vault.deposit(1e6, bob);
    }

    function test_maxDepositAndMaxMint_ReturnZeroForRestrictedReceiver() public {
        assertEq(vault.maxDeposit(bob), type(uint256).max);
        assertEq(vault.maxMint(bob), type(uint256).max);

        vault.addToBlacklist(bob);
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);

        vault.removeFromBlacklist(bob);
        usdat.setFrozen(bob, true);
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
    }

    function test_requestRedeem_RejectsUSDatFrozenOwner() public {
        uint256 shares = vault.MIN_REQUEST_SHARES();
        usdat.setFrozen(alice, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vm.prank(alice);
        vault.requestRedeem(shares, 0);
    }

    function test_isRestricted_CombinesSUSDatBlacklistAndUSDatFreeze() public {
        assertFalse(vault.isRestricted(bob));

        usdat.setFrozen(bob, true);
        assertTrue(vault.isRestricted(bob));
        assertFalse(vault.isBlacklisted(bob));

        usdat.setFrozen(bob, false);
        vault.addToBlacklist(bob);
        assertTrue(vault.isRestricted(bob));
        assertTrue(vault.isBlacklisted(bob));
    }

    function test_removeFromBlacklist_DoesNotClearUSDatRestriction() public {
        vault.addToBlacklist(bob);
        usdat.setFrozen(bob, true);

        vault.removeFromBlacklist(bob);

        assertFalse(vault.isBlacklisted(bob));
        assertTrue(vault.isRestricted(bob));
    }
}
