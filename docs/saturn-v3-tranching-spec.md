# sUSDat V3 eligible-income accounting and perpetual tranching — Technical Specification

**Status:** Audit-target specification; deployment and activation are not authorized
**Date:** 2026-09-01
**Scope:** One V3 release comprising the V2-to-V3 sUSDat accounting upgrade and an
opt-in, non-upgradeable Senior/Junior tranche layer backed by canonical sUSDat.

This document is normative for the checked-in V3 candidate. Section 1 summarizes
changes; Sections 2–4 define behavior and the deployment sequence; Sections 5–6 define
validation and unresolved launch inputs. Appendices preserve rationale, formulas,
compatibility, health behavior, evidence, and the source-to-spec completeness matrix.

---

## 1. What changes

### 1.1 V2 to steady-state V3 core vault

V3 preserves the existing sUSDat proxy, V2 linear storage, ERC-4626/queue behavior,
fixed STRC-mirror and STRCon modules, execution policy, restrictions, and roles. It adds:

- `StakedUSDatEligibleIncomeModule`, a vault-bound external ledger;
- `STRConEligibleIncomeAdapter`, an immutable reader of the approved STRCon cumulative
  shares multiplier;
- one ERC-7201-style namespaced pointer in `StakedUSDat` for the module;
- `initializeV3(module, config)`, reinitializer version 3;
- settlement hooks before supply/exposure changes and after STRCon sales; and
- funded-USDat recognition as existing surplus vests.

The V3 implementation is a steady-state implementation. Legacy `initialize`,
`initializeV2`, `migrate`, and `setMigrationTolerance` selectors revert. V2 parameter
authority is mediated through the installed module after activation: the module is the
only account recognized for `PARAMETER_MANAGER_ROLE`, while its `configManager` controls
the module's allowlisted configuration surface.

### 1.2 V3 opt-in tranche layer

The tranche layer does not modify sUSDat storage or impose tranche accounting on
non-participants. One
non-upgradeable `TrancheAccountant` escrows canonical sUSDat and owns two independently
supplied ERC-20 share classes:

- `Saturn Senior sUSDat` (`sr-sUSDat`); and
- `Saturn Junior sUSDat` (`jr-sUSDat`).

The accountant binds immutable vault, accumulator, Senior participation `alpha`, preferred
coverage, backing-value cap, pauser, and unpauser. It deploys both class tokens itself and
is their only minter/burner. Ordinary users may enter and exit either class independently
when health and coverage permit. A proportional full-stack exit burns both classes and
returns the corresponding fraction of sUSDat without requiring tranche-NAV reads.

### 1.3 Unsupported behavior

The candidate provides no maturity, fixed-dollar guarantee, fixed APR, insurance,
automatic recapitalization, Junior epoch reset, arbitrary asset registry, tranche fees,
governance voting, direct USDat redemption, or production activation. Tranche shares are
claims on an sUSDat-backed wrapper, not direct USDat redemption instruments.

---

## 2. Normative V3 accounting specification

### 2.1 Storage and ABI compatibility

`StakedUSDat` retains V2's inheritance order and linear state declarations. The new
module pointer uses the fixed namespaced slot
`0xe255d11e9749eae2f9a8185bfd8ffc93098a4f3a2febdab8f1259038042d2500`; it does not append
or reinterpret a linear V2 slot. Existing V2 selectors remain unchanged except for the
explicitly disabled migration/initializer functions above. The only required V2 interface
edit exposes the synthetic-shares oracle's actual return tuple used by V3.

The final compatibility snapshot contains 24 compiler-reported storage entries in both V2
and V3, 108 V2 selectors and 110 V3 selectors, and the same 27 event and 55 error
signatures in both versions. V3 adds only `eligibleIncomeModule()` and
`initializeV3(address,(address,address,uint16))` to the vault selector set. An earlier
candidate accidentally omitted the inherited `MAX_MIGRATION_TOLERANCE_BPS()` getter; the
review candidate restores it while leaving migration execution permanently disabled.

The final `StakedUSDat` runtime is 21,619 bytes, 2,957 bytes below EIP-170 and 1,381 bytes
below the 23,000-byte review ceiling. The linked logic library and external module remain
separately deployed code rather than delegatecall facets.

The upgrade rehearsal must prove unchanged proxy slots, balances, total assets, total
supply, queue state, EIP-712 domain separator, pause state, module exposure, and custody.

### 2.2 Activation and initial checkpoint

The timelock batch must execute in this order:

1. grant `PARAMETER_MANAGER_ROLE` on the sUSDat proxy to the predeployed V3 module; and
2. call `upgradeToAndCall(V3 implementation, initializeV3(...))`.

The reinitializer verifies the module's immutable vault binding, sweeps already vested V2
surplus as historical NAV, stores the module pointer, initializes the ledger at the current
raw multiplier, and registers only still-unvested surplus as prospective eligible income.
Initialization creates no retroactive eligible income.

### 2.3 Eligible-income sources

The frozen V3 source set contains two patterns:

1. **STRCon multiplier income.** The adapter reads `(sValue, paused)` for the fixed STRCon
   asset. Zero, paused, decreasing, structurally unresolved, or over-growth observations
   fail closed. The ledger normalizes approved neutral structural changes and records
   cumulative eligible units per sUSDat share.
2. **Funded USDat surplus.** A unit is eligible only after USDat has actually entered the
   vault through the existing surplus inlet and the corresponding amount vests into
   `usdatBalance`. Unvested amounts are pending. Each funded unit is recognized at most
   once.

Other NAV changes—including price appreciation, cash drag, fees, execution effects, and
unapproved asset return—are non-eligible and remain in the V3 Junior residual.

### 2.4 Old-state settlement and hooks

The invariant is: no path may change sUSDat supply, designated STRCon exposure, or source
semantics without first settling or freezing the eligible-income ledger under the old
state.

V3 settles before deposits/mints, queued burns, STRCon buys/sells, relevant oracle or
execution-policy changes, and other mediated dependency changes. A successful STRCon sale
then crystallizes the delivered fraction once at exact received USDat value. A reverted
trade reverts the pre-trade settlement atomically. A complete STRCon exit requires review;
it is not treated as an ordinary partial crystallization.

Ordinary sUSDat or tranche-token transfers and withdrawal requests do not change supply or
designated exposure and are intentionally unhooked. A queued redemption settles once before
the batch fixes its old-supply basis. Funded USDat becomes eligible income only when its
vesting is recognized; later deployment, purchase, withdrawal funding, or conversion cannot
recognize the same value again.

An approved income source must enter custody, NAV, exposure mutation, and eligible-income
accounting as one fixed integration. An adapter or income record alone cannot make an asset
eligible, and callers cannot select a runtime asset identity. This prevents unapproved income
side doors and preserves one-time recognition under the storage boundary in Section 2.1.

Pending income applies only to the income-bearing backing cohort present at the previous
checkpoint. Settlement writes that checkpoint before adopting newly observed custody, so an
unsolicited transfer cannot receive earlier income. Proportional exit scales actual custody
and the tracked income-bearing cohort independently.

### 2.5 Affine cohort accounting

The accumulator exposes cumulative affine lifecycle state:

```text
live units        = a*x + b
crystallized value = c*x + d
```

A consumer checkpoints `(a,b,c,d,nonce)` and applies only the relative transform to its
current backing cohort. This prevents later entrants from claiming historical income or
recovery while preserving proportional partial-sale crystallization for existing holders.
For checkpoint `(a_0,b_0,c_0,d_0)` and current transform `(a,b,c,d)`, the exact
cohort-relative increments are:

```text
relative live units per share = b - a*b_0/a_0
relative crystallized value per share = d - d_0 - (c-c_0)*b_0/a_0
existing Senior live units' = existing Senior live units*a/a_0
new crystallized Senior value = existing Senior live units*(c-c_0)/a_0
```

Each division rounds down. Materialization and affine transforms round down;
`lastRoundingRemainder` records only the most recent materialization remainder and never
carries it across a supply change. Repeated settlement at the same raw index adds no new
income, so callers cannot split one fixed observation into multiple increments.

### 2.6 Review, mediation, and liveness

The module starts Active. The config manager may enter Review, record evidence, resolve a
bounded neutral structural factor, resume after coherent source/custody checks, transfer
its own authority, adjust the approved growth bound, and execute only explicitly
allowlisted configuration calls. Evidence hashes are audit references, not proofs.

When accounting is unavailable, sUSDat issuance, processed redemption, and exposure
rotation fail closed. Ordinary sUSDat transfers and withdrawal requests remain governed by
the unchanged V2 rules. Default-admin upgrade power remains outside the ledger safety
boundary.

---

## 3. Normative V3 tranche-layer specification

### 3.1 Balance sheet and claims

All values use 6-decimal USDat units unless marked WAD. Let:

```text
B = escrowed sUSDat shares
A = marked USDat value of B
Q = contractual Senior claim value
J = max(A - Q, 0)
C = A / Q when Q > 0
```

Senior and Junior are separate capital accounts against one backing pool; they are not two
literal vaults. Eligible income `I` updates:

```text
A' = A + I
Q' = Q + alpha * I
J' = A' - Q'
```

Senior receives only immutable `alpha` participation in approved eligible income through
capitalized NAV. Junior receives residual eligible income, all non-eligible return, and the
first loss. `alpha` is not an APR and does not promise a yield.

### 3.2 Opening and zero-supply behavior

The first capitalization is performed through ordinary Junior then Senior entry and must
produce exact 2:1 Senior:Junior value, with conservative rounding leaving coverage at or
above 150%. New Senior cannot enter without existing Junior coverage. If Senior supply is
zero, new Senior establishes claim at current contributed backing value. If Junior supply
is zero while Senior supply remains nonzero, Junior entry is closed. If both class supplies
are zero, new Junior establishes a fresh position at current contributed backing value.

If Junior NAV reaches zero, the existing Junior token is not reused for recapitalization.
Junior deposits and impaired Senior redemptions close. Organic recovery may restore a
positive residual to the existing Junior class.

### 3.3 One-sided actions

Every one-sided action synchronizes income, requires a fresh coherent vault mark, applies
conservative rounding, enforces caller slippage/deadline bounds, checks account
restrictions, and enforces the immutable backing cap and post-operation coverage.

- Senior deposit/mint increases `A` and `Q` by contributed value and is bounded by excess
  Junior coverage.
- Healthy Senior redemption/withdrawal reduces `A` and `Q` proportionally and improves
  coverage. It is closed when impaired.
- Junior deposit/mint increases `A` and `J`; it is closed when Junior is wiped.
- Junior redemption/withdrawal may remove only value above preferred coverage.

For preferred coverage `C_p > 1`:

```text
Junior redemption capacity = max(0, A - C_p*Q)
Senior deposit capacity     = max(0, (A - C_p*Q)/(C_p - 1))
```

At exactly `A = C_p*Q`, both capacities are zero. The immutable backing-value cap applies
to new inflows using the same fresh NAV. Organic gains or unsolicited sUSDat transfers may
move custody above the cap but mint no claims and do not reopen inflow capacity.

### 3.4 Full-stack exit

`exitFullStack(fractionWad, receiver, owner, maxSeniorShares, maxJuniorShares, minAssets,
deadline)` burns the same global fraction of both class supplies from the owner's balances
and transfers the same fraction of current escrowed sUSDat. For fraction `p` in WAD units:

```text
Senior shares burned = ceil(S_total*p/WAD)
Junior shares burned = ceil(J_total*p/WAD)
backing shares returned = floor(B*p/WAD)
```

The maximum-share and minimum-backing arguments protect the caller from rounding and state
movement. The path does not read tranche NAV or require a healthy income source. It is
available in healthy, below-preferred, impaired, and source-review states whenever sUSDat
can transfer safely and the wrapper is not hard-paused. Dust remains with the surviving
stack, and the exit can never return more than the requested custody fraction.

### 3.5 Operating states

| State | Senior in | Senior out | Junior in | Junior out | transfers | full-stack exit |
|---|---:|---:|---:|---:|---:|---:|
| healthy, coverage `>= C_p` | capacity-gated | open | open | excess-only | open | open |
| healthy, coverage `< C_p` | closed | open | open | closed | open | open |
| impaired (`A < Q`) | closed | closed | closed | closed | open | open |
| source unhealthy/review | closed | closed | closed | closed | open | open |
| hard pause / unsafe transfer | closed | closed | closed | closed | closed | closed |

`hardPaused` is an operational/compliance containment control, not an economic coverage
ratio. Only immutable `PAUSER` may pause and only immutable `UNPAUSER` may unpause. Both
class tokens inherit canonical sUSDat restrictions for caller/from/to and reject all
movement while hard-paused. The v0 class tokens have no independent seizure function;
whether one is legally required remains an open gate.

### 3.6 Rounding and caller protection

Asset-to-value conversions use the current sUSDat mark. Deposits and redemptions round so
the wrapper never gives away more value than the caller contributes or burns. Exact-share
mint paths enforce the cap against the actual rounded-up backing value, not an unrounded
preimage. Every state-changing user action includes a deadline and minimum-output or
maximum-input bound. Reentrancy guards cover all backing-moving paths.

---

## 4. Upgrade and deployment runbook

No step below authorizes signing, broadcast, proxy change, issuance, or activation.

### 4.1 Deploy V3 dependencies

`script/v3/DeployV3Dependencies.s.sol` deploys the immutable adapter, vault-bound module,
and steady-state V3 implementation. Its production path requires an explicit config
manager and expected runtime code hashes. It validates live bindings and leaves the module
inactive. Record deployed addresses, constructor inputs, compiler settings, and runtime
hashes in a reviewed manifest.

### 4.2 Build the V3 timelock batch

`script/v3/BuildV3UpgradeBatch.s.sol` contains deliberately unset production fields and
`CONFIGURATION_APPROVED = false`. After governance inputs and dependency addresses are
frozen, reviewers must fill the manifest, confirm the unique salt and timelock window,
build calldata, independently decode it, and verify live timelock/admin/module/adapter/
implementation bindings. The batch performs only the module role grant and V3 upgrade plus
reinitializer. It does not deploy or activate the tranche layer.

### 4.3 Deploy the V3 tranche layer

`script/v3/DeployTranche.s.sol` requires an explicit approved manifest containing the
activated V3 vault/accumulator, immutable `alpha`, preferred coverage, backing cap, pauser,
unpauser, and expected accountant/token runtime hashes. Missing, zero, mismatched, or
unapproved inputs revert. Deployment creates the accountant and both share classes with
zero backing and zero supply. It performs no issuance or production configuration change.

### 4.4 Required post-step checks

After each separately authorized future transaction, confirm chain ID, transaction input,
runtime hashes, immutable bindings, proxy implementation slot, role ownership, module
state, storage invariants, zero unexpected allowances/supply, and emitted events. Any
mismatch stops the sequence. Activation and first capitalization require separate explicit
approval after audit, legal/accounting, operational, and shadow-reconciliation gates.

---

## 5. Validation gates

The audit target requires:

1. `forge fmt --check`, `forge build --sizes`, and the full non-fork Foundry suite;
2. directed V3 unit, differential, fuzz, invariant, and script-calldata tests;
3. bounded JavaScript calibration and shadow-reconciler tests;
4. V2/V3 storage-layout and ABI comparison;
5. current runtime bytecode size and EIP-170 headroom;
6. static analysis with findings manually mapped to reachable behavior;
7. all three pinned archive-fork rehearsals at mainnet block `25,627,322`;
8. source-to-spec and cross-document stale-claim review; and
9. independent review/audit plus post-V2 live shadow reconciliation before any deployment.

Passing local tests proves only the checked-in code under those fixtures. It is not audit,
production-state, execution, legal, accounting, deployment, or activation approval.

---

## 6. Open launch inputs

Exactly four launch inputs remain intentionally unset:

1. immutable launch `alpha`, after post-V2 shadow reconciliation;
2. exact role addresses and Safe/timelock thresholds;
3. whether class-token seizure/recovery is required; and
4. legal/accounting characterization and approval, including disclosure and final naming.

The `50%` alpha used in tests, models, and archive-fork rehearsals is a calibration fixture,
not a production default or recommendation. Scripts must fail closed until the four inputs
that affect their manifests are explicitly approved. The frozen review parameters that are
not open are 150% preferred coverage, exact 2:1 opening Senior:Junior value, zero protocol
fees, and an initial $500,000-equivalent immutable backing cap.

---

## Appendix A — Rationale and rejected alternatives

The wrapper is opt-in because it isolates tranche economics from legacy sUSDat holders
while preserving canonical sUSDat as backing. Independent capital accounts were selected
over paired-only issuance because they permit healthy one-sided entry and exit; the cost is
a larger state machine and shared-capacity ordering. Fixed-term maturity, claimable-income
rewards, direct STRCon tranching, arbitrary assets, automatic Junior epochs, and runtime
parameter mutation are deferred. The proportional full-stack path is the oracle-independent
escape hatch and does not override unsafe transfer or hard-pause conditions.

Security invariants that apply across these mechanics are:

- one escrowed sUSDat share cannot back more than one accountant position;
- marked Senior value plus Junior residual always equals marked backing value;
- fair same-class entry and exit preserve per-share class NAV within conservative rounding;
- unsupported income cannot enter the Senior allocation, and eligible income cannot be
  allocated or crystallized twice; and
- tranche tokens, LP positions, and other derivative claims cannot be recursively counted
  as new sUSDat backing.

## Appendix B — Permission and health matrix

| Capability | Authority | Fail-closed condition |
|---|---|---|
| V3 proxy upgrade | V2 `DEFAULT_ADMIN_ROLE` / timelock | live binding or manifest mismatch |
| V3 source review/resolution | module `configManager` | custody/source/structural uncertainty |
| V3 mediated parameter call | module allowlist + config manager | unapproved target/selector/data |
| V3 pause | immutable pauser | caller mismatch |
| V3 unpause | immutable unpauser | caller mismatch |
| class mint/burn | accountant only | caller mismatch or action health gate |
| class transfer | holder/operator | restriction or hard pause |
| full-stack exit | class owner/operator | restriction, hard pause, unsafe sUSDat transfer |

## Appendix C — Source-to-spec completeness matrix

| Normative concern | Interfaces/source | Scripts/tests/evidence |
|---|---|---|
| V2 storage/ABI preservation and V3 pointer | `StakedUSDat`, `IStakedUSDat`, eligible-income storage library | directed and fuzzed V2/V3 differential tests covering issuance, transfers, allowances, queued redemption, trading, and core views; V2/V3 fork slot snapshot; storage/ABI inspection |
| STRCon multiplier binding | `ISyntheticSharesOracle`, `IEligibleIncomeAdapter`, `STRConEligibleIncomeAdapter` | adapter unit test and pinned binding fork |
| funded surplus, old-state hooks, review, affine lifecycle | accounting interfaces, module, logic library, V3 vault hooks | eligible-income directed/fuzz tests; six independent stateful properties covering custody, ghost-ledger funding conservation, index acceptance, affine bounds, active-state safety, and independently recomputed unmaterialized previews |
| mediated configuration | module and V3 `hasRole` override | direct success and exact-revert tests for review/resume, structural resolution, growth bounds, config-manager transfer, short calldata, wrong targets, unapproved selectors, and legacy-manager rejection |
| V3 dependency deployment | adapter/module/V3 constructors | `DeployV3Dependencies` plus field-specific fail-closed tests and code-hash checks; the composite V3 fork uses the same deployment entrypoint |
| atomic role grant and reinitializer | V3 initializer and access-control surface | `BuildV3UpgradeBatch` plus calldata/order/fail-closed tests and a local schedule/delay/execute/replay lifecycle |
| immutable V3 bindings and share identity | accountant/share constructors | `DeployTranche` plus binding/hash/zero-supply tests; the composite V3 fork uses a complete approved test manifest and verifies deployed hashes |
| Senior eligible-income claim and Junior residual/first loss | accountant checkpoints and value views | production-accountant directed, fuzz, integration, and invariant tests |
| independent entry/redemption and cap | accountant action/preview/max surfaces | independently recomputed arithmetic for all eight entry/exit actions and zero-supply rounding, per-action deadline/zero/slippage rollback tests, and one-unit-below/at/above checks for all four capacity-constrained directions |
| caller, receiver, owner, operator, and allowances | accountant participant checks and class-token allowance path | complete zero-address matrix, exact restriction errors, exact delegated allowance errors, and successful delegated Senior/Junior redeem, withdraw, and full-stack exit paths |
| impairment, zero supply, donations, recovery | accountant operating state and transition guards | directed tests; six independent stateful properties, including ghost-ledger supply reconciliation, continuous Senior/Junior zero-state relations, and exact independent full-stack preview arithmetic; 13-action handler telemetry; deterministic handler smoke; 256-run, 128,000-call fail-on-revert campaign |
| restrictions and hard pause | accountant policy and both share tokens | exact transfer/restriction/pause tests plus direct accountant-only mint/burn rejection for both classes |
| proportional full-stack exit | accountant preview/exit functions | healthy, impaired, source-review, donation, rounding, invariant tests |
| calibration and shadow reconciliation | accumulator/accountant public state | checked-in JS replay/reconciler tests and synthetic fixture |
| archive production-state compatibility | V2 harness, V3 contracts | three pinned block `25,627,322` fork rehearsals; V3 batch rejects early execution and replay without changing implementation or role state |
| security review | complete V3 source | directed, differential, invariant, script, and fork evidence covers the identified V3 trust and accounting boundaries; independent review and audit remain required |
| unresolved launch inputs | fail-closed script manifests and immutable constructor inputs | Section 6; no production default embedded |

### Callable-surface disposition

The compiler-reported V3 callable surface is dispositioned as follows. Inherited V2 vault
selectors remain covered by the complete V2 suite and the V2/V3 differential suite; the
table below covers the new V3 module and tranche contracts without treating generated
immutable getters or inherited OpenZeppelin code as new custom behavior.

| Surface | Selectors | Direct evidence or justified inheritance |
|---|---|---|
| accountant identity and immutable bindings | uppercase and lowercase vault, accumulator, token, alpha, coverage, cap, pauser, and unpauser getters; `asset` | constructor/deployment binding, runtime-hash, zero-address, value-range, and composite-fork assertions |
| accountant state and checkpoints | `backingAssets`, `backingValue`, `incomeBearingBackingAssets`, `baseSeniorClaimValue`, `markedSeniorValue`, `crystallizedSeniorValue`, `seniorClaimValue`, `juniorResidualValue`, `seniorLiveUnitsWad`, `coverageWad`, `currentValues`, `operatingState`, and five checkpoint getters | direct lifecycle, impairment, source-review, donation, crystallization, zero-supply, fuzz, and independently recomputed invariant assertions |
| accountant actions | `depositSenior`, `mintSenior`, `redeemSenior`, `withdrawSenior`, Junior equivalents, `exitFullStack`, and `syncIncome` | exact success deltas, independent arithmetic, authorization, deadline, slippage/rollback, restriction, health, cap, allowance, and full-stack integration tests |
| accountant previews and limits | eight class previews; eight class max functions; `previewFullStackExit`; Senior-deposit and Junior-redemption capacity views | independent formulas for every class action and zero-supply rounding; below/at/above capacity tests; zero/restricted/unhealthy views; three-fraction stateful recomputation |
| accountant policy | `pause`, `unpause`, `hardPaused`, and `isRestricted` | exact-authority and rollback tests plus both-class transfer/transferFrom and hard-pause behavior |
| eligible-income lifecycle and views | initializer; before/after exposure hooks; funded-surplus register/recognize; materialize; review/resolve/resume; health and state/preview views | initialization, lifecycle, surplus, policy, differential, affine, direct-revert, and six-property ghost-ledger invariant campaign; vault-only hook callers are asserted through the bound vault paths |
| eligible-income governance | `setSTRConMaxUnreviewedGrowthBps`, `setConfigManager`, and `configureEligibleIncomeDependency` | old-bound materialization, invalid-bound rollback, manager transfer, unauthorized caller, short-data, wrong-target, unapproved-selector, allowlisted-target, and legacy-role rejection tests |
| class-token custom behavior | `mint`, `burn`, `transfer`, and `transferFrom`; immutable accountant/policy getters | direct accountant-only mint/burn rejection; exact restriction, operator, allowance, and hard-pause tests for both classes |
| class-token inherited behavior | ERC-20 metadata, balances, supply, approvals/allowances; ERC-2612 permit, nonces, domain separator, and EIP-712 domain | unmodified OpenZeppelin implementations; constructor/deployment identity tests and action/transfer suites exercise balances, supply, approvals, and allowances. No V3 override changes permit/domain semantics. |

## Appendix D — Durable evidence and reproducible commands

The product specification provides the audience-specific explanation, the eligible-income
calibration results preserve the bounded economic rationale, and `test/model/README.md`
documents the checked-in JavaScript tools. This document remains the sole normative
documentation authority, and executable source, scripts, and tests remain authoritative
over every documentation claim.

```sh
forge fmt --check
forge build --sizes
forge test -vvv
forge coverage --report summary --match-path 'test/v3/tranche/*.t.sol' --no-match-test 'invariant_*'
forge coverage --report summary --match-path 'test/v3/eligible-income/*.t.sol' --no-match-test 'invariant_*|test_steadyStateRuntimeHasReviewGradeHeadroom'
node --test test/model/tranche-calibration-replay.test.mjs test/model/tranche-shadow-reconciler.test.mjs
forge inspect src/v2/StakedUSDat.sol:StakedUSDat storageLayout --json
forge inspect src/v3/StakedUSDat.sol:StakedUSDat storageLayout --json
forge inspect src/v2/StakedUSDat.sol:StakedUSDat methodIdentifiers --json
forge inspect src/v3/StakedUSDat.sol:StakedUSDat methodIdentifiers --json
RUN_V2_MOCK_FORK=true RPC_URL="$SATURN_MAINNET_RPC_URL" forge test --match-path test/v2/fork/V2MainnetFork.t.sol --disable-block-gas-limit -vvv
RUN_V3_STRCON_FORK=true RPC_URL="$SATURN_MAINNET_RPC_URL" forge test --match-path test/v3/fork/STRConEligibleIncomeAdapterMainnetFork.t.sol -vvv
RUN_V3_TRANCHE_MOCK_FORK=true RPC_URL="$SATURN_MAINNET_RPC_URL" forge test --match-path test/v3/fork/V3TranchingMainnetFork.t.sol --disable-block-gas-limit -vvv
```

The block-gas-limit override applies only to the two composite test harnesses, each of which
rehearses multiple separately scheduled governance transactions inside one Foundry call. It
does not represent a production transaction. Supply the authorized RPC only through the
process environment; never print or persist its value.
