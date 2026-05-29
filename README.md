# Saturn Yield Dollar (sUSDat)

A yield-bearing wrapper around **USDat**. Users stake USDat and receive **sUSDat**,
an ERC-4626 vault share that accrues yield from tokenized STRC (`tSTRC`) positions.
Redemptions are processed asynchronously through an on-chain withdrawal queue.

## Architecture

Three contracts, deployed on **Ethereum mainnet (chain id 1)**:

| Contract | Role | Pattern |
|---|---|---|
| `StakedUSDat` | ERC-4626 vault minting `sUSDat`; handles deposits, reward vesting, blacklist/compliance, and async redemptions | UUPS proxy + implementation |
| `WithdrawalQueueERC721` | Mints an ERC-721 per redemption request; processes and settles claims | UUPS proxy + implementation |
| `StrcPriceOracle` | Wraps a Chainlink-compatible STRC price feed with staleness and price-bound checks | Standalone (CreateX) |

- **Upgradeability.** `StakedUSDat` and `WithdrawalQueueERC721` sit behind
  ERC-1967 proxies. The implementation address lives in the proxy's EIP-1967
  slot; `_authorizeUpgrade` is gated on `DEFAULT_ADMIN_ROLE`. `StrcPriceOracle`
  is not upgradeable.
- **Immutables.** Each implementation bakes its sibling addresses into runtime
  bytecode as immutables (e.g. `StakedUSDat` holds the oracle and the withdrawal
  queue). The UUPS contracts also bake in their own deployed address
  (`UUPSUpgradeable.__self`). Configuration set at `initialize` time (admin,
  processor, compliance, fees, …) lives in **proxy storage**, not in the
  implementation bytecode.
- **Roles.** `DEFAULT_ADMIN_ROLE` (admin/upgrades), `PROCESSOR_ROLE` (queue
  processing), `COMPLIANCE_ROLE` (blacklist/seizure), `STAKED_USDAT_ROLE`.

## Deployed addresses (mainnet)

| Component | Address |
|---|---|
| USDat (underlying) | `0x23238f20b894f29041f48D88eE91131C395Aaa71` |
| StakedUSDat — proxy | `0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7` |
| StakedUSDat — implementation | `0x2005e0ca201a37694125ff267ae57872bea0a0ce` |
| WithdrawalQueueERC721 — proxy | `0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e` |
| WithdrawalQueueERC721 — implementation | `0x256fa0ba1b6dfb50ee883955c5a99d3c1b017fd5` |
| StrcPriceOracle | `0x5f7eCD0D045c393da6cb6c933c671AC305A871BF` |

## Repository layout

```
src/                       Audited source
  StakedUSDat.sol
  WithdrawalQueueERC721.sol
  StrcPriceOracle.sol
  interfaces/
script/
  Deploy.s.sol             Initial deployment (CreateX deterministic proxies)
  Upgrade*.s.sol           Implementation upgrades
  VerifyCodeHash.s.sol     Code-consistency proof (see below)
test/                      Foundry tests
broadcast/                 On-chain deployment records (per chain id)
verify.sh                  Code-consistency proof runner
foundry.toml               Compiler settings (solc 0.8.30, optimizer, 200 runs)
```

## Development

```shell
forge build        # compile
forge test         # run tests
forge fmt          # format
```

## Audit & code-consistency verification

This repo ships a reproducible proof that the bytecode deployed on mainnet is
exactly the audited source at a known commit. The proof is a single runtime
code hash (`EXTCODEHASH`) on each side: a local build and the live chain.

### Run it

`.env.prod` must provide `RPC_URL` (an Ethereum mainnet endpoint). You do not
need to check out the audited commit — `verify.sh` does a read-only `git diff`
to confirm this checkout's source is identical to it, then builds and compares.

```shell
bash verify.sh
```

Expected output (abridged):

```
  network               : Ethereum mainnet (chain id 1)
  audited commit        : 49240e520408bc2d1d76351c557aa88f4fb9ef1a  (source verified identical)

  StrcPriceOracle        0x5f7eCD0D045c393da6cb6c933c671AC305A871BF
    local  code hash    : 0x13f19c58…3b54ef
    production code hash : 0x13f19c58…3b54ef
  WithdrawalQueueERC721  0x256fa0ba1b6dfb50ee883955c5a99d3c1b017fd5
    local  code hash    : 0x4bbdf6f6…46ffe1
    production code hash : 0x4bbdf6f6…46ffe1
  StakedUSDat            0x2005e0ca201a37694125ff267ae57872bea0a0ce
    local  code hash    : 0x555fcdfc…a8d2a2
    production code hash : 0x555fcdfc…a8d2a2

  MATCH - mainnet implementations run the audited code (commit 49240e5…)
```

### Reference values

Built from commit `49240e520408bc2d1d76351c557aa88f4fb9ef1a` with solc `0.8.30`,
optimizer enabled, 200 runs (per `foundry.toml`).

| Contract | Implementation | EXTCODEHASH | Metadata IPFS hash |
|---|---|---|---|
| StrcPriceOracle | `0x5f7eCD0D…A871BF` | `0x13f19c583dc97f1544de9ed6fbdc01df4115704d30043ad608aac0d73c3b54ef` | `QmYjf6ccPPz3uNxurdMQhZnjz5RviXfKb2C56NnWicgsHA` |
| WithdrawalQueueERC721 | `0x256fa0ba…017fd5` | `0x4bbdf6f68aaefdf98290c5662e7bb0c9d566ffa1e0abff19a5332cf81246ffe1` | `QmUGLgQf1H8zDu4RMq69LRMsaTbxZ73iUTprooGuf7LRRp` |
| StakedUSDat | `0x2005e0ca…a0a0ce` | `0x555fcdfcc7e072b39cb27f6a0f4619c376a0d6b1f6d2b8d60216d5beaca8d2a2` | `QmbyxfkLxuN38bVF46Kq32oDsrmnS4Ww1FwiStpFY8QdbW` |

### How it works

`verify.sh` first does a read-only `git diff --ignore-submodules=dirty` of the
compilation inputs (`src`, the `lib` submodule pins, `foundry.toml`,
`remappings.txt`) against the audited commit — nothing is checked out, moved, or
modified — and aborts if they differ. It then runs `script/VerifyCodeHash.s.sol`,
which compiles that source and deploys each implementation in a local EVM and
logs each contract's `EXTCODEHASH`, and compares those to the live values fetched
with `cast codehash <impl>`.

Because the implementations bake their own deployed address into bytecode (the
UUPS `__self` immutable), the runtime code hash is **address-dependent**. To
reproduce the on-chain hash exactly, the script replays each original deployment
context — the same deployer EOA and nonce — so the local deploy lands at the
same address with identical immutables. `StrcPriceOracle` has no immutables, so
its code hash is independent of address and constructor arguments.

As an independent cross-check, every implementation also embeds a Solidity
metadata IPFS hash (the CBOR tail of its runtime bytecode). The values in the
table above are identical on the local artifact and the on-chain code, which
confirms the source files and compiler settings match. To read the on-chain
code, the trailing CBOR blob holds that metadata hash:

```shell
cast code <impl> --rpc-url $RPC_URL
```

### Scope

This proof verifies the **implementation logic** of each contract. It does not
verify proxy-storage state — admin/processor/compliance role assignments, fee
parameters, the configured price feed, and other values set at `initialize` time
live in proxy storage and must be verified separately (e.g. via `cast call` /
`cast storage` against the proxy addresses).

> Note: the on-chain implementations were deployed across a few commits as the
> protocol was upgraded — the `StakedUSDat` impl at PR #88, the
> `WithdrawalQueueERC721` impl at PR #87, and `StrcPriceOracle` at initial
> deployment. The source of all three is identical at the audited commit
> `49240e5`, which is why a single build reproduces every on-chain code hash.
