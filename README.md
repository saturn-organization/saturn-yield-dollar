# Saturn Yield Dollar

A DeFi yield protocol that enables users to stake USD-backed assets (USDat) and earn yield from Treasury Bill (T-Bill) investments through a sophisticated tokenization and withdrawal queue system.

## Table of Contents

- [Overview](#overview)
- [Token Model](#token-model)
- [Architecture](#architecture)
- [Contracts](#contracts)
- [Key Functionality](#key-functionality)
- [Access Control](#access-control)
- [Security Features](#security-features)
- [Configuration](#configuration)
- [Development](#development)
- [Deployment](#deployment)

## Overview

Saturn Yield Dollar is built for EVM-compatible blockchains and implements:

- **ERC4626 Vault Standard** for composable yield-bearing tokens
- **ERC721-based Withdrawal Queue** for asynchronous redemptions
- **Chainlink Oracle Integration** for real-time T-Bill pricing
- **UUPS Upgradeable Pattern** for secure contract upgrades

## Token Model

| Token | Type | Purpose |
|-------|------|---------|
| **USDat** | ERC20 (external) | Base stablecoin backed by Treasury Bills |
| **sUSDat** | ERC4626 Vault Share | Staked USDat - represents user's share in the vault |
| **tSTRC** | ERC20 | Tokenized STRC - represents off-chain T-Bill holdings |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    USER ACTIONS                         │
│     deposit() / mint() / requestWithdraw() / claim()    │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
              ┌─────────────────────┐
              │   StakedUSDat.sol   │  (ERC4626 Vault)
              │                     │
              │  - Manages deposits │
              │  - Tracks vesting   │
              │  - Handles convert  │
              └────────┬────────────┘
                       │
         ┌─────────────┴─────────────┐
         ▼                           ▼
┌──────────────────────┐   ┌─────────────────────┐
│ WithdrawalQueueERC721│   │  TokenizedSTRC.sol  │
│                      │   │                     │
│ - NFT-based queue    │   │ - Chainlink Oracle  │
│ - Batch processing   │   │ - Price validation  │
│ - Pro-rata claims    │   │ - Staleness checks  │
└──────────────────────┘   └─────────────────────┘
```

### Key Flows

**Deposit Flow:**
1. User calls `deposit(assets)` or `mint(shares)`
2. Deposit fee charged (if enabled) and sent to fee recipient
3. USDat transferred from user to vault
4. sUSDat shares minted to receiver

**Withdrawal Flow:**
1. User calls `requestWithdraw(assets)` or `requestRedeem(shares)`
2. sUSDat shares escrowed in WithdrawalQueue
3. ERC721 NFT minted as receipt
4. Processor sells tSTRC off-chain and calls `processRequests()`
5. User calls `claim()` to receive USDat

**Yield Generation:**
1. Processor converts USDat to tSTRC (off-chain T-Bill purchases)
2. tSTRC value appreciates over time
3. Rewards distributed via `transferInRewards()` and vest over 30 days
4. Share price increases as totalAssets grows

## Contracts

### Main Contracts

| Contract | Lines | Description |
|----------|-------|-------------|
| `StakedUSDat.sol` | 577 | Main ERC4626 vault handling deposits, conversions, and vesting |
| `WithdrawalQueueERC721.sol` | 645 | Async withdrawal queue using ERC721 NFTs as receipts |
| `TokenizedSTRC.sol` | 132 | tSTRC token with Chainlink oracle price feed |

### Interfaces

| Interface | Purpose |
|-----------|---------|
| `IStakedUSDat.sol` | External interface for WithdrawalQueue interactions |
| `ITokenizedSTRC.sol` | Price oracle integration interface |
| `IWithdrawalQueueERC721.sol` | External interface for StakedUSDat interactions |
| `IUSDat.sol` | External USDat token interface |
| `IERC20Burnable.sol` | Standard burnable token interface |

## Key Functionality

### User Functions

| Function | Description |
|----------|-------------|
| `deposit(assets, receiver)` | Deposit USDat, receive sUSDat |
| `mint(shares, receiver)` | Mint specific sUSDat amount |
| `depositWithMinShares(assets, receiver, minShares)` | Deposit with slippage protection |
| `requestWithdraw(assets, minUsdatReceived)` | Request withdrawal with slippage check |
| `requestRedeem(shares, minUsdatReceived)` | Request redemption with slippage check |
| `claim()` | Claim all processed withdrawals |
| `claimBatch(tokenIds[])` | Claim specific withdrawal requests |
| `getMyRequests()` | View own withdrawal requests |
| `getClaimable(user)` | View claimable requests |

### Admin/Processor Functions

| Function | Role | Description |
|----------|------|-------------|
| `convertFromUsdat()` | PROCESSOR | Convert USDat to tSTRC |
| `convertFromStrc()` | PROCESSOR | Convert tSTRC to USDat |
| `transferInRewards()` | PROCESSOR | Distribute vesting rewards |
| `processRequests()` | PROCESSOR | Process withdrawal batch |
| `setVestingPeriod()` | PROCESSOR | Update reward vesting duration |
| `setDepositFee()` | PROCESSOR | Update deposit fee (0-500 bps) |

### Compliance Functions

| Function | Role | Description |
|----------|------|-------------|
| `addToBlacklist()` | COMPLIANCE | Blacklist address |
| `removeFromBlacklist()` | COMPLIANCE | Remove from blacklist |
| `seizeRequests()` | COMPLIANCE | Seize pending withdrawal NFTs |
| `pause()` | COMPLIANCE | Emergency pause |
| `unpause()` | DEFAULT_ADMIN | Resume operations |

## Access Control

| Role | Capabilities |
|------|--------------|
| **DEFAULT_ADMIN** | Upgrade contracts, unpause, grant/revoke roles, set tolerance, redistribute blacklisted funds |
| **PROCESSOR** | Convert USDat/tSTRC, transfer rewards, process withdrawals, update fees and vesting |
| **COMPLIANCE** | Manage blacklist, seize funds, pause protocol |

## Security Features

- **Reentrancy Guards**: All critical functions protected with `nonReentrant`
- **Blacklist System**: Compliance can freeze addresses and seize funds
- **Pause Mechanism**: Emergency pause of deposits and withdrawals
- **Price Validation**: Execution price validated against Chainlink oracle
- **Staleness Checks**: Oracle prices must be within 6 hours
- **Slippage Protection**: Users set minimum acceptable amounts
- **30-day Reward Vesting**: Prevents front-running on reward announcements
- **UUPS Upgradeable**: Allows security fixes without redeployment
- **ERC4626 Offset**: Prevents donation attacks

## Configuration

### Default Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `MAX_VESTING_PERIOD` | 90 days | Maximum reward vesting duration |
| `DEFAULT_VESTING_PERIOD` | 30 days | Default reward vesting duration |
| `MIN_WITHDRAWAL` | 10 USDat | Minimum withdrawal amount |
| `MAX_DEPOSIT_FEE_BPS` | 500 bps (5%) | Maximum deposit fee |
| `DEFAULT_DEPOSIT_FEE` | 10 bps (0.1%) | Default deposit fee |
| `MAX_STALENESS` | 6 hours | Maximum oracle price age |
| `MIN_PRICE` | $20 | tSTRC price floor |
| `MAX_PRICE` | $150 | tSTRC price ceiling |
| `DEFAULT_TOLERANCE` | 2000 bps (20%) | Default price tolerance |

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Local Node

```shell
anvil
```

## Deployment

### Environment Variables

```shell
USDAT=<address>                  # External USDat token address
ORACLE=<address>                 # Chainlink oracle address
ADMIN=<address>                  # Default admin (defaults to deployer)
PROCESSOR=<address>              # Processor role (defaults to deployer)
COMPLIANCE=<address>             # Compliance role (defaults to deployer)
DEPOSIT_FEE_RECIPIENT=<address>  # Fee recipient (defaults to deployer)
```

### Deploy

```shell
forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
```

### Post-Deployment

1. Grant minting role on external USDat contract to WithdrawalQueue
2. Verify oracle address is correctly set on TokenizedSTRC

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) - Standard and upgradeable contracts
- [Foundry](https://github.com/foundry-rs/foundry) - Development framework

## License

See [LICENSE](LICENSE) for details.
