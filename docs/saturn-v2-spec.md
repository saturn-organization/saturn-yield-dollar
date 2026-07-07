# sUSDat v2 — Technical Specification

**Status:** Draft 2 (rewrite of [draft 1](./saturn-v2-upgrade-spec-draft1.md))
**Date:** 2026-07-02
**Scope:** The v2 upgrade of `StakedUSDat` and `WithdrawalQueueERC721`: multi-asset backing
via accounting modules, the STRC → STRCon migration, and the withdrawal-queue rework.

Layout: §1 what changes, §2 the normative v2 spec, §3 the migration runbook, §4 open
questions, §5 risks. Appendix A records why choices were made; Appendix B the STRCon
empirical findings; Appendices C and D deferred features. When the migration completes, §3
and Appendix B archive; §2 and Appendix A remain the durable architecture doc.

---

## 1. What changes

v1 backs sUSDat with a processor-attested mirror of off-chain STRC holdings, priced by a
single hard-wired oracle, with redemptions settled against attested off-chain STRC sales.
v2 replaces the hard-coded STRC leg with pluggable per-asset accounting modules, moves the
position to on-chain tokenized STRC (Ondo's STRCon), and makes redemption settlement
NAV-clean from the vault's own buffer.

### StakedUSDat

| v1 | v2 |
|---|---|
| `strcBalance` mirror accounting, `_strcTotalAssets()` | module registry; `totalAssets()` sums `module.recognizedValue()` (§2.1–2.2). STRC leg lives in MirrorSTRC at upgrade, STRCon after migration |
| `convertFromUsdat` / `convertFromStrc` + `_validateConversion` | `buyVia` / `sellVia` (§2.5); price validation per-module |
| vault-global `toleranceBps`, `setTolerance` | per-module tolerance |
| hard-wired `StrcPriceOracle`, `getStrcOracle()` | per-module oracles (§2.3) |
| `transferInRewards` + STRC vesting surface | moves into MirrorSTRC (§2.3); retires with it |
| `burnQueuedShares(shares, strcAmount)` | `redeemQueuedShares(shares)` (§2.6) |
| `collectDust` | dropped — per-request settlement leaves no dust |
| oracle failure reverts `totalAssets()` and all views | same fail-closed reverts, kept deliberately; `maxDeposit`/`maxMint` catch and report 0 for ERC-4626 (§2.2) |
| — | `transferInSurplus` cash surplus inlet (§2.1) |
| deposit fee (`depositFeeBps`, fee-adjusted `previewDeposit`/`previewMint`) | dropped — deposits at plain NAV (§2.4) |
| — | management and redemption fees (§2.7) |
| — | `seize` (§2.8) |
| `PROCESSOR_ROLE`, `COMPLIANCE_ROLE` | capability-named role taxonomy (§2.8) |

Survives unchanged: the ERC-4626 core with async-redemption overrides (`withdraw`/`redeem`
disabled, `requestRedeem` — its limit param becomes `minSharePrice`), deposit variants
(permit/min-shares), blacklist + `redistributeLockedAmount`, `rescueTokens`
(generalized, §2.2), pause.

### WithdrawalQueueERC721

| v1 | v2 |
|---|---|
| `processRequests(tokenIds, totalUsdatReceived, totalStrcSold, executionPrice)` — batch pro-rata against an attested STRC sale | `processRequests(tokenIds)` — per-request, buffer-clamped partial fills, settled at NAV (§2.6) |
| `claim` + `claimBatch`/`claimAll`/`claimBatchFor`/`claimAllFor` | single `claim(tokenId)` (§2.6) |
| `_validateTotals`, `_isWithinTolerance`, `_validateAmount`, oracle/vault reads | dropped — the queue never prices; couplings are `convertToAssets` and `redeemQueuedShares` only |
| `lockRequests` / `unlockRequests`, `InProgress` | dropped — settlement is atomic at the live mark |
| `minUsdatReceived` (absolute payout bound) | `minSharePrice` (per-share execution-price limit, §2.6); pending entries converted in place at upgrade (§3.1) |
| dust flow (`approve` + `collectDust`) | dropped |
| `SlippageExceeded` revert on unmet limit | below-limit requests are skipped, not reverted |

Survives unchanged: request creation and share escrow, seizure paths, views, pause. Roles
renamed per §2.8.

### Removed functions

Flat list of deployed functions that do not exist in v2 (successor in parentheses).

**StakedUSDat:** `convertFromUsdat` / `convertFromStrc` (→ `buyVia`/`sellVia`),
`burnQueuedShares` (→ `redeemQueuedShares`), `collectDust`, `claim`, `claimBatch`,
`transferInRewards`, `getUnvestedAmount`, `setVestingPeriod`, `setMaxRewardsBps` (→ all four
move into MirrorSTRC), `setTolerance` (→ per-module), `getStrcOracle` (→ per-module oracles),
`setDepositFee` (no successor — deposit fee dropped).

**WithdrawalQueueERC721:** `lockRequests`, `unlockRequests`, `claimBatch`, `claimAll`,
`claimBatchFor`, `claimAllFor` (→ single `claim`), `updateMinUsdatReceived`
(→ `updateMinSharePrice`), and the view surface — `getRequest`, `getStatus`, `isClaimable`,
`getPendingCount`, `getTotalRequests` (→ the `requests` / `nextTokenId` public getters),
`getMyRequests`, `getUserRequests`, `getClaimable`, `getPending`, `getTotalPendingShares`,
`getPendingIdsInRange` (→ ERC721Enumerable views + multicall/events), plus the
`pendingCount` variable (no on-chain consumer). Remaining reads: the `requests` mapping,
`nextTokenId`, and inherited ERC721Enumerable.

---

## 2. V2 specification

Normative. Present tense; rationale in Appendix A.

### 2.1 Vault accounting

```
totalAssets() = usdatBalance
              + (surplusVestingAmount − getUnvestedSurplus())   // vested surplus
              + Σ module.recognizedValue()
```

All values 6-decimal USD. `usdatBalance` is idle USDat: the deposit inlet, the redemption
outlet, and the source/sink of rotations.

**Surplus inlet.** Saturn's USDat float earns income (M0 treasury yield, incentives)
independently of the vault; `transferInSurplus(amount)` (OPERATOR_ROLE) passes it back.
The amount enters a segregated `surplusVestingAmount` leg — in the vault but outside
`usdatBalance` — and vests linearly over `surplusVestingPeriod` (default 24h, max ~7d),
capped per tranche at `maxSurplusBps` of `totalAssets()`. One tranche at a time: a new
transfer requires the prior tranche fully vested. `_sweep()` folds a matured
tranche into `usdatBalance`; it runs atop value-sensitive entrypoints and as a
permissionless poke.

Invariants:
- `totalAssets()` counts only the vested slice of the surplus leg.
- `usdatBalance` outflow paths never touch `surplusVestingAmount`.

### 2.2 Module framework

A module is an accounting adapter for one backing asset. Custody stays in the vault;
modules hold no tokens.

```solidity
interface IAccountingModule {
    /// USD value (6 decimals) the vault recognizes now;
    /// REVERTS when the asset cannot be reliably priced (stale / out-of-bounds / tripwire);
    /// returns 0 without pricing when balance() == 0
    function recognizedValue() external view returns (uint256);
    /// the ERC20 custodied in the vault, or address(0) for a token-less module
    function asset() external view returns (address);
    /// recognized quantity of asset(), a counter — not a live balanceOf
    function balance() external view returns (uint256);
    /// acquire the asset with USDat (venueData: venue-specific, e.g. Ondo RFQ attestation)
    function buy(uint256 usdatIn, uint256 minAssetOut, bytes calldata venueData)
        external returns (uint256 assetOut);
    /// close position back to USDat
    function sell(uint256 assetIn, uint256 minUsdatOut, bytes calldata venueData)
        external returns (uint256 usdatOut);
}
```

`recognizedValue()` = `balance()` × the module's own oracle price, floor-rounded. `buy`/
`sell` are vault-only and are the only writers of `balance()`; each validates its realized
(or attested) price against the module's oracle within the module's tolerance, bounded by
`minAssetOut`/`minUsdatOut`, using per-call exact-amount approvals.

**Registry.** The vault owns an `EnumerableSet.AddressSet` of active modules plus per-module
config; `totalAssets()` iterates it.

```solidity
struct ModuleConfig { uint16 maxWeightBps; }        // hard cap on share of totalAssets()
uint16 public minCashBufferBps;                      // global cash floor

// all onlyRole(MODULE_MANAGER_ROLE)
registerModule(address module, uint16 maxWeightBps)  // reverts if _modules.length() == MAX_MODULES (5)
setMaxWeight(address module, uint16 maxWeightBps)
deregisterModule(address module)                     // only when balance() == 0 (never
                                                     // prices, so a dead oracle can't strand
                                                     // an empty module); real removal, config cleared
```

**Failure semantics — fail-closed by construction.** When a module cannot reliably price,
`recognizedValue()` reverts and the revert propagates through `totalAssets()` into every
value-sensitive path automatically: mints, queue processing, and rotations halt with no
gating code anywhere. Operations that never price — share transfers,
`requestRedeem`, `updateMinSharePrice`, `claim`, seizures — stay live by construction.
Downstream integrators pricing sUSDat via `convertToAssets`/`previewRedeem` inherit the same
protection: they halt rather than transact on a disputed mark. One ERC-4626 compliance
patch: `maxDeposit`/`maxMint` wrap `totalAssets()` in try/catch and return 0 on failure
(the `max*` functions must not revert).

**Rescue.** `rescueTokens(token, amount, to)` (DEFAULT_ADMIN_ROLE) sweeps only untracked
excess: vault balance minus the cash legs (when `token` is USDat) minus `balance()` of every
module whose `asset() == token`.

Invariants:
- **Custody floor** (token-backed modules): `asset().balanceOf(vault) ≥ balance()`. Excess
  custody is unrecognized — an external transfer cannot move NAV.
- NAV changes only through `buy`/`sell`, `transferInSurplus` vesting, deposits, and redemptions.
- A `buyVia` may not push a module above `maxWeightBps` or cash below `minCashBufferBps`;
  **sells are never blocked**. The cash floor governs rotations and deposit deployment only;
  queue processing may draw the buffer to zero.
- `recognizedValue()` reverts when unpriceable — no value-sensitive operation, in the vault
  or downstream, can transact against an unreliable mark.
- Deregistration requires `balance() == 0` — checked without pricing, so an empty module
  with a dead oracle is removable (the only recovery from a permanently failed oracle short
  of an upgrade).
- At most **5** modules (`MAX_MODULES`), so `totalAssets()` — on the hot path of every
  deposit/redeem/preview — stays gas-bounded.

### 2.3 Modules

**MirrorSTRC** (migration bridge; token-less, `asset() == address(0)`). `balance()` is a
processor-attested notional of off-chain STRC with no custody floor, priced through the
deployed `StrcPriceOracle` (Chainlink wrapper, staleness + $20–$150 bounds). Yield: the
monthly STRC dividend arrives off-chain and is pushed in via `transferInRewards(strcAmount)`
(OPERATOR_ROLE), vesting linearly over `vestingPeriod` (30d); the vesting surface
(`getUnvestedAmount`, `vestingAmount`, `maxRewardsBps`, `StillVesting`) lives here. Its
`sell()` decrements the counter and pulls attested USDat from the processor. Migration
setters (vault-only, bypass `buy`/`sell`): `seed(strcBalance, vestingAmount,
lastDistributionTimestamp, vestingPeriod)` one-shot; `setBalance(0)`.

**STRCon** (durable). Ondo Global Markets' tokenized STRC: a structured note backed 1:1 by
STRC shares, price-accumulating — dividends reinvest into the `sValue` multiplier
(`STRCon price = STRC price × sValue`), so yield is continuous in the token price.
`balance()` is a tracked counter under the custody-floor invariant. **No vesting** — the
position is marked to market.

- **Price source:** a wrapper over two Chainlink feeds. Primary — *STRCon/USD (Ondo API)*,
  proxy `0x67d4Ae9f265270aE123c08D2657536771D19cD91` (8 decimals, ~24h heartbeat): the
  recognized mark. Cross-check — *STRCon/USD (Calculated)*, proxy
  `0xC353ac4b425f818Ad87E228bf816E15c2173AC07` (prints regular market hours only): an
  independent path (exchange prints, not Ondo's API).
- **`getPrice()` — v1-style, reverts unless all of:**
  1. answer positive and within bounds (min/max, admin-adjustable — the mark compounds with
     sValue ~1%/mo, so the bounds need periodic raising);
  2. API feed fresh (staleness ~26h, spanning the 24h weekend heartbeat);
  3. Ondo's per-asset pause flag clear (`SyntheticSharesOracle.getSValue(STRCon).paused`,
     set only for scheduled corporate actions);
  4. **cross-feed deviation tripwire**: when the two feeds' prints are contemporaneous
     (`|api.updatedAt − calc.updatedAt| ≤ syncWindow`), require
     `|api − calc| ≤ deviationBps` of calc. Contemporaneous prints disagreeing beyond the
     threshold means an oracle pricing fault — halt. Non-contemporaneous prints (nights,
     weekends, pre-market — the Calculated feed prints regular hours only) are a clock skew,
     not a disagreement: the tripwire disarms and pricing is API-only, the accepted risk
     (§5). Stateless: a trip clears when live prints re-agree or the sync window closes;
     divergence that ends only because the session ended escalates to `PAUSER_ROLE`.
     Initial parameters `syncWindow` ~1h, `deviationBps` 200 (both-fresh agreement measured
     ~0.15%, Appendix B), admin-tunable.

  A closed market still heartbeats and is priced at the last mark; routine dividends ride
  the oracle's drift path and never trip (Appendix B). MirrorSTRC's `StrcPriceOracle` is
  already this shape — the deployed contract continues unchanged. The raw Chainlink feeds
  remain the public last-price layer: an integrator who wants last-print-with-own-policy
  reads them directly (the Midas two-layer pattern); sUSDat's own views bind to the
  validated read.
- Migration setter: `setBalance(amount)` — vault-only, seed-once (`require(balance == 0)`),
  asserts the custody floor.

### 2.4 Deposits

Atomic, 24/7, into the cash buffer at plain live NAV — no deposit fee. No asset is bought
at deposit time; the buffer is deployed by rotations. When any module can't price, deposits
revert (`maxDeposit`/`maxMint` report 0, §2.2).

Instant redemptions are **deferred** (Appendix D — design final); `withdraw`/`redeem` stay
disabled in v2 and the queue is the only exit.

### 2.5 Rotations

All buying and selling of backing assets. Processor-driven (OPERATOR_ROLE), never
user-triggered:

```
vault.buyVia(module, usdatIn, minAssetOut, venueData)
vault.sellVia(module, assetIn, minUsdatOut, venueData)
```

Each delegates to the module's `buy()`/`sell()` (§2.2 guards). On-chain policy is only the
guardrails (`maxWeightBps`, `minCashBufferBps`); target weights, sell-priority, and timing
are off-chain strategy. An asset need not settle atomically — async allocation absorbs
venue timing; slow assets only make queue funding slower, never wrong.

### 2.6 Withdrawal queue

Exits are NAV-clean: priced off the vault's mark, never a venue quote. Redeemers have a
claim on value, not on any specific asset.

**Request.** `requestRedeem(shares, minSharePrice)` on the vault escrows the shares in the
queue and mints an NFT. Minimum request `MIN_REQUEST_SHARES` (10 shares) — denominated in
shares, not assets, because `requestRedeem` never prices (§2.2 liveness; v1's 10-USDat
minimum required a `previewRedeem`):

```solidity
struct Request {
    uint256 shares;          // shares STILL QUEUED — decremented per fill
    uint256 usdatOwed;       // accrued, unclaimed payout
    uint256 timestamp;
    uint256 minSharePrice;   // limit: min execution price per 1e18 shares (v1 minUsdatReceived slot)
    RequestStatus status;    // legacy v1 slot; v2 logic neither reads nor writes it
}
```

Two derived states drive all logic — *open* (`shares > 0`) and *claimable* (`usdatOwed > 0`)
— and both can hold at once (a partially filled request). The original request size lives in
the `WithdrawalRequested` event; a token exists ⟺ `shares > 0 || usdatOwed > 0`.

**Limit semantics.** `minSharePrice` is the minimum execution share price
(`convertToAssets(1e18)`); the redemption fee is charged on the payout after the limit check.
The queue is a limit-order book against NAV: a request fills at its limit or better; below
the limit it is skipped, not reverted, and sits until NAV recovers or the holder lowers the
limit via `updateMinSharePrice` — freely updatable while open; a change applies to future
fills only (past fills are settled).

**Processing.** Funding and processing are separate: the operator tops up the buffer with
`sellVia` on its own cadence (sales are never earmarked for the queue), and settles requests
against one narrow vault primitive that **clamps to the buffer**. The operator passes
ordered tokenIds and no amounts; the buffer decides fill sizes:

```
// WithdrawalQueueERC721, OPERATOR_ROLE, nonReentrant
processRequests(uint256[] tokenIds)
  for each request:
    require request.shares > 0                              // dead token → revert (operator bug)
    if convertToAssets(1e18) < request.minSharePrice → skip   // limit not met (stays queued)
    (filled, usdat) = vault.redeemQueuedShares(request.shares)  // clamped: min(asked, buffer)
    if filled == 0 → break                                  // buffer dry — nothing later fills either
    request.usdatOwed += usdat
    request.shares    -= filled
  // held-back fee stays in the vault → NAV/share rises for remaining holders
```

```solidity
// StakedUSDat — queue-only; clamp, price, burn, transfer in one call
function redeemQueuedShares(uint256 sharesRequested) external onlyWithdrawalQueue
    returns (uint256 sharesRedeemed, uint256 usdat);
// sharesRedeemed = min(sharesRequested, what usdatBalance covers net of the fee)
// usdat = convertToAssets(sharesRedeemed) × (1 − fee), priced before the burn
// fee = elevatedFeeActive ? elevatedRedemptionFeeBps : baseRedemptionFeeBps — one tier per fill
```

Three outcomes per request, deliberately distinct: **revert** on a dead token (operator
bug), **skip** on an unmet limit (a later request may have a lower limit), **break** when
the buffer is dry. Clamping inside the vault means no amounts are computed anywhere else —
a concurrent buffer draw just shrinks the clamp, never reverts the batch — and each
fill floors independently in the vault's favor (a request filled in N slices receives at
most N wei less than one whole fill; no dust machinery).

`redeemQueuedShares` is safe against even a buggy queue: it burns only shares the queue
holds, at a price the vault computes, up to the buffer it has. When sell + process atomicity
is wanted (so no other buffer draw can front-run a fresh top-up), the operator batches
`sellVia` + `processRequests` in one tx from its own tooling.

**Claiming.** One function. `claim(tokenId)` pays the accrued `usdatOwed` and zeroes it;
the NFT burns only when the request is fully filled and drained (`shares == 0` after the
claim). A partially filled holder claims accrued payout anytime — never hostage to the
unfilled remainder. Integrator note: `Claimed` can fire multiple times per token, and a
claim does not imply a burn.

**Compliance.** `seizeRequest` transfers a blacklisted holder's live request NFT (accrued
`usdatOwed` and the open remainder travel with the token); `seize` seizes
accrued `usdatOwed`, burning the token only if fully filled — an open remainder keeps
accruing fills and stays seizable. Both single-token, ENFORCER_ROLE (§2.8).

Invariants:
- Every fill pays exactly `convertToAssets(filled)` net of fee at its own moment — NAV-neutral
  for remaining holders by construction (assets and shares leave proportionally), fee
  excepted — and satisfies the request's `minSharePrice` at that moment.
- Escrowed shares equal Σ `shares` over live requests; queue USDat equals Σ `usdatOwed`.
- The queue's only vault couplings: `convertToAssets`, `redeemQueuedShares`. Adding a backing
  asset never touches the queue.
- Escrowed shares remain NAV-exposed until burned — a request is a place in line, not a
  price commitment.

### 2.7 Fees

| Fee | Destination | Purpose |
|---|---|---|
| redemption fee (`baseRedemptionFeeBps` / `elevatedRedemptionFeeBps`) | stays in the vault | anti-dilution: exits process at cost on average. Two tiers set together (`setRedemptionFees`, PARAMETER_MANAGER, base ≤ elevated ≤ 500 — the limit check is pre-fee, so the cap bounds what user slippage protection doesn't cover); the operator selects the tier (`setElevatedFeeActive`, e.g. off-hours settlement, stress) but never the numbers; never revenue |
| management fee (`managementFeeBps`) | `feeRecipient` | revenue; **initial 50 bps/yr**, hard cap 200 |

**Tier mechanics.** `redemptionFeeBps()` (public view) returns the tier in effect;
integrators query it rather than re-deriving the selection rule. Each fill samples the tier
at its own moment (a mid-batch flip is NAV-movement semantics, not a race); a holder's worst
case is `limit × (1 − elevatedRedemptionFeeBps)`. `previewRedeem` stays gross
(= `convertToAssets`): with `redeem()` disabled, 4626 doesn't bind previews to the queue
fee, and a tier-flipping preview would destabilize integrators that read it as a price —
frontends quote net as `convertToAssets(shares) × (1 − redemptionFeeBps())`.

**Management fee.** A fixed fraction of assets per year, taken as pure supply dilution —
collection never reads a price:

```
collectManagementFee()   // permissionless
  f = managementFeeBps × (block.timestamp − lastFeeCollection) / 365 days
  mint to feeRecipient: totalSupply × f / (1e4 − f)
  lastFeeCollection = block.timestamp
```

The amount is time-determined — collection timing and frequency don't change the total — and
oracle-independent, so collection works even while pricing is down. The fee arrives as shares and
stays NAV-exposed until `feeRecipient` exits like any holder.

`setManagementFee` and `setFeeRecipient` collect first, so a rate change never applies
retroactively and accrued fees mint to the recipient they accrued under. `lastFeeCollection`
must be stamped whenever the fee turns on (initialize / §3.1 reinit) — unstamped with a
nonzero rate, the first collection mints decades of fees.

### 2.8 Roles

Capability-named (`keccak256("<NAME>_ROLE")`), one address may hold several; the split lets
dangerous powers move to colder keys.

| Role | StakedUSDat | WithdrawalQueueERC721 |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant/revoke roles; UUPS upgrade | same |
| `MODULE_MANAGER_ROLE` | register / `setMaxWeight` / deregister modules; `migrate()` | — |
| `PARAMETER_MANAGER_ROLE` | fees, vesting periods, caps, cash floor | — |
| `OPERATOR_ROLE` | rotations, `transferInSurplus`, `transferInRewards`, `setElevatedFeeActive` | `processRequests` |
| `BLACKLISTER_ROLE` | blacklist add/remove (freeze only) | — |
| `ENFORCER_ROLE` | `redistributeLockedAmount`, `seize` | `seizeRequest`, `seize` |
| `PAUSER_ROLE` / `UNPAUSER_ROLE` | pause / unpause | same |

The two contract-to-contract gates are not roles: `redeemQueuedShares` requires
`msg.sender == WITHDRAWAL_QUEUE` and `addRequest` requires `msg.sender == STAKED_USDAT` —
immutable address checks that no key can re-point or widen.

Deliberate separations: **freeze ≠ seize** (a compromised blacklister can freeze, never
move funds) and **pause ≠ unpause** (a compromised pauser can grief, not un-halt).

**`seize`** (new, ENFORCER_ROLE): transfers a blacklisted holder's sUSDat to a recovery
address (e.g. court-directed) — moves shares, no burn, no liquidity needed. Third option
beside freezing and `redistributeLockedAmount`.

---

## 3. Migration

Two steps: the framework upgrade, then the STRC → STRCon flip, with a diligence gate
between. Share price moves at neither step.

### 3.1 Step 1 — framework upgrade

Ships the module system with behavior identical to v1: MirrorSTRC holds today's STRC leg;
STRCon registers empty.

1. Deployer EOA deploys: new `StakedUSDat` impl, new `WithdrawalQueueERC721` impl,
   `MirrorSTRC`, `STRCon`.
2. Set the timelock's `EXECUTOR_ROLE` (currently open). `PROPOSER_ROLE` calls
   `scheduleBatch(delay = 5 days)`:
   - `sUSDat.upgradeToAndCall(impl, reinit)` — reads the v1 STRC slots (`strcBalance`,
     `vestingAmount`, `lastDistributionTimestamp`, `vestingPeriod`), seeds MirrorSTRC from
     them, registers it, re-grants §2.8 roles, and seeds the v2 params: `managementFeeBps`
     (50), **stamps `lastFeeCollection`** (§2.7 — unstamped with a nonzero rate, the first
     collection mints decades of fees), `surplusVestingPeriod` (24h), `maxSurplusBps` (250),
     the redemption fee tiers (per §4). Inside the batch: dropping the STRC leg for one block
     would crash NAV.
   - `WQ.upgradeToAndCall(impl, reinit)` — re-grants roles and converts every historical
     entry in place, scanning on-chain at execution time (the reinit calldata is fixed 5
     days before it runs, so a frozen id list would miss requests created during the
     delay). v1 never zeroed `shares`/`usdatOwed`, so each v1 status needs its own arm to
     satisfy v2's derived states (open = `shares > 0`, claimable = `usdatOwed > 0`):
     ```
     for id in 0..nextTokenId:                    // bounded by total historical requests
         switch requests[id].status:
             Requested, InProgress:               // shares genuinely still escrowed
                 req.minSharePrice = ceilDiv(req.minUsdatReceived × 1e18, req.shares)  // same slot
                 if req.status == InProgress: req.status = Requested
             Processed:                           // settled in v1, only the claim remains
                 req.shares = 0                   //  — else reads as open and would process
                                                  //    again, burning other requests' escrow
             Claimed:                             // NFT already burned, struct left populated
                 delete requests[id]              //  — restores token exists ⟺ shares|owed > 0
     ```
     `ceilDiv`: never weaker than the user's original bound. Don't lock requests once the
     batch is scheduled.
3. Wait 5 days; executor calls `executeBatch` — both proxies upgrade in one tx.
4. Verify on-chain: no-op values match pre-upgrade; `MirrorSTRC.balance` == old
   `strcBalance` with vesting fields seeded; roles re-granted on both contracts; pending
   queue entries carry converted limits, none `InProgress`; Processed entries hold only
   their claim (`shares == 0`) and Claimed entries are cleared; v2 params seeded and
   `lastFeeCollection` == upgrade timestamp.
5. Register STRCon with `balance = 0` and a full-position cap; confirm
   `recognizedValue() == 0`.

**Storage compatibility:** the queue's `Request` struct reuses the `minUsdatReceived` slot
as `minSharePrice`, and `shares` changes meaning from total to still-queued — v1 pending
entries conform as-is (nothing filled yet); Processed and Claimed entries do not (v1 left
their `shares`/`usdatOwed` populated) and are cleaned by the reinit arms above. The
`InProgress` enum variant stays (removing it would renumber `Processed`/`Claimed`) but is
never set again.

**Fork-test first** (prank the timelock):
- *No-op:* `totalAssets`, `previewRedeem`, `previewMint`, `convertToShares`,
  `getUnvestedAmount` identical pre/post at three vesting states (fresh
  `transferInRewards`, mid-vest, fully vested).
- *Behavior:* deposit → mint → `requestRedeem` → `sellVia` + `processRequests` (whole and
  buffer-clamped partial fills) → claim pays `convertToAssets × (1 − fee)` cumulatively across
  fills; `transferInRewards` vests in the
  mirror; `transferInSurplus` vests then sweeps; a stale mirror oracle zeroes `maxDeposit` and
  blocks processing while transfers and redemption requests stay live.

### 3.2 Validation gate (before Step 2)

A small real round-trip through Ondo: **create** STRCon from STRC in-kind (lands in
Fireblocks) → **sell** it back to USDat, measuring the spread → **price** a small amount in
the vault, confirming `recognizedValue()` matches the feed and reverts under a forced
tripwire/staleness condition.

### 3.3 Step 2 — `migrate()`

Off-chain, Saturn converts the mirrored STRC to STRCon in-kind (Ondo creation) into
Fireblocks; MirrorSTRC keeps marking through the settlement window (Saturn carries the
timing on its own books). Then one tx:

```solidity
// one-shot, MODULE_MANAGER_ROLE
function migrate(uint256 expectedStrcon) external onlyRole(MODULE_MANAGER_ROLE) {
    require(!migrated, AlreadyMigrated());
    require(getUnvestedAmount() == 0, MirrorStillVesting());
    uint256 navBefore = totalAssets();

    STRCon.safeTransferFrom(msg.sender, address(this), expectedStrcon); // pull delivery
    strconModule.setBalance(expectedStrcon);
    mirror.setBalance(0);
    deregisterModule(address(mirror));

    require(_within(totalAssets(), navBefore, migrateTolBps), NavStep());
    migrated = true;
}
```

- Atomic swap of recognition: no double-count, no NAV gap, no pause.
- Validated two ways: the custody floor post-transfer, and the NAV-delta assert (bounds the
  oracle-basis step; reverts a botched in-kind ratio).
- Operational: stop `transferInRewards` ≥ 30d before so the vesting precondition holds;
  size `strconCap` for the full position (in-kind lands ~95% of NAV at once); submit
  privately — the basis step is the only snipe surface.
- If in-kind can't cover the full position, the residual winds down by rotation.

### 3.4 Cleanup

`migrate()` already deregisters MirrorSTRC; `transferInRewards` and the STRC vesting surface
retire with it. `StrcPriceOracle` is orphaned. Optional hygiene upgrade drops the spent
`migrate()`.

---

## 4. Open questions

| # | Question | Blocks | Resolution path |
|---|---|---|---|
| 1 | Redemption fee tier numbers — base sized so the average exit processes at cost; elevated sized to off-hours/stress spread | fee params | measure Ondo spread, regular vs off-hours (§3.2 validation) |
| 2 | Residual ex-date step size (n=2, equity-only) — confirm it stays inside noise now that no deposit fee backstops it | risk acceptance | accumulate monthly measurements |
| 3 | Ondo mint/redeem mechanics for contracts: attestations, settlement time, size limits | STRCon module `buy`/`sell` | Ondo docs + §3.2 |

---

## 5. Risk register

- **Ondo issuer/structured-note risk** stacked on Strategy credit risk (new).
- **NAV volatility at feed granularity** — −6.6% week observed (Appendix B) — now
  user-visible; product/communication concern.
- **Weekend stale-price minting — accepted:** mints stay atomic at the last print while the
  market is closed (~2% observed weekend gaps, unmitigated — v2 charges no deposit fee), in
  exchange for 24/7 atomic minting. Revisit if gap-capture is observed.
- **Redemption slippage socialization — mitigated:** redeemers exit at the mark;
  mark-vs-execution gaps land on remaining holders via rotations. Mitigant: the base
  redemption fee sized to the measured spread, the elevated tier flipped on for off-hours
  settlement and stress; residual exposure beyond the fee remains.
- **Oracle-halt downtime:** when the STRCon wrapper reverts (staleness, bounds, Ondo flag,
  or deviation tripwire), all pricing views brick for the duration — including for
  integrators (a lending market can't liquidate against sUSDat while tripped). Chosen
  deliberately over serving a disputed mark; the deviation tripwire adds revert surface v1
  never had, sized by `syncWindow`/`deviationBps` and tuned from measured feed data.
- **Module registration = accounting god-mode:** a malicious module inflates NAV and drains
  the vault. `MODULE_MANAGER_ROLE` gated; treat with UUPS-upgrade gravity. `maxWeightBps`
  bounds the blast radius of a bad module or oracle.
- **Parked limit orders:** a request with `minSharePrice` above NAV sits unfilled
  indefinitely — by design, but holders may not realize; remedy is lowering the limit.
- **Regulatory/eligibility:** STRCon is restricted to qualified non-US investors.

---

## Appendix A — Design rationale

Why the §2 choices were made, including rejected alternatives.

**Pluggable modules instead of the hard-coded STRC leg.** `strcBalance` as self-reported
bookkeeping was the system's largest trust assumption (processor constrained only by oracle
± tolerance); on-chain STRCon makes the position verifiable custody. And a single hard-coded
balance + immutable oracle doesn't generalize to sUSDat's direction — a token backed by
multiple forms of digital credit. Modules isolate what is asset-specific (oracle, venue,
recognition policy); the vault knows nothing about any asset but its own.

**Custody in the vault, not in modules.** Avoids asset fragmentation and keeps
compliance/seizure in one place. Modules are pure accounting adapters.

**`balance()` as a counter, not `balanceOf`.** If recognition tracked live custody, a stray
transfer would inflate NAV. The counter moves only through `buy`/`sell`, so NAV moves only
through authorized paths; `balanceOf` is merely a floor.

**Revert on unpriceable, not a pause flag.** An `isPaused()`-and-last-mark design was
considered and rejected. Its real benefit was only view liveness during an outage (in v2
nothing user-critical prices: transfers, `requestRedeem`, and `claim` stay live under either
design), and it carried two costs. Inside the vault, a gate must be remembered at every
value-sensitive entrypoint — a forgettable-bug class — where a revert propagates fail-closed
automatically. Downstream, integrations built on v1 inherit its revert semantics: they treat
"can't read a price" as "halt." Serving a last mark instead would have them transact —
liquidate, borrow, rebalance — against a price the vault itself considers unreliable. Wrong
price is strictly worse than no price for collateral. This matches deployed practice: Midas
reverts through its validated `DataFeed` in mint/redeem while its raw aggregator stays
publicly readable, and Morpho documents reverting oracles as an intended fail-closed
integration mode (halting `borrow`/`withdrawCollateral`/`liquidate`). The one liveness patch
kept: `maxDeposit`/`maxMint` catch and report 0, per ERC-4626.

**Two-feed STRCon oracle.** The Ondo API feed is single-source — Ondo's own API into
Chainlink — so alone it concentrates pricing trust in the issuer. The Calculated feed derives
from exchange prints: an independent failure domain, but it prints regular market hours only.
Hence the tripwire arms on *contemporaneous prints* (timestamps within `syncWindow`), not on
wall-clock freshness: two live prints disagreeing is an oracle pricing fault and must halt;
a fresh API print differing from a hours-old Calculated print measures elapsed time, not
disagreement — an always-on comparison would false-trip every after-hours session. The trip
is evaluated statelessly rather than latched: latching needs storage writes from the price
path and a clearing flow, while the hole it closes (divergence that "clears" only because
the session ended) is what `PAUSER_ROLE` escalation covers.

**Mark-to-market for STRCon; no vesting.** Vesting exists to smooth *discrete* reward events
(deposit-sniping around a predictable jump). STRCon's dividend is already continuous in the
token price via `sValue`; smoothing a live-priced asset would itself create an exploitable
lag. General snipe defenses, in order: mark to a live price; gate on price reliability, not
the calendar (no hard-coded market-hours windows); redemptions stay async and priced at
execution. The small residual ex-date step (~10–30 bps measured, Appendix B) is accepted
unmitigated — v2 charges no deposit fee; monitor per §4.

**Deposits decoupled from buying.** Ondo's venue is 24/5 with spreads and pauses; coupling
would make deposits revert nights and weekends. The cost is cash drag — an allocation
problem, handled by rotations.

**`transferInSurplus` vault-native, not a module.** USDat is the settlement asset, not
backing; `usdatBalance` is the most-written variable in the vault, and vesting alone is too
thin to justify a module's per-op cross-contract write. Segregating the vesting leg (rather
than subtracting unvested from `usdatBalance`) keeps every `usdatBalance` outflow path free
of underflow guards.

**Funding ≠ processing.** A combined `fundAndProcessRedemptions(legs, tokenIds)` was
considered and rejected: a sale precedes processing either way, so redeemers exit at
post-sale NAV regardless — fusing changes nothing about who bears the venue spread (only the
fee does), and operator tooling can batch the two calls when atomicity matters. Fusing also
would have been the only way to charge *exact* realized cost per request (fee Option 2);
with it rejected, the flat fee is the working assumption.

**Per-request settlement, not batch-and-sum.** v1's batch totals existed because one
external pot of USDat had to be distributed pro-rata. With the vault pricing each redemption
itself, per-request settlement gives an exact amount per request — no pro-rata math, no dust,
no cross-request coupling — and enables skip-not-revert for unmet limits. Sequential fills
settle at the same price anyway: each redemption removes assets and shares proportionally,
so the share price is unchanged across a batch.

**Queue-side entry with a narrow vault primitive.** The alternative — vault-side processing
that loops queue state — either enforces the queue's invariants across a contract boundary
or delegates back to the queue anyway. `redeemQueuedShares` is instead made minimal and
safe against a buggy queue: burns only shares the queue holds, at a vault-computed price,
up to the existing buffer. Trust flows one way and it's narrow — strictly better than v1's
`burnQueuedShares`, which took processor-supplied amounts the vault had to trust.

**Locks removed.** `lockRequests`/`InProgress` protected an in-flight off-chain execution
window (lock → sell STRC over hours → settle at attested price). Atomic settlement at the
live mark has no such window.

**`minSharePrice` instead of `minUsdatReceived`.** A per-share limit means the same thing
regardless of order size, is directly comparable to the live share price, and composes with
partial fills with no proration — an absolute bound would need prorating per fill. The limit
is checked on the gross execution price with the fee charged after, matching the mental
model: get execution, check limit, pay fee. Migration converts pending entries in place
(`ceilDiv(minUsdatReceived × 1e18, shares)`) because the bounds are exactly equivalent in
per-share form — rejected alternatives: zeroing legacy bounds (silently converts user limit
orders to market orders) and era-branching on tokenId (a permanent dual-semantics branch for
as long as one legacy limit order sits, which can be indefinitely).

**Buffer-clamped partial fills.** Settlement capacity is the buffer, so processing is
amount-driven: the vault clamps each fill to what its buffer covers, the operator passes
ordered ids and no amounts, and no fill size is computed anywhere else — a concurrent buffer
draw shrinks the clamp instead of reverting the batch. Two design choices keep the cost low.
*`shares` decrements instead of a `sharesFilled` field*: the struct is unchanged, "open" is
`shares > 0`, and v1 pending entries conform as-is (nothing filled yet); the original size
lives in the request event. *One `claim` function*: the batch/`claimAll`/`*For` family
multiplied every lifecycle change across five functions; with claim-accrued-anytime
semantics, a single `claim(tokenId)` is the whole surface. Alternatives considered:
whole-request-only processing (simplest, but a request larger than the achievable buffer
waits on days of accumulated cash drag); operator-passed `fillShares` (exact but racy —
precomputed amounts revert when the buffer moves); splitting requests at creation into
capped chunks (the cap only approximates amount-driven filling; large orders mint N
enumerable NFTs); queue-level finalization checkpoints à la Lido (O(1) processing, but a
watermark can't sweep past a parked `minSharePrice` limit order). The accepted residual
cost: a non-linear request lifecycle — open and claimable coexist, `Claimed` fires
repeatedly per token, claim does not imply burn — which integrators must handle.

**Management fee.** With STRCon the dividend auto-reinvests on-chain — no off-chain
touchpoint exists, so the protocol fee must be an explicit mechanism. Supply dilution keeps
it time-determined and oracle-free (§2.7).

**Flat redemption fee, two tiers.** Exact per-request cost attribution is a policy choice
dressed as a measurement (which module was sold? how much was buffer refill?) and required
fusing funding with processing. A flat fee sized to the measured spread achieves at-cost on
average. Two governance-set tiers (base/elevated) let settlement continue through
higher-spread windows (off-hours, stress) at a fee that matches: the operator — who already
times processing — selects the tier but never the numbers, and the state is explicit
(`setElevatedFeeActive(bool)`), not a toggle, so scheduled flips are idempotent under tx
retries. An automated session signal (feed-freshness of the Calculated print) was considered
and rejected as machinery the operator's existing scheduling duty doesn't need.

**Role taxonomy.** Names follow the OZ/LayerZero capability convention (agent nouns /
`…_MANAGER`), never team or service names. Freeze ≠ seize and pause ≠ unpause bound the
blast radius of any single compromised key. Renames change the role id
(`keccak256` of the string), so §3.1 re-grants explicitly. The contract-to-contract gates
(`addRequest`, `redeemQueuedShares`) are immutable address checks rather than roles: the
counterpart proxy address never changes, and a role would only add a way for a compromised
admin to widen access.

**One-shot in-kind `migrate()` over attrition.** Rotating the position out through
`sellVia` over weeks would pay the venue spread on the whole book and hold a mixed state
throughout. In-kind creation swaps recognition atomically at zero spread, with the NAV
assert bounding the one-time oracle-basis step.

---

## Appendix B — STRCon empirical findings

Conclusions from on-chain measurement (primarily the 2026-06-15 ex-date, the first
observable on Chainlink feeds) and Ondo correspondence. Stated as final facts; dates are
measurement dates.

**Dividend mechanics (measured Jun 15).**
- `sValue` bumped **1.0096527 → 1.0198431 (+1.009%)** at Jun 15 00:06 UTC (Sunday ~8pm ET
  reopen), via an on-chain `SValueUpdated` — the oracle's **drift path** (limits: 2% per
  24h), not a corporate-action pause. The feed never froze; per-asset `paused` stayed false.
- +1.009% = **gross** dividend / post-drop price (~$0.95 / ~$94) — no withholding haircut in
  the multiplier (net would be ~0.71%); withholding shows up as realized-yield drag instead.
- The May dividend had already been applied (pre-June sValue ~1.0097) — Ondo's claim that
  the multiplier was still 1.0 on Jun 11 was wrong; trust the chain, not the correspondence.
- The bump lands at ~8pm ET when the overnight session reopens, simultaneous with the
  underlying's ex-dividend reprice.
- If STRC's monthly bump ever exceeded the 2% drift limit (≈ >24%/yr rate), dividends would
  cross into the corporate-action pause path — monitor.

**Ex-date behavior of the underlying** (raw prices; dividend $0.958/mo at 11.5%):

| Ex-date | Close before | Ex-date close | Drop | Residual step |
|---|---|---|---|---|
| 2026-04-15 | 100.00 | 99.32 | −$0.68 | ~+28 bps |
| 2026-05-15 | 100.00 | 99.19 | −$0.81 | ~+15 bps |

STRC drops by ~70–85% of the dividend on ex-date — normal preferred-stock behavior, not
pinned-at-par. Combined with the sValue bump, the STRCon price is approximately continuous
through the event with a residual upward step of roughly **10–30 bps** — inside daily
noise (±1%), no cleanly exploitable step observed. n=2,
equity-side; keep measuring (§4).

**Feed roles → API as mark, Calculated as cross-check** (§2.3). The API feed
(`0x67d4Ae9f…cD91`) tracks all sessions and **heartbeats ~24h on a flat price through the
weekend closure**; set staleness at ~26h so the weekend doesn't false-trip. The *Calculated*
feed (`0xC353ac4b…AC07`) prints only in regular hours — it went **68h stale** over the
Jun 15 weekend and missed the event — so it can't be the mark, but agrees ~0.15% when both
are fresh, which sizes the deviation tripwire. Overnight print density on the API feed is
sparse (~6.6h between prints in the quiet session) — it can carry a multi-hour-old mark.

**Session structure (Ondo).** STRC trades all sessions including overnight; the only
scheduled closure is **Friday 8pm ET – Sunday 8pm ET**. Ondo pauses trading for a few
minutes around session transitions, but **the oracle keeps updating through venue pauses**
(Chainlink session-aware smoothing) — hence the wrapper's checks are defined against feed
behavior, never venue behavior or a market-hours calendar.

**Volatility.** STRC fell ~$100 → $93.40 over 2026-06-01..05 (−6.6%), recovered to ~$96–97;
the feeds oscillate continuously at their 0.5% deviation threshold. sUSDat NAV carries this
at feed granularity.

**Open (Jun 15 residue).** The ~10-minute window at the 8pm ET ex-event where the equity leg
may still carry the cum-dividend price while sValue has bumped: the vault prices through it
(a live heartbeat is priceable); measured residual was small, but pin the window's size with
Ondo/Chainlink as more ex-dates accumulate.

**Data sources.**

| What | Where |
|---|---|
| STRCon/USD (Ondo API) Chainlink feed | `0x67d4Ae9f265270aE123c08D2657536771D19cD91`, 8 dec, ~24h heartbeat, ~0.5% deviation |
| STRCon/USD (Calculated) Chainlink feed | `0xC353ac4b425f818Ad87E228bf816E15c2173AC07`, 8 dec, regular hours only |
| Ondo `SyntheticSharesOracle` (Ethereum) | `0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6` — `getSValue(asset)`, drift params (2% / 24h) |
| Ondo `GMTokenManager` (mint/redeem) | `0x2c158BC456e027b2AfFCCadF1BDBD9f5fC4c5C8c` |
| sValue history API (needs `x-api-key`) | `GET https://api.gm.ondo.finance/v1/assets/STRCon/shares-multiplier?range=all`; also the market-data endpoint |
| STRC daily OHLC | stockanalysis.com **raw** prices (Yahoo returns dividend-adjusted prices that erase ex-date drops — do not use) |

---

## Appendix C — Deferred: in-kind minting (`depositInKind`)

Minting sUSDat directly with STRCon is out of scope for v2, deferred to a later upgrade.
Nothing in v2 forecloses it: the vault is UUPS, the module hook is a module-side addition,
and it reuses the whitelist role and fee pattern of Appendix D. Until it's built,
`IAccountingModule` stays at the five §2.2 functions. Trigger to build: a concrete OTC
counterparty.

**For anonymous users the answer is periphery, not the vault** — a wrapper that sells
STRCon on venue and deposits the cash. The user eats the spread and the timing risk at a
real execution price; the vault needs no changes and extends no trust. A vault-native path
exists only for large entries where the venue spread matters, and only whitelisted.

**Agreed shape** — the mirror image of instant redemption (Appendix D):

```
// WHITELISTED only, per-period capped
depositInKind(address module, uint256 assetIn, uint256 minShares, address receiver)
  usdValue = module.creditInKind(assetIn)        // module prices at its own oracle, increments balance()
  asset.safeTransferFrom(caller, vault, assetIn) // custody lands in the vault; assert custody floor
  check module ≤ maxWeightBps post-credit        // same guard as buyVia
  shares = convertToShares(usdValue × (1 − inKindFeeBps))   // priced on pre-credit totalAssets
  require shares ≥ minShares; mint to receiver
```

Pricing stays in the module (`creditInKind` marks at the module's validated oracle, so a
tripped oracle reverts the whole path with no gating code); value is computed on pre-credit
`totalAssets()` — standard ERC-4626 deposit ordering. `creditInKind` is a second writer of
`balance()` beside `buy`/`sell` — the real cost of the feature: the §2.2 invariant weakens
from "buy/sell only" to "vault-authorized module calls only."

**Risks (why whitelisted, capped, and fee-floored):**

- **Stale-mark capture, both directions.** The vault buys STRCon at its own mark, not a
  venue execution; a depositor profits whenever the asset is marked high (weekend gaps,
  sparse overnight prints, a mark lagging a fast drop, the ex-date window — Appendix B).
  Unlike cash deposits, the fee must cover the asset's mark error, not just NAV drift.
- **Round-trip arb with instant redemption.** A counterparty holding both permissions can
  in-kind mint at a stale-high mark and instant-redeem at the same NAV;
  `inKindFeeBps + instantExitFeeBps` becomes a hard floor sized to the worst plausible mark
  error, not to cost recovery.
- **Structural adverse selection.** Even honest counterparties route rationally: in-kind
  when the mark beats their venue execution, venue when it doesn't — a per-event-invisible
  drag on holders no fee level fully removes.
- **Second NAV-writer.** A bug in `creditInKind` is direct NAV inflation — mint-from-nothing;
  widens the module-registration god-mode risk (§5).
- **Liquidity degradation.** Adds backing, no cash: pushes toward `maxWeightBps`, dilutes
  the buffer ratio; the operator rotates behind large entries.
- **Restricted-asset intake.** The vault receives STRCon from third parties rather than only
  buying via Ondo: vault-address eligibility, Ondo transfer restrictions/freezes, and
  post-delivery blacklisting of the depositor become intake-path questions.

The first three share a root cause — the vault pricing a user-timed trade at its own oracle
instead of a venue execution. The residual never reaches zero; it is the §5 "redemption
slippage socialization" class run in reverse, with the depositor picking the moment.

---

## Appendix D — Deferred: instant redemptions (`withdraw`/`redeem`)

Whitelist-gated instant exits are out of scope for v2; `withdraw`/`redeem` stay disabled and
the queue is the only exit. Design final (below); ships as a self-contained later upgrade.
Trigger to build: a concrete curator/integrator who accepts the cap sizing and fee.

**Why deferred.** The cap paradox: a capped, first-come-first-served instant path cannot
provide what integrators actually need — assured liquidity at liquidation time, which is
exactly when everyone exits at once. A small cap is useless; a large cap recreates the
buffer-drain race against the queue; no cap size fixes FCFS-under-stress. In calm markets
the path is a convenience, and a convenience does not justify its cost in the audited
migration: a rolling cap, fee-bearing previews, a second buffer consumer, and three-way
rounding proofs in `maxWithdraw`/`maxRedeem` — each a new interacting invariant. v2.1 ships
exactly this feature as an isolated, auditable diff.

**Agreed shape — standard ERC-4626, not a bespoke function.** `withdraw`/`redeem` come
alive for whitelisted owners (add/remove: WHITELIST_MANAGER_ROLE), so integrators use stock
4626 tooling:

- `maxWithdraw`/`maxRedeem`: 0 unless whitelisted; else
  `min(owner's net value, per-period cap remaining, spendable buffer)` — true instant
  capacity, readable on-chain; 0 when paused or pricing is down (try/catch, §2.2 pattern).
- `previewWithdraw`/`previewRedeem`: execution quotes **net of `instantExitFeeBps`**
  (4626 requires previews to reflect the fee `redeem` charges). This is why the queue and
  all internal pricing already bind to `convertToAssets` — the fee-free NAV mark — leaving
  the previews free; the retrofit touches nothing outside the instant path. Integrator
  note: price sUSDat via `convertToAssets`, never `previewRedeem`.
- Flow: sweep → consume per-period cap → pay net from the buffer; the fee difference stays
  in the vault (NAV-accretive, same mechanism as the redemption fee). Cap in net USDat per
  fixed period; `instantExitFeeBps ≥ baseRedemptionFeeBps` (same cost plus immediacy), hard cap
  500.
- No permit or slippage variants: redeeming your own shares touches no allowance (the vault
  is the share token), and the whitelisted audience is contracts that enforce their own
  bounds; `redeemWithMinAssets` is a 5-line addition on concrete demand.
- `requestRedeem` must check the raw balance, not `maxRedeem` (which becomes instant-only
  capacity).

**Rationale retained from the original design.** Instant redemption is the only user-timed
value-sensitive operation (deposits are atomic but passive; processing and rotations are
operator-timed; claims don't price), so the caller picks the moment they transact against
the mark — and the moments worth picking are the bad ones (weekend-stale mark, the ex-date
window). The whitelist restricts that timing option to counterparties with contractual
recourse and makes a flat fee sufficient; value access stays universal through the queue.
The buffer-priority ordering also stands: the operator batches `sellVia` + `processRequests`
atomically, so instant exits can only touch the standing buffer, never front-run queue
funding.

**Interaction with Appendix C:** shipping in-kind minting and instant redemption to the same
counterparty creates the round-trip arb (mint at a stale-high mark, exit at the same NAV) —
size `inKindFeeBps + instantExitFeeBps` to worst plausible mark error if both ever coexist.
