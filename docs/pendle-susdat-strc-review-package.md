# sUSDat / underlying STRC Pendle architecture review package

## Executive summary

This is an architecture-review candidate for a Pendle series created only after Saturn V2 and the STRC-to-STRCon migration are complete. Users deposit and redeem sUSDat, but Pendle measures principal in underlying offchain STRC. The intended YT return is sUSDat total return relative to underlying STRC, with Ondo STRCon `sValue` growth as the dominant intended dividend component.

The design uses Pendle's unchanged, pinned `PendleERC20WithOracleSY` and exactly two small custom view contracts:

1. `STRCReferenceMetadata`, a zero-supply, non-transferable descriptor that gives Pendle an onchain address and decimal convention for offchain STRC; and
2. `SUSDatSTRCExchangeRateOracle`, a stateless adapter that immutably identifies sUSDat, USDat, and STRCon and returns underlying STRC per sUSDat/SY from the structurally validated active post-V2 pricing path.

There is no custom SY, wrapper, swap, claim path, custom custody path, owner, mutable configuration, legacy oracle, migration detector, phase switch, or fallback. Stock SY alone custodies sUSDat. This package does not deploy or create a market.

## Product objective

Create a Pendle market where sUSDat yield is measured relative to underlying STRC rather than USDat. Users deposit and redeem sUSDat through the SY; PT represents STRC-denominated principal, while YT captures changes in sUSDat value relative to STRC.

The integration targets the post-V2 architecture, where STRCon and the canonical STRCon/USD oracle provide the pricing path while underlying STRC remains the economic numeraire. Launching only after the V2 and STRC-to-STRCon migration is complete avoids encoding migration-transition behavior into the market.

The three distinct roles are:

| Role | Asset |
| --- | --- |
| Deposit, redemption, and SY custody token | sUSDat |
| Pendle principal accounting asset / numeraire | underlying offchain STRC |
| Post-V2 vault asset and pricing inputs | STRCon, validated STRCon/USD, Ondo `sValue` |

STRCon is therefore a pricing source and vault asset, not the Pendle numeraire. Replacing STRC with STRCon in `assetInfo()` would benchmark away STRCon's embedded dividend accrual and produce the wrong product.

## Proposed architecture

```text
sUSDat.convertToAssets(1e18) ── A: 6-decimal USDat NAV ─────────┐
                                                                 │
active sUSDat STRCon module ─► active compatible price oracle ───┤
                                          │                      │
                                          ├─ P: STRCon/USD ──────┼─► floor(A × S × 100 / P)
                                          │                      │      18-decimal STRC/SY
                                          └─ declared S oracle ──┘
                                               S: STRC/STRCon

sUSDat ─► unchanged PendleERC20WithOracleSY ─► PT + YT
              │
              ├─ tokens in/out: sUSDat only
              ├─ custody: exactly 1 sUSDat per 1 SY
              ├─ assetInfo: TOKEN, STRCReferenceMetadata, 18 decimals
              └─ exchangeRate: SUSDatSTRCExchangeRateOracle
```

Proposed stock-SY configuration:

```text
yieldToken         = sUSDat
underlyingAsset    = STRCReferenceMetadata
exchangeRateOracle = SUSDatSTRCExchangeRateOracle
tokensIn           = sUSDat only
tokensOut          = sUSDat only
```

### Why both custom contracts are necessary for the selected stock-SY design

`STRCReferenceMetadata` solves identity, denomination, and metadata. Pinned `PendleERC20WithOracleSY.assetInfo()` always returns `AssetType.TOKEN`, its configured `underlyingAsset`, and `IERC20Metadata(underlyingAsset).decimals()`. The pinned yield factory copies those decimals into PT and YT. Offchain STRC has no ERC-20 address, so this package defines one STRC as `1e18` accounting base units, matching the adapter's rate output and PT/YT arithmetic. A price feed's 8-decimal precision does not define the accounting asset's decimals; Saturn V1's 6-decimal internal STRC counter likewise does not constrain this new offchain descriptor. The descriptor is not money: it has no supply, balances, allowances, transfer path, custody logic, recovery function, or administration. Its address can nevertheless receive unrelated ERC-20 transfers directly; mistakenly sent assets may be irrecoverable. Pendle must confirm in writing that a metadata-only 18-decimal descriptor is acceptable to its contracts, UI, and indexers and confirm the final name and symbol.

`SUSDatSTRCExchangeRateOracle` solves valuation. Neither sUSDat nor the canonical V2 STRCon oracle directly returns Pendle's required underlying-STRC-per-SY value. The adapter resolves the exact module used in active sUSDat NAV, then resolves that module's price oracle and the synthetic-shares oracle declared by that price oracle. It validates the complete graph before combining its inputs.

No wrapper is needed because the stock SY already holds and returns sUSDat 1:1. No custom SY is needed because the stock oracle SY already separates the deposited ERC-20 from the accounting asset and delegates its exchange rate to `IPExchangeRateOracle`.

## PT maturity and settlement

The statement “1 PT = 1 sUSDat at maturity” is incorrect. PT is denominated by Pendle's non-decreasing STRC-per-SY index. On expiry, PT redemption produces an index-governed quantity of SY; redeeming that SY returns the same quantity of sUSDat because stock SY custody is 1:1. The settlement token is sUSDat, while the principal accounting unit is underlying STRC.

## Exchange-rate derivation

Pendle does not require every exchange rate to use 18 accounting decimals. Its exact invariant is:

```text
assetBalance = floor(exchangeRate × syBalance / 1e18)
```

`assetBalance` is expressed in the base units declared by `assetInfo().assetDecimals`; the yield factory also assigns those decimals to PT and YT. This integration deliberately selects 18-decimal underlying-STRC accounting, so its exchange rate must return 18-decimal STRC base units per `1e18` SY. For example, `20e18` SY at a `0.1e18` rate mints `2e18` raw PT/YT, displayed as exactly `2` STRC-denominated PT/YT. Declaring 8 decimals while returning the same `2e18` raw balance would incorrectly display `20,000,000,000` units.

Define:

```text
A = sUSDat.convertToAssets(1e18)
    USDat base units represented by one sUSDat; 6 decimals

P = active compatible STRCon/USD price used by sUSDat's STRCon module
    USD per STRCon; 8 decimals

S = sValue for the exact STRCon token from the oracle declared by P
    underlying STRC shares represented by one STRCon; 18 decimals

R = Pendle exchange rate
    underlying STRC base units represented by one 1e18 SY balance; 18 decimals
```

Economically:

```text
STRCon/USD = STRC/USD × sValue
STRC/USD   = STRCon/USD × 1e18 / sValue
```

Treating USDat as the USD accounting unit:

```text
R = floor(A × S × 1e2 / P)
```

Scale proof:

```text
A: 6 decimals
S: 18 decimals
1e2: scale adjustment
P: 8 decimals

6 + 18 + 2 - 8 = 18 decimals
```

The implementation guards `A * 100`, then computes:

```solidity
Math.mulDiv(A * 100, S, P, Math.Rounding.Floor)
```

This is exactly `floor(A × S × 100 / P)`: multiplying `A` by 100 is exact, `mulDiv` uses a 512-bit intermediate, and there is only one division and one final floor. The adapter reverts if `A * 100` or the mathematically final result cannot fit in `uint256`, or if a positive input combination rounds to zero.

### Worked example

If one sUSDat converts to `10.250000` USDat, STRCon is `$102.50000000`, and `sValue = 1.025`, then implied underlying STRC is `$100`:

```text
R = floor(10,250,000 × 1.025e18 × 100 / 10,250,000,000)
  = 0.1025e18
```

One `1e18` SY balance therefore represents `0.1025` underlying STRC.

### Dividend / ex-dividend example

Suppose underlying STRC is $100 and `sValue = 1`, so one STRCon is $100. A $1 dividend makes STRC ex-dividend at $99 while reinvestment raises `sValue` to `100/99`. STRCon total-return value can remain approximately $100 and sUSDat NAV can remain approximately flat in USD, but each STRCon now represents more underlying STRC. Because `S` is in the numerator, `R` rises by approximately `100/99`; that increase is the intended YT yield.

This is why omitting `sValue`, or using STRCon itself as the accounting asset, is economically wrong for the stated objective.

## Economic behavior and residual basis

For the STRCon-backed part of the vault:

```text
sUSDat NAV ≈ STRCon units per share × STRCon/USD
STRCon/USD = STRC/USD × sValue

sUSDat NAV / STRC/USD ≈ STRCon units per share × sValue
```

Consequences:

- A pure underlying STRC spot move with constant `sValue` should cancel when the STRCon-backed NAV and denominator move proportionally.
- Increasing `sValue` increases the STRC-denominated rate and becomes YT yield.
- Additional STRCon units or other value per sUSDat can also increase the rate.
- USDat cash and other non-STRCon reserves prevent perfect cancellation and create basis.
- USDat is assumed to equal one USD; a USDat depeg is not corrected.
- Donations, fees, losses, and any behavior that changes `convertToAssets` flow directly into the rate.

The accurate product description is “sUSDat total return relative to underlying STRC,” not “perfect dividend-only isolation.”

## Active-path validation and failure behavior

The adapter immutably binds only the economic identities: sUSDat, its USDat asset, and STRCon. On construction and every rate read it resolves `sUSDat.strconModule()`, that module's current oracle, and the synthetic-shares oracle declared by that price oracle. It requires:

- the active module to have code, name sUSDat as `VAULT`, and return the immutable STRCon consistently from both `ASSET()` and inherited `asset()`;
- the active price oracle to have code, name sUSDat as `VAULT`, name the immutable STRCon as `STRCON`, and report 8 decimals; and
- the price oracle's declared synthetic-shares oracle to have code.

This is semantic pinning rather than dependency-address pinning. `A` comes from the active sUSDat accounting graph, while `P` and `S` come from that same graph. A structurally compatible module, price-oracle, or synthetic-oracle rotation remains live. A zero, codeless, malformed, wrong-vault, wrong-asset, or wrong-decimal path fails closed. The adapter cannot prove from interfaces alone that new bytecode implements the reviewed internal semantics, so source, implementation, code-hash, authority, and parameter review remain mandatory before every production transition.

Construction validates structure but deliberately does not read current price or `sValue`; temporary upstream unavailability must not make a correctly configured immutable adapter undeployable. Runtime rejects zero NAV, price, or `sValue`, synthetic pause, invalid active graphs, zero rounded output, and overflow. Upstream and canonical-oracle reverts propagate. There is no cached or fallback rate.

The active-path checks and formula are view-only but not free. Each read resolves the module/oracle graph, `convertToAssets()` may itself value the STRCon module through the active price oracle, the adapter calls that price oracle explicitly, and then reads the same declared `sValue` needed to convert P into underlying STRC. This can repeat price/feed and `sValue` reads. Existing interfaces do not expose A, P, and S as one coherent bundled quote; removing those reads locally would require trusting stale/cached data or changing Saturn interfaces. Production gas must be measured through Pendle's actual router and market paths.

### Alternatives considered

| Design | Decision | Reason |
| --- | --- | --- |
| Pin exact module, price-oracle, and synthetic-oracle addresses | Rejected | Detects every address rotation but turns a supported Saturn oracle replacement into an indefinite denial of rate-dependent operations and PT redemption. Restoring a compromised, retired, stale, or unavailable oracle is not a sufficient recovery plan. |
| Pin module but follow its current oracle | Rejected | Handles routine oracle replacement but still strands PT after a future compatible module replacement, while same-address sUSDat upgrades already remain outside address-only protection. |
| Follow the complete active path with structural checks | Selected | Keeps A, P, and S coherent with current sUSDat accounting and preserves redemption through compatible rotations without adding adapter governance or state. |
| Stateful allowlist, cached rate, fallback, smoothing, or rate-of-change limiter | Rejected | Adds administration and new manipulation, staleness, transition, and liveness failure modes; can also distort genuine dividend/ex-dividend changes and diverge from canonical Saturn policy. |

Dynamic resolution does not make transitions economically harmless. A compatible but erroneous upward rate can still be stored permanently by Pendle's PY high-water mark. The adapter intentionally separates compatibility from transition authorization: it enforces the former onchain, while governance process, independent simulation, and human approval must enforce the latter.

The canonical V2 oracle remains responsible for validating both feed rounds, rejecting future timestamps, enforcing freshness specifically for the reference feed, bounding deviation of the primary value-securing feed from that fresh reference, enforcing underlying-price bounds, and validating synthetic pause and `sValue`. Primary-feed age is not independently bounded; an old but otherwise valid primary round is accepted when the reference is fresh and the two values remain within the configured deviation. Duplicating or strengthening those rules only in this adapter would create inconsistent Saturn valuation policy. Final deployed code, addresses, proxy implementations, and parameters must nevertheless be reverified before launch and after any upgrade.

## Pendle PY/YT semantics

Pinned Pendle V6 computes a non-decreasing high-water mark:

```text
pyIndexCurrent = max(SY.exchangeRate(), pyIndexStored)
```

A raw rate decrease cannot reduce principal already recorded. Recovery below the prior high creates no new YT interest; only a new high does. Conversely, a temporary upward NAV, price, or `sValue` error can be crystallized permanently as YT interest. This asymmetry makes all upstream values and same-block sequencing value-critical.

On Ethereum the pinned Pendle deployment helper selects same-block caching. When enabled, only the first index update in a block observes a new rate; later calls in that block reuse the stored index. The pinned-fork test proves this behavior. Pendle must confirm the production cache setting and any router/market ordering requirements.

## Threat model

| Risk | Classification | Treatment |
| --- | --- | --- |
| Wrong rate direction | Prevented | Pendle unit equation, dimensional proof, worked example, and lifecycle tests establish STRC per SY. |
| Accounting-unit / decimal mismatch | Prevented | The 18-decimal descriptor, 18-decimal rate output, factory-created PT/YT decimals, raw balance equations, and human-readable quantities are tested together. Pendle UI/indexer approval remains required. |
| Intermediate overflow | Prevented/detected | Guarded `A * 100`, 512-bit `mulDiv`, explicit final-overflow tests. |
| Double or premature rounding | Prevented | One exact scaling multiplication and one final downward division. |
| Repeated rounding extraction | Tested | Repeated deposit/tokenize/recombine/redeem cycles cannot increase sUSDat. |
| Descriptor mistaken for transferable STRC | Prevented in contract | Zero supply/balances/allowances and explicit transfer/approval reverts; naming/NatSpec say reference only. |
| Pendle UI/indexer misrepresentation | Operational control | Written Pendle approval and UI/indexer review required before launch. |
| Invalid, negative, malformed, future, divergent, or reverting feed input; stale reference input | Detected by reverting | Canonical V2 oracle checks propagate; adapter rejects zero and never falls back. |
| Old primary round | Accepted canonical policy / constrained | Primary age is not independently bounded, but the reference must be fresh and the primary value must remain within configured deviation. |
| `sValue` pause or zero | Detected by reverting | Checked whenever the rate is read; it does not prevent adapter deployment. |
| `sValue` delay or discontinuity | Accepted upstream risk / operational control | Review provider behavior and monitor production; upward errors may crystallize. |
| sUSDat NAV decrease | Accepted Pendle behavior | Raw rate may fall; PY high-water mark does not. |
| PY high-water crystallization | Accepted protocol behavior | Explicitly tested and disclosed; upstream integrity is value-critical. |
| Temporary price/NAV error | Accepted upstream risk | Positive errors may permanently allocate interest; launch and monitoring controls required. |
| Donation / `convertToAssets` manipulation | Accepted upstream risk | Adapter faithfully reports canonical conversion; tested as rate-changing input. |
| USDat depeg | Accepted residual risk | No USDat/USD feed; one USDat is treated as one USD. |
| Non-STRCon reserves | Accepted residual risk | Their value does not cancel perfectly against the STRC denominator; modeled in tests. |
| STRCon/STRC ex-dividend timing | Accepted oracle timing risk | `P` and `S` must be coherent; discontinuities can affect YT allocation. |
| Proxy/governance/module/oracle/parameter upgrade | Operational control plus structural detection | Compatible active-path rotations remain live. Incompatible graphs revert, but structurally compatible malicious or incorrect bytecode cannot be excluded by interface checks; every change requires preflight and monitoring. |
| Compatible module, price-oracle, or synthetic-oracle rotation | Supported with operational control | Adapter follows the complete active graph so A, P, and S remain coherent and PT redemption remains available. Any upward transition error may crystallize permanently in PY. |
| Incompatible or malformed active dependency graph | Detected by reverting | Code, decimals, both module asset getters, vault, oracle, and declared synthetic-source relationships are checked before rate use. |
| Reentrancy / unexpected token behavior | Minimized by architecture | Adapter is view-only with no state/custody; stock SY owns token handling and must remain the reviewed implementation. |
| Maturity / PT settlement confusion | Tested and documented | PT redeems through index-governed SY; SY returns sUSDat 1:1. |
| Same-block index sequencing | Tested / operational control | Pinned V6 cache behavior is tested; production setting requires Pendle confirmation. |
| User ordering of deposit/tokenize/redeem/index update | Tested within modeled surface | Lifecycle and repeated-sequence tests show no unearned sUSDat extraction. |
| Final overflow or zero-rate rounding | Detected by reverting | No plausible rate is returned. |
| Fail-closed liveness loss | Residual upstream risk | Invalid active structure or unhealthy canonical inputs still halt rate-dependent paths, including post-expiry PT redemption. A compatible corrected active graph restores service without changing the immutable adapter; no fallback can bypass invalid canonical state. |

## Production transition runbook

Every module, price-oracle, synthetic-oracle, implementation, feed, or material parameter change during the full market and redemption lifetime must follow a written procedure:

1. Announce the exact proposed addresses, implementations, code hashes, parameters, authorities, and execution transaction through the applicable timelock before activation.
2. At a named recent production block, fork the complete sUSDat and Pendle state. Verify source and code hashes, the active graph, permissions, feed freshness/deviation/bounds, synthetic pause state, and nonzero rate.
3. Record old and proposed `A`, `P`, `S`, raw `R`, `pyIndexStored`, and the resulting basis-point change. Define the acceptable transition tolerance before observing the result; any exception requires explicit Saturn, Pendle, and security approval. A decrease does not undo a previously stored PY high, while an observed increase may allocate irreversible YT interest.
4. Exercise deposit, SY mint/redeem, PY mint/recombine, market operations, and PT redemption before and after expiry on the fork. Include same-block-cache ordering and outstanding dust PT.
5. Schedule activation away from the expiry boundary and other index-sensitive operations. Do not intentionally call `pyIndexCurrent()` against an unapproved transition quote.
6. After execution, independently verify the active graph, code hashes, A/P/S/R, feed state, and relevant Pendle read and redemption paths. Monitor the first blocks in which Pendle can store the new rate.
7. If validation fails, install a reviewed compatible correction. Do not restore an old dependency merely to unblock Pendle when the old dependency is unsafe. If Pendle already stored an erroneous upward rate, treat it as an economic incident: correcting the raw rate cannot lower the stored PY index.

The exact tolerance, timelock, approvers, monitoring owner, and incident authority remain launch-blocking inputs.

## Verification

Pinned sources:

| Component | Revision/address |
| --- | --- |
| Saturn base | `f9bb4f99d9e0e021ae53a4fda5d6da5079fe8b99` |
| Pendle core V2 | `pendle-finance/pendle-core-v2-public@0fcebf79fa7d9eced3137c8d09829e315ed50b3c` |
| Pendle-compatible OpenZeppelin | `OpenZeppelin/openzeppelin-contracts@fd81a96f01cc42ef1c9a5399364968d0e07e9e90` |
| Pendle SY | `pendle-finance/Pendle-SY-Public@73676d931102a369a978a713abfd0b48e3e34361` |
| Mainnet fork block | `25,892,118` |
| Pendle V6 yield factory in fork | `0x3E6EBa46AbC5ab18ED95F6667d8B2fd4020E4637` |
| Pendle V7 market factory in fork | `0x6d247b1c044fA1E22e6B04fA9F71Baf99EB29A9f` |

Focused coverage includes metadata semantics, 18-decimal asset/PT/YT agreement, raw and human-readable unit equations, immutable economic identities, constructor/runtime active-graph validation including both module asset getters, compatible module/oracle/synthetic rotations, malformed and cross-system replacements, zero/codeless dependencies, token/oracle decimals, coherent A/P/S sourcing, formula direction and scale, exact floor and overflow failures, full-domain arithmetic fuzzing, canonical failure propagation, explicit primary/reference freshness semantics, underlying-price bounds, spot cancellation, `sValue` and ex-dividend yield, reserve basis, donation/NAV risk, exact SY custody, exact PT/YT/SY/sUSDat balance equations, transition-error PY crystallization, repeated sequencing, same-block caching, maturity, atomic post-expiry failure and compatible recovery, and atomic failure on a subsequent mint against an initialized pinned Pendle market. A stateful invariant continuously compares the adapter to the documented formula and both module asset identities while fuzzing NAV, price, `sValue`, compatible oracle rotations, and compatible full-module rotations.

Commands:

```sh
forge fmt --check
forge build --sizes
forge lint src/pendle/STRCReferenceMetadata.sol src/pendle/SUSDatSTRCExchangeRateOracle.sol \
  test/pendle/SUSDatSTRCIntegration.t.sol --severity high
forge test --match-path test/pendle/SUSDatSTRCIntegration.t.sol -vv
RUN_PENDLE_FORK=true RPC_URL=<ARCHIVE_RPC_URL> forge test \
  --match-path test/pendle/SUSDatSTRCIntegration.t.sol --match-test 'test_pinnedFork' -vv
forge test --match-contract StakedUSDatQueuedRedemptionTest --summary
forge test --isolate --match-contract StakedUSDatQueuedRedemptionTest --summary
forge test --summary
git submodule status
git diff --check origin/main...HEAD
git diff --no-ext-diff --no-textconv origin/main...HEAD -- src/pendle test/pendle | rg -n -i \
  'AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|BEGIN .*PRIVATE KEY|api[_-]?key.*[:=]|private[_-]?key.*[:=]|client[_-]?secret.*[:=]'
```

The final scoped credential-scan command is expected to exit `1` with no output because ripgrep found no match. The public package was also manually checked to exclude private transcripts, private workspace links, and outbound-message drafts.

Verified candidate results:

- formatting and compilation pass; the build emits non-fatal Solar preprocessing warnings from the pinned Pendle import graph and compiler warnings in pinned `forge-std`;
- dependency lock entries match the exact Git submodule revisions, and a fresh build emits no dependency-lock warning;
- high-severity scoped lint reports no high-severity issue;
- custom runtime sizes: `STRCReferenceMetadata` 712 bytes; `SUSDatSTRCExchangeRateOracle` 2,916 bytes;
- focused non-fork suite: 20 passed, 0 failed, 6 intentionally skipped fork tests; arithmetic fuzzing ran 256 cases;
- stateful formula invariant: 256 runs, 128,000 calls, 0 reverts, including compatible oracle and module rotations;
- pinned Pendle lifecycle, exact maturity accounting, initialized-market atomic failure, compatible rotation before and after expiry-index finalization, transition-error PY crystallization, and same-block cache: 6 passed, 0 failed at block `25,892,118`;
- queued-redemption transient-storage lifecycle: 6 passed, 0 failed both with and without Forge transaction isolation;
- full non-fork repository suite: 422 passed, 0 failed, 7 intentionally skipped opt-in fork tests; and
- final formatting, diff, submodule/lock consistency, and scoped changed-file credential checks pass.

The fork uses the live pinned Pendle yield and market factories and their exact PT/YT/market implementations, but mocks post-V2 Saturn state that did not exist at that historical block. It proves interface, lifecycle, balance-equation, expiry-liveness, and initialized-market mint-failure compatibility—not correctness of the future production deployment, router/swap paths, or AMM parameterization. A new fork using final deployed V2 addresses and code is mandatory before launch.

## Proposed deployment inputs (not yet authorized)

```text
STRCReferenceMetadata()

SUSDatSTRCExchangeRateOracle(
  sUSDat,
  USDat,
  STRCon
)

PendleERC20WithOracleSY(
  sUSDat,
  deployedSTRCReferenceMetadata,
  deployedSUSDatSTRCExchangeRateOracle,
  PendleApprovedOffchainRewardManager
)
```

Still unset and non-deployable: final V2 active-graph addresses and code hashes, exact initial synthetic-oracle confirmation, transition controls, SY proxy/initializer/owner/reward manager, factory version, cache setting, expiry, market parameters, and liquidity plan.

A production deployment rehearsal must independently verify exact code hashes and bindings, then require a currently usable nonzero exchange rate before creating the SY or market. Those are launch-time preflight checks, not adapter-construction invariants.

## Non-goals

- No V1 or legacy STRC oracle support.
- No onchain migration detector, phase switch, dual-oracle transition, cached fallback, smoothing, or adapter-owned transition control.
- No custom SY, wrapper vault, swap, claim, reward collection, or discretionary custody.
- No USDat/USD depeg correction or elimination of non-STRCon reserve basis.
- No production deployment, market creation, liquidity, governance action, signing, broadcasting, or external communication.
- No claim that mocked post-V2 state proves final production safety.

## Questions requiring written disposition

Pendle:

1. Is a zero-supply, non-transferable metadata descriptor acceptable as stock SY's `underlyingAsset` with `AssetType.TOKEN`?
2. Confirm the proposed `STRC Accounting Reference`, `STRC`, 18-decimal convention. The 18-decimal choice matches the adapter output and PT/YT raw units; it is independent of the 8-decimal price feeds.
3. Will Pendle UI and indexers clearly distinguish this reference from transferable STRC?
4. Confirm the exact underlying-STRC-per-SY direction and downward rounding.
5. Confirm the stock `PendleERC20WithOracleSY`, factory, proxy, initializer, owner, offchain reward manager, same-block cache setting, expiry flow, and review workflow.
6. What additional router or swap-path integration tests are required beyond the included initialized-market subsequent-mint atomic-failure test?
7. Confirm that following a structurally compatible active sUSDat pricing path is acceptable for the full market and redemption lifetime, including post-expiry PT redemption and the production transition runbook.

WatchPug:

1. Confirm `floor(A × S × 100 / P)` and the guarded-scaling plus full-precision `mulDiv` implementation.
2. Confirm reliance on canonical V2 oracle validation without duplicating those policies in the adapter, including fresh-reference/deviation enforcement without an independent primary-age bound.
3. Review `sValue` and ex-dividend timing, PY high-water crystallization, reserve basis, donation/NAV behavior, USDat depeg, and upgrade risks.
4. Review the selected semantic-pinning design: compatible active-path rotations remain live, incompatible graphs fail closed, and structurally valid transitions remain subject to code review, simulation, monitoring, and irreversible PY-high-water risk.
5. Confirm the tested ranges and mocked post-V2 pinned lifecycle are sufficient for architecture approval pending a production-state fork.
