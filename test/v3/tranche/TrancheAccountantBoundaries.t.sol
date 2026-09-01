// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TrancheAccountant} from "../../../src/v3/TrancheAccountant.sol";
import {TrancheAccountantFixture} from "./helpers/TrancheAccountantFixture.sol";

contract TrancheAccountantBoundariesTest is TrancheAccountantFixture {
    uint256 private constant VALUE_SCALE = 1e12;

    // ============ Near-Capacity Success ============

    function test_depositSenior_AllowsOneUnitBelowReportedCapacity() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 limit = accountant.maxDepositSenior(address(this));
        assertGt(limit, 1);
        uint256 assets = limit - 1;
        uint256 backingBefore = accountant.backingAssets();

        accountant.depositSenior(assets, address(this), accountant.previewDepositSenior(assets), block.timestamp);

        assertEq(accountant.backingAssets(), backingBefore + assets);
    }

    function test_mintSenior_AllowsOneUnitBelowReportedCapacity() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 limit = accountant.maxMintSenior(address(this));
        assertGt(limit, 1);
        uint256 shares = limit - 1;
        uint256 expectedAssets = accountant.previewMintSenior(shares);
        uint256 backingBefore = accountant.backingAssets();

        assertEq(accountant.mintSenior(shares, address(this), expectedAssets, block.timestamp), expectedAssets);
        assertEq(accountant.backingAssets(), backingBefore + expectedAssets);
    }

    function test_redeemJunior_AllowsOneUnitBelowReportedCapacity() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 limit = accountant.maxRedeemJunior(address(this));
        assertGt(limit, 1);
        uint256 shares = limit - 1;
        uint256 assets = accountant.previewRedeemJunior(shares);
        uint256 backingBefore = accountant.backingAssets();

        accountant.redeemJunior(shares, address(this), address(this), assets, block.timestamp);

        assertEq(accountant.backingAssets(), backingBefore - assets);
        assertGe(accountant.coverageWad(), accountant.PREFERRED_COVERAGE_WAD());
    }

    function test_withdrawJunior_AllowsOneUnitBelowReportedCapacity() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 limit = accountant.maxWithdrawJunior(address(this));
        assertGt(limit, 1);
        uint256 assets = limit - 1;
        uint256 expectedShares = accountant.previewWithdrawJunior(assets);
        uint256 backingBefore = accountant.backingAssets();

        assertEq(
            accountant.withdrawJunior(assets, address(this), address(this), expectedShares, block.timestamp),
            expectedShares
        );
        assertEq(accountant.backingAssets(), backingBefore - assets);
        assertGe(accountant.coverageWad(), accountant.PREFERRED_COVERAGE_WAD());
    }

    // ============ Exact Action Accounting ============

    function test_depositSenior_MintsExactPreviewAndMovesExactBacking() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 assets = accountant.maxDepositSenior(address(this)) / 2;
        uint256 expectedShares = Math.mulDiv(
            vault.convertToAssets(assets), senior.totalSupply(), accountant.seniorClaimValue(), Math.Rounding.Floor
        );
        assertEq(accountant.previewDepositSenior(assets), expectedShares);
        uint256 backingBefore = accountant.backingAssets();

        uint256 shares = accountant.depositSenior(assets, alice, expectedShares, block.timestamp);

        assertEq(shares, expectedShares);
        assertEq(senior.balanceOf(alice), expectedShares);
        assertEq(accountant.backingAssets(), backingBefore + assets);
    }

    function test_mintSenior_PullsExactPreviewAndMintsExactShares() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 shares = accountant.maxMintSenior(address(this)) / 2;
        uint256 expectedValue =
            Math.mulDiv(shares, accountant.seniorClaimValue(), senior.totalSupply(), Math.Rounding.Ceil);
        uint256 expectedAssets = _sharesForValueUp(expectedValue);
        assertEq(accountant.previewMintSenior(shares), expectedAssets);
        uint256 backingBefore = accountant.backingAssets();

        uint256 assets = accountant.mintSenior(shares, alice, expectedAssets, block.timestamp);

        assertEq(assets, expectedAssets);
        assertEq(senior.balanceOf(alice), shares);
        assertEq(accountant.backingAssets(), backingBefore + expectedAssets);
    }

    function test_redeemSenior_PaysExactPreviewAndBurnsExactShares() public {
        _bootstrap();
        uint256 shares = senior.balanceOf(address(this)) / 10;
        uint256 expectedValue =
            Math.mulDiv(shares, accountant.seniorClaimValue(), senior.totalSupply(), Math.Rounding.Floor);
        uint256 expectedAssets = vault.convertToShares(expectedValue);
        assertEq(accountant.previewRedeemSenior(shares), expectedAssets);
        uint256 backingBefore = accountant.backingAssets();
        uint256 receiverBefore = vault.balanceOf(alice);

        uint256 assets = accountant.redeemSenior(shares, alice, address(this), expectedAssets, block.timestamp);

        assertEq(assets, expectedAssets);
        assertEq(vault.balanceOf(alice), receiverBefore + expectedAssets);
        assertEq(accountant.backingAssets(), backingBefore - expectedAssets);
    }

    function test_withdrawSenior_BurnsExactPreviewAndPaysExactAssets() public {
        _bootstrap();
        uint256 assets = accountant.maxWithdrawSenior(address(this)) / 10;
        uint256 expectedShares = Math.mulDiv(
            vault.convertToAssets(assets), senior.totalSupply(), accountant.seniorClaimValue(), Math.Rounding.Ceil
        );
        assertEq(accountant.previewWithdrawSenior(assets), expectedShares);
        uint256 sharesBefore = senior.balanceOf(address(this));
        uint256 backingBefore = accountant.backingAssets();

        uint256 shares = accountant.withdrawSenior(assets, alice, address(this), expectedShares, block.timestamp);

        assertEq(shares, expectedShares);
        assertEq(senior.balanceOf(address(this)), sharesBefore - expectedShares);
        assertEq(vault.balanceOf(alice), assets);
        assertEq(accountant.backingAssets(), backingBefore - assets);
    }

    function test_depositJunior_MintsExactPreviewAndMovesExactBacking() public {
        _bootstrap();
        uint256 assets = vault.balanceOf(address(this)) / 100;
        uint256 expectedShares = Math.mulDiv(
            vault.convertToAssets(assets), junior.totalSupply(), accountant.juniorResidualValue(), Math.Rounding.Floor
        );
        assertEq(accountant.previewDepositJunior(assets), expectedShares);
        uint256 backingBefore = accountant.backingAssets();

        uint256 shares = accountant.depositJunior(assets, alice, expectedShares, block.timestamp);

        assertEq(shares, expectedShares);
        assertEq(junior.balanceOf(alice), expectedShares);
        assertEq(accountant.backingAssets(), backingBefore + assets);
    }

    function test_mintJunior_PullsExactPreviewAndMintsExactShares() public {
        _bootstrap();
        uint256 shares = junior.totalSupply() / 100;
        uint256 expectedValue =
            Math.mulDiv(shares, accountant.juniorResidualValue(), junior.totalSupply(), Math.Rounding.Ceil);
        uint256 expectedAssets = _sharesForValueUp(expectedValue);
        assertEq(accountant.previewMintJunior(shares), expectedAssets);
        uint256 backingBefore = accountant.backingAssets();

        uint256 assets = accountant.mintJunior(shares, alice, expectedAssets, block.timestamp);

        assertEq(assets, expectedAssets);
        assertEq(junior.balanceOf(alice), shares);
        assertEq(accountant.backingAssets(), backingBefore + expectedAssets);
    }

    function test_redeemJunior_PaysExactPreviewAndBurnsExactShares() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 shares = accountant.maxRedeemJunior(address(this)) / 2;
        uint256 expectedValue =
            Math.mulDiv(shares, accountant.juniorResidualValue(), junior.totalSupply(), Math.Rounding.Floor);
        uint256 expectedAssets = vault.convertToShares(expectedValue);
        assertEq(accountant.previewRedeemJunior(shares), expectedAssets);
        uint256 backingBefore = accountant.backingAssets();

        uint256 assets = accountant.redeemJunior(shares, alice, address(this), expectedAssets, block.timestamp);

        assertEq(assets, expectedAssets);
        assertEq(vault.balanceOf(alice), expectedAssets);
        assertEq(accountant.backingAssets(), backingBefore - expectedAssets);
    }

    function test_withdrawJunior_BurnsExactPreviewAndPaysExactAssets() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 assets = accountant.maxWithdrawJunior(address(this)) / 2;
        uint256 expectedShares = Math.mulDiv(
            vault.convertToAssets(assets), junior.totalSupply(), accountant.juniorResidualValue(), Math.Rounding.Ceil
        );
        assertEq(accountant.previewWithdrawJunior(assets), expectedShares);
        uint256 sharesBefore = junior.balanceOf(address(this));
        uint256 backingBefore = accountant.backingAssets();

        uint256 shares = accountant.withdrawJunior(assets, alice, address(this), expectedShares, block.timestamp);

        assertEq(shares, expectedShares);
        assertEq(junior.balanceOf(address(this)), sharesBefore - expectedShares);
        assertEq(vault.balanceOf(alice), assets);
        assertEq(accountant.backingAssets(), backingBefore - assets);
    }

    // ============ Capacity Boundaries ============

    function test_redeemJunior_AllowsReportedLimitAndRejectsFirstValueAboveCapacity() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 capacityValue = accountant.juniorRedemptionCapacityValue();
        uint256 residualValue = accountant.juniorResidualValue();
        uint256 supply = junior.totalSupply();
        uint256 atCapacityShares = accountant.maxRedeemJunior(address(this));
        uint256 aboveCapacityShares = Math.mulDiv(capacityValue + 1, supply, residualValue, Math.Rounding.Ceil);
        assertLe(aboveCapacityShares, junior.balanceOf(address(this)));

        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        accountant.redeemJunior(aboveCapacityShares, address(this), address(this), 0, block.timestamp);

        uint256 expectedAssets = accountant.previewRedeemJunior(atCapacityShares);
        assertEq(
            accountant.redeemJunior(atCapacityShares, address(this), address(this), expectedAssets, block.timestamp),
            expectedAssets
        );
        assertGe(accountant.coverageWad(), accountant.PREFERRED_COVERAGE_WAD());
    }

    function test_withdrawJunior_AllowsValueAtCapacityAndRejectsFirstValueAbove() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 capacity = accountant.juniorRedemptionCapacityValue();
        assertGt(capacity, 0);
        uint256 aboveCapacityAssets = vault.convertToShares(capacity + 1) + 1;

        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        accountant.withdrawJunior(aboveCapacityAssets, address(this), address(this), type(uint256).max, block.timestamp);

        uint256 atCapacityAssets = vault.convertToShares(capacity);
        uint256 shares = accountant.withdrawJunior(
            atCapacityAssets, address(this), address(this), type(uint256).max, block.timestamp
        );
        assertGt(shares, 0);
        assertGe(accountant.coverageWad(), accountant.PREFERRED_COVERAGE_WAD());
    }

    function test_depositSenior_AllowsReportedLimitAndRejectsFirstValueAboveCapacity() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 capacityValue = accountant.seniorDepositCapacityValue();
        uint256 atCapacityAssets = vault.convertToShares(capacityValue);
        uint256 aboveCapacityAssets = vault.convertToShares(capacityValue + 1) + 1;
        assertLe(vault.convertToAssets(atCapacityAssets), capacityValue);
        assertGt(vault.convertToAssets(aboveCapacityAssets), capacityValue);

        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        accountant.depositSenior(aboveCapacityAssets, address(this), 0, block.timestamp);

        uint256 backingBefore = accountant.backingAssets();
        accountant.depositSenior(atCapacityAssets, address(this), 0, block.timestamp);
        assertEq(accountant.backingAssets(), backingBefore + atCapacityAssets);
    }

    function test_mintSenior_AllowsReportedLimitAndRejectsFirstShareAboveCapacity() public {
        _bootstrap();
        accountant.depositJunior(vault.balanceOf(address(this)) / 20, address(this), 0, block.timestamp);
        uint256 limit = accountant.maxMintSenior(address(this));
        assertGt(limit, 0);

        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        accountant.mintSenior(limit + 1, address(this), type(uint256).max, block.timestamp);

        uint256 expectedAssets = accountant.previewMintSenior(limit);
        uint256 backingBefore = accountant.backingAssets();
        assertEq(accountant.mintSenior(limit, address(this), expectedAssets, block.timestamp), expectedAssets);
        assertEq(accountant.backingAssets(), backingBefore + expectedAssets);
    }

    // ============ Time and Rounding Boundaries ============

    function test_deadline_AllowsExactCurrentTimestampAndRejectsOneSecondBefore() public {
        _bootstrap();
        uint256 assets = vault.balanceOf(address(this)) / 100;
        accountant.depositJunior(assets, address(this), 0, block.timestamp);

        vm.expectRevert(TrancheAccountant.ExpiredDeadline.selector);
        accountant.depositJunior(assets, address(this), 0, block.timestamp - 1);
    }

    function test_zeroSupplyPreviewsUseIndependentValueScaleAndRoundUp() public view {
        uint256 assets = vault.balanceOf(address(this)) / 100;
        uint256 value = vault.convertToAssets(assets);
        uint256 shares = value * VALUE_SCALE + 1;

        assertEq(accountant.previewDepositSenior(assets), value * VALUE_SCALE);
        assertEq(accountant.previewMintSenior(shares), _sharesForValueUp(Math.ceilDiv(shares, VALUE_SCALE)));
        assertEq(accountant.previewDepositJunior(assets), value * VALUE_SCALE);
        assertEq(accountant.previewMintJunior(shares), _sharesForValueUp(Math.ceilDiv(shares, VALUE_SCALE)));
    }

    // ============ Helpers ============

    function _sharesForValueUp(uint256 value) private view returns (uint256 shares) {
        shares = vault.convertToShares(value);
        if (vault.convertToAssets(shares) < value) ++shares;
    }
}
