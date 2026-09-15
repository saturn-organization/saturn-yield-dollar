// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SharedConfig} from "./SharedConfig.sol";

abstract contract UpgradeConfig is SharedConfig {
    // Validation limits, not initial fee or tolerance settings.
    uint16 public constant MAX_FEE_BPS = 500;
    uint16 public constant MAX_EXECUTION_TOLERANCE_BPS = 500;

    address public constant STAKED_USDAT_IMPLEMENTATION = 0x2b7074CF6681382b70E239063931ebE83C0f4E0A;
    address public constant WITHDRAWAL_QUEUE_IMPLEMENTATION = 0xdAF6f8523D7A707D173A12041e1523FDF1373f23;
    address public constant STRC_MIRROR_MODULE = 0xa2Cf4B9410cEbcDCeb3cFf772aC0219F6D1105C9;
    address public constant STRCON_MODULE = 0x3C0f0b502aa7C2ed85620f7f52B8eFb8049b1ECf;
    address public constant EXECUTION_POLICY = 0x69a4cc75f654Eb5fF0eD73E0153Fd17Fc66878dc;

    // TODO: Set approved upgrade configuration. Zeros are unapproved placeholders.
    address public constant RECOVERY_ADDRESS = 0x6e5301A99E321f535C9e077f8f7F98770229B1a4;
    // Dedicated USDat wallet that preapproves the vault for surplus transfers.
    address public constant SURPLUS_SOURCE = 0xbBeb892bAA398251EBe80809906F2Ae51EF5a783;
    address public constant EXECUTION_VEHICLE = 0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468;

    uint16 public constant BASE_REDEMPTION_FEE_BPS = 10;
    uint16 public constant ELEVATED_REDEMPTION_FEE_BPS = 50;
    uint16 public constant ELEVATED_DEPOSIT_FEE_BPS = 25;
    uint16 public constant EXECUTION_TOLERANCE_BPS = 75;
    uint16 public constant MIGRATION_TOLERANCE_BPS = 200;

    // Six-decimal USDat units.
    uint128 public constant INITIAL_EXECUTION_CAPACITY = 6_000_000e6;
    uint128 public constant INITIAL_EXECUTION_REFILL_PER_DAY = 6_000_000e6;

    // TODO: Set approved vault role holders.
    address public constant VAULT_PARAMETER_MANAGER = 0x6F72de4F529a03Bfa883825152656a8c62CBB626;
    address public constant VAULT_MARKET_MODE_MANAGER = 0xC35580434261f667d6abBDa9E3dC1DC31e5A1b92;
    address public constant VAULT_OPERATOR = 0xC35580434261f667d6abBDa9E3dC1DC31e5A1b92;
    address public constant VAULT_SURPLUS_MANAGER = 0xC35580434261f667d6abBDa9E3dC1DC31e5A1b92;
    address public constant VAULT_BLACKLISTER = 0xf5a93281ac8604f99755cc489317e75aC334cfE2;
    address public constant VAULT_ENFORCER = 0x6F72de4F529a03Bfa883825152656a8c62CBB626;
    address public constant VAULT_PAUSER = 0xf5a93281ac8604f99755cc489317e75aC334cfE2;
    address public constant VAULT_UNPAUSER = 0x6F72de4F529a03Bfa883825152656a8c62CBB626;

    address public constant QUEUE_OPERATOR = 0xC35580434261f667d6abBDa9E3dC1DC31e5A1b92;
    address public constant QUEUE_ENFORCER = 0x6F72de4F529a03Bfa883825152656a8c62CBB626;
    address public constant QUEUE_PAUSER = 0xf5a93281ac8604f99755cc489317e75aC334cfE2;
    address public constant QUEUE_UNPAUSER = 0x6F72de4F529a03Bfa883825152656a8c62CBB626;

    bytes32 public constant UPGRADE_PREDECESSOR = bytes32(0);
    bytes32 public constant BATCH_SALT = bytes32(0);
    bool public constant UPGRADE_CONFIGURATION_APPROVED = false;
}
