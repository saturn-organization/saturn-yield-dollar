// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {STRConExecutionPolicy} from "../../../src/v2/STRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract StakedUSDatExecutionConfigHarness is StakedUSDat {
    constructor(address parameterManager) StakedUSDat(IWithdrawalQueueERC721(address(1))) {
        _grantRole(PARAMETER_MANAGER_ROLE, parameterManager);
        _grantRole(MARKET_MODE_MANAGER_ROLE, parameterManager);
        _grantRole(PAUSER_ROLE, parameterManager);
    }

    function requireUnexpiredDeadline(uint256 deadline) external view {
        _requireUnexpiredDeadline(deadline);
    }

    function bindExecutionPolicy(ISTRConExecutionPolicy policy) external {
        executionPolicy = policy;
    }
}

contract ExecutionConfigSTRConModuleMock {
    address public immutable VAULT;

    constructor(address vault) {
        VAULT = vault;
    }
}

contract StakedUSDatExecutionConfigTest is Test {
    StakedUSDatExecutionConfigHarness private vault;
    ExecutionConfigSTRConModuleMock private strconModule;
    ISTRConExecutionPolicy private policy;

    address private executionVehicle = makeAddr("executionVehicle");
    address private replacementVehicle = makeAddr("replacementVehicle");
    address private unauthorized = makeAddr("unauthorized");

    event ExecutionVehicleUpdated(address indexed oldVehicle, address indexed newVehicle);
    event ExecutionToleranceUpdated(uint16 oldBps, uint16 newBps);
    event ExecutionCapacityUpdated(uint128 maximum, uint128 refillPerDay);

    function setUp() public {
        vault = new StakedUSDatExecutionConfigHarness(address(this));
        strconModule = new ExecutionConfigSTRConModuleMock(address(vault));
        policy = new STRConExecutionPolicy(address(vault), ISTRConModule(address(strconModule)));
        vault.bindExecutionPolicy(policy);
    }

    function test_executionConfig_DefaultsAndGetters() public view {
        assertEq(policy.executionVehicle(), address(0));
        assertEq(policy.executionToleranceBps(), 0);
        assertEq(policy.MAX_EXECUTION_TOLERANCE_BPS(), 500);

        (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated) = policy.executionCapacity();
        assertEq(maximum, 0);
        assertEq(available, 0);
        assertEq(refillPerDay, 0);
        assertEq(lastUpdated, 0);
    }

    function test_setExecutionVehicle_UpdatesAndEmits() public {
        vm.expectEmit(true, true, false, true, address(policy));
        emit ExecutionVehicleUpdated(address(0), executionVehicle);
        policy.setExecutionVehicle(executionVehicle);

        vm.expectEmit(true, true, false, true, address(policy));
        emit ExecutionVehicleUpdated(executionVehicle, replacementVehicle);
        policy.setExecutionVehicle(replacementVehicle);

        assertEq(policy.executionVehicle(), replacementVehicle);
    }

    function test_setExecutionVehicle_AcceptsIdempotentUpdateAndEmits() public {
        policy.setExecutionVehicle(executionVehicle);

        vm.expectEmit(true, true, false, true, address(policy));
        emit ExecutionVehicleUpdated(executionVehicle, executionVehicle);
        policy.setExecutionVehicle(executionVehicle);

        assertEq(policy.executionVehicle(), executionVehicle);
    }

    function test_setExecutionVehicle_RequiresParameterManagerRole() public {
        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        vm.prank(unauthorized);
        policy.setExecutionVehicle(executionVehicle);

        assertEq(policy.executionVehicle(), address(0));
    }

    function test_setExecutionVehicle_RejectsZeroAddress() public {
        policy.setExecutionVehicle(executionVehicle);

        vm.expectRevert(ISTRConExecutionPolicy.InvalidZeroAddress.selector);
        policy.setExecutionVehicle(address(0));

        assertEq(policy.executionVehicle(), executionVehicle);
    }

    function test_setExecutionTolerance_AcceptsZeroAndCapAndEmits() public {
        vm.expectEmit(false, false, false, true, address(policy));
        emit ExecutionToleranceUpdated(0, 500);
        policy.setExecutionTolerance(500);

        vm.expectEmit(false, false, false, true, address(policy));
        emit ExecutionToleranceUpdated(500, 0);
        policy.setExecutionTolerance(0);

        assertEq(policy.executionToleranceBps(), 0);
    }

    function test_setExecutionTolerance_AcceptsIdempotentUpdateAndEmits() public {
        policy.setExecutionTolerance(100);

        vm.expectEmit(false, false, false, true, address(policy));
        emit ExecutionToleranceUpdated(100, 100);
        policy.setExecutionTolerance(100);

        assertEq(policy.executionToleranceBps(), 100);
    }

    function test_setExecutionTolerance_RequiresParameterManagerRole() public {
        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        vm.prank(unauthorized);
        policy.setExecutionTolerance(100);

        assertEq(policy.executionToleranceBps(), 0);
    }

    function test_setExecutionTolerance_RejectsAboveCap() public {
        policy.setExecutionTolerance(100);

        vm.expectRevert(ISTRConExecutionPolicy.InvalidExecutionTolerance.selector);
        policy.setExecutionTolerance(501);

        assertEq(policy.executionToleranceBps(), 100);
    }

    function test_setExecutionCapacity_UpdatesConfigWithoutAddingAvailableCapacity() public {
        vm.warp(100);

        vm.expectEmit(false, false, false, true, address(policy));
        emit ExecutionCapacityUpdated(1_000e6, 100e6);
        policy.setExecutionCapacity(1_000e6, 100e6);

        (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated) = policy.executionCapacity();
        assertEq(maximum, 1_000e6);
        assertEq(available, 0);
        assertEq(refillPerDay, 100e6);
        assertEq(lastUpdated, 100);
    }

    function test_setExecutionCapacity_RequiresParameterManagerRole() public {
        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        vm.prank(unauthorized);
        policy.setExecutionCapacity(1_000e6, 100e6);

        (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated) = policy.executionCapacity();
        assertEq(maximum, 0);
        assertEq(available, 0);
        assertEq(refillPerDay, 0);
        assertEq(lastUpdated, 0);
    }

    function test_executionConfig_RemainsCallableWhilePausedAndRestricted() public {
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);
        vault.pause();

        policy.setExecutionVehicle(executionVehicle);
        policy.setExecutionTolerance(500);
        policy.setExecutionCapacity(1_000e6, 100e6);

        assertTrue(vault.paused());
        assertEq(uint256(vault.marketMode()), uint256(IStakedUSDat.MarketMode.Restricted));
        assertEq(policy.executionVehicle(), executionVehicle);
        assertEq(policy.executionToleranceBps(), 500);

        (uint128 maximum,, uint128 refillPerDay,) = policy.executionCapacity();
        assertEq(maximum, 1_000e6);
        assertEq(refillPerDay, 100e6);
    }

    function test_requireUnexpiredDeadline_UsesInclusiveBoundary() public {
        vm.warp(100);

        vault.requireUnexpiredDeadline(block.timestamp);
        vault.requireUnexpiredDeadline(block.timestamp + 1);
        vault.requireUnexpiredDeadline(type(uint256).max);

        vm.expectRevert(IStakedUSDat.DeadlineExpired.selector);
        vault.requireUnexpiredDeadline(block.timestamp - 1);
    }

    function test_executionPolicy_IsBoundAndStoredInAppendedSlotSixteen() public view {
        assertEq(policy.VAULT(), address(vault));
        assertEq(address(policy.STRCON_MODULE()), address(strconModule));
        assertEq(address(vault.executionPolicy()), address(policy));
        assertEq(vm.load(address(vault), bytes32(uint256(16))), bytes32(uint256(uint160(address(policy)))));
    }
}
