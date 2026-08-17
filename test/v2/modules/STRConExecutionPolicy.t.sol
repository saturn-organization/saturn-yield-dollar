// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";
import {ISTRConPriceOracle} from "../../../src/v2/interfaces/oracles/ISTRConPriceOracle.sol";
import {STRConExecutionPolicy} from "../../../src/v2/STRConExecutionPolicy.sol";

contract ExecutionPolicyVaultMock {
    mapping(bytes32 role => mapping(address account => bool enabled)) private _roles;

    function setRole(bytes32 role, address account, bool enabled) external {
        _roles[role][account] = enabled;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function initializePolicy(
        ISTRConExecutionPolicy policy,
        address vehicle,
        uint16 toleranceBps,
        uint128 maximum,
        uint128 refillPerDay
    ) external {
        policy.initialize(vehicle, toleranceBps, maximum, refillPerDay);
    }

    function validateBuy(
        ISTRConExecutionPolicy policy,
        uint256 usdatPaid,
        uint256 assetReceived,
        address expectedVehicle
    ) external returns (uint256 oraclePrice) {
        return policy.validateBuy(usdatPaid, assetReceived, expectedVehicle);
    }

    function validateSell(
        ISTRConExecutionPolicy policy,
        uint256 assetDelivered,
        uint256 usdatReceived,
        address expectedVehicle
    ) external returns (uint256 oraclePrice) {
        return policy.validateSell(assetDelivered, usdatReceived, expectedVehicle);
    }
}

contract ExecutionPolicyModuleMock is ISTRConModule {
    error PriceReadFailed();

    address public immutable VAULT;
    address public immutable ASSET = address(0x2222);

    uint256 private _price;
    bool private _priceReadFails;

    constructor(address vault, uint256 initialPrice) {
        VAULT = vault;
        _price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function setPriceReadFails(bool shouldFail) external {
        _priceReadFails = shouldFail;
    }

    function recognizedValue() external pure returns (uint256) {
        return 0;
    }

    function balance() external pure returns (uint256) {
        return 0;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function getPrice() external view returns (uint256) {
        if (_priceReadFails) revert PriceReadFailed();
        return _price;
    }

    function buy(uint256) external pure {}

    function sell(uint256) external pure {}

    function oracle() external pure returns (ISTRConPriceOracle) {
        return ISTRConPriceOracle(address(0));
    }

    function setOracle(address) external pure {}
}

contract STRConExecutionPolicyTest is Test {
    struct Capacity {
        uint128 maximum;
        uint128 available;
        uint128 refillPerDay;
        uint64 lastUpdated;
    }

    uint256 private constant ORACLE_PRICE = 100e8;
    uint16 private constant MAX_TOLERANCE_BPS = 500;
    bytes32 private constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");

    uint256 private constant ASSET_AMOUNT = 100e18;
    uint128 private constant BUY_BOUNDARY = 10_500e6;
    uint256 private constant BUY_FAVORABLE = 9_900e6;
    uint256 private constant SELL_BOUNDARY = 9_500e6;
    uint256 private constant SELL_FAVORABLE = 10_100e6;

    ExecutionPolicyVaultMock private vault;
    ExecutionPolicyModuleMock private module;
    STRConExecutionPolicy private policy;

    address private vehicle = makeAddr("executionVehicle");
    address private unauthorized = makeAddr("unauthorized");

    event ExecutionVehicleUpdated(address indexed oldVehicle, address indexed newVehicle);
    event ExecutionToleranceUpdated(uint16 oldBps, uint16 newBps);
    event ExecutionCapacityUpdated(uint128 maximum, uint128 refillPerDay);

    function setUp() public {
        vm.warp(1_000_000);

        vault = new ExecutionPolicyVaultMock();
        module = new ExecutionPolicyModuleMock(address(vault), ORACLE_PRICE);
        policy = new STRConExecutionPolicy(address(vault), module);

        vault.setRole(PARAMETER_MANAGER_ROLE, address(this), true);
        vault.initializePolicy(policy, vehicle, MAX_TOLERANCE_BPS, 100_000e6, 0);
    }

    function test_constructor_BindsVaultAndModuleAndStartsUninitialized() public {
        STRConExecutionPolicy fresh = _deployUninitialized();

        assertEq(fresh.VAULT(), address(vault));
        assertEq(address(fresh.STRCON_MODULE()), address(module));
        assertEq(fresh.executionVehicle(), address(0));
        assertEq(fresh.executionToleranceBps(), 0);

        Capacity memory capacity = _capacity(fresh);
        assertEq(capacity.maximum, 0);
        assertEq(capacity.available, 0);
        assertEq(capacity.refillPerDay, 0);
        assertEq(capacity.lastUpdated, 0);
    }

    function test_constructor_RejectsEitherZeroBinding() public {
        vm.expectRevert(ISTRConExecutionPolicy.InvalidZeroAddress.selector);
        new STRConExecutionPolicy(address(0), module);

        vm.expectRevert(ISTRConExecutionPolicy.InvalidZeroAddress.selector);
        new STRConExecutionPolicy(address(vault), ISTRConModule(address(0)));
    }

    function test_initialize_RequiresVaultRunsOnceAndStartsBucketFull() public {
        STRConExecutionPolicy fresh = _deployUninitialized();

        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        fresh.initialize(vehicle, 100, 1_000e6, 100e6);

        vault.initializePolicy(fresh, vehicle, 100, 1_000e6, 100e6);

        assertEq(fresh.executionVehicle(), vehicle);
        assertEq(fresh.executionToleranceBps(), 100);
        Capacity memory capacity = _capacity(fresh);
        assertEq(capacity.maximum, 1_000e6);
        assertEq(capacity.available, capacity.maximum);
        assertEq(capacity.refillPerDay, 100e6);
        assertEq(capacity.lastUpdated, uint64(block.timestamp));

        vm.expectRevert(ISTRConExecutionPolicy.AlreadyInitialized.selector);
        vault.initializePolicy(fresh, vehicle, 100, 1_000e6, 100e6);
    }

    function test_initialize_InvalidInputDoesNotConsumeOneShot() public {
        STRConExecutionPolicy fresh = _deployUninitialized();

        vm.expectRevert(ISTRConExecutionPolicy.InvalidZeroAddress.selector);
        vault.initializePolicy(fresh, address(0), 100, 1_000e6, 100e6);

        vm.expectRevert(ISTRConExecutionPolicy.InvalidExecutionTolerance.selector);
        vault.initializePolicy(fresh, vehicle, MAX_TOLERANCE_BPS + 1, 1_000e6, 100e6);

        vault.initializePolicy(fresh, vehicle, MAX_TOLERANCE_BPS, 1_000e6, 100e6);
        assertEq(fresh.executionVehicle(), vehicle);
    }

    function test_setExecutionVehicle_RequiresVaultRoleValidatesAndEmits() public {
        address replacement = makeAddr("replacementVehicle");

        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        vm.prank(unauthorized);
        policy.setExecutionVehicle(replacement);

        vm.expectRevert(ISTRConExecutionPolicy.InvalidZeroAddress.selector);
        policy.setExecutionVehicle(address(0));

        vm.expectEmit(true, true, false, true, address(policy));
        emit ExecutionVehicleUpdated(vehicle, replacement);
        policy.setExecutionVehicle(replacement);

        assertEq(policy.executionVehicle(), replacement);
    }

    function test_setExecutionTolerance_RequiresVaultRoleAcceptsCapAndEmits() public {
        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        vm.prank(unauthorized);
        policy.setExecutionTolerance(100);

        vm.expectRevert(ISTRConExecutionPolicy.InvalidExecutionTolerance.selector);
        policy.setExecutionTolerance(MAX_TOLERANCE_BPS + 1);

        vm.expectEmit(false, false, false, true, address(policy));
        emit ExecutionToleranceUpdated(MAX_TOLERANCE_BPS, 0);
        policy.setExecutionTolerance(0);

        assertEq(policy.executionToleranceBps(), 0);
    }

    function test_setExecutionCapacity_RequiresVaultRoleAndEmits() public {
        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        vm.prank(unauthorized);
        policy.setExecutionCapacity(1_000e6, 100e6);

        vm.expectEmit(false, false, false, true, address(policy));
        emit ExecutionCapacityUpdated(1_000e6, 100e6);
        policy.setExecutionCapacity(1_000e6, 100e6);

        Capacity memory capacity = _capacity(policy);
        assertEq(capacity.maximum, 1_000e6);
        assertEq(capacity.available, 1_000e6);
        assertEq(capacity.refillPerDay, 100e6);
        assertEq(capacity.lastUpdated, uint64(block.timestamp));
    }

    function test_setters_WorkBeforeInitializationWithoutInitializingPolicy() public {
        STRConExecutionPolicy fresh = _deployUninitialized();
        address replacement = makeAddr("replacementVehicle");

        fresh.setExecutionVehicle(replacement);
        fresh.setExecutionTolerance(MAX_TOLERANCE_BPS);
        fresh.setExecutionCapacity(1_000e6, 100e6);

        assertEq(fresh.executionVehicle(), replacement);
        assertEq(fresh.executionToleranceBps(), MAX_TOLERANCE_BPS);
        Capacity memory capacity = _capacity(fresh);
        assertEq(capacity.maximum, 1_000e6);
        assertEq(capacity.available, 0);
        assertEq(capacity.refillPerDay, 100e6);

        vault.initializePolicy(fresh, vehicle, 100, 2_000e6, 200e6);
        assertEq(fresh.executionVehicle(), vehicle);
        assertEq(_capacity(fresh).available, 2_000e6);
    }

    function test_validateBuyAndSell_RequireVaultCaller() public {
        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        policy.validateBuy(BUY_BOUNDARY, ASSET_AMOUNT, vehicle);

        vm.expectRevert(ISTRConExecutionPolicy.Unauthorized.selector);
        policy.validateSell(ASSET_AMOUNT, SELL_BOUNDARY, vehicle);

        assertEq(_capacity(policy).available, 100_000e6);
    }

    function test_validateBuy_AcceptsInclusiveBoundaryReturnsOracleAndRejectsFirstUnitAbove() public {
        uint256 oraclePrice = vault.validateBuy(policy, BUY_BOUNDARY, ASSET_AMOUNT, vehicle);
        assertEq(oraclePrice, ORACLE_PRICE);

        Capacity memory afterBoundary = _capacity(policy);
        vm.expectRevert(ISTRConExecutionPolicy.ExecutionPriceMismatch.selector);
        vault.validateBuy(policy, BUY_BOUNDARY + 1, ASSET_AMOUNT, vehicle);
        _assertCapacity(policy, afterBoundary);
    }

    function test_validateBuy_CeilRoundsRealizedPriceAgainstVault() public {
        Capacity memory beforeCapacity = _capacity(policy);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionPriceMismatch.selector);
        vault.validateBuy(policy, BUY_BOUNDARY + 1, ASSET_AMOUNT + 1, vehicle);

        _assertCapacity(policy, beforeCapacity);
    }

    function test_validateSell_AcceptsInclusiveBoundaryReturnsOracleAndRejectsFirstUnitBelow() public {
        uint256 oraclePrice = vault.validateSell(policy, ASSET_AMOUNT, SELL_BOUNDARY, vehicle);
        assertEq(oraclePrice, ORACLE_PRICE);

        Capacity memory afterBoundary = _capacity(policy);
        vm.expectRevert(ISTRConExecutionPolicy.ExecutionPriceMismatch.selector);
        vault.validateSell(policy, ASSET_AMOUNT, SELL_BOUNDARY - 1, vehicle);
        _assertCapacity(policy, afterBoundary);
    }

    function test_validateSell_FloorRoundsRealizedPriceAgainstVault() public {
        Capacity memory beforeCapacity = _capacity(policy);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionPriceMismatch.selector);
        vault.validateSell(policy, ASSET_AMOUNT + 1, SELL_BOUNDARY, vehicle);

        _assertCapacity(policy, beforeCapacity);
    }

    function test_validations_RejectChangedVehicleWithoutReadingPriceOrConsumingCapacity() public {
        address replacement = makeAddr("replacementVehicle");
        policy.setExecutionVehicle(replacement);
        module.setPriceReadFails(true);
        Capacity memory beforeCapacity = _capacity(policy);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionVehicleMismatch.selector);
        vault.validateBuy(policy, BUY_BOUNDARY, ASSET_AMOUNT, vehicle);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionVehicleMismatch.selector);
        vault.validateSell(policy, ASSET_AMOUNT, SELL_BOUNDARY, vehicle);

        _assertCapacity(policy, beforeCapacity);
    }

    function test_validations_ChargeGreaterOfUSDatAndCeilOracleNotional() public {
        policy.setExecutionCapacity(40_000e6, 0);

        vault.validateBuy(policy, BUY_FAVORABLE, ASSET_AMOUNT, vehicle);
        assertEq(_capacity(policy).available, 30_000e6);

        vault.validateBuy(policy, BUY_BOUNDARY, ASSET_AMOUNT, vehicle);
        assertEq(_capacity(policy).available, 19_500e6);

        vault.validateSell(policy, ASSET_AMOUNT, SELL_FAVORABLE, vehicle);
        assertEq(_capacity(policy).available, 9_400e6);
    }

    function test_validations_CeilRoundNonDivisibleOracleNotionalInBothDirections() public {
        policy.setExecutionTolerance(1);
        policy.setExecutionCapacity(300e6, 0);

        vault.validateBuy(policy, 100e6, 1e18 + 1, vehicle);
        assertEq(_capacity(policy).available, 199_999_999);

        vault.validateSell(policy, 1e18 + 1, 100e6, vehicle);
        assertEq(_capacity(policy).available, 99_999_998);
    }

    function test_buyAndSell_ConsumeOneSharedBucketWithoutRefund() public {
        policy.setExecutionCapacity(25_000e6, 0);

        vault.validateBuy(policy, BUY_BOUNDARY, ASSET_AMOUNT, vehicle);
        assertEq(_capacity(policy).available, 14_500e6);

        vault.validateSell(policy, ASSET_AMOUNT, SELL_BOUNDARY, vehicle);
        assertEq(_capacity(policy).available, 4_500e6);
    }

    function test_executionCapacity_RefillsLinearlyAtExactBoundary() public {
        policy.setExecutionCapacity(BUY_BOUNDARY, 8_640e6);
        vault.validateBuy(policy, BUY_BOUNDARY, ASSET_AMOUNT, vehicle);
        assertEq(_capacity(policy).available, 0);

        vm.warp(block.timestamp + 999);
        Capacity memory beforeFailure = _capacity(policy);
        assertEq(beforeFailure.available, 99_900_000);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionCapacityExceeded.selector);
        vault.validateBuy(policy, 100e6, 1e18, vehicle);
        _assertCapacity(policy, beforeFailure);

        vm.warp(block.timestamp + 1);
        vault.validateBuy(policy, 100e6, 1e18, vehicle);
        assertEq(_capacity(policy).available, 0);
    }

    function test_failedPriceAndOracleValidationRollBackCapacity() public {
        policy.setExecutionCapacity(BUY_BOUNDARY, 0);
        Capacity memory beforeCapacity = _capacity(policy);

        vm.expectRevert(ISTRConExecutionPolicy.ExecutionPriceMismatch.selector);
        vault.validateBuy(policy, BUY_BOUNDARY + 1, ASSET_AMOUNT, vehicle);
        _assertCapacity(policy, beforeCapacity);

        module.setPriceReadFails(true);
        vm.expectRevert(ExecutionPolicyModuleMock.PriceReadFailed.selector);
        vault.validateBuy(policy, BUY_BOUNDARY, ASSET_AMOUNT, vehicle);
        _assertCapacity(policy, beforeCapacity);
    }

    function test_setExecutionCapacity_AccruesOldRateThenClampsWithoutTopUp() public {
        policy.setExecutionCapacity(20_000e6, 8_640e6);
        vault.validateBuy(policy, BUY_BOUNDARY, ASSET_AMOUNT, vehicle);

        vm.warp(block.timestamp + 1 hours);
        policy.setExecutionCapacity(15_000e6, 4_320e6);
        Capacity memory capacity = _capacity(policy);
        assertEq(capacity.maximum, 15_000e6);
        assertEq(capacity.available, 9_860e6);
        assertEq(capacity.refillPerDay, 4_320e6);
        assertEq(capacity.lastUpdated, uint64(block.timestamp));

        policy.setExecutionCapacity(25_000e6, 4_320e6);
        capacity = _capacity(policy);
        assertEq(capacity.maximum, 25_000e6);
        assertEq(capacity.available, 9_860e6);

        policy.setExecutionCapacity(9_000e6, 4_320e6);
        capacity = _capacity(policy);
        assertEq(capacity.maximum, 9_000e6);
        assertEq(capacity.available, 9_000e6);
    }

    function test_vehicleAndToleranceUpdatesDoNotResetCapacityAndZeroMaximumDisables() public {
        address replacement = makeAddr("replacementVehicle");
        policy.setExecutionCapacity(BUY_BOUNDARY, 0);
        vault.validateBuy(policy, BUY_BOUNDARY, ASSET_AMOUNT, vehicle);
        Capacity memory empty = _capacity(policy);

        policy.setExecutionTolerance(0);
        policy.setExecutionVehicle(replacement);
        assertEq(_capacity(policy).available, 0);

        policy.setExecutionCapacity(0, 0);
        vm.expectRevert(ISTRConExecutionPolicy.ExecutionCapacityExceeded.selector);
        vault.validateBuy(policy, 100e6, 1e18, replacement);

        Capacity memory disabled = _capacity(policy);
        assertEq(disabled.maximum, 0);
        assertEq(disabled.available, 0);
        assertEq(disabled.lastUpdated, empty.lastUpdated);
    }

    function _deployUninitialized() private returns (STRConExecutionPolicy fresh) {
        return new STRConExecutionPolicy(address(vault), module);
    }

    function _capacity(ISTRConExecutionPolicy target) private view returns (Capacity memory capacity) {
        (capacity.maximum, capacity.available, capacity.refillPerDay, capacity.lastUpdated) = target.executionCapacity();
    }

    function _assertCapacity(ISTRConExecutionPolicy target, Capacity memory expected) private view {
        Capacity memory actual = _capacity(target);
        assertEq(actual.maximum, expected.maximum);
        assertEq(actual.available, expected.available);
        assertEq(actual.refillPerDay, expected.refillPerDay);
        assertEq(actual.lastUpdated, expected.lastUpdated);
    }
}
