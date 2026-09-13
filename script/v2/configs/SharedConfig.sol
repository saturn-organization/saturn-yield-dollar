// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract SharedConfig {
    uint256 public constant EXPECTED_CHAIN_ID = 1;
    uint256 public constant TIMELOCK_DELAY = 5 days;
    uint16 public constant MAX_MIGRATION_TOLERANCE_BPS = 500;

    address public constant USDAT = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address public constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;
    address public constant WITHDRAWAL_QUEUE_PROXY = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;
    address public constant STRCON = 0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c;
    address public constant TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;
    address public constant PROPOSER = 0x610182581C93687Ca03F4a8E7f124f8cEC616820;
}
