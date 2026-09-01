// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TrancheAccountant} from "../../../src/v3/TrancheAccountant.sol";
import {TrancheShare} from "../../../src/v3/TrancheShare.sol";
import {TrancheAccountantFixture} from "./helpers/TrancheAccountantFixture.sol";

contract TrancheAccountantPolicyTest is TrancheAccountantFixture {
    // ============ Share Authority ============

    function test_shareMintAndBurn_RejectNonAccountantForBothClasses() public {
        vm.expectRevert(TrancheShare.OnlyAccountant.selector);
        senior.mint(alice, 1);
        vm.expectRevert(TrancheShare.OnlyAccountant.selector);
        senior.burn(alice, 1);

        vm.expectRevert(TrancheShare.OnlyAccountant.selector);
        junior.mint(alice, 1);
        vm.expectRevert(TrancheShare.OnlyAccountant.selector);
        junior.burn(alice, 1);
    }

    // ============ Pause Authority ============

    function test_pause_RejectsUnauthorizedCallerWithoutMutation() public {
        vm.prank(alice);
        vm.expectRevert(TrancheAccountant.UnauthorizedPause.selector);
        accountant.pause();
        assertFalse(accountant.hardPaused());
    }

    function test_unpause_RejectsUnauthorizedCallerWithoutMutation() public {
        accountant.pause();
        vm.prank(alice);
        vm.expectRevert(TrancheAccountant.UnauthorizedPause.selector);
        accountant.unpause();
        assertTrue(accountant.hardPaused());
    }

    function test_pauseAndUnpause_AllowExactAuthorities() public {
        accountant.pause();
        assertTrue(accountant.hardPaused());
        accountant.unpause();
        assertFalse(accountant.hardPaused());
    }

    // ============ Participant Validation ============

    function test_depositSenior_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.depositSenior(1, address(0), 0, block.timestamp);
    }

    function test_depositJunior_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.depositJunior(1, address(0), 0, block.timestamp);
    }

    function test_mintSenior_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.mintSenior(1, address(0), type(uint256).max, block.timestamp);
    }

    function test_mintJunior_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.mintJunior(1, address(0), type(uint256).max, block.timestamp);
    }

    function test_redeemSenior_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.redeemSenior(1, address(0), address(this), 0, block.timestamp);
    }

    function test_redeemSenior_RejectsZeroOwner() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.redeemSenior(1, address(this), address(0), 0, block.timestamp);
    }

    function test_redeemJunior_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.redeemJunior(1, address(0), address(this), 0, block.timestamp);
    }

    function test_redeemJunior_RejectsZeroOwner() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.redeemJunior(1, address(this), address(0), 0, block.timestamp);
    }

    function test_withdrawSenior_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.withdrawSenior(1, address(0), address(this), type(uint256).max, block.timestamp);
    }

    function test_withdrawSenior_RejectsZeroOwner() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.withdrawSenior(1, address(this), address(0), type(uint256).max, block.timestamp);
    }

    function test_withdrawJunior_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.withdrawJunior(1, address(0), address(this), type(uint256).max, block.timestamp);
    }

    function test_withdrawJunior_RejectsZeroOwner() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.withdrawJunior(1, address(this), address(0), type(uint256).max, block.timestamp);
    }

    function test_exitFullStack_RejectsZeroOwner() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.exitFullStack(1, address(this), address(0), 1, 1, 0, block.timestamp);
    }

    function test_exitFullStack_RejectsZeroReceiver() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.exitFullStack(1, address(0), address(this), 1, 1, 0, block.timestamp);
    }

    // ============ Delegated Allowances ============

    function test_redeemJunior_ThirdPartyRequiresAllowanceAndThenSucceeds() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 shares = accountant.maxRedeemJunior(address(this)) / 2;

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(accountant), 0, shares)
        );
        accountant.redeemJunior(shares, bob, address(this), 0, block.timestamp);

        junior.approve(address(accountant), shares);
        vm.prank(bob);
        assertGt(accountant.redeemJunior(shares, bob, address(this), 0, block.timestamp), 0);
    }

    function test_withdrawSenior_ThirdPartyRequiresAllowanceAndThenSucceeds() public {
        _bootstrap();
        uint256 assets = accountant.maxWithdrawSenior(address(this)) / 10;
        uint256 shares = accountant.previewWithdrawSenior(assets);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(accountant), 0, shares)
        );
        accountant.withdrawSenior(assets, bob, address(this), shares, block.timestamp);

        senior.approve(address(accountant), shares);
        vm.prank(bob);
        assertEq(accountant.withdrawSenior(assets, bob, address(this), shares, block.timestamp), shares);
    }

    function test_withdrawJunior_ThirdPartyRequiresAllowanceAndThenSucceeds() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 assets = accountant.maxWithdrawJunior(address(this)) / 10;
        uint256 shares = accountant.previewWithdrawJunior(assets);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(accountant), 0, shares)
        );
        accountant.withdrawJunior(assets, bob, address(this), shares, block.timestamp);

        junior.approve(address(accountant), shares);
        vm.prank(bob);
        assertEq(accountant.withdrawJunior(assets, bob, address(this), shares, block.timestamp), shares);
    }

    function test_exitFullStack_ThirdPartyRequiresBothAllowancesAndThenSucceeds() public {
        _bootstrap();
        uint256 fraction = WAD / 10;
        (uint256 assets, uint256 seniorShares, uint256 juniorShares) = accountant.previewFullStackExit(fraction);

        senior.approve(address(accountant), seniorShares);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(accountant), 0, juniorShares
            )
        );
        accountant.exitFullStack(fraction, bob, address(this), seniorShares, juniorShares, assets, block.timestamp);

        junior.approve(address(accountant), juniorShares);
        vm.prank(bob);
        (uint256 paid,,) =
            accountant.exitFullStack(fraction, bob, address(this), seniorShares, juniorShares, assets, block.timestamp);
        assertEq(paid, assets);
    }

    // ============ Account Restrictions ============

    function test_depositSenior_RestrictedReceiverHasZeroLimitsAndReverts() public {
        _bootstrap();
        vault.addToBlacklist(alice);
        assertEq(accountant.maxDepositSenior(alice), 0);
        assertEq(accountant.maxMintSenior(alice), 0);
        vm.expectRevert(abi.encodeWithSelector(TrancheAccountant.RestrictedAccount.selector, alice));
        accountant.depositSenior(1, alice, 0, block.timestamp);
    }

    function test_depositJunior_RestrictedReceiverHasZeroLimitsAndReverts() public {
        _bootstrap();
        vault.addToBlacklist(alice);
        assertEq(accountant.maxDepositJunior(alice), 0);
        assertEq(accountant.maxMintJunior(alice), 0);
        vm.expectRevert(abi.encodeWithSelector(TrancheAccountant.RestrictedAccount.selector, alice));
        accountant.depositJunior(1, alice, 0, block.timestamp);
    }

    function test_redeemSenior_RejectsRestrictedCaller() public {
        _bootstrap();
        vault.addToBlacklist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TrancheAccountant.RestrictedAccount.selector, bob));
        accountant.redeemSenior(1, alice, address(this), 0, block.timestamp);
    }

    function test_redeemJunior_RejectsRestrictedCaller() public {
        _bootstrap();
        vault.addToBlacklist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TrancheAccountant.RestrictedAccount.selector, bob));
        accountant.redeemJunior(1, alice, address(this), 0, block.timestamp);
    }

    function test_redeemSenior_RestrictedOwnerHasZeroLimitsAndReverts() public {
        _bootstrap();
        assertTrue(senior.transfer(alice, senior.balanceOf(address(this)) / 10));
        vault.addToBlacklist(alice);
        assertEq(accountant.maxRedeemSenior(alice), 0);
        assertEq(accountant.maxWithdrawSenior(alice), 0);
        vm.expectRevert(abi.encodeWithSelector(TrancheAccountant.RestrictedAccount.selector, alice));
        accountant.redeemSenior(1, address(this), alice, 0, block.timestamp);
    }

    function test_redeemJunior_RestrictedOwnerHasZeroLimitsAndReverts() public {
        _bootstrap();
        assertTrue(junior.transfer(alice, junior.balanceOf(address(this)) / 10));
        vault.addToBlacklist(alice);
        assertEq(accountant.maxRedeemJunior(alice), 0);
        assertEq(accountant.maxWithdrawJunior(alice), 0);
        vm.expectRevert(abi.encodeWithSelector(TrancheAccountant.RestrictedAccount.selector, alice));
        accountant.redeemJunior(1, address(this), alice, 0, block.timestamp);
    }

    function test_redeemSenior_RejectsRestrictedReceiver() public {
        _bootstrap();
        vault.addToBlacklist(alice);
        vm.expectRevert(abi.encodeWithSelector(TrancheAccountant.RestrictedAccount.selector, alice));
        accountant.redeemSenior(1, alice, address(this), 0, block.timestamp);
    }

    function test_redeemJunior_RejectsRestrictedReceiver() public {
        _bootstrap();
        vault.addToBlacklist(alice);
        vm.expectRevert(abi.encodeWithSelector(TrancheAccountant.RestrictedAccount.selector, alice));
        accountant.redeemJunior(1, alice, address(this), 0, block.timestamp);
    }

    // ============ Transfer Restrictions ============

    function test_seniorTransfer_RejectsRestrictedSender() public {
        _assertRestrictedSender(senior);
    }

    function test_juniorTransfer_RejectsRestrictedSender() public {
        _assertRestrictedSender(junior);
    }

    function test_seniorTransfer_RejectsRestrictedReceiver() public {
        _assertRestrictedReceiver(senior);
    }

    function test_juniorTransfer_RejectsRestrictedReceiver() public {
        _assertRestrictedReceiver(junior);
    }

    function test_seniorTransferFrom_RejectsRestrictedOperator() public {
        _assertRestrictedOperator(senior);
    }

    function test_juniorTransferFrom_RejectsRestrictedOperator() public {
        _assertRestrictedOperator(junior);
    }

    // ============ Helpers ============

    function _assertRestrictedSender(TrancheShare token) private {
        _bootstrap();
        assertTrue(token.transfer(alice, token.balanceOf(address(this)) / 10));
        vault.addToBlacklist(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TrancheShare.RestrictedAccount.selector, alice));
        token.transfer(bob, 1);
    }

    function _assertRestrictedReceiver(TrancheShare token) private {
        _bootstrap();
        vault.addToBlacklist(bob);
        vm.expectRevert(abi.encodeWithSelector(TrancheShare.RestrictedAccount.selector, bob));
        token.transfer(bob, 1);
    }

    function _assertRestrictedOperator(TrancheShare token) private {
        _bootstrap();
        token.approve(bob, 1);
        vault.addToBlacklist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TrancheShare.RestrictedAccount.selector, bob));
        token.transferFrom(address(this), alice, 1);
    }
}
