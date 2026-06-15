# sUSDat Multi-Asset Backing & STRCon Migration — Design Spec

**Status:** Draft for discussion
**Date:** 2026-06-11
**Scope:** Migrating sUSDat's STRC exposure from off-chain mirrored holdings to on-chain
tokenized STRC (Ondo's STRCon), and generalizing vault accounting to support multiple
backing assets ("multi-asset digital credit").

> Single document while in design phase. At implementation time, split by lifecycle:
> a durable **multi-asset vault architecture** spec (§3–7, §11: modules, yield
> recognition, oracle, liquidity/settlement/allocation, fees, integrations) and a
> time-bound **STRC→STRCon migration plan** (§1–2, 9: bridge module, attrition
> wind-down, measurements), archived when the migration completes.

---

## 1. Background

### 1.1 Current architecture

sUSDat is an ERC-4626 vault (UUPS proxy) over USDat. Backing is split across two
internally tracked balances:

- `usdatBalance` — idle USDat held by the vault.
- `strcBalance` — a **mirror** of Saturn's off-chain STRC brokerage holdings. The tokens
  are not on-chain; the balance is processor-attested bookkeeping.

`totalAssets() = usdatBalance + vested STRC value`, with STRC priced via `StrcPriceOracle`
(Chainlink wrapper with staleness + $20–$150 bounds checks).

Yield enters via `transferInRewards(strcAmount)` (PROCESSOR_ROLE): Saturn receives the
monthly STRC dividend off-chain and pushes it in as additional mirrored STRC, vesting
linearly over `vestingPeriod` (30 days) to prevent deposit-sniping around discrete reward
events. Conversions between the legs (`convertFromUsdat` / `convertFromStrc`) are
processor-attested and validated against the oracle within `toleranceBps` (currently 20%).

Redemptions are async via `WithdrawalQueueERC721`: shares escrowed, NFT minted, processor
sells STRC off-chain, settlement validated against oracle price and `previewRedeem`.

### 1.2 Why migrate

- **Trust reduction.** `strcBalance` as self-reported bookkeeping is the largest trust
  assumption in the system (processor constrained only by oracle ± 20%). Holding STRCon
  on-chain makes the position verifiable custody: `STRCon.balanceOf(vault)`.
- **Multi-asset direction.** sUSDat should become a token backed by multiple forms of
  digital credit. The single hard-coded `strcBalance` + single immutable oracle does not
  generalize.

### 1.3 What STRCon is

Ondo Global Markets' tokenized STRC (launched ~2026-05-04 on Ethereum, BNB, Solana).
Structured note issued by Ondo, backed 1:1 by STRC shares at regulated broker-dealers.
Offered to qualified non-US investors only (EEA/UK qualified investors, Swiss
professional clients) — **vault eligibility/allowlisting must be confirmed with Ondo**.

**Total-return, price-accumulating model (Ethereum):**

```
STRCon price = underlying STRC market price × sValue
```

`sValue` (shares multiplier) comes from Ondo's `SyntheticSharesOracle`. Dividends are
never paid out; they are reinvested (net of tax withholding) into more STRC and reflected
as an sValue increase. One token represents a growing number of STRC shares.

**Corporate-action / dividend mechanics:**

- sValue updates ≤1% per 24h: automated, no extended pause. STRC's monthly dividend at
  11.5%/yr ≈ 0.958%/month sits *just under* this threshold (if the rate exceeds ~12%/yr,
  dividends flip into the manual large-update path).
- sValue updates >1%: scheduled ≥24h ahead, price frozen, manual confirmation, ≥10 min
  pause.
- Routine dividend pause: trading halted ~7:50–8:10pm ET the evening before ex-date.
  **8pm ET is the start of the next trading day** (overnight session); a stock with a
  Monday ex-date goes ex at 8pm ET the prior Sunday. The sValue bump and the underlying's
  ex-dividend repricing are designed to be simultaneous at that boundary.
- **When `SyntheticSharesOracle.paused = true`, the Chainlink STRCon feeds freeze at the
  last known good price.** Note this applies to the >1% manual path; see §1.4 — routine
  dividend *trading* pauses do not necessarily pause the oracle.

### 1.4 Ondo-confirmed mechanics (direct correspondence, 2026-06-11)

From Kian and Matt Blumberg at Ondo:

- **Multiplier formula confirmed:** `tokenPrice = sharesMultiplier × stockPrice`. On the
  dividend event, the stock drops by the distribution amount and within a few minutes the
  system increases `sharesMultiplier` by `dividend / post-drop stock price` (e.g. +0.97%
  for a $0.96 distribution on a $99.04 post-drop price → token ≈ unchanged at ~$100).
  Kian's stated formula uses the **gross** dividend — no withholding haircut mentioned.
  This contradicts the public docs' "net of applicable tax withholdings"; confirm which
  applies to STRC (§8.2).
- **`sharesMultiplier` is still 1.0 as of 2026-06-11.** The June 15 ex-date will be the
  first adjustment ever for STRCon. Open question (§8.10): STRCon launched May 4 and the
  May 15 ex-date passed with no multiplier change — where did the May dividend go?
- **Dividend pause:** trading paused ~10 minutes before and after the distribution
  moment. Per Matt, the dividend snapshot is taken at **8pm ET on the ex-date**; the
  public corporate-actions doc says the pause is the evening *before* the ex-date (which
  is the same 8pm boundary described from the other side, since the trading day flips at
  8pm). Exact window for June 15 to be confirmed empirically — watch both the June 14
  8pm ET and June 15 8pm ET windows (§2.3).
- **STRC trades in all sessions**, including the 8pm–4am ET overnight session. The only
  scheduled unavailability is **weekends: Friday 8pm ET – Sunday 8pm ET**. This
  substantially mitigates the overnight-gap risk (§4.3) at the session level (print
  density still unverified).
- **Trading pauses ≠ oracle pauses.** Ondo also pauses trading for a few minutes around
  session transitions (e.g. 9:29–9:31am ET) for volatility; **the oracle continues
  updating during these windows**, with Chainlink applying a "session-aware smoothing"
  mechanism (see Chainlink tokenized-equity-feeds docs). Design consequence: the vault
  cannot equate "Ondo trading is paused" with "feed is frozen," and vice versa — the
  `isPaused()` policy must be defined against feed behavior, not venue behavior.
- `sharesMultiplier` is also available from Ondo's Get Market Data endpoint
  (`/v1/assets/{symbol}/market-data`), in addition to the history endpoint in §2.1.

---

## 2. Empirical findings (as of 2026-06-10)

### 2.1 Data sources

| What | Where |
|---|---|
| STRCon/USD (Ondo API) Chainlink feed | proxy `0x67d4Ae9f265270aE123c08D2657536771D19cD91`, 8 dec, 24h heartbeat, ~0.5% deviation |
| STRCon-USD (Calculated) Chainlink feed | proxy `0xC353ac4b425f818Ad87E228bf816E15c2173AC07`, 8 dec, 24h heartbeat |
| Ondo `SyntheticSharesOracle` (Ethereum) | `0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6` |
| Ondo `GMTokenManager` (mint/redeem) | `0x2c158BC456e027b2AfFCCadF1BDBD9f5fC4c5C8c` |
| sValue history API (needs `x-api-key`) | `GET https://api.gm.ondo.finance/v1/assets/STRCon/shares-multiplier?range=all` |
| STRC daily OHLC | stockanalysis.com raw prices (verified consistent with on-chain feeds) |

> Data-quality note: Yahoo Finance chart data for STRC returned **dividend-adjusted**
> prices, which mechanically erase ex-date drops and initially produced a false "STRC
> never drops on ex-date" conclusion. Raw prices from stockanalysis.com reconcile with
> the on-chain feeds at the ~1% level (e.g. Jun 5: Nasdaq close $93.40 vs feed $94.23
> shortly after close — sub-1% session-timing difference, vs Yahoo's adjusted $99.95).
> Use raw prices only.

### 2.2 Ex-date behavior of STRC (raw prices, dividend $0.958/mo at 11.5%)

| Ex-date | Close before | Ex-date close | Drop | Residual step |
|---|---|---|---|---|
| 2026-04-15 | 100.00 | 99.32 | −$0.68 | ~+28 bps |
| 2026-05-15 | 100.00 | 99.19 | −$0.81 | ~+15 bps |

STRC drops by ~70–85% of the dividend on ex-date — mostly normal preferred-stock
behavior, **not** pinned-at-par. Combined with an sValue bump per Kian's formula
(gross dividend / post-drop price ≈ +0.97%), the STRCon token price would be
*approximately* continuous through the dividend event, with a residual upward step of
roughly **10–30 bps** (order of the current 10 bps deposit fee; well inside daily noise).
Sample size: 2 ex-dates, equity side only — no STRCon dividend event has occurred yet.

> **Correction (2026-06-11):** an earlier draft inferred sValue ≈ 1.0096 after the May
> ex-date from the feed/equity price ratio on May 20–21. Ondo has confirmed
> `sharesMultiplier` is still **1.0**; that ~1% ratio was intraday/session timing, not
> the multiplier. No reinvestment has happened yet, and the May dividend's whereabouts
> is an open question (§8.10).

### 2.3 Feed coverage gap

Both Chainlink STRCon feeds went live **2026-05-20/21** — after the May 15 ex-date.
Per Ondo (§1.4) the multiplier has never adjusted, so the **June 15 ex-date is the
first sValue adjustment in STRCon's existence** — a fully observable natural experiment.
The exact event moment is ambiguous between Ondo's public docs (evening before ex-date)
and Matt's description (8pm ET on the ex-date): watch the feeds across **both** the
2026-06-14 ~8pm ET and 2026-06-15 ~8pm ET windows. Note 06-14 8pm ET is also the weekend
reopen (Friday 8pm – Sunday 8pm closure, §1.4), so the first window coincides with
~48 hours of feed quiet. Re-run the feed round-walk after the event to measure: the
actual step, the pause duration, feed behavior during the pause (freeze vs smoothed
updates), and the time-to-first-fresh-print afterward (overnight liquidity question,
§4.3/§5.3).

### 2.4 Volatility

STRC fell ~$100 → $93.40 over 2026-06-01..05 (−6.6%) and recovered to ~$96–97. The feeds
oscillate continuously at their 0.5% deviation threshold. A mark-to-market vault will
carry this volatility in sUSDat NAV at feed granularity — a product/communication
consideration independent of any mechanism design, and it means the 10–30 bps residual
step must be estimated by averaging over multiple ex-dates.

---

## 3. Core design change: pluggable accounting modules

### 3.1 Concept

Replace the hard-coded `strcBalance` accounting with a registry of per-asset
**accounting modules** that roll up into `totalAssets()`:

```
totalAssets() = usdatBalance + Σ module.recognizedValue()
```

```solidity
interface IAccountingModule {
    /// USD value (6 decimals) the vault should recognize now
    function recognizedValue() external view returns (uint256);
    /// true when this asset cannot be reliably priced (oracle paused/stale)
    function isPaused() external view returns (bool);
    /// acquire the asset with USDat (venueData: e.g. Ondo RFQ attestation + signature)
    function buy(uint256 usdatIn, uint256 minAssetOut, bytes calldata venueData)
        external returns (uint256 assetOut);
    /// close position back to USDat
    function sell(uint256 assetIn, uint256 minUsdatOut, bytes calldata venueData)
        external returns (uint256 usdatOut);
}
```

Each module owns its oracle wiring, its **yield-recognition policy**, and its **venue
execution**. The vault stops knowing what vesting is — and what an RFQ is.

`venueData` is what keeps the interface generic: for the STRCon module it carries the
Ondo RFQ attestation + signature (processor fetches the quote off-chain, §6.1); for
MirrorSTRC it is empty and `sell()` is the legacy attested-bookkeeping pattern (validate
vs oracle, decrement internal balance, pull USDat from the processor). Same interface,
different internals. Two guards live inside `sell()`/`buy()`: the module validates the
realized execution price against **its own oracle** within tolerance (today's
`convertFromStrc` validation, relocated to where the trade happens), and
`minUsdatOut`/`minAssetOut` bounds each call. `buy`/`sell` are callable only via the
vault (processor-gated, §6.1); since the vault holds custody (§3.2), each call works on
a per-call exact-amount approval — no standing allowances.

### 3.2 Design decisions

1. **Custody stays in the vault.** Modules are accounting adapters (own storage, no token
   custody); `recognizedValue()` is computed against the vault's balances. Avoids asset
   fragmentation, keeps compliance/seizure paths in one place.
2. **Module registration is god-mode.** A module sits in the share-price path; a
   malicious module inflates NAV and drains the vault through redemptions. Registration
   is `DEFAULT_ADMIN_ROLE` and must be treated with the gravity of a UUPS upgrade.
3. **Modules report unpriceable rather than reverting.** Today an oracle revert bricks
   `totalAssets()` and the whole vault. With `isPaused()`, the vault degrades
   deliberately: block mints/processing/rotations; keep share transfers, redemption
   *requests*, and claims of already-processed withdrawals alive.
4. **USDat stays native.** The cash leg is not a module; ERC-4626 semantics (USDat as
   deposit/withdraw asset) are unchanged. Multi-asset applies to the *backing* side
   only. Refined principle: modules encapsulate what is *asset-specific* (oracles,
   venues, per-asset recognition); **the vault knows nothing about any asset but its
   own** — so smoothing inflows of its own denomination is vault business, handled by
   the cash yield inlet (§4.4), not a module.

### 3.3 Initial modules

| Module | Balance source | Pricing | Yield recognition |
|---|---|---|---|
| **MirrorSTRC** (migration bridge) | internal balance (seeded from current `strcBalance`/`vestingAmount` state) | StrcPriceOracle | `transferInRewards` + linear vesting (today's behavior, unchanged) |
| **STRCon** | `STRCon.balanceOf(vault)` | Chainlink STRCon feed (§5) | **None** — mark to market. Dividend yield is already continuous in the token price (§4) |

The module system ships first with behavior identical to today (MirrorSTRC only); STRCon
is added when diligence completes. No flag-day migration.

---

## 4. Yield recognition & dividend sniping

### 4.1 Why STRCon needs no vesting

Today's vesting exists because the dividend arrives as a **discrete off-chain cash event**
disconnected from the price: the oracle takes the ex-date price drop immediately, the
compensating reward lands later via `transferInRewards`, and vesting smooths the
disconnect.

A held STRCon position has no disconnect: yield accrues continuously through the
underlying's intra-month price drift, and the ex-date drop is offset by the simultaneous
sValue bump. There is no reward event to vest. Empirically (§2.2) the residual ex-date
step is ~10–30 bps, not the naive ~96 bps.

Consequently: `transferInRewards`, `vestingAmount`, `vestingPeriod`, `getUnvestedAmount`,
`maxRewardsBps`, and `StillVesting` are retired for STRCon (retained only inside
MirrorSTRC). Smoothing a marked-to-market asset would itself create an exploitable lag.

### 4.2 Snipe analysis

A snipe requires minting or redeeming at a price that does not reflect an imminent,
predictable change. Defenses, in order of importance:

1. **Mark to a live market price; never a discrete/lagged NAV.**
2. **Gate on price reliability, not the calendar.** When the module `isPaused()` (oracle
   paused or stale): `maxDeposit`/`maxMint` → 0; queue `processRequests` blocked;
   rotations blocked. Do **not** hard-code Ondo's current 7:50–8:10pm window.
3. **Redemptions stay async and priced at execution** (existing queue design). A
   mispriced mint cannot complete a round trip at the mispriced level.
4. **Deposit fee as backstop for the residual step.** Sized ~2–3× the measured residual
   ex-date step (pending more data; current estimate suggests ~25–50 bps would dominate
   it; 10 bps may be marginal). Conditional on §2.3 measurement.

Random ex-date deviation (market noise) is ordinary price risk, shared pro-rata — not a
design problem. Only *systematic, predictable* steps are exploitable.

### 4.3 The overnight-gap risk (open)

If STRC does **not** print in the overnight session after the 8pm ex-event, the equity
feed may carry the cum-dividend price while sValue has already bumped → STRCon feed
**overpriced by ~one dividend** from ~8:10pm until the first real ex-dividend trade
(pre-market or 9:30 open). Consequences: deposits in the window overpay (user harm);
a redemption *processed* in the window overpays the redeemer (holder harm).

Mitigations / partial resolution:

- **Ondo confirms STRC trades in all sessions including overnight (§1.4)**, so the
  session-coverage version of this risk is retired. The residual question is print
  *density*: a session can be open with no trades. Measure time-to-first-print after the
  June 15 event.
- Chainlink applies **session-aware smoothing** around session transitions while the
  oracle keeps updating — so the feed may be *moving but smoothed* rather than frozen
  during the event window. Per Chainlink docs, smoothing introduces tracking lag with
  convergence "within seconds to tens of seconds" after legitimate moves — short relative
  to vault operations, but it means the feed can briefly trail a real post-dividend
  reprice. Chainlink explicitly recommends integrators "consider pausing high-risk
  operations during transitions," which aligns with the gating design here.
- Extend the deposit gate past the event until the underlying mark is credibly
  post-event. Note: plain `updatedAt` staleness checks may not catch "fresh timestamp,
  stale trade."
- Operational rule: never process the withdrawal queue between an ex-event (8pm ET) and
  the next session with confirmed prints.

### 4.4 Cash yield inlet: `transferInUsdatYield`

Saturn's USDat float is larger than the vault and generates income independently of it
(M0 treasury yield on the float, incentives). Saturn wants the ability to pass some of
this back to the vault at its discretion — observed scale: **>$50k every ~3 days**.
Sources are mechanically indistinguishable; one inlet serves all.

**Derivation (first principles):**

1. An explicit inlet is required regardless of design — internal accounting ignores
   donations (`rescueTokens` sweeps untracked USDat).
2. The only design variable is **recognition timing**. Instant recognition creates a
   NAV step of `amount / TVL` at a predictable cadence: ~10 bps per event on a $50M
   vault — at the round-trip fee floor (~20 bps) now that atomic exits remove time at
   risk, and it scales the wrong way (events grow with the float, faster than TVL).
   Operational smoothing (smaller, more frequent transfers) puts the safety property in
   an unenforced ops convention. **Short linear vesting** removes the step at any size:
   an attacker must hold NAV exposure across the vest to capture anything.
3. The vesting period only needs to exceed the cheap round-trip window — hours, not
   weeks (precedent: Ethena's StakedUSDe vests reward transfers over **8 hours**).
   Default 24h, admin-configurable, low max (~7 days). With vest ≤ deposit cadence, the
   existing revert-if-still-vesting rule works unchanged — no overlap machinery.

**Mechanism — the cash twin of the audited `transferInRewards` pattern (~20 lines):**

```solidity
function transferInUsdatYield(uint256 amount) external onlyRole(PROCESSOR_ROLE) {
    require(getUnvestedUsdatYield() == 0, StillVesting());   // same rule as today
    require(amount <= /* maxUsdatYieldBps-style cap */, ...); // fat-finger/compromise guard
    usdatBalance += amount;
    usdatYieldVestingAmount = amount;
    lastUsdatYieldTimestamp = block.timestamp;
    IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
}
// totalAssets() subtracts getUnvestedUsdatYield() — the exact pattern
// _strcTotalAssets uses today, with price pinned at 1.
```

**Why vault-native, not a module:** cash yield is a *flow*, not an asset — no price
(always $1), no oracle, no venue, no pause state. A module would host one timer and
require sweep mechanics (moving vested value into the spendable buffer) that exist only
because of the module boundary itself. The vesting machinery already exists, deployed
and audited, in this codebase. A CashYield core module (with an
`IAccountingModule`/`ITradeableModule` interface split) is shelved — worth resurrecting
only if multiple cash-like inlets with *different* recognition policies are ever needed.

**Naming:** `transferInUsdatYield` — rhymes with `transferInRewards` (same role, same
shape), uses the contract's existing `usdat*` vocabulary, and "yield" stays
source-agnostic while distinguishing it from the STRC rewards path. Companions:
`getUnvestedUsdatYield()`, `usdatYieldVestingAmount`, `usdatYieldVestingPeriod`.

---

## 5. Oracle layer

### 5.1 Requirements for the STRCon module's price source

- Read price + verify freshness, **and** read `SyntheticSharesOracle.paused` explicitly
  → drives `isPaused()`. Today's "revert on staleness" behavior is replaced by deliberate
  degradation (§3.2.3).
- **Bounds must be sValue-aware.** Static $20–$150 bounds are wrong for a
  price-accumulating token that grows without bound. Either bound the *underlying* STRC
  feed and read sValue separately, or scale bounds by sValue.
- Feed choice: "STRCon-USD (Calculated)" (= equity × sValue) vs "STRCon/USD (Ondo API)"
  (Ondo's quote). They tracked each other closely in observed history; the Calculated
  feed matches the theoretical construction. Decide after observing both through the
  June 15 event; consider cross-checking one against the other as a sanity bound.

### 5.2 Existing StrcPriceOracle

Unchanged for MirrorSTRC. Retired when off-chain holdings reach zero.

### 5.3 Staleness nuances

- A frozen-but-heartbeating feed defeats timestamp-based staleness checks. The pause flag
  (§5.1) is one signal; staleness is the fallback for outages — but neither alone is
  sufficient (§1.4: trading pauses, oracle pauses, and smoothing windows are three
  different states).
- **Weekends — the stale-mint gap (exists in the current vault today).** STRC is
  unavailable Friday 8pm ET – Sunday 8pm ET, but the feed **heartbeats fresh timestamps
  on the flat price**, so the 26h staleness check passes and **mints execute at Friday's
  price all weekend**. This is the status quo, not a future STRCon issue. It is
  exploitable: STRC's repricing drivers (BTC / Strategy credit) trade 24/7, so weekend
  news creates a known Monday gap against a knowable stale NAV. Observed example: last
  Friday Jun 5 print ~$94.2 → first Monday print +2.0% at 9:30:23am — a weekend minter
  captured ~20× the deposit fee with no timing precision. The reverse direction harms
  the depositor instead (and `minShares` doesn't protect them — it quotes against the
  same stale preview). Staleness checks and the pause flag are both blind to this
  (fresh timestamps, no pause).

  **Design decision: mints are atomic at all times the oracle reports a price.**
  Deposit + mint stay synchronous 24/7, including weekends at the last available print —
  consistent with the current vault's behavior and kept deliberately as a product
  principle for future designs (async mints and closed-market gates were considered and
  rejected). The only gate is genuine price unavailability — corporate-action pause /
  `SyntheticSharesOracle.paused` / feed failure — surfaced through the module's
  `isPaused()` (§3.2).

  The weekend-gap exposure above is therefore an **accepted risk** (recorded in §10).
  Partial mitigants already in the design: deposit fee, async exits (no fast round
  trip), and the cash buffer diluting any gap capture pro-rata.

---

## 6. Liquidity, settlement, and allocation

### 6.1 Rotations are module calls

`convertFromUsdat`/`convertFromStrc` generalize to vault entrypoints that route through
the module registry (PROCESSOR_ROLE, band-checked per §6.5):

```
vault.buyVia(module, usdatIn, minAssetOut, venueData)
vault.sellVia(module, assetIn, minUsdatOut, venueData)
```

For STRCon the full chain is **atomic in one transaction**: Ondo RFQ
`redeemWithAttestation` (STRCon → USDC/USDon, settled atomically, quote signed off-chain
via Ondo's attestation API with short/long duration ↔ tighter/wider spread) → **M0
SwapFacility (USDC → USDat, confirmed atomic)** → USDat in the vault. The
attested-bookkeeping trust assumption disappears; price validation happens inside the
module (§3.1). **Module selection is the processor's call, passed as a parameter** —
"which asset to sell" is strategy (sell-priority, overweight-first) and lives off-chain
per §6.5; the on-chain bands, per-module oracle checks, and `min*Out` bounds make any
selection safe (worst case: allocation drift within bands).

**Do not make purchase atomic with deposit.** Ondo's venue is 24/5 with attestation
flows, quote spreads, and event pauses; coupling deposits to venue availability makes
deposits revert nights/weekends/pauses. Deposits land in the USDat buffer; the processor
rotates on a cadence. Fairness does not require instant conversion: depositors mint at
the blended live mark, so un-rotated cash never captures yield it didn't pay for —
it only creates **cash drag**, an allocation-management issue.

### 6.2 Three concerns, kept separate

Today `processRequests` bundles claim pricing, sale validation, and (implicitly)
portfolio composition. In a multi-asset vault these are three layers:

1. **Claim pricing** (queue) — a redeemer is owed `previewRedeem(shares)`, a USD claim
   against blended NAV. Asset-agnostic; unchanged. Redeemers have no claim on any
   particular asset, only on value.
2. **Liquidity sourcing** (vault manager via rotations) — keeping `usdatBalance`
   sufficient to process the queue (§6.4). Redemptions themselves never sell assets.
3. **Allocation policy** (vault config) — what the portfolio should look like (§6.5).
   Liquidity sourcing pushes toward it rather than fighting it.

### 6.3 Exit paths: atomic buffer redemption + NAV-clean queue

User exits are **NAV-clean**: priced off the vault's mark, never off venue quotes.
(Direct user-facing RFQ sale was considered and rejected: it makes every NAV-vs-quote
mismatch someone's loss, and it puts four external liveness dependencies — Ondo quotes,
quote expiry vs inclusion, Ondo per-user limits shared across all redeemers, Saturn's
API — into the most trust-sensitive flow. Venue execution lives only inside module
`buy`/`sell`.) Two paths:

1. **Atomic buffer redemption (primary).** Burn shares, pay
   `previewRedeem(shares) × (1 − redemptionFeeBps)` from `usdatBalance` immediately.
   Gated on module liveness (`isPaused()`), capped per period; cap sizes against the
   standing buffer alone (§6.4). Open to all holders up to the cap; integrator contracts
   (e.g. srUSDat, §11) may get reserved capacity.
2. **The queue (all-weather fallback).** Buffer exhausted, weekends/pauses, oversized
   exits, limit-price patience. Same NAV-clean pricing at processing time.

**Redemptions never sell anything.** Asset sales happen only through rotations (§6.1),
where oracle/tolerance validation already lives.

**Queue batches are funded just-in-time, atomically — never from the standing buffer:**

```
// StakedUSDat, PROCESSOR_ROLE, nonReentrant — single transaction
fundAndProcessRedemptions(SellLeg[] legs, uint256[] tokenIds)
  for leg in legs: _sellVia(leg.module, leg.assetAmount, leg.minUsdatOut, leg.venueData)
  WITHDRAWAL_QUEUE.processRequests(tokenIds)   // queue: vault-only caller
    for each request:
      gross  = previewRedeem(request.shares)     // position value at processing time
      payout = gross × (1 − redemptionFeeBps)    // net of redemption fee (below)
      if payout < minUsdatReceived → skip (emit, stays queued)   // limit checked NET
    pull exactly Σ(payouts) from vault (usdatBalance decrement) + burn escrowed shares
    // held-back fee stays in usdatBalance → NAV/share ticks up for remaining holders
```

Why this shape:

- **Atomicity is mandatory, not a nicety**: a standalone sell followed by a separate
  processing tx leaves the JIT proceeds in the shared `usdatBalance` and visible in the
  mempool — frontrunnable by atomic redemptions. One tx ⇒ nothing to race. Reservation
  accounting (earmarking buffer for locked batches) was rejected as stateful machinery
  the atomic bundle makes unnecessary.
- **The orchestration lives on the vault** (already the asset-aware party holding the
  registry, custody, and roles) — no router contract to manage, no signer-infra
  dependency. `processRequests` is callable **only by the vault**, making "the queue
  never draws the standing buffer race-prone" a property of the call graph, not an
  operational convention.
- **`legs` may be empty**: on heavy-deposit days the buffer already covers the batch —
  that's §6.4 netting, a conscious processor choice, race-free because it's one tx
  (insufficient balance ⇒ requests skip and roll to the next batch).
- **Self-consistency**: processing is liveness-gated (`previewRedeem` needs live marks)
  and JIT funding needs a live venue — the same condition. Whenever the queue may
  process, funding is available; when venues are closed, requests wait, which is what a
  queue is for. (MirrorSTRC-funded batches: same bundle, `sell()` pulls USDat from the
  processor's wallet per the legacy pattern.)

**Fill at position value, not at limit.** Requests execute at limit *or better* —
standard limit-order semantics. Filling at the limit would punish conservative floors
(users respond with razor-tight limits → more failed processing), and would corrupt the
processor's role from scheduler into a counterparty incentivized to process low-limit
requests when NAV is high. `minUsdatReceived` is protection, not a price agreement —
matching the deployed code's semantics.

**Redemption fee (anti-dilution levy).** Redeemers exit at the oracle *mid* mark, but
replenishing rotations realize mid minus Ondo's quote spread — a structural one-way
drag on remaining holders proportional to redemption turnover (~2 bps/month at a 20 bps
spread and 10% monthly turnover; worse exactly when spreads widen in stress).
Mitigation: configurable `redemptionFeeBps`, applied at processing, hard-capped (cf.
`MAX_DEPOSIT_FEE_BPS`), default sized to the measured Ondo spread (§8.6/§8.16).
The held-back portion **stays in the vault** (full share value burned, net payout
paid → NAV/share rises): redeemers pay their own exit costs, holders are made whole,
nobody profits. Deliberately distinct from the deposit fee, which goes to
`feeRecipient` as revenue — redemption fee is cost recovery, not revenue (§7).
It also doubles as the stress lever: raise toward the cap in a stressed market instead
of inventing emergency machinery. Charging at claim instead was rejected (`usdatOwed`
is fixed at processing; deducting later makes the recorded amount lie and complicates
claim/seizure paths). A flat fee is deliberately crude vs true swing pricing —
flat-but-configurable captures most of the value at a fraction of the complexity, and
processor cadence already nets flows before anything trades.

**Fee × limit interaction:** the limit is checked against the **net** payout, so a fee
raise cannot silently take from queued holders — their requests stop executing until
they consent by lowering their limit.

**Limit semantics (`minUsdatReceived` retained).** Each request carries a limit amount
set by the holder; the queue is effectively a limit-order book against vault NAV, and
the processor chooses which requests are executable. If NAV drops after a holder enters
the queue, their request does not process at the bad price — it sits queued until NAV
recovers or the holder lowers their limit (`updateMinUsdatReceived`, with the existing
only-downward-while-locked rule). Because payouts are now computed independently per
request (no batch pro-rata interdependence), an unmet limit **skips that request**
rather than reverting the batch (a skipped `InProgress` request auto-reverts to
`Requested`). Unmet-limit requests may sit indefinitely — holder-controlled by design;
compliance paths (`seizeRequests`) cover adversarial cases.

Deleted relative to current code: `_validateTotals` and all three triangulating checks
(the one number that matters is computed, not verified); `executionPrice`/`totalStrcSold`
params; the queue's oracle, `strcBalance`, and `toleranceBps` dependencies; the dust
path (`collectDust` + approve dance — pulling exactly Σ(payouts) leaves no remainder);
`burnQueuedShares`' `strcAmount` coupling.

Remaining queue↔vault couplings: `previewRedeem`, share escrow/burn, funding pull.
The queue is fully asset-agnostic — **adding future assets never touches it**.
`previewRedeem` reads `totalAssets()`, so processing is naturally gated by the same
module `isPaused()` liveness as everything else. Partial processing (as many requests
as available cash covers) is fine; the queue is already async. `lockRequests` is
retained so `minUsdatReceived` can't change while the manager arranges liquidity for a
batch.

**Residual trade-off — slippage socialization (recorded in §10):** redeemers receive
the oracle mark, not realized sale proceeds; the mark-vs-execution gap lands on
remaining holders via rotations. The redemption fee above is the primary mitigant
(sized to the spread, raised in stress); additional bounds: rotation tolerance checks,
fund-before-process sequencing, and unmet limits naturally throttling exits in a
falling market.

### 6.4 Liquidity management: rotation policy

With redemption decoupled, all liquidity and allocation work happens through rotations,
managed by the vault manager (processor) within the §6.5 guardrails:

**The standing buffer (`usdatBalance`) serves exactly two purposes: atomic exits
(§6.3 path 1) and deposits awaiting rotation.** Queue batches are funded just-in-time
(§6.3), so the buffer and the queue never compete; the atomic-exit cap sizes against
the buffer with no haircut for queue needs.

1. **Net flows first.** Deposits accumulate in `usdatBalance`; atomic exits draw from
   it; on flush days the processor processes queue batches with empty `legs` (§6.3).
   Only *net* redemption demand requires selling.
2. **Sell from the most-overweight asset** vs target weights when funding is needed —
   every funding event doubles as rebalancing.
3. **Pro-rata** when everything is at target.

**Migration-era override: MirrorSTRC sells first, always.** With target weight zero and
top sell-priority, normal operations perform the migration by attrition — funding needs
drain the trust-heavy off-chain leg, deposits rotate into STRCon, no forced trades, no
flag day. The migration plan largely reduces to allocation config.

If a module `isPaused()`, sell the next source; allocation drift is the correct failure
mode (asymmetry principle, §6.5). The cash floor (`minCashBufferBps`) governs rotations
and deposit deployment only — queue processing may draw `usdatBalance` to zero; never
let a buffer target block a withdrawal.

### 6.5 Allocation policy: banded targets

Realized APY ≈ asset yield × allocation ratio, so allocation is the yield knob.
(Note the drift is structural even with zero trading: the STRCon leg grows itself via
dividend reinvestment while the cash leg only shrinks — bands do work monthly, not just
in stress.) The residual ex-date step also scales with allocation (80% × 30 bps = 24 bps
share-price step) — run fee-vs-step on the blended number.

Enforcement options:

| | Mechanism | Assessment |
|---|---|---|
| Soft | Targets off-chain; processor discretion | Re-introduces the trust being migrated away |
| **Banded (recommended)** | Per-module `targetWeightBps` + `maxWeightBps` hard cap + global `minCashBufferBps` on-chain; processor free within bands; rotations/sales must not breach caps or worsen deviation beyond band | Trust-minimized where it matters, flexible where it doesn't |
| Hard | Exact ratios; every flow auto-rebalances | Brittle: forces trades at bad times; bricks when an asset is paused |

**Asymmetry principle: strict on entering risk, lenient on exiting it.** A hard cap may
block a rotation *into* an asset; no floor may ever block a withdrawal settlement. If
the preferred sale source is paused, selling the "wrong" asset and drifting from target
is correct — drift is recoverable, frozen withdrawals are a crisis. `maxWeightBps` is
also the blast-radius limit on a bad module/oracle.

**Keep the on-chain surface to guardrails, not strategy.** v1 knobs: cash floor,
per-asset cap, sell-priority order. Target-weight optimization and trade selection live
in the processor's off-chain logic, where iteration is cheap, bounded by the on-chain
caps and floors.

---

## 7. Protocol fee (new requirement)

Today the dividend passes through Saturn's hands off-chain before `transferInRewards` —
an implicit fee/timing control point. With STRCon, 100% of the (post-withholding)
dividend auto-reinvests into the vault's position; **no moment exists where Saturn
touches the yield**. If Saturn wants a management/performance fee, it must be an explicit
on-chain mechanism (e.g., periodic share mint to `feeRecipient` against a high-water
mark, or a skim at rotation). Decide **before** migration — retrofitting a fee onto
holders later is a worse conversation.

Fee taxonomy: **deposit fee** → `feeRecipient` (revenue); **redemption fee** (§6.3) →
stays in the vault (cost recovery / anti-dilution, never revenue); **protocol fee on
yield** (this section) → `feeRecipient` (revenue, mechanism TBD); **cash yield rebate**
(§4.4) → into the vault (economically a *negative* protocol fee — Saturn declining
revenue; decide jointly with the protocol fee so the net take is one coherent number).
Keeping the revenue vs cost-recovery distinction clean matters for how fee flows audit.

---

## 8. Open questions / diligence

| # | Question | How to resolve |
|---|---|---|
| 1 | Can the vault contract hold STRCon? Transfer restrictions/allowlists for contracts vs mint/redeem-only KYC? Eligibility of Saturn entity & vault users | Ask Ondo directly (docs are thin) |
| 2 | Withholding: Kian's confirmed formula uses the **gross** dividend (§1.4) but public docs say "net of applicable tax withholdings" — which applies to STRC? Drives the residual-step sign/size | Confirm with Ondo; verify against the measured June 15 sValue bump vs $0.958 |
| 3 | Measured STRCon step, pause duration, feed behavior during pause (freeze vs smoothed), time-to-first-print at a real ex-event | Re-run feed round-walk after **2026-06-15**; watch both candidate windows (06-14 and 06-15 ~8pm ET, §2.3) |
| 4 | STRC overnight print *density* post-ex-event (session coverage confirmed §1.4; liquidity not) | June 15 measurement |
| 5 | Which feed (Calculated vs Ondo API) as primary; cross-check policy | Observe both through June 15 |
| 6 | Ondo mint/redeem mechanics for contracts: attestations, settlement time, quote spread, size limits (`GMTokenManager`) | Ondo docs/API + integration test |
| 7 | Fee mechanism design (§7) | Product decision |
| 8 | Residual-step estimate needs more ex-dates (n=2, equity-side only) | Accumulate monthly measurements |
| 9 | If STRC's rate exceeds ~12%/yr, monthly dividends cross into Ondo's >1% manual-pause path | Monitor; affects pause-window assumptions |
| 10 | **Where did the May dividend go?** STRCon launched May 4; the May 15 ex-date passed; `sharesMultiplier` is still 1.0 (§1.4). Late reinvestment pending? Holders absorbed the drop? Custody acquired post-record-date? | Ask Ondo (Kian) |
| 11 | Chainlink session-aware smoothing behavior: how it shapes the feed around session transitions, dividend events, and the weekend reopen; interaction with our staleness/pause gating (§5.3) | Read Chainlink tokenized-equity-feeds docs §session-aware-smoothing; observe June 15 |
| 12 | Weekend staleness policy: feed economically ~48h stale Fri 8pm – Sun 8pm ET (§5.3) | Design decision after observing weekend feed behavior |
| 13 | Cash floor (`minCashBufferBps`) sizing vs expected withdrawal-queue volume | Ops data: historical queue volume distribution |
| 14 | Per-asset `maxWeightBps` hard caps from day one? (Recommended — doubles as module/oracle blast-radius limit, §6.5) | Product/risk decision |
| 15 | Exact definition of the "reliable price" predicate behind `isPaused()` for the corporate-action gate (§5.3): pause flag + staleness + what else? | Design decision after June 15 observation |
| 16 | `redemptionFeeBps` default and cap sizing (§6.3) | Measure Ondo's actual mint/redeem spread (with §8.6); set default ≈ spread |
| 17 | Ondo per-user trading limits: the vault is one Ondo "user" — all rotations/JIT funding share one limit bucket; what are the limits and do they constrain stress-day processing? (§6.1) | Ondo Get Trading Limits endpoint + ask Kian (onboarding otherwise assumed complete) |
| 18 | Atomic-exit cap sizing and period (§6.3); interacts with cash floor (§8.13) | Ops data + product decision |
| 19 | Reserved atomic-exit capacity for integrator contracts (srUSDat) vs open shared cap (§11.2) | Product decision |
| 20 | Senior claim must be computable on-chain at request time for the §11.1 waterfall fix — is srUSDat's senior NAV a clean waterfall output? | Tranche product design |
| 21 | `transferInUsdatYield` parameters (§4.4): vesting period default/max (proposed 24h / ~7d) and per-transfer cap (separate bps knob from `maxRewardsBps`?) | Product decision; size cap from expected pass-back cadence |

## 9. Migration sequencing (proposed)

1. **Module framework upgrade** — registry + `isPaused()` gating; MirrorSTRC module seeded
   with current state; behavior identical to today. Withdrawal-queue validation inverted
   (§6.3). New implementation → regenerate code-hash reference values for `verify.sh`
   (immutables change).
2. **Diligence gate** — resolve §8 items 1–6; ≥2 more measured ex-dates.
3. **STRCon module** — register with conservative allocation cap; wind `MirrorSTRC`
   down primarily **by attrition** (§6.4: MirrorSTRC target weight 0, top
   sell-priority — withdrawals drain it, deposits rotate into STRCon), supplemented by
   explicit rotation (or in-kind transfer if Ondo supports it) if attrition is too slow.
4. **Cleanup upgrade** — retire MirrorSTRC, `transferInRewards` & vesting surface,
   StrcPriceOracle.
5. **Future assets** — new module per instrument, each with its own oracle and
   recognition policy.

## 10. Risk register (summary)

- **Ondo issuer/structured-note risk** stacked on Strategy credit risk (new).
- **NAV volatility at feed granularity** (−6.6% week observed) now user-visible (§2.4).
- **Oracle pause/freeze windows** — handled by `isPaused()` gating; overnight gap open (§4.3).
- **Weekend stale-price minting — accepted by design** (§5.3): mints stay atomic at the
  last available print while the market is closed; observed weekend gaps ~2% vs 10 bps
  deposit fee. Accepted in exchange for 24/7 atomic minting; revisit if weekend-gap
  capture is observed in practice.
- **Redemption slippage socialization — mitigated by design** (§6.3): redeemers exit at
  the oracle mark; mark-vs-execution gaps land on remaining holders via rotations.
  Primary mitigant: configurable `redemptionFeeBps` paid back to the vault, sized to
  the measured Ondo spread, raised toward its cap in stress. Residual exposure: gap
  beyond the fee during stress; unmet limits throttle the first-exit dynamic.
- **Module registration = accounting god-mode** — admin-gated, upgrade-level review (§3.2).
- **Residual ex-date step** ~10–30 bps vs 10 bps deposit fee — fee sizing pending data (§4.2).
- **Withholding drag** — realized yield < 11.5% headline (quantify via §8.2).
- **Regulatory/eligibility** — qualified-investor restrictions on STRCon (§8.1).
- **Atomic-exit buffer dynamics** (§6.3): the capped buffer path is first-come
  first-served; in stress it exhausts and exits fall back to the queue — by design, but
  the cap + fee parameters determine how that transition feels. Bounded by the cap;
  queue fallback is always available.

---

## 11. Tranche products on top of the vault (srUSDat / jrUSDat)

srUSDat (senior) / jrUSDat (junior) tranche sUSDat: junior absorbs NAV risk first,
senior takes reduced, protected yield. The exit design above was shaped partly by this
integration.

### 11.1 The queue-exposure problem and the waterfall fix

A senior holder exiting through the sUSDat queue would bear full sUSDat NAV exposure
while queued — violating the senior promise exactly during exit. The fix is a tranche-
layer accounting rule, **zero vault changes**: the senior's payout is **fixed at request
time** (senior-claim value, accruing the senior rate while waiting); the tranche
contract holds the queued sUSDat position; any drift between the fixed senior payout
and realized proceeds settles against the **junior** tranche — the same waterfall that
allocates every other gain/loss. Junior is structurally levered-long sUSDat; bearing
exit-window drift is a coherent, pricable part of the junior deal. The senior redeemer
retains only whole-structure default risk (junior fully wiped while waiting), which is
the senior deal anyway.

### 11.2 Exit latency for seniors

With the §6.3 exit stack, senior exits via the tranche contract normally hit the
**atomic buffer path** (instant, NAV − fee — a 5–10 bps per-exit fee is noise
annualized against a senior rate; fees only eat senior yield if exits are frequent,
in which case they should). Queue residence in normal conditions collapses to processor
cadence (JIT funding makes refills atomic), and §11.1 covers whatever residence remains.

**Open (§8.19):** whether srUSDat gets **reserved capacity** within the atomic-exit cap
(a one-line extension) or shares the open cap. Admission criteria should be mechanical
(caps, fee, liveness gating) so any third-party integrator can qualify — a facility
with criteria, not a favor.

### 11.3 Alternatives shelved

- **Junior as exit counterparty** (junior side purchases senior exits at fixed claim
  value, earning a spread for immediacy): elegant endgame, fully internal to the
  tranche product, zero vault surface — revisit if senior exit volume outgrows the
  buffer.
- **Secondary liquidity** (srUSDat/USDC AMM): market-priced instant exit; compliance
  constraints on the tranche token likely decide this.
