// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {StakedUSDat} from "../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract StakedUSDatExecutionConfigHarness is StakedUSDat {
    constructor(address parameterManager) StakedUSDat(IWithdrawalQueueERC721(address(1))) {
        _grantRole(PARAMETER_MANAGER_ROLE, parameterManager);
        _grantRole(MARKET_MODE_MANAGER_ROLE, parameterManager);
        _grantRole(PAUSER_ROLE, parameterManager);
    }

    function requireUnexpiredDeadline(uint256 deadline) external view {
        _requireUnexpiredDeadline(deadline);
    }
}

contract StakedUSDatExecutionConfigTest is Test {
    StakedUSDatExecutionConfigHarness private vault;

    address private executionVehicle = makeAddr("executionVehicle");
    address private replacementVehicle = makeAddr("replacementVehicle");
    address private unauthorized = makeAddr("unauthorized");

    event ExecutionVehicleUpdated(address indexed oldVehicle, address indexed newVehicle);
    event ExecutionToleranceUpdated(uint16 oldBps, uint16 newBps);

    function setUp() public {
        vault = new StakedUSDatExecutionConfigHarness(address(this));
    }

    function test_executionConfig_DefaultsAndGetters() public view {
        IStakedUSDat vaultInterface = IStakedUSDat(address(vault));

        assertEq(vaultInterface.executionVehicle(), address(0));
        assertEq(vaultInterface.executionToleranceBps(), 0);
        assertEq(vault.MAX_EXECUTION_TOLERANCE_BPS(), 500);
    }

    function test_setExecutionVehicle_UpdatesAndEmits() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit ExecutionVehicleUpdated(address(0), executionVehicle);
        vault.setExecutionVehicle(executionVehicle);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ExecutionVehicleUpdated(executionVehicle, replacementVehicle);
        vault.setExecutionVehicle(replacementVehicle);

        assertEq(vault.executionVehicle(), replacementVehicle);
    }

    function test_setExecutionVehicle_AcceptsIdempotentUpdateAndEmits() public {
        vault.setExecutionVehicle(executionVehicle);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ExecutionVehicleUpdated(executionVehicle, executionVehicle);
        vault.setExecutionVehicle(executionVehicle);

        assertEq(vault.executionVehicle(), executionVehicle);
    }

    function test_setExecutionVehicle_RequiresParameterManagerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setExecutionVehicle(executionVehicle);

        assertEq(vault.executionVehicle(), address(0));
    }

    function test_setExecutionVehicle_RejectsZeroAddress() public {
        vault.setExecutionVehicle(executionVehicle);

        vm.expectRevert(IStakedUSDat.InvalidZeroAddress.selector);
        vault.setExecutionVehicle(address(0));

        assertEq(vault.executionVehicle(), executionVehicle);
    }

    function test_setExecutionTolerance_AcceptsZeroAndCapAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit ExecutionToleranceUpdated(0, 500);
        vault.setExecutionTolerance(500);

        vm.expectEmit(false, false, false, true, address(vault));
        emit ExecutionToleranceUpdated(500, 0);
        vault.setExecutionTolerance(0);

        assertEq(vault.executionToleranceBps(), 0);
    }

    function test_setExecutionTolerance_AcceptsIdempotentUpdateAndEmits() public {
        vault.setExecutionTolerance(100);

        vm.expectEmit(false, false, false, true, address(vault));
        emit ExecutionToleranceUpdated(100, 100);
        vault.setExecutionTolerance(100);

        assertEq(vault.executionToleranceBps(), 100);
    }

    function test_setExecutionTolerance_RequiresParameterManagerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setExecutionTolerance(100);

        assertEq(vault.executionToleranceBps(), 0);
    }

    function test_setExecutionTolerance_RejectsAboveCap() public {
        vault.setExecutionTolerance(100);

        vm.expectRevert(IStakedUSDat.InvalidExecutionTolerance.selector);
        vault.setExecutionTolerance(501);

        assertEq(vault.executionToleranceBps(), 100);
    }

    function test_executionConfig_RemainsCallableWhilePausedAndRestricted() public {
        vault.setMarketMode(IStakedUSDat.MarketMode.RESTRICTED);
        vault.pause();

        vault.setExecutionVehicle(executionVehicle);
        vault.setExecutionTolerance(500);

        assertTrue(vault.paused());
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.RESTRICTED));
        assertEq(vault.executionVehicle(), executionVehicle);
        assertEq(vault.executionToleranceBps(), 500);
    }

    function test_requireUnexpiredDeadline_UsesInclusiveBoundary() public {
        vm.warp(100);

        vault.requireUnexpiredDeadline(block.timestamp);
        vault.requireUnexpiredDeadline(block.timestamp + 1);
        vault.requireUnexpiredDeadline(type(uint256).max);

        vm.expectRevert(IStakedUSDat.DeadlineExpired.selector);
        vault.requireUnexpiredDeadline(block.timestamp - 1);
    }

    function test_executionConfig_PacksIntoAppendedSlotSixteen() public {
        vault.setExecutionVehicle(executionVehicle);
        vault.setExecutionTolerance(500);

        uint256 expected = uint256(uint160(executionVehicle)) | (uint256(vault.executionToleranceBps()) << 160);
        assertEq(vm.load(address(vault), bytes32(uint256(16))), bytes32(expected));
    }
}
