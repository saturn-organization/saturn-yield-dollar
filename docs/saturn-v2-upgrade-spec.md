# sUSDat Multi-Asset Backing & STRCon Migration — Design Spec

**Status:** Draft for discussion
**Date:** 2026-06-11
**Scope:** Migrating sUSDat's STRC exposure from off-chain mirrored holdings to on-chain
tokenized STRC (Ondo's STRCon), and generalizing vault accounting to support multiple
backing assets ("multi-asset digital credit").

> Single document while in design phase. At implementation time, split by lifecycle:
> a durable **multi-asset vault architecture** spec (§3–4, 6–8: module framework, yield
> recognition, the STRCon module, liquidity/settlement/allocation, fees) and a
> time-bound **STRC→STRCon migration plan** (§1–2, §5 the MirrorSTRC bridge, §11
> sequencing), archived when the migration completes.

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
  `rescueTokens` (§3.6).

So NAV moves only through authorized paths — an external transfer can't inflate the share price.

Token-less modules (MirrorSTRC) return `asset() == address(0)`: `balance()` is notional, priced
via their own oracle with no custody floor.

Each module owns its oracle wiring, yield-recognition policy, and venue execution.

`venueData` keeps the interface generic: for STRCon it carries the Ondo RFQ attestation +
signature; for MirrorSTRC it carries the attested execution price, and `sell()` decrements the
counter and pulls USDat from the processor. Each `buy`/`sell` enforces two guards: the module
validates the realized (or attested) price against its own oracle within tolerance, and
`minUsdatOut`/`minAssetOut` bounds the call. `buy`/`sell` are vault-only (§7.2); since the
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
  (oracles, venues, per-asset recognition); **the vault knows nothing about any asset but its own** — so smoothing inflows of its own denomination is vault business, handled by the cash yield inlet (§4.3), not a module.

### 3.3 Initial modules

| Module | Balance source | Pricing | Yield recognition |
|---|---|---|---|
| **MirrorSTRC** (migration bridge) | internal balance (seeded from current `strcBalance`/`vestingAmount` state) | StrcPriceOracle | `transferInRewards` + linear vesting (today's behavior, unchanged) |
| **STRCon** | tracked `balance` counter; invariant `STRCon.balanceOf(vault) ≥ balance` | Chainlink STRCon feed (§6) | **None** — mark to market. Dividend yield is already continuous in the token price (§4) |

The module system ships first with behavior identical to today (MirrorSTRC only); STRCon
is added when diligence completes. No flag-day migration.

### 3.4 Registration & the module registry

The vault owns the registry; `totalAssets()` iterates it (§3.5). State is an
`EnumerableSet.AddressSet` of *active* modules plus a parallel config mapping whose only
on-chain knob is the concentration cap (no target weight — §7.2):

```solidity
using EnumerableSet for EnumerableSet.AddressSet;

struct ModuleConfig {
    uint16 maxWeightBps;   // hard cap on this module's share of totalAssets()
}
EnumerableSet.AddressSet private _modules;        // active set; dense, no dead entries
mapping(address => ModuleConfig) public moduleConfig;
uint16 public minCashBufferBps;                   // global cash floor (§7.2)
```

The set is the authoritative membership record — there is no `registered` bool to drift out
of sync with the array. Deregistration is a real removal (swap-and-pop inside the set), so a
wound-down module leaves no dead entry for `totalAssets()` to iterate. Order is irrelevant: a
sum is commutative, and nothing else reads a stable on-chain order (sell-priority is off-chain,
§7.2).

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

`deregisterModule` requires zero recognized value (position wound down by attrition, §7.2) so
no backing is stranded, and clears the config so a later re-registration of the same address
can't inherit a stale cap. Membership checks are `_modules.contains(module)`.

**Cap = max ownership.** `maxWeightBps` bounds a module's share of NAV: a `buyVia` (§7.2)
reverts if it would push `module.recognizedValue() / totalAssets()` over the cap; sells are
never blocked (asymmetry, §7.2). It's also the blast-radius limit on a bad module/oracle.

> ⚠️ **TODO — bound the registry loop.** `totalAssets()` iterates `_modules` and calls every
> `recognizedValue()`, on the hot path (each deposit/redeem/preview/rotation). The set is
> admin-gated (not user-griefable), but still unbounded: enforce a hard cap on `_modules.length()`
> in `registerModule` and keep each `recognizedValue()` gas-bounded, so a large registry or one
> heavy module can't make
> `totalAssets()` too expensive to call.

### 3.5 Recognized value (the general pattern)

Every module turns its holdings into a USD figure the vault can sum. This is the
**valuation surface** of `IAccountingModule` — `recognizedValue()` + `isPaused()` — as
distinct from its **execution surface** (`buy()`/`sell()`, used only by rotations, §7.2);
both live on the one interface, but valuation never depends on execution. The vault never
prices anything itself — it only sums what modules report.

- **`recognizedValue()` = quantity × price**, in 6-decimal USD, rounded **Floor** (never
  over-count). Quantity comes from custody (a live `balanceOf(vault)` or an internal
  counter); price comes from the **module's own** oracle. There is no shared vault oracle —
  pricing is a per-module concern, and §6 describes the STRCon module's.
- **The full NAV, in one place:**
  ```
  totalAssets() = usdatBalance
                + (yieldVestingAmount - getUnvestedYield())   // vested cash yield (§4.3)
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

Each module defines its own `isPaused()` predicate against its own price source; §6.4 gives
the STRCon module's (the two-signal pause/staleness rule).

### 3.6 Rescuing untracked tokens

`rescueTokens` sweeps strays — tokens sitting in the vault that aren't recognized backing.
With multiple assets it can't hard-code the USDat legs; rescuable excess for any `token` is
its vault balance minus everything legitimately held: the cash legs when `token` is USDat
(`usdatBalance + yieldVestingAmount`, §4.3), plus `balance()` of every module whose
`asset() == token`.

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

The subtraction underflows only if a module reports `balance()` above custody, which the
invariant (§3.1) forbids — so a broken module reverts, not mis-rescues. A token-less module
(`asset() == address(0)`, MirrorSTRC) shields no real token, so stray STRC stays sweepable
even post-migration. (Cold-path; shares the unbounded-`_modules` caveat, §3.4.)

---

## 4. Yield recognition & dividend sniping

### 4.1 Recognition policy is per-module

Each module owns its yield-recognition policy (§3.5). There are two shapes, and the choice
turns on whether yield is already in the live price:

- **Marked-to-market (live-priced):** yield accrues continuously through the price, so it is
  recognized continuously — **no vesting**. Smoothing a live-priced asset would itself
  create an exploitable lag. STRCon is this shape (§6.1).
- **Discrete off-chain reward event:** yield arrives as a lump disconnected from the mark, so
  it **vests linearly** to stop deposit-sniping around the event. MirrorSTRC keeps this
  (`transferInRewards` + vesting, today's behavior); the vault-native cash inlet
  `transferInYield` is the same shape for USDat income (§4.3).

The rest of §4 is the asset-agnostic snipe analysis and the cash inlet; the STRCon
specifics (why it needs no vesting, its ex-date residual step) live in §6.

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

### 4.3 Cash yield inlet: `transferInYield`

Saturn's USDat float earns income (M0 treasury yield, incentives) independently of the
vault and wants to pass some back at its discretion — observed scale **>$50k every ~3
days**. One inlet serves all sources.

**Why vesting.** It stops the yield transfer from being sniped. Default **24h**, max ~7d.

**Mechanism.** Yield enters a segregated `yieldVestingAmount` leg — in the vault but out of
`usdatBalance` — and vests linearly over `yieldVestingPeriod`. `totalAssets()` counts only
the vested slice; `sweepVestedYield()` folds a fully-vested tranche into `usdatBalance` in
one step.

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

The yield gets its own leg because `usdatBalance` has many outflow paths: subtracting unvested
yield there would force an underflow guard into every one. Segregating it and adding back only
the vested slice keeps `usdatBalance` clean. `_sweepVestedYield()` also runs atop the
value-sensitive entrypoints (deposit/mint, redemption funding, rotations) and as a
permissionless poke, so a matured tranche becomes spendable without waiting for the next
`transferInYield`.

STRC vesting uses the opposite model: the amount sits inside `strcBalance` and the unvested
part is subtracted.

**Accepted micro-wart:** mid-vest the partially-vested slice is in NAV but not yet liquid, so a
large redemption sells a sliver of module while the sub-$50k slice waits for the next sweep —
no value lost, self-heals.

**Why vault-native, not a module.** USDat is the settlement asset, not backing: `usdatBalance`
is the most-written variable in the vault, and the only separable piece — vesting — is too thin
to justify a module's per-op cross-contract write.

---

## 5. The MirrorSTRC module

MirrorSTRC is the migration bridge: a **token-less** module (`asset() == address(0)`) that
mirrors Saturn's off-chain STRC. Its `balance()` is a processor-attested notional with no
custody floor; `recognizedValue()` prices it through `StrcPriceOracle`. It reproduces today's
behavior exactly and retires once the position is migrated to STRCon (§11).

### 5.1 Yield: `transferInRewards` + vesting

Unchanged from today. The monthly STRC dividend lands off-chain and is pushed in via
`transferInRewards` (OPERATOR_ROLE), vesting linearly over `vestingPeriod` (30d) to stop
deposit-sniping around the discrete reward. The vesting surface — `getUnvestedAmount`,
`vestingAmount`, `maxRewardsBps`, `StillVesting` — lives here, not in the vault.

### 5.2 Pricing: `StrcPriceOracle`

The deployed Chainlink wrapper (staleness + $20–$150 bounds). Unchanged; retired when off-chain
holdings reach zero.

### 5.3 Migration code

Vault-only setters that write the recognized balance directly, bypassing `buy`/`sell`:
- `seed(strcBalance, vestingAmount, lastDistributionTimestamp, vestingPeriod)` — one-shot; Step 1
  `reinit` calls it to reproduce the old STRC leg exactly.
- `setBalance(0)` — `migrate()` calls it to drop the counter to 0, after which the vault
  deregisters the module.

## 6. The STRCon module

STRCon is the durable backing module; this section gathers everything asset-specific to it —
yield recognition, pricing, the pause rule, and its migration setter. The general valuation
surface it implements (`recognizedValue()` + `isPaused()`) is §3.5.

### 6.1 Why STRCon needs no vesting

STRCon is price-accumulating: the dividend is reinvested into its `sValue` multiplier (§1.3),
so yield accrues continuously in the token price instead of arriving as a discrete payout. With
no reward event to smooth, STRCon is marked to market with no vesting — the
`transferInRewards`/vesting surface lives only in MirrorSTRC (§5.1).

### 6.2 The STRCon module's price source

price = equity feed × sValue

**STRCon/USD (Ondo API)** 
- Proxy `0x67d4Ae9f265270aE123c08D2657536771D19cD91`
- 8 decimals
- 24h heartbeat
- ~0.5% deviation threshold

**STRCon/USD (Calculated)** 
- Proxy `0xC353ac4b425f818Ad87E228bf816E15c2173AC07`
- 8 decimals
- 0.5% deviation threshold
- updates during regular market hours only — no weekend/overnight heartbeat (went 68h stale over the Jun 15 weekend)

**STRCon/USD (Ondo API)** heartbeats in a predictable manner and there for the right choice. We can set an onchain threshold to know if the oracle is stale.

### 6.3 The overnight-gap / cum-dividend mark (open)

At the 8pm ET ex-event `sValue` bumps immediately; until STRC actually trades ex-dividend, the
equity leg may still carry the cum-dividend price, so the STRCon mark is briefly high by ~one
dividend and a mint or processed redemption in that window overpays. The vault **prices
through** it (a live heartbeat is priceable, like the weekend stale-mint gap); Jun 15 showed the
residual step small with no freeze (§B.3), so this is provisional pending confirmation of the
window's size and duration with Ondo/Chainlink.

### 6.4 When the vault can and can't use the STRCon price

§3.5 set the general rule: `recognizedValue()` never reverts, and `isPaused()` decides
whether the vault may transact. This section defines `isPaused()` for STRCon.

The vault keeps using the price as long as the feed is alive (heartbeating), even when the
market is closed. It blocks mints and redemptions in only two cases: Ondo sets the pause flag,
or the feed dies. (Queue requests, claims of already-processed withdrawals, and share transfers
never price, so they stay live throughout — per the §3.5 gating rule.)

| Situation | Feed | `isPaused()` | Vault |
|---|---|---|---|
| **Market closed** — weekend, after-hours, holiday | frozen, still heartbeating | no | uses the last price |
| **Trading pause / smoothing** — session changes, dividend moment (~10 min) | still updating | no | uses the price |
| **Oracle pause** — `getSValue(STRCon).paused` = true (a scheduled `CorporateAction`, not routine dividends) | frozen | **yes** | blocks mints & redemptions; requests, claims, transfers stay live |
| **Outage** — feed stops updating | stale | **yes** | blocks mints & redemptions; requests, claims, transfers stay live |

A closed market and an oracle pause show the same flat price, so the vault keys on Ondo's pause
flag — not a market-hours calendar — to tell them apart: a closed market is safe to price
against (ordinary stale-price risk), a scheduled sValue change is not. (Pricing through a closed
market means weekend deposits mint at the stale Friday mark — an accepted cost, §9.)

### 6.5 Migration code

`setBalance(amount)` — vault-only, seed-once (`require(balance == 0)`), asserts
`STRCon.balanceOf(vault) >= amount`. `migrate()` calls it to set the counter to the
in-kind-delivered amount instead of routing through `buyVia` (§11).

---

## 7. Liquidity, settlement, and allocation

The deployed `processRequests` does three jobs at once: it prices the claim, validates the
STRC sale, and sets portfolio composition. Multi-asset backing splits them into three
independent layers:

1. **What a redeemer is owed** — `previewRedeem(shares)`, a USD claim on blended NAV.
   Asset-agnostic; redeemers have no claim on any specific asset, only on value.
2. **Where the cash comes from** — the processor keeps the buffer funded by selling assets
   (§7.2). Redemptions never sell anything themselves.
3. **What the portfolio should hold** — the allocation policy the processor steers toward
   (§7.2).

### 7.1 Deposits — unchanged

Deposits work exactly as today: atomic, 24/7, into the USDat cash buffer. The depositor mints
at the live blended NAV (§3.5), and no asset is bought at deposit time.

Buying the asset is deliberately decoupled from the deposit: Ondo's venue is 24/5 with quote
spreads and pauses, so coupling would make deposits revert nights, weekends, and during pauses.
Deposits wait in the buffer and the processor rotates them on its own cadence (§7.2); the only
cost is **cash drag**, an allocation problem.

### 7.2 Asset allocation — asynchronous

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

- **Required:** it is priceable — `recognizedValue()` + `isPaused()` (§3.5). Pricing is all
  that NAV and the gates depend on.
- **Not required:** atomic settlement, an on-chain venue, 24/7 liquidity, or instant fills.

Async allocation absorbs the timing, so the vault never needs a sale to finish in one tx.
STRCon *happens* to settle atomically (Ondo RFQ `redeemWithAttestation` → M0 `SwapFacility` →
USDat), but a T+1 or illiquid asset works the same — it only makes queue funding *slower*
(§7.3), never wrong.

**Allocation policy is on-chain guardrails.**  The two on-chain guardrails are `maxWeightBps`
per module (a hard concentration cap) and a global `minCashBufferBps`. A rotation may not
push a module above its cap or cash below the floor; inside that, the processor is free.
Target weights, sell-priority, and trade timing are off-chain strategy.

**Asymmetry: strict entering risk, lenient exiting it.** A cap may block a buy *into* an
asset; no floor may ever block a withdrawal. 
`maxWeightBps` also caps the blast radius of a bad module or oracle. The cash floor governs
rotations and deposit deployment only; queue processing may draw the buffer to zero.

### 7.3 Redemptions — two paths

Exits are **NAV-clean**: priced off the vault's marked price, never off a venue quote. 

**Path 1 — atomic buffer redemption (instant).** Burn shares, pay
`previewRedeem(shares) × (1 − instantExitFeeBps)` from the buffer immediately. Gated on module
liveness and capped per period against the standing buffer.

> ⚠️ **TODO — how to set `instantExitFeeBps`.** Should be ≥ the queue fee (same slippage, plus
> immediacy). Open: a flat premium over the queue fee, or **utilization-based** — rising as the
> buffer drains, so the last slice is the most expensive and is reserved for real need.

> ⚠️ **TODO — reserved / whitelist access.** Think through whether whitelist gets access or everyone can access the instant redemptions.

**Path 2 — the queue (the fallback).** Used when the buffer is exhausted, the exit is oversized, or the holder wants to wait for a better price. Same NAV-clean
pricing, applied at processing time but the user does not need to pay the instant redemption fee

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

It allows for a clean way to close positions in the queue without competing with the cash buffer but if there is a cash buffer we can access it rather than closing positions. 

**Limit semantics.** Each request carries `minUsdatReceived`, making the queue a limit-order
book against NAV: a request fills at its limit or better, never worse. If NAV falls below the
limit, the request sits (skipped, not reverted) until NAV recovers or the holder lowers the
limit. 

The current problem with the design is if we are not able to process users within the same day they could end up sitting in the queue for weeks until STRC repegs. 

**Redemption fee — anti-dilution, not revenue.** Redeemers exiting create a one way drag because closing a position has a cost. `redemptionFeeBps` charges the user a fee to close the position. The goal of this fee is to target at cost processing.

> ⚠️ **TODO — revisit before settling the fee.** The fee's job is to make exits process *at cost*. 
> Option 1: charge some flat fee that is configurable but constant. The average should cover redemptions at cost. 
> Option 2: calculate the actual cost of closing the positions. If a users position request a `sell()` then calculate the cost and charge as `redemptionFee`

The queue is fully asset-agnostic — its only couplings to the vault are `previewRedeem`,
share escrow/burn, and the funding pull, so adding an asset never touches it. 

(Dropped from
the deployed queue: `_validateTotals` and its triangulating checks, the
`executionPrice`/`totalStrcSold` params, and the oracle/`strcBalance`/`toleranceBps`
dependencies.)

---

## 8. Protocol fee (new requirement)

Today the dividend passes through Saturn's hands off-chain before `transferInRewards` —
an implicit fee/timing control point. With STRCon, 100% of the (post-withholding)
dividend auto-reinvests into the vault's position; **no moment exists where Saturn
touches the yield**. If Saturn wants a management/performance fee, it must be an explicit
on-chain mechanism 

Fee taxonomy: 

**deposit fee** → `feeRecipient` (revenue); 

**redemption fee** (§7.3) →
stays in the vault (cost recovery / anti-dilution, never revenue); 

**protocol fee on yield** → `feeRecipient` can recieve shares every so often in order to take a management fee on the vault. ⚠️ **TODO — decide on fee mechanism.** 

---

## 9. Risk register (summary)

- **Ondo issuer/structured-note risk** stacked on Strategy credit risk (new).
- **NAV volatility at feed granularity** (−6.6% week observed) now user-visible (§B.4).
- **Oracle pause/freeze windows** — handled by `isPaused()` gating; overnight gap open (§6.3).
- **Weekend stale-price minting — accepted by design** (§6.4): mints stay atomic at the
  last available print while the market is closed; observed weekend gaps ~2% vs 10 bps
  deposit fee. Accepted in exchange for 24/7 atomic minting; revisit if weekend-gap
  capture is observed in practice.
- **Redemption slippage socialization — mitigated by design** (§7.3): redeemers exit at
  the oracle mark; mark-vs-execution gaps land on remaining holders via rotations.
  Primary mitigant: configurable `redemptionFeeBps` paid back to the vault, sized to
  the measured Ondo spread, raised toward its cap in stress. Residual exposure: gap
  beyond the fee during stress; unmet limits throttle the first-exit dynamic.
- **Module registration = accounting god-mode** — admin-gated, upgrade-level review (§3.2).
- **Residual ex-date step** ~10–30 bps vs 10 bps deposit fee — fee sizing pending data (§4.2).
- **Withholding drag** — realized yield < 11.5% headline (quantify via §C.2).
- **Regulatory/eligibility** — qualified-investor restrictions on STRCon (§C.1).
- **Atomic-exit buffer dynamics** (§7.3): the capped buffer path is first-come
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
  business-actor name; referenced in §1.1, §4.3, §7.3) and **`COMPLIANCE_ROLE` →
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

A small real round-trip through Ondo before committing the position (§C item 6):

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
  but must be high enough that the first post-migration rotation isn't wedged (§7.2).
- **Submit privately** (MEV-protected) — the basis step is the only snipe surface and it's one
  known tx.
- STRCon delivery is **pull**: Fireblocks `approve(vault)`, then `migrate()` does the
  `transferFrom` — so the tokens enter and the counter is set in the same tx, no window of
  unrecognized STRCon sitting in the vault.
- If in-kind can't cover the full position (eligibility/size limits), the residual winds down
  by rotation (§7.2) — but the one-shot flip is the primary path, replacing the old
  attrition-first plan.

### Migration-only module code

The vault-only setters used by Step 1 `reinit` and Step 2 `migrate()` are documented with
their modules: MirrorSTRC's `seed(…)` and `setBalance(0)` (§5.3), STRCon's `setBalance(amount)`
(§6.5). All write the recognized balance directly, bypassing `buy`/`sell`.

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
  applies to STRC (§C.2).
- **`sharesMultiplier` is still 1.0 as of 2026-06-11.** The June 15 ex-date will be the
  first adjustment ever for STRCon. Open question (§C.9): STRCon launched May 4 and the
  May 15 ex-date passed with no multiplier change — where did the May dividend go?
- **Dividend pause:** trading paused ~10 minutes before and after the distribution
  moment. Per Matt, the dividend snapshot is taken at **8pm ET on the ex-date**; the
  public corporate-actions doc says the pause is the evening *before* the ex-date. Exact
  window for June 15 to be confirmed empirically — watch both the June 14 8pm ET and June 15
  8pm ET windows (§B.3).
- **STRC trades in all sessions**, including the 8pm–4am ET overnight session. The only
  scheduled unavailability is **weekends: Friday 8pm ET – Sunday 8pm ET**. This
  substantially mitigates the overnight-gap risk (§6.3) at the session level (print
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
> is an open question (§C.9).
>
> **Update (2026-06-16):** on-chain `SValueUpdated` shows STRCon's sValue was already
> **~1.0096527 before Jun 15** and bumped to **1.0198431** on the ex-date (via the drift path).
> So the May dividend *was* applied (§C.9 resolved) and the multiplier was never 1.0 by June —
> Ondo's "still 1.0 on Jun 11" was wrong. See §B.3, §C.2.

### B.3 Feed coverage gap

Both Chainlink STRCon feeds went live **2026-05-20/21**, after the May 15 ex-date. The
June 15 ex-date was the first one observable on-chain — measured below. (It was *not*
STRCon's first sValue adjustment, as originally assumed: on-chain history shows the May
dividend had already been applied, §C.9. The bump landed at the Sunday 8pm ET reopen via
the drift path, not the "8pm-ET-on-the-ex-date" window the docs implied.)

**Measured (2026-06-15, from the Chainlink feeds):**

- **STRCon sValue bumped 1.0096527 → 1.0198431** — a **+1.009%** step (the +0.0101904
  absolute delta is the "0.01019…" figure first cited) — at **Jun 15 00:06 UTC (Sun ~8pm ET
  reopen)**, via an on-chain `SValueUpdated`: the **drift path**, not a corporate-action
  pause. +1.009% = gross dividend / post-drop price (~$0.95 / ~$94) → confirms the **gross**
  formula (§C.2). (STRCon's asset key in the oracle is `0xecabe1ff…`.)
- **sValue was already ~1.0097 pre-June**, so the May dividend was applied — Jun 15 was *not*
  the first-ever adjustment (§C.9). The separate **+1.68% feed jump at Jun 16 00:00 was
  stock**, not the multiplier (which had bumped 24h earlier).
- **No pause, no freeze.** Because the dividend came via the drift path, the per-asset
  `paused` stayed false and the feed kept updating normally through the bump — the
  corporate-action pause is only for scheduled large actions (§C.10).
- **Residual step small / in the ±1% noise:** the token stayed ~continuous through the bump
  (the +1.009% sValue rise offset by the ex-dividend stock drop); no clean exploitable step.
  Pinning it to bps needs the equity feed.
- **Feed choice → Ondo API.** It tracks the reopen and overnight and **heartbeats ~24h on a
  flat price** through the weekend closure (rounds 158/159 identical at 96.0497, 24h apart).
  The Calculated feed went **68h stale** over the weekend and missed the event entirely (only
  prints in regular hours). See §6.2/§C.5.
- **Overnight density sparse:** ~6.6h between prints in the quiet overnight session (§C.4).
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

---

## Appendix C — Open questions / diligence

| # | Question | How to resolve |
|---|---|---|
| 1 | **Resolved: the vault contract can hold STRCon.** Mint/redeem eligibility (Saturn entity onboarded to Ondo) assumed complete — see §C.13. | Confirmed with Ondo |
| 2 | **Resolved: gross.** On-chain `SValueUpdated` (Jun 15): STRCon sValue **1.0096527 → 1.0198431**, a **+1.009%** step (the +0.0101904 absolute delta is what was first cited). +1.009% = gross dividend / post-drop price (~$0.95 / ~$94) — gross, not net-of-withholdings (~0.71% would be net). | Confirmed on-chain |
| 3 | **Mostly resolved (§B.3).** Event at 8pm ET on the ex-date; **no feed freeze** (printed 24s apart through it, even at a >1% bump); step small / inside the ±1% noise. Remaining: pin the residual step in bps via the equity feed. | Done via feed round-walk; equity-feed pull pending |
| 4 | **Resolved (§B.3): sparse.** ~6.6h between Ondo-feed prints in the quiet overnight session — it prints, but can carry a multi-hour-old mark. | Measured June 15 |
| 5 | **Resolved → Ondo API** (§6.2/§B.3). It heartbeats ~24h and tracks all sessions; Calculated went 68h stale over the weekend and missed the event. Calculated kept only as an optional sanity cross-check (agrees ~0.15% when both fresh). | Measured June 15 |
| 6 | Ondo mint/redeem mechanics for contracts: attestations, settlement time, quote spread, size limits (`GMTokenManager`) | Ondo docs/API + integration test |
| 7 | Residual-step estimate needs more ex-dates (n=2, equity-side only) | Accumulate monthly measurements |
| 8 | If STRC's monthly bump ever exceeds the **2% drift limit** (≈ a >24%/yr rate — far from today's 11.5%), dividends would cross into the corporate-action pause path. | Monitor `allowedDriftBps` vs the monthly bump |
| 9 | **Resolved — not missing.** On-chain, STRCon's sValue was already **~1.0096527 before the Jun 15 ex-date** (the pre-bump value in its `SValueUpdated`), so the May dividend was applied (≈+0.97% via the drift path). Ondo's "still 1.0 on Jun 11" was wrong. | On-chain |
| 10 | **Resolved (§B.3).** Routine dividends arrive via the oracle's **drift path** (`SValueUpdated`), so the per-asset `paused` stays false and the feed never freezes — confirmed at the Jun 15 bump. The pause flag (`getSValue(asset).paused`) only fires for scheduled `CorporateAction` events. | On-chain |
| 11 | **Resolved (§B.3):** the Ondo feed **heartbeats ~24h** on a flat price through the closure (not economically live, but the timestamp stays fresh). Set the STRCon staleness threshold ~**26h** to span the heartbeat (a 24h threshold false-trips); weekend mints then price the flat Friday mark — the accepted risk (§6.4). | Measured June 15 |
| 12 | **Resolved (§6.4):** exactly two signals — `getSValue(STRCon).paused` OR feed staleness — nothing else. Routine dividends use the drift path (no pause), so `paused` only fires for scheduled corporate actions (§C.10). | Decided; June 15 observed |

---
