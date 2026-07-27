// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISTRConModule} from "./modules/ISTRConModule.sol";

/**
 * @title ISTRConExecutionPolicy
 * @author Saturn
 * @notice Vault-bound STRCon execution configuration, price validation, and turnover capacity.
 */
interface ISTRConExecutionPolicy {
    error AlreadyInitialized();
    error ExecutionCapacityExceeded();
    error ExecutionPriceMismatch();
    error ExecutionVehicleMismatch();
    error InvalidExecutionTolerance();
    error InvalidZeroAddress();
    error Unauthorized();

    event ExecutionCapacityUpdated(uint128 maximum, uint128 refillPerDay);
    event ExecutionToleranceUpdated(uint16 oldBps, uint16 newBps);
    event ExecutionVehicleUpdated(address indexed oldVehicle, address indexed newVehicle);

    function VAULT() external view returns (address);
    function STRCON_MODULE() external view returns (ISTRConModule);
    function MAX_EXECUTION_TOLERANCE_BPS() external view returns (uint16);

    function executionVehicle() external view returns (address);
    function executionToleranceBps() external view returns (uint16);

    function executionCapacity()
        external
        view
        returns (uint128 maximum, uint128 available, uint128 refillPerDay, uint64 lastUpdated);

    function initialize(address vehicle, uint16 toleranceBps, uint128 maximum, uint128 refillPerDay) external;
    function setExecutionVehicle(address newVehicle) external;
    function setExecutionTolerance(uint16 newBps) external;
    function setExecutionCapacity(uint128 newMaximum, uint128 newRefillPerDay) external;

    function validateBuy(uint256 usdatPaid, uint256 assetReceived, address expectedVehicle)
        external
        returns (uint256 oraclePrice);

    function validateSell(uint256 assetDelivered, uint256 usdatReceived, address expectedVehicle)
        external
        returns (uint256 oraclePrice);
}
