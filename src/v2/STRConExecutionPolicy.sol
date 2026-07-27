// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISTRConExecutionPolicy} from "./interfaces/ISTRConExecutionPolicy.sol";
import {ISTRConModule} from "./interfaces/modules/ISTRConModule.sol";

/**
 * @title STRConExecutionPolicy
 * @author Saturn
 * @notice Fixed execution policy for the vault's STRCon rotations.
 */
contract STRConExecutionPolicy is ISTRConExecutionPolicy {
    bytes32 private constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant ORACLE_NOTIONAL_SCALE = 1e20;
    uint256 private constant REFILL_PERIOD = 1 days;

    uint16 public constant MAX_EXECUTION_TOLERANCE_BPS = 500;

    address public immutable VAULT;
    ISTRConModule public immutable STRCON_MODULE;

    address public executionVehicle;
    uint16 public executionToleranceBps;

    uint128 private _maximum;
    uint128 private _available;
    uint128 private _refillPerDay;
    uint64 private _lastUpdated;
    bool private _initialized;

    modifier onlyVault() {
        require(msg.sender == VAULT, Unauthorized());
        _;
    }

    modifier onlyParameterManager() {
        require(IAccessControl(VAULT).hasRole(PARAMETER_MANAGER_ROLE, msg.sender), Unauthorized());
        _;
    }

    constructor(address vault, ISTRConModule strconModule) {
        require(vault != address(0) && address(strconModule) != address(0), InvalidZeroAddress());
        VAULT = vault;
        STRCON_MODULE = strconModule;
    }

    /// @inheritdoc ISTRConExecutionPolicy
    function initialize(address vehicle, uint16 toleranceBps, uint128 maximum, uint128 refillPerDay)
        external
        onlyVault
    {
        require(!_initialized, AlreadyInitialized());
        _setExecutionVehicle(vehicle);
        _setExecutionTolerance(toleranceBps);

        _maximum = maximum;
        _available = maximum;
        _refillPerDay = refillPerDay;
        _lastUpdated = uint64(block.timestamp);
        _initialized = true;
    }

    /// @inheritdoc ISTRConExecutionPolicy
    function setExecutionVehicle(address newVehicle) external onlyParameterManager {
        _setExecutionVehicle(newVehicle);
    }

    /// @inheritdoc ISTRConExecutionPolicy
    function setExecutionTolerance(uint16 newBps) external onlyParameterManager {
        _setExecutionTolerance(newBps);
    }

    /// @inheritdoc ISTRConExecutionPolicy
    function setExecutionCapacity(uint128 newMaximum, uint128 newRefillPerDay) external onlyParameterManager {
        uint128 available = uint128(Math.min(_availableCapacity(), uint256(newMaximum)));

        _maximum = newMaximum;
        _available = available;
        _refillPerDay = newRefillPerDay;
        _lastUpdated = uint64(block.timestamp);

        emit ExecutionCapacityUpdated(newMaximum, newRefillPerDay);
    }

    /// @inheritdoc ISTRConExecutionPolicy
    function executionCapacity()
        external
        view
        returns (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated)
    {
        return (_maximum, uint128(_availableCapacity()), _refillPerDay, _lastUpdated);
    }

    /// @inheritdoc ISTRConExecutionPolicy
    function validateBuy(uint256 usdatPaid, uint256 assetReceived, address expectedVehicle)
        external
        onlyVault
        returns (uint256 oraclePrice)
    {
        _requireExpectedVehicle(expectedVehicle);

        oraclePrice = STRCON_MODULE.getPrice();
        uint256 buyPrice = Math.mulDiv(usdatPaid, ORACLE_NOTIONAL_SCALE, assetReceived, Math.Rounding.Ceil);
        uint256 maximumBuyPrice = Math.mulDiv(
            oraclePrice, BPS_DENOMINATOR + uint256(executionToleranceBps), BPS_DENOMINATOR, Math.Rounding.Floor
        );
        require(buyPrice <= maximumBuyPrice, ExecutionPriceMismatch());

        uint256 oracleNotional = Math.mulDiv(assetReceived, oraclePrice, ORACLE_NOTIONAL_SCALE, Math.Rounding.Ceil);
        _consumeCapacity(Math.max(usdatPaid, oracleNotional));
    }

    /// @inheritdoc ISTRConExecutionPolicy
    function validateSell(uint256 assetDelivered, uint256 usdatReceived, address expectedVehicle)
        external
        onlyVault
        returns (uint256 oraclePrice)
    {
        _requireExpectedVehicle(expectedVehicle);

        oraclePrice = STRCON_MODULE.getPrice();
        uint256 sellPrice = Math.mulDiv(usdatReceived, ORACLE_NOTIONAL_SCALE, assetDelivered, Math.Rounding.Floor);
        uint256 minimumSellPrice = Math.mulDiv(
            oraclePrice, BPS_DENOMINATOR - uint256(executionToleranceBps), BPS_DENOMINATOR, Math.Rounding.Ceil
        );
        require(sellPrice >= minimumSellPrice, ExecutionPriceMismatch());

        uint256 oracleNotional = Math.mulDiv(assetDelivered, oraclePrice, ORACLE_NOTIONAL_SCALE, Math.Rounding.Ceil);
        _consumeCapacity(Math.max(usdatReceived, oracleNotional));
    }

    function _setExecutionVehicle(address newVehicle) private {
        require(newVehicle != address(0), InvalidZeroAddress());
        address oldVehicle = executionVehicle;
        executionVehicle = newVehicle;
        emit ExecutionVehicleUpdated(oldVehicle, newVehicle);
    }

    function _setExecutionTolerance(uint16 newBps) private {
        require(newBps <= MAX_EXECUTION_TOLERANCE_BPS, InvalidExecutionTolerance());
        uint16 oldBps = executionToleranceBps;
        executionToleranceBps = newBps;
        emit ExecutionToleranceUpdated(oldBps, newBps);
    }

    function _requireExpectedVehicle(address expectedVehicle) private view {
        require(expectedVehicle == executionVehicle, ExecutionVehicleMismatch());
    }

    function _consumeCapacity(uint256 notional) private {
        uint256 available = _availableCapacity();
        require(notional <= available, ExecutionCapacityExceeded());

        // `available` is capped by the uint128 `_maximum`, and `notional` cannot exceed it.
        // forge-lint: disable-next-line(unsafe-typecast)
        _available = uint128(available - notional);
        _lastUpdated = uint64(block.timestamp);
    }

    function _availableCapacity() private view returns (uint256) {
        uint256 refill = Math.mulDiv(_refillPerDay, block.timestamp - uint256(_lastUpdated), REFILL_PERIOD);
        return Math.min(uint256(_maximum), uint256(_available) + refill);
    }
}
