# V2 Deployment Runbook

Execution checklist and evidence record for the v1 → v2 upgrade and subsequent
STRC → STRCon migration. Operational decisions, observations, and evidence remain
`TBD`. Contract addresses, role holders, constructor/initializer inputs, expected
code hashes, and builder configuration are organized by script in
[deployment configurations](./v2-deployment-configurations.md).

Sources: [technical specification §3](./saturn-v2-spec.md#3-migration),
[dependency deployment](../script/v2/DeployV2Dependencies.s.sol),
[upgrade builder](../script/v2/BuildV2UpgradeBatch.s.sol), and
[migration builder](../script/v2/BuildV2Migration.s.sol).

## 1. Reviewed build and current-state baseline

Build using the reviewed inputs in the configuration document and verify the live
proxy/dependency bindings against it. Verify every role holder and control model,
including inherited admins and the legacy oracle's own role registry. Enforce
the separation and timelock requirements in specification §2.8; nonzero-address
checks in the builders do not establish that those requirements are satisfied.

Use `foundry.toml`, `remappings.txt`, and the pinned dependency revisions at the
reviewed commit. Capture the actual Solidity and Foundry versions, resolved build
profile and EVM target, optimizer settings, and any overrides in the build record.
These values are collected from the build rather than entered as launch parameters.

| Record | Value / evidence | Check |
|---|---|---|
| Build artifacts / command / configuration reference | TBD | Reproduce from the configured commit, dependencies, toolchain, and build settings. |
| Build / test / storage-layout evidence | TBD | Include runtime and initcode size checks for all new artifacts. |
| Configuration reviewer / review reference | TBD | Addresses, immutable bindings, roles, signers, quorums, and timelock controls. |
| Baseline block number / hash / network verification | TBD | Same chain as all three scripts. |
| Current vault implementation / runtime code hash | TBD | Read the existing proxy implementation. |
| Current queue implementation / runtime code hash | TBD | Read the existing proxy implementation. |
| Vault accounting / hard-pause snapshot | TBD | `totalAssets`, `totalSupply`, share conversions, tracked USDat, custody, unvested rewards, and pause state. |
| Legacy mirror-seed compatibility | TBD | Vesting period within 1–90 days, rewards cap within 1–500 bps, and computed unvested STRC no greater than balance. |
| Legacy oracle state / validation evidence | TBD | Address/hash, underlying feed, role holders, `maxPriceStaleness`, bounds, decimals, price, and round. |
| USDat / sUSDat / STRCon unit verification | TBD | 6 / 18 / 18 decimals; execution capacity uses 6-decimal USDat units. |
| Transition USDat buffer target / funding evidence | TBD | Mirrored STRC cannot be sold after Step 1; insufficient buffer delays queue processing. |

### Queue inherited state and transition

These are snapshots and coordination records. The queue reinitializer does not
take them as arguments or rewrite existing requests.

| Record | Value / evidence | Check |
|---|---|---|
| Queue-local pause state at upgrade | TBD | Preserved independently of vault pause. |
| Complete legacy-request inventory / snapshot block | TBD | IDs, statuses, request fields, NFT ownership/approvals, and enumeration. |
| Escrowed shares / funded USDat liabilities / custody | TBD | Reconcile before and after the upgrade. |
| Legacy `InProgress` IDs / unlock or reset transactions | TBD | Unlock in v1 or reset in v2; record the complete rescan before processing resumes. |
| Legacy-limit notice / owner grace-period end | TBD | Existing limit slots become net per-share limits without conversion. |
| Processing-resumption time / responsible operator | TBD | After the grace period and legacy-request recovery. |

## 2. Deploy and verify dependencies

Completed: the user confirms deployment and Etherscan verification of all seven
dependencies. The supplied addresses and hashes match the
[dependency manifest](./v2-deployment/DeployV2Dependencies.md).
The preparation instructions below remain as the deployment procedure reference.

Use the reviewed [DeployV2Dependencies inputs](./v2-deployment/DeployV2Dependencies.md)
and record the actual deployment signer and nonce sequence. The deployment plan
included Forge's prepended deterministic linked-library deployment,
followed by the wrapper, mirror, STRCon module, policy, queue implementation,
and vault implementation. The populated predictions use nonce `64` for the library
factory transaction and `65`–`70` for the six `CREATE` transactions; see the
[dependency deployment table](./v2-deployment/DeployV2Dependencies.md).

Before simulation, confirm all seven `EXPECTED_*` addresses in
`DependenciesConfig.sol`, the configured `PRIMARY_FEED`, and all seven expected
runtime code hashes.

Read the deployer's next transaction nonce, accounting for pending transactions,
during the final deployment simulation. Record the nonce assigned to each
transaction, including the preceding library-deployment transaction, and recheck
before broadcasting. If the nonce has changed, regenerate the predicted addresses
and address-dependent expected hashes before proceeding, and update the reviewed
`EXPECTED_*` address constants in `DependenciesConfig.sol`.
Regenerate affected hashes if the build or bindings change.

The six ordinary `CREATE` addresses depend on the deployer address and each
transaction's nonce. Their order is wrapper, mirror, STRCon module, policy, queue
implementation, then vault implementation. Confirm the new planned sequence
with a simulation using the configured deployer and compare its addresses with the
predictions and matching runtime hashes in the dependency deployment document.
`run()` rejects any address mismatch during local execution before broadcast;
this check does not reserve addresses or roll back transactions already submitted.
Reconcile those predictions with the deployment receipts before using the
addresses in the upgrade batch. The script
passes newly created dependency addresses into later constructors automatically.

The current CREATE predictions were checked with `cast compute-address` and the
CREATE address formula. This example predicts the STRCon module at nonce `67`:

```sh
cast compute-address 0x59Ebb7143dDDd7b045dE7B0bd0F99446143F1624 --nonce 67
```

Reproduce the library prediction using the script's CREATE2 factory
`0x4e59b44847b379578588920cA78FbF26c0B4956C`, zero `TRADE_LOGIC_SALT`, and the
creation-code hash recorded below. Recalculate if the library bytecode changes;
the deployer wallet nonce does not determine this library address. Check its
address-dependent runtime and all vault link references.

Expected runtime hashes are reviewed inputs in
the configuration document; observed hashes below are on-chain measurements
and must match those inputs, including constructor immutables and library links.

Six expected hashes were calculated for the previous `62`–`68` nonce plan on 2026-09-08 using Solidity
`0.8.36`, optimizer `150` runs, EVM `osaka`, and IPFS metadata. All artifact metadata
source hashes matched the local files. Local constructor execution with the exact
configured immutables, planned sender/nonces, and library links, including the
CREATE2 library deployment, reproduced all six hashes. These are expected values,
not mainnet observations.

The oracle hash was calculated and locally verified on 2026-09-11 with the confirmed
primary-feed address and mocked 8-decimal feed responses. Live feed checks remain required.

The policy and both implementation hashes were recalculated for the `64`–`70` plan
from current artifacts with the correct embedded addresses and library links.
Artifact source hashes matched local files; the other four expected hashes are
unchanged. The user subsequently confirmed the dry run and deployment succeeded.

Hashes below are from the user-supplied deployment output; Etherscan verification
is user-confirmed. Independent post-deployment reads remain part of reconciliation.

| Artifact | Transaction / block or existing-code evidence | Reported runtime hash | Source / ABI verification |
|---|---|---|---|
| `STRConTradeExecutionLogic` | TBD | `0x3fd06ec46b4894fee8cf52acd25ac1b4671db5e32644cab70d7201c9b50830e3` | Etherscan-verified (user-confirmed) |
| `STRConPriceOracle` | TBD | `0x0e4a38c2cf995d18597294cf3d16a26222538828eacc24a711fd882b2188954f` | Etherscan-verified (user-confirmed) |
| `STRCMirrorModule` | TBD | `0x9d36b5975c2637fc6e51e682333971f643e79d910e83f18460691077d3c573a0` | Etherscan-verified (user-confirmed) |
| `STRConModule` | TBD | `0xa7e50e2c3b872a8e522c5b22ff5316d53f9ae2495867846b5d0fc07a343e94bb` | Etherscan-verified (user-confirmed) |
| `STRConExecutionPolicy` | TBD | `0xe92e2d05245a5048f7c39cb31049be1fe9f70b7e1bcf1febc77cf4dbd5d50f89` | Etherscan-verified (user-confirmed) |
| `WithdrawalQueueERC721` implementation | TBD | `0x0cee4341cb8c1bf5acc02a27454ad5dc15b3bd13a6f64d9fb03d1708ce34172e` | Etherscan-verified (user-confirmed) |
| `StakedUSDat` implementation | TBD | `0xcc057ad6ff68536048ac4c350ce3019047b01117fe4be61401cc4c0bafecc456` | Etherscan-verified (user-confirmed) |

| Verification record | Value / evidence | Check |
|---|---|---|
| Deployment signer / CREATE nonce sequence | Planned: configured signer, library factory transaction `64`, CREATE transactions `65`–`70`; actual deployment evidence: TBD | Map every deployment to the resulting configured address in the [dependency deployment table](./v2-deployment/DeployV2Dependencies.md). |
| Nonce lookup time / block / RPC / latest and pending values | Pending: `64`; time/block/RPC/latest: TBD | User-supplied pending nonce for the configured deployer. Recheck before final simulation and broadcast. |
| Library deployment status / live verification | Deployed and Etherscan-verified (user-confirmed); independent live evidence: TBD | Match the configured library address and hash. |
| Library creation-code hash / predicted address / linkage | Unchanged creation-code hash: `0x0debc3575364496e82fe59e27650d769acf0516b0e60aca5348f651b2cddb483`; predicted address: `0xDF89cCf4Ead4Ea2398400DF3E44BAA595695b0b6`; deployed linkage: TBD | Reconfirm the final build, CREATE2 prediction, and deployed linkage. |
| Complete binding reconciliation | TBD | Proxy/asset/queue, mirror/legacy oracle, wrapper/token/feeds, module/wrapper, policy/module, and implementation/library. |
| Fresh module / policy state | TBD | Mirror unseeded, not retired, balance zero; STRCon balance zero; policy vehicle, tolerance, and all capacity fields zero. |
| Wrapper and feed units / initial configuration | TBD | Wrapper and both feeds: 8 decimals. Initial deviation: `100` bps (`1%`), supplied by the deployment script constant; validate against the replacement primary feed per the [recommendation](./drafts/strcon-feed-deviation-findings.md#recommendation). Initial staleness: 26 hours; bounds: `20e8`–`150e8`; caps: 1,000 bps and 36 hours. |
| Live oracle read / validation block | TBD | Both rounds, reference freshness, deviation, `sValue`, asset pause flag, bounds, and returned price. |
| STRConModule constructor smoke test | TBD | Oracle has required decimals and returns a callable, nonzero price. |
| Vault STRCon custody before migration | TBD | Distinguish token custody from the module's recognized balance. |
| Governance contract/control verification | TBD | Runtime hashes, deployment/source evidence, delays, role grants, proposers, executors, cancellers, signers, and quorums for each configured timelock. |

The deployment script supplies the initial deviation constant to the wrapper's
constructor. The listed staleness, bounds, and caps are code-defined defaults and
checks, not additional constructor inputs. The deployment script does not provision governance timelocks;
record verification evidence for every configured existing or newly provisioned instance.

## 3. Rehearse the exact batch and prepare queue owners

Complete the [BuildV2UpgradeBatch inputs](./v2-deployment/BuildV2UpgradeBatch.md),
run the production upgrade builder's `run()` preflights, and rehearse its exact
generated batch against current mainnet state using the reviewed artifacts,
deployed addresses, and production roles. Preserve pre/post storage and accounting
comparisons. A storage-layout error or accounting mismatch blocks scheduling.

The existing [mock fork test](../test/v2/fork/V2MainnetFork.t.sol) exercises pinned
v1 state with fork-created deployments, placeholder roles, injected inventory, and
refreshed oracle timestamps. Its helpers bypass the builders' production
preflights; passing it does not complete the exact production rehearsal.

Announce that each legacy `minUsdatReceived` slot becomes a 6-decimal minimum net
`minSharePrice` per `1e18` shares after the active redemption fee. Preserve request
values and communicate sufficient time after the upgrade for owners to update or
cancel before processing resumes. Inventory every `InProgress` request and prepare
its v1 unlock or v2 reset using the queue table above.

| Record | Value / evidence |
|---|---|
| Current-state rehearsal block number / hash | TBD |
| Exact artifacts / configuration / generated transactions | TBD |
| Production preflights / rehearsal storage and accounting results | TBD |
| Upgrade notice / timing / responsible owner | TBD |
| Critical frontend / bot / indexer / partner readiness before Step 1 | TBD |

## 4. Schedule and execute the atomic upgrade

After configuration review and successful rehearsal, schedule the two
`upgradeToAndCall` payloads as one batch through the configured five-day admin
timelock. The builder places the vault upgrade first and queue upgrade second.
After the delay, revalidate readiness and execute the exact scheduled batch;
failure of either reinitializer reverts both upgrades.

### Timelock operation evidence

Keep the two operations separate. Step 2 is scheduled only after the validation
gate below. Chosen timelock addresses, proposer, delay, salts, predecessor,
Step 1 planned timestamps, and migration arguments are in deployment configurations.

| Record | Step 1: atomic upgrades | Step 2: migration |
|---|---|---|
| Builder approval flag / review evidence | TBD | TBD |
| Timelock / proposer / executor authority verification | TBD | TBD |
| Execution submitter | TBD | TBD |
| Generated targets / ETH values / inner payloads | TBD | TBD |
| Schedule calldata | TBD | TBD |
| Execute calldata | TBD | TBD |
| Operation ID / on-chain hash comparison | TBD | TBD |
| Scheduling transaction / block / timestamp | TBD | TBD |
| Ready-at timestamp / planned execution time confirmation | TBD | TBD |
| Pre-execution readiness / simulation evidence | TBD | TBD |
| Execution transaction / block / timestamp | TBD | TBD |
| Post-execution accounting / roles / bindings evidence | TBD | TBD |

## 5. Validate Step 1 and recover legacy requests

`StakedUSDat.initializeV2` automatically reads `strcBalance`, `vestingAmount`,
`lastDistributionTimestamp`, `vestingPeriod`, and `maxRewardsBps` from preserved
v1 proxy storage and passes them to `STRCMirrorModule.seed(...)`. The deployer
does not supply seed arguments. Compare all five values and unvested rewards
at the upgrade, alongside NAV, supply, share conversions, and custody.

Verify configured roles and bindings, including derived authorization on the
mirror, wrapper, module, and policy; these contracts have no local role registry.
Confirm both proxies preserve their individual pause states and existing queue
requests. Any mismatch blocks the validation gate and Step 2.

| Record | Value / evidence | Check |
|---|---|---|
| Pre/post-upgrade state reconciliation | TBD | Vault accounting, five copied seed fields, rewards, queue requests/NFTs, liabilities, custody, and pauses. |
| Configuration / role / dependency reconciliation | TBD | All configured holders, fees, tolerances, recovery/surplus addresses, module/policy bindings, and wrapper parameters. |
| Code-defined initialization results | TBD | Surplus vesting: 3 days; effective mode: Elevated; `regularModeValidUntil == 0`. |
| Derived policy capacity state | TBD | Available capacity starts at configured maximum; `lastUpdated` equals initialization timestamp. |
| Empty STRCon accounting position | TBD | `STRConModule.balance() == 0` after Step 1 and again after the round trip. |
| Surplus-source funding / vault allowance | TBD | Amount and approval evidence. |
| Vault and execution-vehicle eligibility | TBD | Exact settlement addresses and vehicle control/signers/quorum evidence. |
| Vehicle funding source / inventory target | TBD | Covers both sides of the small validation round trip. |
| Vehicle USDat / STRCon allowances to vault | TBD | Amounts and approval references. |
| Small buy/sell round-trip terms / transactions | TBD | Amounts, vehicle, deadlines, custody changes, and returned empty recognized position. |
| Oracle basis / migration-tolerance review | TBD | Approved tolerance remains conservative and sufficient; any adjustment is active before Step 2 scheduling. |
| USDon residual handling / inventory reconciliation owner | TBD | Vehicle operations outside vault accounting. |

Reset each remaining inherited `InProgress` ID with
`resetLegacyInProgressRequest`, then rescan the complete inventory. This preserves
the queue's current pause state. Record the results in the queue table; resume
processing only after no `InProgress` entries remain and the communicated grace
period has ended. An unpaused vault has Elevated-mode permissions immediately
after initialization, so withholding queue processing requires operator coordination.

## 6. Prepare, schedule, and execute migration

Stop `transferInRewards` and wait for `STRCMirrorModule.getUnvestedAmount() == 0`;
the active tranche and live vesting period determine the wait. Reconcile the final
mirrored position and off-chain STRC disposition. The execution vehicle must obtain
and approve the full corresponding STRCon delivery before scheduling Step 2.

Fill and review the [BuildV2Migration inputs](./v2-deployment/BuildV2Migration.md)
after the round trip, then run the
production migration builder's `run()` preflights and record its operation above.
Confirm the approved migration tolerance is active and the deadline accommodates
the five-day delay. Schedule `migrate(expectedStrcon, deadline)` through the admin
timelock only after the validation gate is complete.

| Record | Value / evidence | Check |
|---|---|---|
| Reward cutoff / vesting-completion time | TBD | Derived from the active tranche; later rewards block migration. |
| Final mirrored position / off-chain STRC disposition | TBD | Evidence for the timelocked attestation; off-chain disposition cannot be verified on chain. |
| Final vehicle delivery / allowance readiness | TBD | Exact configured amount, vehicle eligibility, funding, and vault approval. |
| Migration readiness / revalidation block | TBD | Vault unpaused, deadline valid, mirror seeded/not retired/unvested zero, recognized STRCon balance zero, and current vehicle/tolerance match. |
| Current prices / projected whole-vault NAV | TBD | Both positions price successfully and projected NAV satisfies the builder's tolerance check. |
| Pre/post-migration accounting and custody | TBD | Exact STRCon delivery, recognized balance, whole-vault NAV tolerance, USDat, supply, and queue liabilities. |
| Final retirement evidence | TBD | Mirror permanently retired at zero; STRCon recognized balance equals delivery and custody covers it. |

Revalidate live readiness after the delay before executing the scheduled operation.
The migration atomically pulls the exact STRCon amount, retires the mirror,
recognizes STRCon, and verifies custody and NAV. A revert rolls back the transfer
and both module positions. After success, the retired mirror returns zero without
an oracle read and rejects reward/parameter mutations.

## 7. Integration and operational handoff

| Record | Value / evidence | Check |
|---|---|---|
| Final ABI / contract-address publication | TBD | Vault, queue, modules, wrapper, policy, and linked-library events emitted by the vault. |
| Frontend / bot / indexer readiness | TBD | Changed selectors, net per-share queue limits, fees, and fail-closed oracle handling. |
| Market-mode monitoring owner / fallback keeper / risk approver | TBD | Mode expiry and operational ownership per specification. |
| Launch monitoring / incident-response reference | TBD | Oracle health, custody, roles, pause/unpause ownership, and specification Appendix G. |
