// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SharedConfig} from "./SharedConfig.sol";

abstract contract MigrationConfig is SharedConfig {
    address public constant MIGRATION_TIMELOCK = 0x6F72de4F529a03Bfa883825152656a8c62CBB626;
    address public constant MIGRATION_PROPOSER = 0x7A5A4064005584bc727666ec82548A9139d5F21e;
    uint256 public constant MIGRATION_TIMELOCK_DELAY = 1 hours;

    // Step 2 operation. TODO: Set after the upgrade validation round trip.
    // Vehicle and tolerance attest live state; they are independent of initial settings.
    uint256 public constant EXPECTED_STRCON = 593_235_440_171_947_300_000_000; // 593,235.4401719473 STRCon (18 decimals).
    address public constant EXPECTED_EXECUTION_VEHICLE = 0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468;
    uint16 public constant EXPECTED_MIGRATION_TOLERANCE_BPS = 200;
    uint256 public constant MIGRATION_DEADLINE = 1790899200; // 2026-10-02 00:00:00 UTC (Friday).

    bytes32 public constant MIGRATION_PREDECESSOR = bytes32(0);
    bytes32 public constant MIGRATION_SALT = bytes32(0);
    bool public constant MIGRATION_CONFIGURATION_APPROVED = true;
}
