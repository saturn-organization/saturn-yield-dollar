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

Dry-run first by omitting `--broadcast` and `--verify`.
Copy the output addresses into [UpgradeConfig.sol](../script/v2/configs/UpgradeConfig.sol).

## Step 2 — Schedule and execute the upgrade

- [ ] Completed

### Before scheduling

- Complete and approve the remaining [upgrade inputs](./v2-deployment/BuildV2UpgradeBatch.md).
  Review changes since the auditor-reviewed commit.
- Check current role holders and timelock controls against the configuration.
  Resolve the spec conflict for shared parameter-manager/enforcer/unpauser and
  blacklister/pauser holders before approval.
- Snapshot NAV, supply, custody, unvested rewards, both pause states, and queue
  requests/NFT ownership/approvals/liabilities. Rehearse the exact upgrade batch
  against current mainnet state and check storage/accounting.
- Confirm dependency bindings and live oracle prices. Check the transition USDat
  buffer: mirrored STRC cannot be sold after the upgrade. Buffer target: TBD.
- Notify legacy request owners and set the post-upgrade grace-period end: TBD.
  Confirm owners will have a working way to update or cancel requests.

### Schedule and execute

The targets run `source syncprod`: set `RPC_URL`, `ADMIN` to the Fireblocks proposer address,
and `PRIVATE_KEY` for execution, alongside the existing Fireblocks client settings.
Scheduling verifies that `ADMIN` holds `PROPOSER_ROLE` on the five-day timelock.

1. Set `UPGRADE_CONFIGURATION_APPROVED = true` after review and simulate scheduling:

   ```bash
   make upgrade-schedule-dry-run
   ```

   This uses the regular RPC and makes no Fireblocks signing request.
2. Review the generated batch and operation ID. The batch upgrades the vault first
   and queue second atomically. Schedule it through Fireblocks:

   ```bash
   make upgrade-schedule
   ```

   Record the transaction hash and on-chain ready-at time.
3. After the five-day delay, recheck readiness and simulate execution:

   ```bash
   make upgrade-execute-dry-run
   ```

4. After a successful simulation, execute and save the transaction hash:

   ```bash
   make upgrade-execute
   ```

Each command regenerates the batch from the current configuration; the timelock
must recognize that exact operation as ready to execute. Keep the configuration
unchanged after scheduling; changing the batch requires a new proposal and delay.
Unscheduled, waiting, or completed operations are refused.
After broadcasting, the targets independently confirm the on-chain result;
scheduling logs the actual ready-at time.

Use the five-day admin timelock in [SharedConfig](../script/v2/configs/SharedConfig.sol),
not the two-day operational-role timelock. `BuildV2UpgradeBatch` remains read-only;
the schedule and execute targets submit transactions.

### Before migration or queue processing resumes

- Compare accounting, custody, requests, and pause states to the snapshot.
  Check the mirror seed against legacy `strcBalance`, `vestingAmount`,
  `lastDistributionTimestamp`, `vestingPeriod`, and `maxRewardsBps`.
  The initializer copies these automatically from vault storage.
- Check installed implementations, modules, roles, fees, tolerances, and policy
  settings against the configuration. The vault starts in Elevated mode.
- Have the vault operator run a small STRCon buy/sell round trip using the funded,
  approved execution vehicle. Return `STRConModule.balance()` to zero.
  Confirm the live migration tolerance is suitable for the observed price difference.
- Have the queue operator call `resetLegacyInProgressRequest` for every remaining
  `InProgress` request, then rescan all requests.
- Resume queue processing only after the rescan is clear and owners have had the
  full grace period. Queue pause blocks updates and cancellation; vault pause
  also blocks cancellation. Extend the grace period if those actions were unavailable.

Legacy limits are **not converted**: the old absolute `minUsdatReceived` value
becomes `minSharePrice`, a minimum net USDat price per `1e18` shares in 6-decimal
units, after fees. Owners need to review their limits before processing resumes.

## Step 3 — Schedule and execute migration

- [ ] Completed

1. Stop mirror `transferInRewards` calls. Wait for
   `STRCMirrorModule.getUnvestedAmount() == 0`; do not restart rewards.
2. Reconcile the final off-chain STRC disposition. Fund the execution vehicle
   with the full STRCon delivery and approve the vault to pull it.
3. Complete the [migration inputs](./v2-deployment/BuildV2Migration.md):
   amount, live vehicle/tolerance, deadline, and salt. Allow the five-day delay
   plus execution time before the deadline.
4. Confirm the vault is unpaused, the mirror is seeded and not retired,
   recognized STRCon balance is zero, and prices/projected NAV pass the checks.
   Approve the configuration and set `MIGRATION_CONFIGURATION_APPROVED = true`.
5. Generate the operation:

   ```bash
   forge script script/v2/migrate/BuildV2Migration.s.sol:BuildV2Migration --rpc-url "$RPC_URL"
   ```

6. Review and submit `scheduleCalldata` from `PROPOSER` to the five-day admin
   `TIMELOCK`, with zero ETH. Save the operation ID, calldata, transaction hash,
   and ready-at time.
7. After the delay, recheck prices/NAV, vehicle eligibility, funding, allowance,
   tolerance, pause state, zero unvested rewards, and zero recognized STRCon.
   Simulate the saved `executeCalldata`, then execute with zero ETH before the deadline.
   The builder's five-days-ahead deadline check is for scheduling, not this final simulation.
8. Save the execution transaction hash. Confirm the mirror is retired at zero,
   recognized STRCon equals the delivery, custody covers it, NAV change is within
   tolerance, and supply/queue liabilities are unchanged.

Keep recognized STRCon balance at zero between the validation round trip and migration.

## Step 4 — Cleanup

- [ ] Completed

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

## Communication Plan
