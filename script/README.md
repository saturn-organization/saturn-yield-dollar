# Deployment Guide

This guide covers deploying the Saturn Yield Dollar protocol contracts.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Access to an RPC endpoint for your target network
- Deployer wallet with sufficient ETH for gas
- External contract addresses ready (USDat token, Chainlink oracle)

## Contracts Deployed

| Contract | Type | Description |
|----------|------|-------------|
| TokenizedSTRC | Implementation | tSTRC token with oracle price feed |
| WithdrawalQueueERC721 | Implementation + Proxy | NFT-based withdrawal queue (UUPS upgradeable) |
| StakedUSDat | Implementation + Proxy | Main ERC4626 vault (UUPS upgradeable) |

## Environment Variables

### Required

| Variable | Description |
|----------|-------------|
| `USDAT` | Address of the external USDat token contract |
| `ORACLE` | Address of the Chainlink price oracle for STRC/USD |

### Optional

These default to the deployer address if not specified:

| Variable | Description |
|----------|-------------|
| `ADMIN` | Address granted DEFAULT_ADMIN_ROLE on all contracts |
| `PROCESSOR` | Address granted PROCESSOR_ROLE for conversions and withdrawals |
| `COMPLIANCE` | Address granted COMPLIANCE_ROLE for blacklist management |
| `DEPOSIT_FEE_RECIPIENT` | Address that receives deposit fees |

## Deployment Order

The script deploys contracts in this specific order due to dependencies:

```
1. TokenizedSTRC
   └── Needs: oracle address
   
2. WithdrawalQueueERC721 (Implementation + Proxy)
   └── Needs: USDat address, TokenizedSTRC address
   
3. StakedUSDat Implementation
   └── Needs: TokenizedSTRC address, WithdrawalQueueERC721 address (immutables)
   
4. StakedUSDat Proxy
   └── Initialized with: admin, processor, compliance, depositFeeRecipient, USDat
   
5. Link contracts and grant roles
   └── TokenizedSTRC: grant STAKED_USDAT_ROLE to StakedUSDat proxy
   └── WithdrawalQueueERC721: setStakedUSDat (also grants STAKED_USDAT_ROLE)
   └── WithdrawalQueueERC721: grant PROCESSOR_ROLE to processor
   └── WithdrawalQueueERC721: grant COMPLIANCE_ROLE to compliance
```

## Role Grants (Automatic)

The deployment script automatically grants these roles:

### TokenizedSTRC
| Role | Granted To |
|------|------------|
| DEFAULT_ADMIN_ROLE | Admin |
| STAKED_USDAT_ROLE | StakedUSDat Proxy |

### WithdrawalQueueERC721
| Role | Granted To |
|------|------------|
| DEFAULT_ADMIN_ROLE | Admin |
| STAKED_USDAT_ROLE | StakedUSDat Proxy |
| PROCESSOR_ROLE | Processor |
| COMPLIANCE_ROLE | Compliance |

### StakedUSDat
| Role | Granted To |
|------|------------|
| DEFAULT_ADMIN_ROLE | Admin |
| PROCESSOR_ROLE | Processor |
| COMPLIANCE_ROLE | Compliance |

## Post-Deployment (Manual)

After deployment, you must manually grant the minting role on the external USDat contract:

```
USDat.grantRole(MINTER_ROLE, <WithdrawalQueueERC721 Proxy Address>)
```

This allows the WithdrawalQueue to mint USDat when processing withdrawal requests.

## Environment File Setup

Create a `.env` file in the project root:

```shell
# Required
USDAT=0x...                    # USDat token contract address
ORACLE=0x...                   # Chainlink STRC/USD price oracle address

# Optional - Defaults to deployer if not set
ADMIN=0x...                    # DEFAULT_ADMIN_ROLE on all contracts
PROCESSOR=0x...                # PROCESSOR_ROLE for conversions/withdrawals
COMPLIANCE=0x...               # COMPLIANCE_ROLE for blacklist management
DEPOSIT_FEE_RECIPIENT=0x...    # Address that receives deposit fees

# Deployment
PRIVATE_KEY=0x...              # Deployer private key
RPC_URL=https://...            # Network RPC endpoint
ETHERSCAN_API_KEY=...          # For contract verification (optional)
```

Make sure `.env` is in your `.gitignore`.

## Deployment Commands

### Live Deployment

```shell
source .env
forge script script/Deploy.s.sol:DeployScript --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Dry Run (Simulation)

```shell
source .env
forge script script/Deploy.s.sol:DeployScript --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

### With Verification

```shell
source .env
forge script script/Deploy.s.sol:DeployScript --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

## Deployment Output

The script logs all deployed addresses:

```
=== Deployment Configuration ===
Deployer: 0x...
Admin: 0x...
Processor: 0x...
Compliance: 0x...
Deposit Fee Recipient: 0x...
USDat: 0x...
Oracle: 0x...

1. TokenizedSTRC deployed at: 0x...
2. WithdrawalQueueERC721 Implementation deployed at: 0x...
   WithdrawalQueueERC721 Proxy deployed at: 0x...
3. StakedUSDat Implementation deployed at: 0x...
4. StakedUSDat Proxy deployed at: 0x...
5. TokenizedSTRC: Granted STAKED_USDAT_ROLE to StakedUSDat
6. WithdrawalQueueERC721: Set StakedUSDat and granted STAKED_USDAT_ROLE
7. WithdrawalQueueERC721: Granted PROCESSOR_ROLE to 0x...
8. WithdrawalQueueERC721: Granted COMPLIANCE_ROLE to 0x...

=== Deployment Complete ===
TokenizedSTRC: 0x...
WithdrawalQueueERC721: 0x...
StakedUSDat Implementation: 0x...
StakedUSDat Proxy: 0x...
```

## Important Addresses to Save

After deployment, save these addresses for integration:

| Contract | Use |
|----------|-----|
| **StakedUSDat Proxy** | Main entry point for users (deposits, withdrawals) |
| **WithdrawalQueueERC721 Proxy** | For claiming withdrawals and viewing queue status |
| **TokenizedSTRC** | For oracle price queries |
| **StakedUSDat Implementation** | Needed for future upgrades |
| **WithdrawalQueueERC721 Implementation** | Needed for future upgrades |

## Upgrading Contracts

Both StakedUSDat and WithdrawalQueueERC721 use the UUPS proxy pattern. To upgrade:

1. Deploy new implementation contract
2. Call `upgradeToAndCall(newImplementation, data)` on the proxy
3. Only DEFAULT_ADMIN_ROLE can perform upgrades
