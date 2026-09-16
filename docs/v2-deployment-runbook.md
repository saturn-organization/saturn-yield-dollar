# V2 Deployment Runbook

Ethereum mainnet (`chain ID 1`). Auditor-reviewed baseline:
[`f9bb4f99d9e0e021ae53a4fda5d6da5079fe8b99`](https://github.com/saturn-organization/saturn-yield-dollar/commit/f9bb4f99d9e0e021ae53a4fda5d6da5079fe8b99).

## **Initial parameters**

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

## **✅ Step 1 — Deploy all necessary contracts**

Set the [dependency inputs](./v2-deployment/DeployV2Dependencies.md), including
expected addresses and hashes for the deployment nonce. Run the deployment script:

```bash
forge script script/v2/DeployV2Dependencies.s.sol:DeployV2Dependencies \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$SCANNER_API_KEY"
```

Copy the output addresses into [UpgradeConfig.sol](../script/v2/configs/UpgradeConfig.sol).

### Deployed addresses

| Contract | Address |
|---|---|
| STRConTradeExecutionLogic library | `0x5756699Ee0EB8247A334671E2b17228256cC7A47` |
| STRConPriceOracle | `0x8201ff053Bb7C96c10Fb9611934C14142B2702dE` |
| STRCMirrorModule | `0xa2Cf4B9410cEbcDCeb3cFf772aC0219F6D1105C9` |
| STRConModule | `0x3C0f0b502aa7C2ed85620f7f52B8eFb8049b1ECf` |
| STRConExecutionPolicy | `0x69a4cc75f654Eb5fF0eD73E0153Fd17Fc66878dc` |
| WithdrawalQueueERC721 implementation | `0xdAF6f8523D7A707D173A12041e1523FDF1373f23` |
| StakedUSDat implementation | `0x2b7074CF6681382b70E239063931ebE83C0f4E0A` |

## **Step 2 — Schedule and execute the upgrade (5 days)**

### Overview

- Minimum duration: five days between scheduling and execution.
- Set `UPGRADE_CONFIGURATION_APPROVED = true` in
  [UpgradeConfig.sol](../script/v2/configs/UpgradeConfig.sol).
- The vault starts in Elevated mode: 25 bps deposits and 50 bps redemptions.
  Regular mode requires a separate `authorizeRegularMode(validUntil)` call by
  the market-mode manager. Existing vault and queue pause states are preserved.
- After the upgrade, withdrawals can only be processed from available USDat in
  the vault. The legacy STRC position cannot be sold to replenish that buffer.
- Operator hold: keep processing stopped until migration is complete, legacy
  `InProgress` requests are cleared, and the review period has ended.

### Execution steps

1. Propose the upgrade through Fireblocks:

   ```bash
   make upgrade-schedule
   ```

2. After the five-day timelock delay, execute with the deployer key:

   ```bash
   make upgrade-execute
   ```

## **Step 3 — Schedule and execute migration**

### Overview

- Duration: off-chain transfers and minting, followed by a minimum two-day
  timelock delay. Total time depends on the settlement timings below.
- Migration uses the `PARAMETER_MANAGER_ROLE` timelock:
  `0x6F72de4F529a03Bfa883825152656a8c62CBB626`.
- During the Wednesday-to-Monday review period, keep both the vault and queue
  unpaused so users can update or cancel requests.
- Stop mirror `transferInRewards` calls. At scheduling and execution, the vault
  must be unpaused, the mirror fully vested (`getUnvestedAmount() == 0`), and
  the recognized STRCon module balance zero.
- Migration pulls STRCon from the execution vehicle into the vault, retires
  the STRC mirror, and recognizes the STRCon position. The absolute whole-vault
  NAV change must be within 200 bps (2%).

### Execution steps

1. Move STRC from Clear Street to Alpaca. Planning estimate: T+1 day.

2. Mint STRCon through ITN to the Saturn Fund Ltd. Tres-Ondo Account:
   `0xeAB18842D6ba63BCCd556e27f55ee7790907002B`.
   Timing is unconfirmed; current estimate: T+1 day.

3. Redeem from the fund in STRCon and send the tokens to the Saturn Global
   Capital Investments Ltd. Fireblocks Processor wallet:
   `0x09D6E34cE24D54890fF0BC6a090b5f880F8C729f`.
   Estimated timing: a few hours.

4. Transfer STRCon to the execution vehicle in Saturn Vault Corporation:
   `0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468`.

5. Date the deed of gift legal contract.

6. Verify the STRCon delivery and valuation. Use human-readable amounts,
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

7. Approve the vault to pull the STRCon amount from the execution vehicle.
   From `0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468`, approve the vault proxy
   (`0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7`) for `EXPECTED_STRCON`.

8. Schedule migration through Fireblocks:

   ```bash
   make migrate-schedule
   ```

9. Execute the scheduled migration after the two-day delay:

   ```bash
   make migrate-execute
   ```

   Both phases recheck live readiness. Keep the configuration unchanged after
   scheduling and execute before the original deadline.
   Confirm the mirror is retired at zero and the vault's STRCon custody and
   recognized balance reflect the delivery.

## **Step 4 — Cleanup**

### 1. Onchain

After the upgrade has been validated, revoke these obsolete roles on the proxies:

| Proxy | Role to revoke | Current holder |
|---|---|---|
| Vault and queue | `PROCESSOR_ROLE` | `0x09D6E34cE24D54890fF0BC6a090b5f880F8C729f` |
| Vault and queue | `COMPLIANCE_ROLE` | `0x10D59F776db12b4B271b2609CB8b7Ddd0A82703B` |
| Queue | `STAKED_USDAT_ROLE` | `0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7` |

1. Schedule and execute `revokeRole(roleId, holder)` through the role administrator
   for every obsolete grant. These calls are separate from the upgrade batch.
2. Verify the old grants are removed and approved v2 roles remain.
   Preserve the approved `DEFAULT_ADMIN_ROLE` timelock on both proxies;
   any extra active admins or v2 holders need separate review.

Do not remove legacy oracle administration while the mirror still needs it.
After retirement, check for other consumers before decommissioning it.

### 2. Webapp

1. Update the frontend to calculate and send `minSharePrice` instead of
   `minUsdatReceived` for withdrawal requests.
2. Add a countdown showing when an order is expected to be executed.
3. Update the analytics page's data pulls and replace STRC holdings with STRCon
   holdings.
4. Add a Cancel Request button for withdrawal requests.

### 3. Admin Portal

1. Display the withdrawal queue as a table.
2. Update vesting on the sUSDat page to use the new v2 variables.
3. Replace Unvested STRC with Unvested USDat and remove Vested STRC.
4. Replace Total STRC with Total STRCon and track the STRCon balance.

## **Communication Plan (To Do)**

### Wednesday announcement

#### What is happening?

- Saturn is upgrading sUSDat to v2.
- The vault's STRC backing is being migrated to STRCon, which will be held and
  tracked on-chain.
- Users do not need to migrate or exchange their tokens. Existing sUSDat stays
  in their wallets.
- Redemption processing will temporarily slow and then pause during the
  transition. The timeline below explains when processing stops and resumes.
- Yield distributions will pause and resume after the upgrade, including yield
  earned during the pause. Users who stay through the transition will receive
  that deferred yield rather than miss out on it.

#### What is the timeline?

Planned schedule:

- Friday — Upgrade proposal: Submit the upgrade proposal to begin the
  five-day timelock. Redemption processing slows.
- Monday — STRC transfer: Begin moving STRC for conversion to STRCon.
  Redemption processing pauses.
- Wednesday — Upgrade and schedule migration: Execute the sUSDat v2 upgrade
  and submit the migration proposal to the two-day timelock. Redemption
  processing remains paused.
- Friday — Migration: Execute the STRCon migration. Redemption processing
  remains paused while final checks are completed.
- Following Monday — Return to normal: Normal redemption processing is
  expected to resume once checks and the request-owner grace period are complete.

#### What changes for users?

1. Per-share redemption limits: `minUsdatReceived` changes to `minSharePrice`.
   Users set a minimum net USDat payout per sUSDat, after fees, instead of a
   minimum total payout. Existing limits are not automatically converted and
   need to be reviewed before processing resumes.
2. Base and Elevated fees: Deposit/mint and redemption fees depend on the
   vault's mode. The initial fees are:

   - Base (Regular): 0% deposit/mint fee and 0.10% (10 bps) redemption fee.
   - Elevated: 0.25% (25 bps) deposit/mint fee and 0.50% (50 bps) redemption fee.

   The vault starts in Elevated mode after the upgrade. The redemption fee is
   determined when a request is processed, not when submitted.
3. Cancel requests: Users can cancel an open redemption request and recover
   their escrowed sUSDat before it is processed.
4. Temporary redemption delays: Redemption processing will be slower than
   normal and then paused during the upgrade and migration. Normal processing
   will resume once the transition and final checks are complete.
5. Request review period: From Wednesday after the upgrade until Monday before
   processing resumes, users can cancel pending withdrawal requests or update
   their `minSharePrice`. Existing limits are not automatically converted from
   total-payout amounts to per-share prices, so users should review and adjust
   them during this window.

### Follow-up announcements

- Friday — Upgrade proposal: Announce that the upgrade is scheduled and share
  the upgrade scheduling transaction. Etherscan link: TBD.
- Wednesday — Upgrade and schedule migration: Announce that the upgrade has
  executed and migration is scheduled. Share both transactions:

  - Executed upgrade transaction — Etherscan link: TBD.
  - Scheduled migration transaction — Etherscan link: TBD.

- Friday — Migration: Announce that migration has executed and share the
  migration execution transaction. Etherscan link: TBD. Confirm that redemption
  processing remains paused while final checks are completed.
- Following Monday — Return to normal: Announce when normal redemption
  processing resumes.

## **Schedule**

Proposed timeline: Friday migration and Monday reopening, with processing
stopped when the STRC transfer begins.

### Wednesday — Announce the update

- Publish the proposed timeline, including the processing hold from Monday
  until the following Monday.
- Explain that new reward distributions will temporarily stop; existing
  rewards continue vesting.
- Notify legacy request owners about the limit changes and their opportunity
  to update or cancel requests before processing resumes.
- Confirm DTC, ITN, and fund-redemption timing. Arrange any funding buffer in
  advance.
- Set the final reward-distribution cutoff so vesting finishes before migration
  scheduling.

### Friday — Schedule the upgrade

1. Set `UPGRADE_CONFIGURATION_APPROVED = true`.
2. Run `make upgrade-schedule`.
3. Publish the proposal and its earliest Wednesday execution time.
4. Complete remaining v1 settlements before Monday's transfer.

### Monday — Stop processing and transfer STRC

1. Stop withdrawal processing and STRC balance-changing operations.
2. Reconcile the vault's recorded STRC against the shares being transferred.
3. Submit the full-position DTC transfer from Clear Street to Alpaca.
4. Announce that the processing hold has started.

### Tuesday — Mint and deliver STRCon

1. Once the shares arrive, execute the ITN mint into the Saturn Fund Ltd.
   Tres-Ondo Account.
2. Check the conversion:

   ```text
   STRCon conversion target = vault STRC shares / sValue applied at minting
   ```

3. In-kind redeem STRCon from the fund to the Saturn Global Capital Investments
   Ltd. Fireblocks Processor wallet.
4. Transfer the intended delivery to the Saturn Vault Corporation execution
   vehicle.
5. Date the deed-of-gift legal contract.
6. Confirm the exact available delivery. Keep any excess inventory separate
   from the migration amount.

Tuesday is a target; transfers and minting may carry into Wednesday.

### Wednesday — Execute the upgrade and schedule migration

Proceed once the delivery is ready and legacy vesting is complete.

1. After the five-day delay, run `make upgrade-execute`.
2. Reset any remaining legacy `InProgress` requests so owners can update or
   cancel them.
3. Check the proposed delivery:

   ```text
   abs(delivery × STRCon oracle price − STRC mirror value)
       ≤ 0.02 × total vault NAV
   ```

4. Set `EXPECTED_STRCON`, a migration deadline allowing the two-day wait plus
   execution buffer, and `MIGRATION_CONFIGURATION_APPROVED = true`.
5. Approve the vault to pull `EXPECTED_STRCON` from the execution vehicle.
6. Run `make migrate-schedule`.
7. Announce the upgrade and earliest migration execution time.

### Friday — Execute migration

1. After the full two-day delay, run `make migrate-execute`. It rechecks
   funding, allowance, vesting, and valuation.
2. Confirm the STRCon delivery and permanent retirement of the STRC mirror.
3. Announce successful migration and that reopening checks are underway.

### Friday through Monday — Verify and reopen

1. Verify accounting, custody, and v2 operations.
2. On Monday, schedule obsolete-role revocations through the five-day admin
   timelock.
3. Confirm the request-owner grace period has ended.
4. Authorize Regular mode during market hours and resume normal processing.
5. Announce reopening.

Execute the role revocations after their five-day delay.

If the off-chain delivery slips, move the Wednesday upgrade and subsequent
dates rather than compressing the checks.
