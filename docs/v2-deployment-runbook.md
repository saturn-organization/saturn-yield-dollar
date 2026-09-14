# V2 Deployment Runbook

Ethereum mainnet (`chain ID 1`). Auditor-reviewed source:
[`f9bb4f99d9e0e021ae53a4fda5d6da5079fe8b99`](https://github.com/saturn-organization/saturn-yield-dollar/commit/f9bb4f99d9e0e021ae53a4fda5d6da5079fe8b99).

## Initial parameters

Agreed values so far; remaining launch parameters are TBD.

| Parameter | Value | Why |
|---|---|---|
| `INITIAL_EXECUTION_CAPACITY` | 6,000,000 USDat (`6_000_000e6`) | Shared buy/sell burst allowance with 20% headroom above the historical $5 million peak buying day. |
| `INITIAL_EXECUTION_REFILL_PER_DAY` | 6,000,000 USDat/day (`6_000_000e6`) | Supports consecutive busy trading days; an empty, unused bucket refills in 24 hours. |
| `V2_ORACLE_INITIAL_DEVIATION_BPS` | 100 bps (1%) | Rejects the largest observed feed disagreements while limiting pricing interruptions in the [historical sample](./drafts/strcon-feed-deviation-findings.md#recommendation). |
| `EXECUTION_TOLERANCE_BPS` | 75 bps (0.75%) | Leaves 36.33 bps above the largest observed all-in buy gap while execution is manual; reassess 50 bps after [delayed-settlement testing](./drafts/strcon-execution-tolerance-testing.md). |
| `MIGRATION_TOLERANCE_BPS` | 200 bps (2%) | Headroom above the supplied 6.6 bps valuation gap; limits the absolute whole-vault NAV change, not expected migration cost. See [migration analysis](./drafts/strcon-migration-tolerance.md). |
| `BASE_REDEMPTION_FEE_BPS` | 10 bps (0.10%) | Initial Regular-mode cost-recovery fee above the observed 6.52–8.54 bps sell-side gaps; return conversion to USDat is fee-free. |
| `ELEVATED_REDEMPTION_FEE_BPS` | 50 bps (0.50%) | Additional liquidity allowance for exits processed in Elevated mode. |
| `ELEVATED_DEPOSIT_FEE_BPS` | 25 bps (0.25%) | Keeps entry cheaper than Elevated exits while contributing to purchase costs. |

## ✅ Step 1 — Deploy all necessary contracts

Set the [dependency inputs](./v2-deployment/DeployV2Dependencies.md), including
expected addresses and hashes for the deployment nonce. Run the deployment script:

```bash
forge script script/v2/DeployV2Dependencies.s.sol:DeployV2Dependencies \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --etherscan-api-key "$SCANNER_API_KEY"
```

Copy the output addresses into [UpgradeConfig.sol](../script/v2/configs/UpgradeConfig.sol).

### Deployed addresses

| Contract | Address |
|---|---|
| STRConTradeExecutionLogic library | `0xDF89cCf4Ead4Ea2398400DF3E44BAA595695b0b6` |
| STRConPriceOracle | `0xc3200E39B18f9F208c551155a0F4F2299Bb827E9` |
| STRCMirrorModule | `0x5f860f46BEaA5A3fEE7726329a079243eCA4B5c1` |
| STRConModule | `0x5f7bd5C95EE38706C4c4B609D44ABF63Ad8b2C4F` |
| STRConExecutionPolicy | `0x30A8faEAd711d5c10285250d690B84caF50622A9` |
| WithdrawalQueueERC721 implementation | `0x0Bb1Bcfb13987a647FE2f7db5f73C03F57696d73` |
| StakedUSDat implementation | `0x188597b16D391cF7FB74b7f12e4f736B8a1B2516` |

## Step 2 — Schedule and execute the upgrade (5 days)

### Overview

- Minimum duration: five days between scheduling and execution.
- Set `UPGRADE_CONFIGURATION_APPROVED = true` in
  [UpgradeConfig.sol](../script/v2/configs/UpgradeConfig.sol).
- Switch the frontend to v2 immediately after the upgrade executes.
- The vault starts in **Elevated** mode: 25 bps deposits and 50 bps redemptions.
  Regular mode requires a separate `authorizeRegularMode(validUntil)` call by
  the market-mode manager. Existing vault and queue pause states are preserved.
- After the upgrade, withdrawals can only be processed from available USDat in
  the vault. The legacy STRC position cannot be sold to replenish that buffer.
- Operator hold: keep processing stopped until migration is complete, legacy
  `InProgress` requests are cleared, and the owner grace period has ended.

### Execution steps

1. Propose the upgrade through Fireblocks:

   ```bash
   make upgrade-schedule
   ```

2. After the five-day timelock delay, execute with the deployer key:

   ```bash
   make upgrade-execute
   ```

## Step 3 — Schedule and execute migration

### Overview

- Duration: off-chain transfers and minting, followed by a minimum five-day
  timelock delay. Total time depends on the settlement timings below.
- Stop mirror `transferInRewards` calls. At scheduling and execution, the vault
  must be unpaused, the mirror fully vested (`getUnvestedAmount() == 0`), and
  the recognized STRCon module balance zero.
- Migration pulls STRCon from the execution vehicle into the vault, retires
  the STRC mirror, and recognizes the STRCon position. The absolute whole-vault
  NAV change must be within 200 bps (2%).

### Execution steps

1. **Move STRC from Clear Street to Alpaca.** Planning estimate: T+1 day.

2. **Mint STRCon through ITN** to the Saturn Fund Ltd. Tres-Ondo Account:
   `0xeAB18842D6ba63BCCd556e27f55ee7790907002B`.
   Timing is unconfirmed; current estimate: T+1 day.

3. **Redeem from the fund in STRCon** and send the tokens to the Saturn Global
   Capital Investments Ltd. Fireblocks Processor wallet:
   `0x09D6E34cE24D54890fF0BC6a090b5f880F8C729f`.
   Timing: TBD.

4. **Transfer STRCon to the execution vehicle** in Saturn Vault Corporation:
   `0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468`.

5. **Date the deed of gift legal contract.**

6. **Verify the STRCon delivery and valuation.** Use human-readable amounts,
   sValue, and prices, not raw contract integers:

   ```text
   Expected STRCon tokens = STRC shares converted / sValue used for minting
   STRCon value = delivered STRCon tokens × current STRCon oracle price
   STRC value = STRC shares in mirror × current STRC oracle price
   NAV change (%) = abs(STRCon value − STRC value) / total vault NAV × 100
   Pass: abs(STRCon value − STRC value) ≤ total vault NAV × 0.02
   ```

   Set in [MigrationConfig.sol](../script/v2/configs/MigrationConfig.sol):

   ```text
   EXPECTED_STRCON = delivered STRCon tokens × 10^18
   MIGRATION_DEADLINE = chosen Unix expiry timestamp
   MIGRATION_CONFIGURATION_APPROVED = true
   ```

7. **Approve the vault to pull the STRCon amount from the execution vehicle.**
   From `0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468`, approve the vault proxy
   (`0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7`) for `EXPECTED_STRCON`.

8. **Schedule migration through Fireblocks:**

   ```bash
   make migrate-schedule
   ```

9. **Execute the scheduled migration after the five-day delay:**

   ```bash
   make migrate-execute
   ```

   Both phases recheck live readiness. Keep the configuration unchanged after
   scheduling and execute before the original deadline.
   Confirm the mirror is retired at zero and the vault's STRCon custody and
   recognized balance reflect the delivery.

## Step 4 — Cleanup (To Do)

After the upgrade has been validated, revoke these obsolete roles on the proxies:

| Proxy | Roles to revoke | Current holders |
|---|---|---|
| Vault | `PROCESSOR_ROLE`, `COMPLIANCE_ROLE` | TBD |
| Queue | `PROCESSOR_ROLE`, `COMPLIANCE_ROLE`, `STAKED_USDAT_ROLE` | TBD |

1. Find all current holders using role-grant/revoke events and `hasRole`.
   Role IDs are `keccak256(bytes(roleName))`.
2. Schedule and execute `revokeRole(roleId, holder)` through the role administrator
   for every obsolete grant. These calls are separate from the upgrade batch.
3. Verify the old grants are removed and approved v2 roles remain.
   Preserve the approved `DEFAULT_ADMIN_ROLE` timelock on both proxies;
   any extra active admins or v2 holders need separate review.

Do not remove legacy oracle administration while the mirror still needs it.
After retirement, check for other consumers before decommissioning it.

## Communication Plan (To Do)

1. Before upgrade execution, notify legacy request owners that processing will
   remain stopped until migration and the owner grace period are complete.
   Explain that existing limits are not converted: the old absolute
   `minUsdatReceived` value becomes `minSharePrice`, a minimum net USDat payout
   per `1e18` shares in 6-decimal units, after fees.
2. Publish the post-upgrade grace-period end (**TBD**) and instructions for
   updating or cancelling requests. Confirm owners have a working way to do both.
   Queue pause blocks both actions; vault pause also blocks cancellation.
   Extend the grace period if those actions were unavailable.
