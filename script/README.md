# Deployment Scripts

## Overview

This folder contains deployment scripts for the sUSDat protocol contracts using [CreateX](https://github.com/pcaversaccio/createx) for deterministic addresses across all chains.

## Deployed Contracts

| Contract | Type | Description |
|----------|------|-------------|
| StrcPriceOracle | Non-upgradeable | Chainlink-compatible price oracle wrapper for STRC |
| WithdrawalQueueERC721 | UUPS Proxy | NFT-based withdrawal queue for redemption requests |
| StakedUSDat | UUPS Proxy | ERC4626 vault for staking USDat |

## Deterministic Addresses

Using deployer `0x8CBA689B49f15E0a3c8770496Df8E88952d6851d`:

| Contract | Address |
|----------|---------|
| StrcPriceOracle | `0x9C87dd67355c8Da172D3e2A2cADE1CcD15E23A58` |
| WithdrawalQueueERC721 Proxy | `0x3b2bd22089ED734979BB80A614d812b31B37ece4` |
| StakedUSDat Proxy | `0x1383cB4A7f78a9b63b4928f6D4F77221b50f30a4` |

These addresses are the same on any chain when using the same deployer and salts.

## Salt Configuration

Salts are defined at the top of `Deploy.s.sol`:

```solidity
string constant SALT_STRC_ORACLE = "StrcPriceOracle";
string constant SALT_WQ_IMPL = "WithdrawalQueueERC721.impl";
string constant SALT_WQ_PROXY = "WithdrawalQueueERC721.proxy";
string constant SALT_SUSDAT_IMPL = "StakedUSDat.impl";
string constant SALT_SUSDAT_PROXY = "StakedUSDat.proxy";
```

To deploy new versions, update these salt strings (e.g., `"StrcPriceOracle.v2"`).

## Environment Variables

Create a `.env` file with the following:

```bash
# Required
PRIVATE_KEY=<deployer_private_key>
RPC_URL=<rpc_endpoint>
USDAT=<usdat_token_address>
ORACLE=<chainlink_strc_oracle_address>

# Optional (defaults to deployer)
ADMIN=<admin_address>
PROCESSOR=<processor_address>
COMPLIANCE=<compliance_address>
DEPOSIT_FEE_RECIPIENT=<fee_recipient_address>
```

## Deployment Command

```bash
source .env && forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Add `--verify` to verify contracts on Etherscan:

```bash
source .env && forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

## Deployment Order

1. **Compute addresses** - All addresses are precomputed using CreateX
2. **StrcPriceOracle** - Deployed with admin and oracle address
3. **WithdrawalQueueERC721 Impl** - Implementation with USDAT and precomputed StakedUSDat proxy address
4. **WithdrawalQueueERC721 Proxy** - Initialized with admin, precomputed StakedUSDat proxy, processor, and compliance (roles granted in initialize)
5. **StakedUSDat Impl** - Implementation with StrcPriceOracle and WithdrawalQueue proxy
6. **StakedUSDat Proxy** - Initialized with admin, processor, compliance, fee recipient, and USDAT

## Roles

All roles are granted during initialization - no manual role grants required.

### StakedUSDat Roles
- `DEFAULT_ADMIN_ROLE` - Admin
- `PROCESSOR_ROLE` - Processor
- `COMPLIANCE_ROLE` - Compliance

### WithdrawalQueueERC721 Roles
- `DEFAULT_ADMIN_ROLE` - Admin
- `STAKED_USDAT_ROLE` - StakedUSDat Proxy
- `PROCESSOR_ROLE` - Processor
- `COMPLIANCE_ROLE` - Compliance

### StrcPriceOracle Roles
- `DEFAULT_ADMIN_ROLE` - Admin

## CreateX Factory

The deployment uses CreateX at `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`, which is deployed on all major chains.
