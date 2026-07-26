// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract StakedUSDatMarketModeHarness is StakedUSDat {
    constructor(address marketModeManager) StakedUSDat(IWithdrawalQueueERC721(address(1))) {
        _grantRole(MARKET_MODE_MANAGER_ROLE, marketModeManager);
        _grantRole(PAUSER_ROLE, marketModeManager);
    }

    function guardedOperation() external view whenNotRestricted returns (bool) {
        return true;
    }
}

contract StakedUSDatMarketModeTest is Test {
    StakedUSDatMarketModeHarness private vault;

    address private unauthorized = makeAddr("unauthorized");

    event MarketModeChanged(IStakedUSDat.MarketMode oldMode, IStakedUSDat.MarketMode newMode);

    function setUp() public {
        vault = new StakedUSDatMarketModeHarness(address(this));
    }

    function test_DefaultModeIsRegular() public view {
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Regular));
    }

    function test_SetMarketMode_TransitionsAndEmits() public {
        _setMode(IStakedUSDat.MarketMode.Regular, IStakedUSDat.MarketMode.Elevated);
        _setMode(IStakedUSDat.MarketMode.Elevated, IStakedUSDat.MarketMode.Restricted);
        _setMode(IStakedUSDat.MarketMode.Restricted, IStakedUSDat.MarketMode.Regular);
    }

    function test_SetMarketMode_EmitsForIdempotentTarget() public {
        _setMode(IStakedUSDat.MarketMode.Regular, IStakedUSDat.MarketMode.Regular);
    }

    function test_SetMarketMode_RequiresMarketModeManagerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.MARKET_MODE_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);

        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Regular));
    }

    function test_SetMarketMode_RemainsCallableWhilePaused() public {
        vault.pause();

        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);

        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));
        assertTrue(vault.paused());
    }

    function test_WhenNotRestricted_AllowsRegularAndElevated() public {
        assertTrue(vault.guardedOperation());

        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);

        assertTrue(vault.guardedOperation());
    }

    function test_WhenNotRestricted_RevertsRestricted() public {
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);

        vm.expectRevert(IStakedUSDat.MarketRestricted.selector);
        vault.guardedOperation();
    }

    function _setMode(IStakedUSDat.MarketMode oldMode, IStakedUSDat.MarketMode newMode) private {
        vm.expectEmit(false, false, false, true, address(vault));
        emit MarketModeChanged(oldMode, newMode);

        vault.setMarketMode(newMode);

        assertEq(uint256(vault.marketMode()), uint256(newMode));
    }
}
