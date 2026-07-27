// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract StakedUSDatMarketModeHarness is StakedUSDat {
    constructor(address manager) StakedUSDat(IWithdrawalQueueERC721(address(1))) {
        _grantRole(MARKET_MODE_MANAGER_ROLE, manager);
        _grantRole(PARAMETER_MANAGER_ROLE, manager);
        _grantRole(PAUSER_ROLE, manager);
    }

    function guardedOperation() external view whenNotRestricted returns (bool) {
        return true;
    }
}

contract StakedUSDatMarketModeTest is Test {
    StakedUSDatMarketModeHarness private vault;

    address private unauthorized = makeAddr("unauthorized");

    event MarketModeChanged(IStakedUSDat.MarketMode oldMode, IStakedUSDat.MarketMode newMode);
    event RegularModeAuthorized(uint64 validUntil);

    function setUp() public {
        vm.warp(100 days);
        vault = new StakedUSDatMarketModeHarness(address(this));
        vault.setRedemptionFees(5, 10);
        vault.setElevatedDepositFee(25);
    }

    function test_DefaultExpiredRegularConfigurationIsEffectivelyElevated() public view {
        assertEq(vault.regularModeValidUntil(), 0);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));
        assertEq(vault.redemptionFeeBps(), 10);
        assertEq(vault.depositFeeBps(), 25);
    }

    function test_authorizeRegularMode_AcceptsMaximumAndExpiresAtExactDeadline() public {
        uint64 validUntil = uint64(block.timestamp + 8 hours);

        vm.expectEmit(false, false, false, true, address(vault));
        emit MarketModeChanged(IStakedUSDat.MarketMode.Elevated, IStakedUSDat.MarketMode.Regular);
        vm.expectEmit(false, false, false, true, address(vault));
        emit RegularModeAuthorized(validUntil);
        vault.authorizeRegularMode(validUntil);

        assertEq(vault.MAX_REGULAR_MODE_VALIDITY(), 8 hours);
        assertEq(vault.regularModeValidUntil(), validUntil);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Regular));
        assertEq(vault.redemptionFeeBps(), 5);
        assertEq(vault.depositFeeBps(), 0);

        vm.warp(validUntil - 1);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Regular));

        vm.warp(validUntil);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));
        assertEq(vault.redemptionFeeBps(), 10);
        assertEq(vault.depositFeeBps(), 25);
        assertTrue(vault.guardedOperation());
    }

    function test_authorizeRegularMode_RejectsPresentPastAndAboveMaximum() public {
        uint64 originalDeadline = vault.regularModeValidUntil();

        vm.expectRevert(IStakedUSDat.InvalidRegularModeAuthorization.selector);
        vault.authorizeRegularMode(uint64(block.timestamp));

        vm.expectRevert(IStakedUSDat.InvalidRegularModeAuthorization.selector);
        vault.authorizeRegularMode(uint64(block.timestamp - 1));

        vm.expectRevert(IStakedUSDat.InvalidRegularModeAuthorization.selector);
        vault.authorizeRegularMode(uint64(block.timestamp + 8 hours + 1));

        assertEq(vault.regularModeValidUntil(), originalDeadline);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));
    }

    function test_authorizeRegularMode_RequiresMarketModeManagerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.MARKET_MODE_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.authorizeRegularMode(uint64(block.timestamp + 1 hours));

        assertEq(vault.regularModeValidUntil(), 0);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));
    }

    function test_setMarketMode_RequiresMarketModeManagerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.MARKET_MODE_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);

        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));
    }

    function test_authorizeRegularMode_RenewsExpiredAuthorizationWhilePaused() public {
        uint64 firstDeadline = uint64(block.timestamp + 1);
        vault.authorizeRegularMode(firstDeadline);
        vault.pause();
        vm.warp(firstDeadline);

        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));

        uint64 renewedDeadline = uint64(block.timestamp + 8 hours);
        vault.authorizeRegularMode(renewedDeadline);

        assertTrue(vault.paused());
        assertEq(vault.regularModeValidUntil(), renewedDeadline);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Regular));
    }

    function test_authorizeRegularMode_ReturnsFromRestrictedWithFreshDeadline() public {
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);

        uint64 validUntil = uint64(block.timestamp + 8 hours);
        vault.authorizeRegularMode(validUntil);

        assertEq(vault.regularModeValidUntil(), validUntil);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Regular));
    }

    function test_setMarketMode_RejectsRegularAndSupportsMoreRestrictiveModes() public {
        vault.authorizeRegularMode(uint64(block.timestamp + 8 hours));

        vm.expectEmit(false, false, false, true, address(vault));
        emit MarketModeChanged(IStakedUSDat.MarketMode.Regular, IStakedUSDat.MarketMode.Elevated);
        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));

        vm.expectEmit(false, false, false, true, address(vault));
        emit MarketModeChanged(IStakedUSDat.MarketMode.Elevated, IStakedUSDat.MarketMode.Restricted);
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Restricted));

        vm.expectRevert(IStakedUSDat.InvalidRegularModeAuthorization.selector);
        vault.setMarketMode(IStakedUSDat.MarketMode.Regular);
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Restricted));
    }

    function test_RestrictedModeDominatesUnexpiredRegularAuthorization() public {
        uint64 validUntil = uint64(block.timestamp + 8 hours);
        vault.authorizeRegularMode(validUntil);
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);
        vm.warp(validUntil - 1);

        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Restricted));
        assertEq(vault.redemptionFeeBps(), 10);
        assertEq(vault.depositFeeBps(), 25);

        vm.expectRevert(IStakedUSDat.MarketRestricted.selector);
        vault.guardedOperation();
    }

    function test_setMarketMode_RemainsCallableWhilePaused() public {
        vault.pause();

        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);

        assertTrue(vault.paused());
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Restricted));
    }
}
