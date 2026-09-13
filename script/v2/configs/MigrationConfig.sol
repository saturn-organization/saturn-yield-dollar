// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SharedConfig} from "./SharedConfig.sol";

abstract contract MigrationConfig is SharedConfig {
    // Step 2 operation. TODO: Set after the upgrade validation round trip.
    // Vehicle and tolerance attest live state; they are independent of initial settings.
    uint256 public constant EXPECTED_STRCON = 0; // 18-decimal STRCon units.
    address public constant EXPECTED_EXECUTION_VEHICLE = address(0);
    uint16 public constant EXPECTED_MIGRATION_TOLERANCE_BPS = 0;
    uint256 public constant MIGRATION_DEADLINE = 0; // Unix timestamp.
    bytes32 public constant MIGRATION_PREDECESSOR = bytes32(0);
    bytes32 public constant MIGRATION_SALT = bytes32(0); // TODO: Unique, nonzero salt.
    bool public constant MIGRATION_CONFIGURATION_APPROVED = false;
}
