// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TrancheAccountant} from "../../../src/v3/TrancheAccountant.sol";
import {TrancheAccountantFixture} from "./helpers/TrancheAccountantFixture.sol";

contract TrancheAccountantDirectRevertsTest is TrancheAccountantFixture {
    struct State {
        uint256 backing;
        uint256 incomeBearingBacking;
        uint256 baseSeniorClaim;
        uint256 seniorLiveUnits;
        uint256 crystallizedSenior;
        uint256 seniorSupply;
        uint256 juniorSupply;
        uint256 seniorBalance;
        uint256 juniorBalance;
        uint256 vaultBalance;
    }

    // ============ Deadline Reverts ============

    function test_depositSenior_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.depositSenior(1, address(this), 0, block.timestamp - 1);
    }

    function test_mintSenior_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.mintSenior(1, address(this), type(uint256).max, block.timestamp - 1);
    }

    function test_redeemSenior_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.redeemSenior(1, address(this), address(this), 0, block.timestamp - 1);
    }

    function test_withdrawSenior_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.withdrawSenior(1, address(this), address(this), type(uint256).max, block.timestamp - 1);
    }

    function test_depositJunior_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.depositJunior(1, address(this), 0, block.timestamp - 1);
    }

    function test_mintJunior_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.mintJunior(1, address(this), type(uint256).max, block.timestamp - 1);
    }

    function test_redeemJunior_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.redeemJunior(1, address(this), address(this), 0, block.timestamp - 1);
    }

    function test_withdrawJunior_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.withdrawJunior(1, address(this), address(this), type(uint256).max, block.timestamp - 1);
    }

    function test_exitFullStack_RejectsExpiredDeadline() public {
        _bootstrap();
        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.exitFullStack(1, address(this), address(this), 1, 1, 0, block.timestamp - 1);
    }

    // ============ Zero-Amount Rollback ============

    function test_depositSenior_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        accountant.depositSenior(0, address(this), 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_mintSenior_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.mintSenior(0, address(this), type(uint256).max, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_redeemSenior_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.redeemSenior(0, address(this), address(this), 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_withdrawSenior_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.withdrawSenior(0, address(this), address(this), type(uint256).max, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_depositJunior_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.depositJunior(0, address(this), 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_mintJunior_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.mintJunior(0, address(this), type(uint256).max, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_redeemJunior_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.redeemJunior(0, address(this), address(this), 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_withdrawJunior_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.withdrawJunior(0, address(this), address(this), type(uint256).max, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_exitFullStack_RejectsZeroWithoutMutation() public {
        _bootstrap();
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.InvalidAmount.selector);
        accountant.exitFullStack(0, address(this), address(this), 0, 0, 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    // ============ Slippage Rollback ============

    function test_depositJunior_RejectsMinimumSharesWithoutMutation() public {
        _bootstrap();
        uint256 assets = vault.balanceOf(address(this)) / 100;
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.depositJunior(assets, address(this), type(uint256).max, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_depositSenior_RejectsMinimumSharesWithoutMutation() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 100, address(this), 0, block.timestamp);
        uint256 assets = accountant.maxDepositSenior(address(this)) / 2;
        assertGt(assets, 0);
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.depositSenior(assets, address(this), type(uint256).max, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_mintJunior_RejectsMaximumAssetsWithoutMutation() public {
        _bootstrap();
        uint256 shares = accountant.previewDepositJunior(vault.balanceOf(address(this)) / 100);
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.mintJunior(shares, address(this), 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_mintSenior_RejectsMaximumAssetsWithoutMutation() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 100, address(this), 0, block.timestamp);
        uint256 shares = accountant.maxMintSenior(address(this)) / 2;
        assertGt(shares, 0);
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.mintSenior(shares, address(this), 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_redeemSenior_RejectsMinimumAssetsWithoutMutation() public {
        _bootstrap();
        uint256 shares = senior.balanceOf(address(this)) / 10;
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.redeemSenior(shares, address(this), address(this), type(uint256).max, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_redeemJunior_RejectsMinimumAssetsWithoutMutation() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 shares = accountant.maxRedeemJunior(address(this)) / 2;
        assertGt(shares, 0);
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.redeemJunior(shares, address(this), address(this), type(uint256).max, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_withdrawSenior_RejectsMaximumSharesWithoutMutation() public {
        _bootstrap();
        uint256 assets = accountant.maxWithdrawSenior(address(this)) / 10;
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.withdrawSenior(assets, address(this), address(this), 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_withdrawJunior_RejectsMaximumSharesWithoutMutation() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 assets = accountant.maxWithdrawJunior(address(this)) / 2;
        assertGt(assets, 0);
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.withdrawJunior(assets, address(this), address(this), 0, block.timestamp);
        _assertUnchanged(beforeState);
    }

    function test_exitFullStack_RejectsMaximumSeniorSharesWithoutMutation() public {
        _bootstrap();
        (uint256 assets, uint256 seniorShares, uint256 juniorShares) = accountant.previewFullStackExit(0.1e18);
        assertGt(assets, 0);
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.exitFullStack(
            0.1e18, address(this), address(this), seniorShares - 1, juniorShares, 0, block.timestamp
        );
        _assertUnchanged(beforeState);
    }

    function test_exitFullStack_RejectsMaximumJuniorSharesWithoutMutation() public {
        _bootstrap();
        (, uint256 seniorShares, uint256 juniorShares) = accountant.previewFullStackExit(0.1e18);
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.exitFullStack(
            0.1e18, address(this), address(this), seniorShares, juniorShares - 1, 0, block.timestamp
        );
        _assertUnchanged(beforeState);
    }

    function test_exitFullStack_RejectsMinimumAssetsWithoutMutation() public {
        _bootstrap();
        (uint256 assets, uint256 seniorShares, uint256 juniorShares) = accountant.previewFullStackExit(0.1e18);
        State memory beforeState = _snapshot();
        vm.expectRevert(TrancheAccountant.SlippageExceeded.selector);
        accountant.exitFullStack(
            0.1e18, address(this), address(this), seniorShares, juniorShares, assets + 1, block.timestamp
        );
        _assertUnchanged(beforeState);
    }

    // ============ State Helpers ============

    function _snapshot() private view returns (State memory state) {
        state = State({
            backing: accountant.backingAssets(),
            incomeBearingBacking: accountant.incomeBearingBackingAssets(),
            baseSeniorClaim: accountant.baseSeniorClaimValue(),
            seniorLiveUnits: accountant.seniorLiveUnitsWad(),
            crystallizedSenior: accountant.crystallizedSeniorValue(),
            seniorSupply: senior.totalSupply(),
            juniorSupply: junior.totalSupply(),
            seniorBalance: senior.balanceOf(address(this)),
            juniorBalance: junior.balanceOf(address(this)),
            vaultBalance: vault.balanceOf(address(this))
        });
    }

    function _assertUnchanged(State memory beforeState) private view {
        assertEq(accountant.backingAssets(), beforeState.backing);
        assertEq(accountant.incomeBearingBackingAssets(), beforeState.incomeBearingBacking);
        assertEq(accountant.baseSeniorClaimValue(), beforeState.baseSeniorClaim);
        assertEq(accountant.seniorLiveUnitsWad(), beforeState.seniorLiveUnits);
        assertEq(accountant.crystallizedSeniorValue(), beforeState.crystallizedSenior);
        assertEq(senior.totalSupply(), beforeState.seniorSupply);
        assertEq(junior.totalSupply(), beforeState.juniorSupply);
        assertEq(senior.balanceOf(address(this)), beforeState.seniorBalance);
        assertEq(junior.balanceOf(address(this)), beforeState.juniorBalance);
        assertEq(vault.balanceOf(address(this)), beforeState.vaultBalance);
    }
}
