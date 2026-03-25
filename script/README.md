# Deployment Scripts

## Overview

This folder contains deployment scripts for the sUSDat protocol contracts using [CreateX](https://github.com/pcaversaccio/createx) for deterministic proxy addresses across all chains.

## Deployed Contracts

| Contract | Type | Description |
|----------|------|-------------|
| StrcPriceOracle | Non-upgradeable | Chainlink-compatible price oracle wrapper for STRC |
| WithdrawalQueueERC721 | UUPS Proxy | NFT-based withdrawal queue for redemption requests |
| StakedUSDat | UUPS Proxy | ERC4626 vault for staking USDat |

## Sepolia Testnet Addresses (v2)

Using deployer `0x8CBA689B49f15E0a3c8770496Df8E88952d6851d`:

| Contract | Address |
|----------|---------|
| StrcPriceOracle | `0x5f7eCD0D045c393da6cb6c933c671AC305A871BF` |
| WithdrawalQueueERC721 Proxy | `0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e` |
| StakedUSDat Proxy | `0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7` |
| MockChainlinkOracle | `0x99AC1d95B3bb883BC11f4B49399C06e96a118a8D` |
| ChainlinkOracle | `0xf4d2076277fff631EFC4385Ab36b1f7734218d23` |

**Note:** Proxy addresses are deterministic via CreateX (same on all chains with same deployer). Implementation addresses use standard CREATE and may vary by chain.

## Salt Configuration

Salts are defined at the top of `Deploy.s.sol`:

```solidity
string constant SALT_STRC_ORACLE = "StrcPriceOracle.v2";
string constant SALT_WQ_PROXY = "WithdrawalQueueERC721.proxy.v2";
string constant SALT_SUSDAT_PROXY = "StakedUSDat.proxy.v2";
```

To deploy new versions, update these salt strings (e.g., `"StrcPriceOracle.v3"`).

## Environment Variables

Create a `.env` file with the following:

```bash
# Required
PRIVATE_KEY=<deployer_private_key>
RPC_URL=<rpc_endpoint>
USDAT=<usdat_token_address>
ORACLE=<chainlink_strc_oracle_address>
ETHERSCAN_API_KEY=<etherscan_api_key>

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

## Verification

After deployment, verify contracts on Etherscan:

```bash
# StrcPriceOracle
forge verify-contract <STRC_ORACLE_ADDRESS> src/StrcPriceOracle.sol:StrcPriceOracle \
  --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address)" <ADMIN> <ORACLE>)

# WithdrawalQueueERC721 Impl
forge verify-contract <WQ_IMPL_ADDRESS> src/WithdrawalQueueERC721.sol:WithdrawalQueueERC721 \
  --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address)" <USDAT> <SUSDAT_PROXY>)

# StakedUSDat Impl
forge verify-contract <SUSDAT_IMPL_ADDRESS> src/StakedUSDat.sol:StakedUSDat \
  --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address)" <STRC_ORACLE> <WQ_PROXY>)
```

## Deployment Order

1. **Compute addresses** - Proxy addresses are precomputed using CreateX
2. **StrcPriceOracle** - Deployed via CreateX with admin and oracle address
3. **WithdrawalQueueERC721 Impl** - Deployed via CREATE with USDAT and precomputed StakedUSDat proxy address
4. **WithdrawalQueueERC721 Proxy** - Deployed via CreateX, initialized with admin, StakedUSDat proxy, processor, compliance
5. **StakedUSDat Impl** - Deployed via CREATE with StrcPriceOracle and WithdrawalQueue proxy
6. **StakedUSDat Proxy** - Deployed via CreateX, initialized with admin, processor, compliance, fee recipient, USDAT

## Upgrade Scripts

To upgrade implementations without changing proxy addresses:

```bash
# Upgrade StakedUSDat
forge script script/UpgradeStakedUSDat.s.sol --rpc-url $RPC_URL --broadcast

# Upgrade WithdrawalQueueERC721
forge script script/UpgradeWithdrawalQueueERC721.s.sol --rpc-url $RPC_URL --broadcast
```

## Mock Oracle (Testnet Only)

For testnet deployments, a mock oracle is available:

```bash
# Deploy mock oracle
forge script script/DeployMockOracle.s.sol --rpc-url $RPC_URL --broadcast

# Update heartbeat (run periodically to prevent staleness)
MOCK_ORACLE=<address> forge script script/OracleHeartbeat.s.sol --rpc-url $RPC_URL --broadcast
```

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
