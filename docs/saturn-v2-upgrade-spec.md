# sUSDat Multi-Asset Backing & STRCon Migration — Design Spec

**Status:** Draft for discussion
**Date:** 2026-06-11
**Scope:** Migrating sUSDat's STRC exposure from off-chain mirrored holdings to on-chain
tokenized STRC (Ondo's STRCon), and generalizing vault accounting to support multiple
backing assets ("multi-asset digital credit").

> Single document while in design phase. At implementation time, split by lifecycle:
> a durable **multi-asset vault architecture** spec (§3–7: modules, yield
> recognition, oracle, liquidity/settlement/allocation, fees) and a
> time-bound **STRC→STRCon migration plan** (§1–2, 11: bridge module, attrition
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
professional clients) 

**Total-return, price-accumulating model (Ethereum):**

```
STRCon price = underlying STRC market price × sValue
```

`sValue` (shares multiplier) comes from Ondo's `SyntheticSharesOracle`. Dividends are
never paid out; they are reinvested (net of tax withholding) into more STRC and reflected
as an sValue increase. One token represents a growing number of STRC shares.

**Dividend mechanics (measured Jun 15, §B.3):**

- sValue updates two ways. **Drift path:** changes within `allowedDriftBps` per `driftCooldown`
  (**2% / 24h**) apply automatically via `SValueUpdated`, no pause. **Corporate-action path:**
  larger changes are scheduled (`scheduleCorporateActionPause` → feed freezes →
  `CorporateActionApplied`).
- The monthly dividend bump is `dividend / post-drop price` ≈ **+1.009%** (sValue 1.0096527 →
  1.0198431, STRC ~$94). Under the 2% limit, so it rides the **drift path** — no pause, feed
  never froze.
- `getSValue(asset)` returns `(sValue, paused)`, per-asset. `paused` is set only for a scheduled
  corporate action, never routine dividends, and none has been observed yet.
- The bump lands at **~8pm ET**, when the overnight session reopens (the regular close is 4pm
  ET), simultaneous with the underlying's ex-dividend reprice.

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
    /// the ERC20 this module custodies in the vault, or address(0) if token-less (e.g. MirrorSTRC)
    function asset() external view returns (address);
    /// tracked quantity of asset() recognized as backing, in asset()'s own units.
    /// invariant (token-backed modules): asset().balanceOf(vault) >= balance()
    function balance() external view returns (uint256);
    /// acquire the asset with USDat (venueData: e.g. Ondo RFQ attestation + signature)
    function buy(uint256 usdatIn, uint256 minAssetOut, bytes calldata venueData)
        external returns (uint256 assetOut);
    /// close position back to USDat
    function sell(uint256 assetIn, uint256 minUsdatOut, bytes calldata venueData)
        external returns (uint256 usdatOut);
}
```

`recognizedValue()` is a position's NAV: the module's tracked **`balance()`** counter priced
through its **oracle**.

- **`balance()`** is the recognized quantity — a counter, not a live `balanceOf`.
- **`buy`/`sell`** are the only functions that change it.
- **`balanceOf`** is only a custody floor (`asset().balanceOf(vault) >= balance()`), never the
  recognized amount. Excess custody (a stray transfer) is unrecognized and swept by
  `rescueTokens` (§4.4).

So NAV moves only through authorized paths — an external transfer can't inflate the share price.

Token-less modules (MirrorSTRC) return `asset() == address(0)`: `balance()` is notional, priced
via their own oracle with no custody floor.

Each module owns its oracle wiring, yield-recognition policy, and venue execution.

`venueData` keeps the interface generic: for STRCon it carries the Ondo RFQ attestation +
signature; for MirrorSTRC it carries the attested execution price, and `sell()` decrements the
counter and pulls USDat from the processor. Each `buy`/`sell` enforces two guards: the module
validates the realized (or attested) price against its own oracle within tolerance, and
`minUsdatOut`/`minAssetOut` bounds the call. `buy`/`sell` are vault-only (§6.2); since the
vault holds custody (§3.2), each call uses a per-call exact-amount approval — no standing
allowances.

### 3.2 Design decisions

1. **Custody stays in the vault.** Modules are accounting adapters (own storage, no token
   custody); `recognizedValue()` is computed against the vault's balances. Avoids asset
   fragmentation, keeps compliance/seizure paths in one place.
2. **Module registration is god-mode.** A module sits in the share-price path; a
   malicious module inflates NAV and drains the vault through redemptions. Registration
   is gated by `MODULE_MANAGER_ROLE` and must be treated with the gravity of a UUPS upgrade.
3. **Modules report unpriceable rather than reverting.** Today an oracle revert bricks
   `totalAssets()` and the whole vault. With `isPaused()`, the vault degrades
   deliberately: block mints/processing/rotations; keep share transfers, redemption
   *requests*, and claims of already-processed withdrawals alive.
    > ⚠️ **TODO — Is this the right design choice**
    > Design 1: If an oracle can report a price then report it engaging an isPaused() flag if 
    > the oracle value falls outside the expected bounds. 
    > Design 2: If an oracle falls outside the expected bounds fail the oracle call. This is 
    > the current setup with the STRC/USD oracle and the wrapper which verifies the price.
4. **USDat stays native.** Refined principle: modules encapsulate what is *asset-specific* 
  (oracles, venues, per-asset recognition); **the vault knows nothing about any asset but its own** — so smoothing inflows of its own denomination is vault business, handled by the cash yield inlet (§4.4), not a module.

### 3.3 Initial modules

| Module | Balance source | Pricing | Yield recognition |
|---|---|---|---|
| **MirrorSTRC** (migration bridge) | internal balance (seeded from current `strcBalance`/`vestingAmount` state) | StrcPriceOracle | `transferInRewards` + linear vesting (today's behavior, unchanged) |
| **STRCon** | tracked `balance` counter; invariant `STRCon.balanceOf(vault) ≥ balance` | Chainlink STRCon feed (§5) | **None** — mark to market. Dividend yield is already continuous in the token price (§4) |

The module system ships first with behavior identical to today (MirrorSTRC only); STRCon
is added when diligence completes. No flag-day migration.

### 3.4 Registration & the module registry

The vault owns the registry; `totalAssets()` iterates it (§5.1). State is an
`EnumerableSet.AddressSet` of *active* modules plus a parallel config mapping whose only
on-chain knob is the concentration cap (no target weight — §6.2):

```solidity
using EnumerableSet for EnumerableSet.AddressSet;

struct ModuleConfig {
    uint16 maxWeightBps;   // hard cap on this module's share of totalAssets()
}
EnumerableSet.AddressSet private _modules;        // active set; dense, no dead entries
mapping(address => ModuleConfig) public moduleConfig;
uint16 public minCashBufferBps;                   // global cash floor (§6.2)
```

The set is the authoritative membership record — there is no `registered` bool to drift out
of sync with the array. Deregistration is a real removal (swap-and-pop inside the set), so a
wound-down module leaves no dead entry for `totalAssets()` to iterate. Order is irrelevant: a
sum is commutative, and nothing else reads a stable on-chain order (sell-priority is off-chain,
§6.2).

All three registry mutations are gated by **`MODULE_MANAGER_ROLE`**, treated with
upgrade-level gravity (§3.2.2): a registered module sits in the share-price path, so a
malicious one inflates NAV and drains the vault.

```solidity
// all onlyRole(MODULE_MANAGER_ROLE)
registerModule(address module, uint16 maxWeightBps)  // _modules.add(module), set config; enforce count cap
setMaxWeight(address module, uint16 maxWeightBps)     // adjust the cap
deregisterModule(address module)                      // only when recognizedValue() == 0:
                                                       //   _modules.remove(module); delete moduleConfig[module]
```

`deregisterModule` requires zero recognized value (position wound down by attrition, §6.2) so
no backing is stranded, and clears the config so a later re-registration of the same address
can't inherit a stale cap. Membership checks are `_modules.contains(module)`.

**Cap = max ownership.** `maxWeightBps` bounds a module's share of NAV: a `buyVia` (§6.2)
reverts if it would push `module.recognizedValue() / totalAssets()` over the cap; sells are
never blocked (asymmetry, §6.2). It's also the blast-radius limit on a bad module/oracle.

> ⚠️ **TODO — bound the registry loop.** `totalAssets()` iterates `_modules` and calls every
> `recognizedValue()`, on the hot path (each deposit/redeem/preview/rotation). The set is
> admin-gated (not user-griefable), but still unbounded: enforce a hard cap on `_modules.length()`
> in `registerModule` and keep each `recognizedValue()` gas-bounded, so a large registry or one
> heavy module can't make
> `totalAssets()` too expensive to call.

---

## 4. Yield recognition & dividend sniping

### 4.1 Why STRCon needs no vesting

Today's vesting exists because the dividend arrives as a **discrete off-chain cash event**
disconnected from the price: the oracle takes the ex-date price drop immediately, the
compensating reward lands later via `transferInRewards`, and vesting smooths the
disconnect.

A held STRCon position has no disconnect: yield accrues continuously through the
underlying's intra-month price drift, and the ex-date drop is offset by the simultaneous
sValue bump. There is no reward event to vest. Empirically (§B.2) the residual ex-date
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
   it; 10 bps may be marginal). Conditional on §B.3 measurement.

Random ex-date deviation (market noise) is ordinary price risk, shared pro-rata — not a
design problem. Only *systematic, predictable* steps are exploitable.

### 4.3 The overnight-gap / cum-dividend mark (open — under verification)

If STRC does **not** print in the overnight session after the 8pm ex-event, the equity
feed may carry the cum-dividend price while sValue has already bumped → STRCon feed
**overpriced by ~one dividend** from ~8:10pm until the first real ex-dividend trade
(pre-market or 9:30 open). Consequences: deposits in the window overpay (user harm);
a redemption *processed* in the window overpays the redeemer (holder harm).

Per the §5.4 pricing principle the vault **prices through** this window — a heartbeating
feed is priceable, no calendar/event gate — treating it like the weekend stale-mint gap.
That stance is **provisional** on the gap being comparable in size to the weekend gap.

> ⚠️ **TODO — verify with the Ondo and Chainlink teams.** Whether the STRCon feed actually
> carries a cum-dividend mark around the 8pm ET ex-window,
> and if so how large and for how long. The "price through it" decision rests on this being
> small and short (≈ the ~10–30 bps residual step, §B.2) rather than a full one-dividend
> (~96 bps) mispricing. **Revisit the gating decision if it turns out larger or
> longer-lived than the weekend gap.**

What's already known / partial resolution:

- **Ondo confirms STRC trades in all sessions including overnight (Appendix A)**, so the
  session-coverage version of this risk is retired. The residual question is print
  *density*: a session can be open with no trades. Measure time-to-first-print after the
  June 15 event.
- Chainlink applies **session-aware smoothing** around session transitions while the
  oracle keeps updating — so the feed may be *moving but smoothed* rather than frozen
  during the window, converging "within seconds to tens of seconds" after legitimate
  moves. This is part of what's being confirmed: smoothed-but-moving shrinks the gap;
  frozen-cum-dividend does not.
- **Interim caution (pending verification only):** until the exposure is confirmed
  bounded, the processor avoids processing the withdrawal queue between an ex-event
  (8pm ET) and the next session with confirmed prints. This is an off-chain operational
  choice, not an on-chain gate, and is dropped once the gap is confirmed small.

### 4.4 Cash yield inlet: `transferInYield`

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
   an attacker must hold NAV exposure across the vest to capture anything. (A no-vesting
   alternative — cap each transfer so the step stays below the deposit+redemption
   round-trip fee — was considered and rejected: it silently breaks the moment a fee is
   set to zero, at which point every transfer is a clean atomic mint→`transferInYield`→
   atomic-exit sandwich. Vesting eliminates the step itself and is independent of fee
   policy.)
3. The vesting period only needs to exceed the cheap round-trip window — hours, not
   weeks (precedent: Ethena's StakedUSDe vests reward transfers over **8 hours**).
   Default 24h, admin-configurable, low max (~7 days). With vest ≤ deposit cadence, the
   existing revert-if-still-vesting rule works unchanged — no overlap machinery.

**Mechanism.** Cash yield enters through `transferInYield` and is held in a dedicated
vesting leg — `yieldVestingAmount` — physically in the vault but kept separate from
`usdatBalance`. It vests linearly over `yieldVestingPeriod` (default 24h). `totalAssets()`
counts only the portion that has vested so far; when a tranche finishes vesting,
`sweepVestedYield()` moves it into `usdatBalance`, where it becomes ordinary spendable
cash. The vesting math never writes `usdatBalance` directly — the yield lives in its own
leg until it is fully recognized, then crosses over in one step.

```solidity
// yieldVestingAmount holds USDat in the vault but OUT of usdatBalance until vested.

function transferInYield(uint256 amount) external onlyRole(OPERATOR_ROLE) {
    _sweepVestedYield();                                       // fold a matured prior tranche into usdatBalance
    require(getUnvestedYield() == 0, StillVesting());          // prior tranche fully vested
    require(amount <= Math.mulDiv(totalAssets(), maxYieldBps, BPS), YieldExceedsMax());
    yieldVestingAmount = amount;                               // segregated leg, NOT usdatBalance
    lastYieldTimestamp = block.timestamp;
    IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
}

// NAV adds only the vested-so-far slice of the segregated leg:
//   totalAssets() = usdatBalance
//                 + (yieldVestingAmount - getUnvestedYield())   // vested cash yield
//                 + Σ module.recognizedValue()
// getUnvestedYield() is the same time-based linear curve as getUnvestedAmount() today.

// the single controlled outflow: move a fully-vested tranche into the spendable buffer.
function _sweepVestedYield() internal {
    if (yieldVestingAmount > 0 && getUnvestedYield() == 0) {   // only when fully vested
        usdatBalance += yieldVestingAmount;
        yieldVestingAmount = 0;
    }
}
```

`_sweepVestedYield()` also runs at the top of the value-sensitive entrypoints
(deposit/mint, redemption funding, rotations) and is exposed as a permissionless poke, so
a matured tranche becomes spendable without waiting for the next `transferInYield`.

**How this differs from the current (STRC) vesting.** Both use the same linear curve —
`getUnvestedYield()` is `getUnvestedAmount()` with the price pinned at 1. The structural
difference is *where the vesting amount sits* and *which way `totalAssets()` corrects for
it*:

| | Current STRC vesting | Cash yield (this) |
|---|---|---|
| Where the vesting amount lives | inside `strcBalance`, the asset leg it belongs to | a dedicated `yieldVestingAmount` leg, separate from `usdatBalance` |
| `totalAssets()` correction | **subtracts** the unvested part from `strcBalance` | **adds** only the vested-so-far part of the leg |
| How it becomes usable | already in `strcBalance`; the single sell path (`convertFromStrc`) only releases the *vested* part | swept into `usdatBalance` once a tranche is fully vested |
| Why this shape | `strcBalance` has one outflow, so subtract-and-guard-at-the-sell is clean | `usdatBalance` has many outflows; subtracting there would force a `− unvested` floor into every one to avoid underflow — so the yield gets its own leg instead |

**Touch-points (the entire footprint):** the inflow (`transferInYield`), the NAV view (one
added term), the sweep, and `rescueTokens` — whose excess becomes
`balanceOf(this) − usdatBalance − yieldVestingAmount`, so the segregated leg is not
mistaken for a donation and swept out. Nothing else in the vault references vesting; the
settlement ledger stays sacred.

**Rescue generalizes across modules.** With multiple backing assets `rescueTokens(token,…)`
can no longer hard-code the USDat legs. The rescuable excess for any `token` is its vault
balance minus everything legitimately held in it: the native cash legs when `token` is USDat
(`usdatBalance + yieldVestingAmount`), **plus `balance()` of every registered module whose
`asset() == token`**:

```solidity
function rescueTokens(address token, uint256 amount, address to)
    external onlyRole(DEFAULT_ADMIN_ROLE)
{
    uint256 protected;
    if (token == asset()) protected = usdatBalance + yieldVestingAmount; // vault's ERC4626 asset
    for (uint256 i; i < _modules.length(); ++i) {
        IAccountingModule m = IAccountingModule(_modules.at(i));
        if (m.asset() == token) protected += m.balance();
    }
    require(amount <= IERC20(token).balanceOf(address(this)) - protected, ExceedsRescuable());
    IERC20(token).safeTransfer(to, amount);
}
```

"Token-backed" vs "token-less" is not a branch — it falls out of `asset()`. A token-backed
module (STRCon) protects exactly its tracked counter, so the rescuable excess is precisely the
unrecognized donations/dust/in-flight. A token-less module (MirrorSTRC, `asset() == address(0)`)
matches no real ERC20 and is **transparent to rescue**: mirrored-STRC notional never shields a
real token, and stray STRC sent to the vault — including post-migration, once the mirror is
deregistered — stays sweepable. The subtraction is left bare: it underflows only if a module
reports `balance()` above real custody, which the per-module invariant forbids — surfacing a
broken module as a revert rather than a silent mis-rescue. (The loop is admin-only and cold-path,
but shares the unbounded-`_modules` caveat of the `totalAssets()` loop, §3.4.)

**Accepted micro-wart:** during the ≤24h vest the *partially*-vested slice is recognized
in NAV but not yet liquid (a clean partial sweep would mean re-anchoring the linear
schedule to its original end-time — deferred unless liquidity-during-vest ever matters).
If a large redemption lands mid-vest, JIT funding sells a sliver of module while the
sub-$50k slice waits for the next sweep; no value is lost (it is in `totalAssets()` either
way) and it self-heals on full vest. Negligible against the vault size.

**Why vault-native, not a module:** a USDat accounting module is tempting for consistency
— every other backing asset is a module. But USDat is not a backing asset; it is the
**settlement / unit-of-account asset**. `usdatBalance` is written by deposit, mint,
withdraw, redeem, atomic-exit, every rotation leg, and JIT queue funding (§6.3) — the
most-written variable in the system; hiding it behind a module would add a cross-contract
write to every core operation. The only separable piece is the vesting accounting above,
and it is too thin (a counter, a timestamp, one linear curve, a sweep) to justify a
module. (A module *could* hold its own counter — MirrorSTRC does — so the tracked-counter
pattern is not what forces this; the settlement-ledger chokepoint is.)

**No shared library.** The linear-vesting math is duplicated with MirrorSTRC during the
migration, but that is a migration-window artifact — MirrorSTRC retires at §11 step 4,
after which vesting lives in exactly one place (the vault). Extracting a shared
`LinearVest` library for code that becomes single-use within the migration is an
abstraction over soon-to-be-single-use code. Inline it as the cash twin of the deployed,
audited `transferInRewards` pattern.

**Naming:** `transferInYield`, not `transferInUsdatYield`. The vault's `transferIn` is
always its own asset, so the `Usdat` prefix carries no information; and `transferInRewards`
retires with MirrorSTRC, so the surviving permanent inflow takes the clean name rather
than deferring to the legacy one. `transferInYield` vs `transferInRewards` reads as a
clear cash-vs-STRC distinction during the migration window, and "yield" stays
source-agnostic for future cash inlets. Companions: `getUnvestedYield()`,
`yieldVestingAmount`, `lastYieldTimestamp`, `yieldVestingPeriod`, `maxYieldBps`,
`sweepVestedYield()`.

---

## 5. Valuation: recognized value & oracles

### 5.1 Recognized value (the general pattern)

Every module turns its holdings into a USD figure the vault can sum. This is the
**valuation surface** of `IAccountingModule` — `recognizedValue()` + `isPaused()` — as
distinct from its **execution surface** (`buy()`/`sell()`, used only by rotations, §6.2);
both live on the one interface, but valuation never depends on execution. The vault never
prices anything itself — it only sums what modules report.

- **`recognizedValue()` = quantity × price**, in 6-decimal USD, rounded **Floor** (never
  over-count). Quantity comes from custody (a live `balanceOf(vault)` or an internal
  counter); price comes from the **module's own** oracle. There is no shared vault oracle —
  pricing is a per-module concern, and §5.2+ describe the STRCon module's.
- **The full NAV, in one place:**
  ```
  totalAssets() = usdatBalance
                + (yieldVestingAmount - getUnvestedYield())   // vested cash yield (§4.4)
                + Σ module.recognizedValue()
  ```
- **`recognizedValue()` never reverts.** It returns the latest mark even when stale — during
  an oracle freeze that *is* the last good price; during a genuine outage it is an old one.
  Reverting here would brick `totalAssets()` and the whole vault (exactly the failure §3.2.3
  removes); the gate is `isPaused()`, not a revert.
- **`isPaused()` is the gate, per module.** While any priced module reports `isPaused()`, the
  vault degrades deliberately (§3.2.3): **value-sensitive operations block** — mints
  (`maxDeposit`/`maxMint` → 0), rotations, and queue *processing* — because they would
  transact against an unreliable mark; **view-level operations stay alive** — share
  transfers, redemption *requests*, and claims of already-processed withdrawals. The
  aggregate rule is simply: *any priced module paused ⇒ value-sensitive ops blocked*.

Each module defines its own `isPaused()` predicate against its own price source; §5.4 gives
the STRCon module's (the two-signal pause/staleness rule).

### 5.2 The STRCon module's price source

- **`isPaused()` keys on exactly two signals** (detailed in §5.4): the oracle's **per-asset**
  pause — `getSValue(STRCon)` returns `(sValue, paused)` — and genuine feed staleness (no heartbeat). A
  frozen-but-heartbeating feed is **not** paused — the vault prices through it. Today's
  "revert on staleness" behavior is replaced by this deliberate degradation (§3.2.3).
- **Bounds must be sValue-aware.** Static $20–$150 bounds are wrong for a
  price-accumulating token that grows without bound. Either bound the *underlying* STRC
  feed and read sValue separately, or scale bounds by sValue. This is a glitch/manipulation
  sanity check — orthogonal to the pause logic, and wide enough not to trip on legitimate
  moves.
- **Feed choice → use "STRCon/USD (Ondo API)"** (proxy `0x67d4…cD91`), resolved from the
  June 15 data (§B.3). The Ondo feed tracks the reopen + overnight and **heartbeats ~24h** on
  a flat price through the weekend, so a ~26h staleness check stays satisfied and 24/7 minting
  works. The "Calculated" feed (equity × sValue) only prints in regular hours — it went **68h
  stale** over the weekend and missed the ex-event entirely, so it would block minting on
  staleness and is unusable for 24/7. The two agree to ~0.15% when both are fresh, so the
  Calculated feed is at most a sanity cross-check, never primary.

### 5.3 Existing StrcPriceOracle

Unchanged for MirrorSTRC. Retired when off-chain holdings reach zero.

### 5.4 When the vault can and can't use the STRCon price

§5.1 set the general rule: `recognizedValue()` never reverts, and `isPaused()` decides
whether the vault may transact. This section defines `isPaused()` for STRCon.

The vault keeps using the price as long as the feed is alive (heartbeating), even when the
market is closed. It stops in only two cases: Ondo sets the pause flag, or the feed dies.

| Situation | Feed | `isPaused()` | Vault |
|---|---|---|---|
| **Market closed** — weekend, after-hours, holiday | frozen, still heartbeating | no | uses the last price |
| **Trading pause / smoothing** — session changes, dividend moment (~10 min) | still updating | no | uses the price |
| **Oracle pause** — `getSValue(STRCon).paused` = true (a scheduled `CorporateAction`, not routine dividends) | frozen | **yes** | stops |
| **Outage** — feed stops updating | stale | **yes** | stops |

The two "frozen" rows are the subtle part: a closed market and an oracle pause can show the
exact same flat price, but the vault treats them oppositely. The difference is *why* the
price is frozen:

- **Market closed:** the frozen number is the last real trade. Nobody knows which way the
  price will move when the market reopens — it's ordinary stale-price risk, so we keep using
  it.
- **Oracle pause:** Ondo sets this flag only when it has scheduled a known, large price
  change. The frozen number is about to jump in a known direction, so minting against it is a
  guaranteed arb — we stop.

That's why the vault checks Ondo's pause flag, not a market-hours calendar: a closed market
is fine to price, a pending sValue change is not, and only the flag tells them apart.

**The cost we accept: weekend stale minting.** STRC stops trading Friday 8pm ET and reopens
Sunday 8pm ET, but the feed keeps reporting Friday's price the whole time (confirmed
2026-06-15: a ~24h heartbeat re-publishes the flat price, §B.3). So anyone who deposits over
the weekend mints at Friday's price. This already happens in the current vault.

This is a real edge, because the things that move STRC — BTC and Strategy's credit — trade
all weekend. Weekend news can make Monday open at a very different price. On Friday June 5
STRC was ~$94.2; Monday it opened **+2.0%**. A weekend depositor captures that 2% — roughly
20× the deposit fee, with no skill or timing. If Monday opens lower instead, the weekend
depositor is the one who loses, and `minShares` won't protect them because it is quoted off
the same stale price.

We accept this to keep minting 24/7. The deposit fee, async exits, and cash-buffer dilution
blunt it. The cum-dividend ex-window (§4.3) behaves the same way.

---

## 6. Liquidity, settlement, and allocation

The deployed `processRequests` does three jobs at once: it prices the claim, validates the
STRC sale, and sets portfolio composition. Multi-asset backing splits them into three
independent layers:

1. **What a redeemer is owed** — `previewRedeem(shares)`, a USD claim on blended NAV.
   Asset-agnostic; redeemers have no claim on any specific asset, only on value.
2. **Where the cash comes from** — the processor keeps the buffer funded by selling assets
   (§6.2). Redemptions never sell anything themselves.
3. **What the portfolio should hold** — the allocation policy the processor steers toward
   (§6.2).

The rest of this section is the general mechanism, with STRCon as the worked example.

### 6.1 Deposits — unchanged

Deposits work exactly as today: atomic, 24/7, into the USDat cash buffer. The depositor mints
at the live blended NAV (§5), and no asset is bought at deposit time.

Buying the asset is deliberately not coupled to the deposit. Ondo's venue is 24/5 with quote
spreads and pauses; coupling would make deposits revert nights, weekends, and during pauses.
Deposits sit in the buffer and the processor rotates them into assets on its own cadence
(§6.2). This is fair because the depositor already minted at the blended mark — un-rotated
cash earns nothing it didn't pay for. The only cost is **cash drag**, which is an allocation
problem, not a fairness one.

### 6.2 Asset allocation — asynchronous

All buying and selling of assets happens here, driven by the processor, never by a user.
Two entrypoints replace `convertFromUsdat`/`convertFromStrc`:

```
vault.buyVia(module, usdatIn, minAssetOut, venueData)
vault.sellVia(module, assetIn, minUsdatOut, venueData)
```

Each calls the module's own `buy()`/`sell()`, which own the venue. `venueData` carries
whatever the venue needs — for STRCon, the Ondo RFQ attestation and signature; for
MirrorSTRC, nothing, since its `sell()` is the legacy attested-bookkeeping pull. The module
checks its realized price against its own oracle, and `min*Out` bounds the call. So whichever
asset the processor picks is safe — the worst case is allocation drift within the caps below.

**An asset does not need to settle atomically.** The bar to add an asset is low:

- **Required:** it is priceable — `recognizedValue()` + `isPaused()` (§5). Pricing is all
  that NAV and the gates depend on.
- **Not required:** atomic settlement, an on-chain venue, 24/7 liquidity, or instant fills.

The vault never depends on a sale finishing in one transaction, because allocation is
asynchronous: deposits fund the buffer, the buffer absorbs timing, and the processor trades
on a cadence. STRCon *happens* to settle atomically (Ondo RFQ `redeemWithAttestation` → M0
`SwapFacility` → USDat, one tx), which is convenient but not load-bearing. An asset that
settles T+1 works the same way — `sell()` starts the sale, the USDat arrives whenever it
arrives, and nothing breaks. An illiquid asset only makes queue funding *slower* (§6.3),
never wrong. The one real constraint on a new asset is that you can mark it.

**Allocation policy is on-chain guardrails, not strategy.** Realized APY ≈ asset yield ×
allocation, so allocation is the yield knob. The two on-chain guardrails are `maxWeightBps`
per module (a hard concentration cap) and a global `minCashBufferBps`. A rotation may not
push a module above its cap or cash below the floor; inside that, the processor is free.
Target weights, sell-priority, and trade timing are off-chain strategy.

**Asymmetry: strict entering risk, lenient exiting it.** A cap may block a buy *into* an
asset; no floor may ever block a withdrawal. If the asset you'd rather sell is paused, sell
another and let the weights drift — drift is recoverable, a frozen withdrawal is a crisis.
`maxWeightBps` also caps the blast radius of a bad module or oracle. The cash floor governs
rotations and deposit deployment only; queue processing may draw the buffer to zero.

### 6.3 Redemptions — two paths

Exits are **NAV-clean**: priced off the vault's mark, never off a venue quote. (A
user-facing RFQ sale was rejected: it turns every mark-vs-quote gap into someone's loss and
puts four external liveness dependencies into the most trust-sensitive flow.) Redemptions
**never sell an asset** — selling only happens in allocation (§6.2). There are two paths.

**Path 1 — atomic buffer redemption (instant).** Burn shares, pay
`previewRedeem(shares) × (1 − instantExitFeeBps)` from the buffer immediately. Gated on module
liveness and capped per period against the standing buffer.

Path 1 buys what the queue doesn't: immediacy, and priority on a shared, finite resource — the
buffer every holder provisions and the processor refills later by rotating (paying spread). So
it carries its **own fee, separate from and at least as high as the queue's**. It recovers the
same deferred rotation slippage the queue fee does (the buffer gets refilled at a spread either
way), plus an **immediacy premium** that prices jumping the line and rations the buffer toward
holders who genuinely need to exit now. The per-period cap and this fee together decide how the
buffer is shared.

> ⚠️ **TODO — how to set `instantExitFeeBps`.** Should be ≥ the queue fee (same slippage, plus
> immediacy). Open: a flat premium over the queue fee, or **utilization-based** — rising as the
> buffer drains, so the last slice is the most expensive and is reserved for real need. And:
> does the premium stay in the vault (compensating the holders who provision the buffer) or go
> to `feeRecipient` as revenue (§7)?

> ⚠️ **TODO — reserved / whitelist access.** Think through whether integrator contracts (e.g.
> srUSDat) — or a whitelist more generally — get reserved capacity or priority on the
> instant path within the cap. Unsettled. If added, admission should be mechanical criteria,
> not a favor.

**Path 2 — the queue (the fallback).** Used when the buffer is exhausted, an asset is paused,
the exit is oversized, or the holder wants to wait for a better price. Same NAV-clean
pricing, applied at processing time.

For an atomic asset, the queue is funded and closed in one transaction:

```
// StakedUSDat, OPERATOR_ROLE, nonReentrant — single transaction
fundAndProcessRedemptions(SellLeg[] legs, uint256[] tokenIds)
  for leg in legs: _sellVia(leg.module, leg.assetAmount, leg.minUsdatOut, leg.venueData)
  WITHDRAWAL_QUEUE.processRequests(tokenIds)        // queue: vault-only caller
    for each request:
      payout = previewRedeem(request.shares) × (1 − redemptionFeeBps)
      if payout < minUsdatReceived → skip (stays queued)   // limit checked NET
    pull Σ(payouts) from the buffer + burn escrowed shares
    // held-back fee stays in the vault → NAV/share rises for remaining holders
```

It's one transaction because a sell followed by a separate processing tx leaves the fresh
proceeds in the buffer, visible in the mempool and frontrunnable by an atomic redemption.
Bundling leaves nothing to race. `processRequests` is callable **only by the vault**, so "the
queue can't race the buffer" holds by the call graph, not by convention.

**`legs` can be empty — and this is how non-atomic assets are handled.** When the buffer
already holds enough cash — from net deposits or from an async sale (§6.2) that has already
settled — the processor processes the queue straight from the buffer with no legs. So the
queue never requires an atomic asset; the bundled sell is just an optimization for the assets
that support it.

**Limit semantics.** Each request carries `minUsdatReceived`, making the queue a limit-order
book against NAV: a request fills at its limit or better, never worse. If NAV falls below the
limit, the request sits (skipped, not reverted) until NAV recovers or the holder lowers the
limit. This is also why raising the fee can't quietly take from queued holders — the limit is
checked on the net payout, so their requests just stop filling until they consent.

**Redemption fee — anti-dilution, not revenue.** Redeemers exit at the oracle mid, but the
rotations that refill the buffer realize mid minus the venue spread — a one-way drag on
remaining holders. `redemptionFeeBps` (configurable, hard-capped, default ≈ the measured
spread) recovers exactly that: the held-back amount stays in the vault, so the redeemer
covers their own exit cost and no one profits. It also serves as the stress lever — raise it
toward the cap instead of building emergency machinery.

**Residual trade-off (§9):** redeemers get the mark, not realized proceeds, so the
mark-vs-execution gap lands on remaining holders through rotations. The fee is the main
mitigant; rotation tolerance checks and unmet limits throttling exits in a falling market
bound the rest.

> ⚠️ **TODO — revisit before settling the fee.** The fee's job is to make exits
> process *at cost, on average*: the redeemer pays their own exit slippage, remaining holders
> are insulated. A flat `redemptionFeeBps` is a crude proxy — right on average, wrong on any
> single exit, and too small exactly when spreads blow out. Is there a better instrument?
> - **Pass-through** — charge the actual `mark − realized` of the sale that funded the exit.
>   Exact, but only defined when the redemption *triggers* a sale; the buffer path sells
>   nothing, so it still needs a fee. It also makes the payout unknown until the sale and lets
>   the processor's timing move what a redeemer gets — the user-facing-RFQ dynamic §6.3
>   rejected.
> - **Dynamic fee** — size it from recently observed rotation slippage (an on-chain EWMA of
>   `mark − realized`). Tracks real conditions instead of a guessed constant, keeps the queue
>   asset-agnostic. Likely the better middle ground.

The queue is fully asset-agnostic — its only couplings to the vault are `previewRedeem`,
share escrow/burn, and the funding pull, so adding an asset never touches it. (Dropped from
the deployed queue: `_validateTotals` and its triangulating checks, the
`executionPrice`/`totalStrcSold` params, and the oracle/`strcBalance`/`toleranceBps`
dependencies.)

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
| 1 | **Resolved: the vault contract can hold STRCon.** Mint/redeem eligibility (Saturn entity onboarded to Ondo) assumed complete — see §8.13. | Confirmed with Ondo |
| 2 | **Resolved: gross.** On-chain `SValueUpdated` (Jun 15): STRCon sValue **1.0096527 → 1.0198431**, a **+1.009%** step (the +0.0101904 absolute delta is what was first cited). +1.009% = gross dividend / post-drop price (~$0.95 / ~$94) — gross, not net-of-withholdings (~0.71% would be net). | Confirmed on-chain |
| 3 | **Mostly resolved (§B.3).** Event at 8pm ET on the ex-date; **no feed freeze** (printed 24s apart through it, even at a >1% bump); step small / inside the ±1% noise. Remaining: pin the residual step in bps via the equity feed. | Done via feed round-walk; equity-feed pull pending |
| 4 | **Resolved (§B.3): sparse.** ~6.6h between Ondo-feed prints in the quiet overnight session — it prints, but can carry a multi-hour-old mark. | Measured June 15 |
| 5 | **Resolved → Ondo API** (§5.2/§B.3). It heartbeats ~24h and tracks all sessions; Calculated went 68h stale over the weekend and missed the event. Calculated kept only as an optional sanity cross-check (agrees ~0.15% when both fresh). | Measured June 15 |
| 6 | Ondo mint/redeem mechanics for contracts: attestations, settlement time, quote spread, size limits (`GMTokenManager`) | Ondo docs/API + integration test |
| 7 | Residual-step estimate needs more ex-dates (n=2, equity-side only) | Accumulate monthly measurements |
| 8 | If STRC's monthly bump ever exceeds the **2% drift limit** (≈ a >24%/yr rate — far from today's 11.5%), dividends would cross into the corporate-action pause path. | Monitor `allowedDriftBps` vs the monthly bump |
| 9 | **Resolved — not missing.** On-chain, STRCon's sValue was already **~1.0096527 before the Jun 15 ex-date** (the pre-bump value in its `SValueUpdated`), so the May dividend was applied (≈+0.97% via the drift path). Ondo's "still 1.0 on Jun 11" was wrong. | On-chain |
| 10 | **Resolved (§B.3).** Routine dividends arrive via the oracle's **drift path** (`SValueUpdated`), so the per-asset `paused` stays false and the feed never freezes — confirmed at the Jun 15 bump. The pause flag (`getSValue(asset).paused`) only fires for scheduled `CorporateAction` events. | On-chain |
| 11 | **Resolved (§B.3):** the Ondo feed **heartbeats ~24h** on a flat price through the closure (not economically live, but the timestamp stays fresh). Set the STRCon staleness threshold ~**26h** to span the heartbeat (a 24h threshold false-trips); weekend mints then price the flat Friday mark — the accepted risk (§5.4). | Measured June 15 |
| 12 | **Resolved (§5.4):** exactly two signals — `getSValue(STRCon).paused` OR feed staleness — nothing else. Routine dividends use the drift path (no pause), so `paused` only fires for scheduled corporate actions (§8.10). | Decided; June 15 observed |

---

## 9. Risk register (summary)

- **Ondo issuer/structured-note risk** stacked on Strategy credit risk (new).
- **NAV volatility at feed granularity** (−6.6% week observed) now user-visible (§B.4).
- **Oracle pause/freeze windows** — handled by `isPaused()` gating; overnight gap open (§4.3).
- **Weekend stale-price minting — accepted by design** (§5.4): mints stay atomic at the
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

## 10. Other changes bundled with this upgrade

Cleanups shipped alongside the migration, independent of the multi-asset architecture.

### 10.1 Access-control roles

Least-privilege roles, each named for the **capability** it governs, not an actor. One address
may hold several at launch; the split lets dangerous powers move to slower/colder keys later.

Naming follows the OpenZeppelin / LayerZero convention: `bytes32 public constant <NAME>_ROLE =
keccak256("<NAME>_ROLE")`, where `<NAME>` is the *capability* — an agent noun (OZ:
`MINTER`/`PAUSER`/`OPERATOR`) or a `…_MANAGER` for configuration roles — never a Saturn team or
service. `DEFAULT_ADMIN_ROLE` stays the OZ root that grants/revokes the rest.

| Role | Gates |
|---|---|
| `DEFAULT_ADMIN_ROLE` | grant/revoke roles; UUPS upgrade |
| `MODULE_MANAGER_ROLE` | register / `setMaxWeight` / deregister modules (§3.4) |
| `PARAMETER_MANAGER_ROLE` | parameter setters — fees, vesting, tolerance, caps, cash floor, weights |
| `OPERATOR_ROLE` | rotations, `transferInYield`/`transferInRewards`, queue processing |
| `BLACKLISTER_ROLE` | blacklist add/remove (freeze only) |
| `ENFORCER_ROLE` | `redistributeLockedAmount` + `recall` — move a blacklisted holder's shares |
| `PAUSER_ROLE` | pause |
| `UNPAUSER_ROLE` | unpause |

Two separations are deliberate:

- **Freeze ≠ seize.** `BLACKLISTER_ROLE` only blacklists (freeze, reversible). Moving a frozen
  holder's funds — `redistributeLockedAmount` (to all holders) or `recall` (to a recovery
  address) — needs `ENFORCER_ROLE`. A compromised blacklister key can freeze but never drain.
- **Pause ≠ unpause.** A compromised `PAUSER_ROLE` can grief (pause) but cannot un-halt a
  legitimately paused vault; recovery needs the distinct `UNPAUSER_ROLE`.

Two renames carry an operational cost, since AccessControl keys membership by
`keccak256("<NAME>_ROLE")` — changing the string changes the id, so old grants don't carry:

- **`PROCESSOR_ROLE` → `OPERATOR_ROLE`** (OZ's canonical agent noun, replacing the deployed
  business-actor name; referenced in §1.1, §4.4, §6.3) and **`COMPLIANCE_ROLE` →
  `BLACKLISTER_ROLE`** both need an explicit re-grant in `StakedUSDat` *and*
  `WithdrawalQueueERC721`. This is free because §11 step 1 already ships new implementations and
  re-grants roles during migration — but it must be an explicit step, not assumed.

`STAKED_USDAT_ROLE` on the queue (a specific contract may call) is left as-is: it's the
capability/relationship pattern, like LayerZero's `MESSAGE_LIB_ROLE`, not an actor name.

### 10.2 Blacklist recall

A blacklisted holder can currently only be frozen (`BLACKLISTER_ROLE`) or have their shares
burned and redistributed to all holders (`redistributeLockedAmount`). **Recall** adds a third
option: an `ENFORCER_ROLE`, blacklisted-only function that transfers the holder's sUSDat to a
`to` address (e.g. court-directed recovery). It moves *shares* — no burn, no liquidity needed.

---

## 11. Migration sequencing (proposed)

Two steps. **Step 1** is the contract upgrade. **Step 2** is the STRC→STRCon migration
(`migrate()`). A diligence gate sits between them; cleanup follows.

### Step 1 — Framework upgrade

Swap both implementations, bring up the module framework, engage `MirrorSTRC` (holding today's
STRC), and register an empty `STRCon` module. Share price does not move.

**Test first, on a mainnet fork.** Run the upgrade by pranking the timelock, then assert:

- *No-op:* `totalAssets`, `previewRedeem`, `previewMint`, `convertToShares`, `getUnvestedAmount`
  identical pre/post, at three vesting states (fully unvested after `transferInRewards`,
  mid-vest, fully vested) via time-warp.
- *Behavior:* deposit → mint → requestRedeem → `fundAndProcessRedemptions` → claim pays
  `previewRedeem × (1 − fee)`; `transferInRewards` vests in the mirror; `transferInYield` vests
  then sweeps; a stale mirror oracle zeroes `maxDeposit` and blocks processing while transfers
  and redeem requests stay live.

**Steps**

1. Deployer EOA deploys: new `StakedUSDat` impl, new `WithdrawalQueueERC721` impl, `MirrorSTRC`
   module, `STRCon` module.
2. Set the timelock's `EXECUTOR_ROLE` to a known address (currently open). `PROPOSER_ROLE` calls
   `scheduleBatch(delay = 5 days)` with two payloads:
   - `sUSDat.upgradeToAndCall(sUSDatImpl, reinit)` — `reinit` reads the v1 STRC slots
     (`strcBalance` / `vestingAmount` / `lastDistributionTimestamp` / `vestingPeriod`), seeds
     `MirrorSTRC` from them, registers it, and re-grants the §10.1 roles. This is *inside* the
     batch because dropping the STRC leg for even one block would crash NAV.
   - `WQ.upgradeToAndCall(WQImpl, reinit)`.
3. Wait the 5-day delay.
4. Executor calls `executeBatch` with the same args — both proxies upgrade in one tx;
   `MirrorSTRC` is seeded and registered.
5. Verify the upgrade on-chain: no-op values match pre-upgrade; `MirrorSTRC.balance` == old
   `strcBalance` with vesting fields seeded; `OPERATOR_ROLE` / `BLACKLISTER_ROLE` re-granted on
   both contracts.
6. Register the `STRCon` module with `balance = 0` and its full-position cap; confirm
   `recognizedValue() == 0`.

`migrate()` (Step 2) follows after the diligence gate.

### Validation (before Step 2)

A small real round-trip through Ondo before committing the position (§8 item 6):

1. **Create** — in-kind create a small amount of STRCon from STRC; confirm it lands in Fireblocks.
2. **Sell** — sell it back to USDat through Ondo; confirm the exit and measure the spread (this
   is how redemptions get funded post-migration).
3. **Price** — send a small amount into the vault; confirm the `STRCon` module's
   `recognizedValue()` matches the feed mark and `isPaused()` reads correctly.

### Step 2 — `migrate()` (the in-kind flip)

Off-chain, Saturn converts the mirrored STRC into STRCon **in-kind** (Ondo creation), landing
the tokens in its Fireblocks wallet. MirrorSTRC keeps marking the position (attested, unchanged)
through the settlement window — Saturn carries the timing on its own books; the vault sees no
gap. When the STRCon is in hand, one `migrate()` tx performs the whole swap:

```solidity
// one-shot, MODULE_MANAGER_ROLE; reverts on second call
function migrate(uint256 expectedStrcon) external onlyRole(MODULE_MANAGER_ROLE) {
    require(!migrated, AlreadyMigrated());
    require(getUnvestedAmount() == 0, MirrorStillVesting());            // no vesting cliff
    uint256 navBefore = totalAssets();

    STRCon.safeTransferFrom(msg.sender, address(this), expectedStrcon); // vault takes custody
    strconModule.setBalance(expectedStrcon);                           // recognize STRCon (module already registered in Step 1)

    mirror.setBalance(0);                                              // mirror stops marking
    deregisterModule(address(mirror));                                // recognizedValue()==0 ⇒ allowed

    require(_within(totalAssets(), navBefore, migrateTolBps), NavStep()); // bounds the basis step
    migrated = true;
}
```

- **Atomic swap of recognition.** Before the tx the mirror counts and STRCon doesn't; after,
  STRCon counts and the mirror is gone. No double-count, no NAV gap, no vault pause.
- **Validates the conversion two ways:** the post-transfer custody invariant
  (`STRCon.balanceOf(vault) >= strconModule.balance()`) and the NAV-delta assert, which bounds
  the one-time oracle-basis step and reverts a botched in-kind ratio rather than mis-marking.
- **Vesting cliff avoided operationally:** stop `transferInRewards` ~one `vestingPeriod` (30d)
  before, so `getUnvestedAmount() == 0` holds at call time.
- **`strconCap` is sized for the full position**, not "conservative" — in-kind lands the whole
  leg at once, so STRCon is ~95% of NAV immediately; the cap blocks `buyVia`, not `migrate()`,
  but must be high enough that the first post-migration rotation isn't wedged (§6.2).
- **Submit privately** (MEV-protected) — the basis step is the only snipe surface and it's one
  known tx.
- STRCon delivery is **pull**: Fireblocks `approve(vault)`, then `migrate()` does the
  `transferFrom` — so the tokens enter and the counter is set in the same tx, no window of
  unrecognized STRCon sitting in the vault.
- If in-kind can't cover the full position (eligibility/size limits), the residual winds down
  by rotation (§6.2) — but the one-shot flip is the primary path, replacing the old
  attrition-first plan.

### Migration-only module code

Both modules need setters that write the recognized balance directly, bypassing `buy`/`sell`.
Vault-only, used solely by Step 1 `reinit` and Step 2 `migrate()`.

**MirrorSTRC**
- `seed(strcBalance, vestingAmount, lastDistributionTimestamp, vestingPeriod)` — vault-only,
  one-shot. Step 1 `reinit` calls it to reproduce the old STRC leg exactly.
- `setBalance(0)` — vault-only. `migrate()` calls it to drop the counter to 0; the vault then
  deregisters the module.

**STRCon**
- `setBalance(amount)` — vault-only, seed-once (`require(balance == 0)`); asserts
  `STRCon.balanceOf(vault) >= amount`. `migrate()` calls it to set the counter to the
  in-kind-delivered amount instead of going through `buyVia`.

### Cleanup

Retire the MirrorSTRC module — `migrate()` already deregisters it. `transferInRewards` and the
STRC vesting surface live *inside* the module (Step 1), so they retire with it; nothing
STRC-specific is left in the vault to strip out. `StrcPriceOracle` was the mirror's oracle and
is orphaned once the module is gone. The only vault-side change is an optional hygiene upgrade
dropping the spent one-shot `migrate()`.

### Future assets

New module per instrument, each with its own oracle and recognition policy.

---

## Appendix A — Ondo correspondence (2026-06-11)

Historical record from Kian and Matt Blumberg at Ondo. Some points are superseded by the §B.3
on-chain measurements (e.g. `sharesMultiplier` was already ~1.0097 before Jun 15, not 1.0).

- **Multiplier formula confirmed:** `tokenPrice = sharesMultiplier × stockPrice`. On the
  dividend event, the stock drops by the distribution amount and within a few minutes the
  system increases `sharesMultiplier` by `dividend / post-drop stock price` (e.g. +0.97%
  for a $0.96 distribution on a $99.04 post-drop price → token ≈ unchanged at ~$100).
  Kian's stated formula uses the **gross** dividend — no withholding haircut mentioned.
  This contradicts the public docs' "net of applicable tax withholdings"; confirm which
  applies to STRC (§8.2).
- **`sharesMultiplier` is still 1.0 as of 2026-06-11.** The June 15 ex-date will be the
  first adjustment ever for STRCon. Open question (§8.9): STRCon launched May 4 and the
  May 15 ex-date passed with no multiplier change — where did the May dividend go?
- **Dividend pause:** trading paused ~10 minutes before and after the distribution
  moment. Per Matt, the dividend snapshot is taken at **8pm ET on the ex-date**; the
  public corporate-actions doc says the pause is the evening *before* the ex-date. Exact
  window for June 15 to be confirmed empirically — watch both the June 14 8pm ET and June 15
  8pm ET windows (§B.3).
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
  (`/v1/assets/{symbol}/market-data`), in addition to the history endpoint in §B.1.

---

## Appendix B — Empirical findings (as of 2026-06-10)

### B.1 Data sources

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

### B.2 Ex-date behavior of STRC (raw prices, dividend $0.958/mo at 11.5%)

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
> is an open question (§8.9).
>
> **Update (2026-06-16):** on-chain `SValueUpdated` shows STRCon's sValue was already
> **~1.0096527 before Jun 15** and bumped to **1.0198431** on the ex-date (via the drift path).
> So the May dividend *was* applied (§8.9 resolved) and the multiplier was never 1.0 by June —
> Ondo's "still 1.0 on Jun 11" was wrong. See §B.3, §8.2.

### B.3 Feed coverage gap

Both Chainlink STRCon feeds went live **2026-05-20/21**, after the May 15 ex-date. The
June 15 ex-date was the first one observable on-chain — measured below. (It was *not*
STRCon's first sValue adjustment, as originally assumed: on-chain history shows the May
dividend had already been applied, §8.9. The bump landed at the Sunday 8pm ET reopen via
the drift path, not the "8pm-ET-on-the-ex-date" window the docs implied.)

**Measured (2026-06-15, from the Chainlink feeds):**

- **STRCon sValue bumped 1.0096527 → 1.0198431** — a **+1.009%** step (the +0.0101904
  absolute delta is the "0.01019…" figure first cited) — at **Jun 15 00:06 UTC (Sun ~8pm ET
  reopen)**, via an on-chain `SValueUpdated`: the **drift path**, not a corporate-action
  pause. +1.009% = gross dividend / post-drop price (~$0.95 / ~$94) → confirms the **gross**
  formula (§8.2). (STRCon's asset key in the oracle is `0xecabe1ff…`.)
- **sValue was already ~1.0097 pre-June**, so the May dividend was applied — Jun 15 was *not*
  the first-ever adjustment (§8.9). The separate **+1.68% feed jump at Jun 16 00:00 was
  stock**, not the multiplier (which had bumped 24h earlier).
- **No pause, no freeze.** Because the dividend came via the drift path, the per-asset
  `paused` stayed false and the feed kept updating normally through the bump — the
  corporate-action pause is only for scheduled large actions (§8.10).
- **Residual step small / in the ±1% noise:** the token stayed ~continuous through the bump
  (the +1.009% sValue rise offset by the ex-dividend stock drop); no clean exploitable step.
  Pinning it to bps needs the equity feed.
- **Feed choice → Ondo API.** It tracks the reopen and overnight and **heartbeats ~24h on a
  flat price** through the weekend closure (rounds 158/159 identical at 96.0497, 24h apart).
  The Calculated feed went **68h stale** over the weekend and missed the event entirely (only
  prints in regular hours). See §5.2/§8.5.
- **Overnight density sparse:** ~6.6h between prints in the quiet overnight session (§8.4).
- **On-chain state (Jun 16):** `getSValue(STRCon)` = **(1.0198431, paused=false)**; `assetData`
  → `allowedDriftBps = 200` (2%), `driftCooldown = 86400` (24h), `lastUpdate` = the Jun 15
  00:06 bump, `pauseStartTime = 0` (never paused). The Jun 15 00:06 `SValueUpdated` was the
  **only** sValue event in the window — confirming the Jun 16 +1.68% feed move was stock.

### B.4 Volatility

STRC fell ~$100 → $93.40 over 2026-06-01..05 (−6.6%) and recovered to ~$96–97. The feeds
oscillate continuously at their 0.5% deviation threshold. A mark-to-market vault will
carry this volatility in sUSDat NAV at feed granularity — a product/communication
consideration independent of any mechanism design, and it means the 10–30 bps residual
step must be estimated by averaging over multiple ex-dates.
