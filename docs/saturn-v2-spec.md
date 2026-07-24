# sUSDat v2 — Technical Specification

**Status:** Draft 2 (rewrite of [draft 1](./saturn-v2-upgrade-spec-draft1.md))
**Date:** 2026-07-24
**Scope:** The v2 upgrade of `StakedUSDat` and `WithdrawalQueueERC721`: fixed accounting
modules for the legacy STRC mirror and STRCon, the STRC → STRCon migration, and the
withdrawal-queue rework. Arbitrary multi-asset support is deferred.

Layout: §1 summarizes changes; §2 is normative; §3 is the migration runbook; §4–5 track
open questions and risks. Appendices A–G record rationale, empirical findings, deferred
features, economic/mode references, and incident response. After migration, archive §3 and
Appendix B; §2 and Appendices A and E–G remain durable.

---

## 1. What changes

v1 backs sUSDat with a processor-attested, single-oracle mirror of off-chain STRC and
settles redemptions against attested STRC sales. v2 uses two fixed accounting modules,
moves the position to on-chain STRCon, and settles redemptions at NAV from the vault's
buffer. `STRCMirror` exists only to preserve and migrate the v1 position; `STRConModule` is
the sole token-backed tradable module.

### StakedUSDat

| v1 | v2 |
|---|---|
| `strcBalance` mirror accounting, `_strcTotalAssets()` | two fixed module slots; `totalAssets()` explicitly includes `STRCMirror.recognizedValue()` and `STRConModule.recognizedValue()` (§2.1–2.2) |
| `convertFromUsdat` / `convertFromStrc` + `_validateConversion` | exact-amount `buy(module, amountIn, amountOut, deadline)` / `sell(...)` (§2.5); the vault settles tokens, validates execution price, and directs STRCon module accounting |
| vault-global `toleranceBps`, `setTolerance` | vault-global `executionToleranceBps`, used only by `buy`/`sell` and capped at 500 bps |
| hard-wired `StrcPriceOracle`, `getStrcOracle()` | per-module oracles (§2.3) |
| `transferInRewards` + STRC vesting surface | moves into STRCMirror (§2.3); retires with it |
| `burnQueuedShares(shares, strcAmount)` | `redeemQueuedShares(shares, minSharePrice)` (§2.6) |
| `collectDust` | dropped — per-request settlement leaves no dust |
| oracle failure reverts `totalAssets()` and all views | same fail-closed reverts, kept deliberately; `maxDeposit`/`maxMint` catch and report 0 for ERC-4626 (§2.2) |
| — | `transferInSurplus` cash surplus inlet (§2.1) |
| one configured deposit fee | market-mode fee: zero in Regular, elevated in Elevated, and deposits disabled in Restricted (§2.4, §2.7) |
| — | `MarketMode` selects Regular, Elevated, or Restricted operation; hard pause remains separate (§2.7) |
| — | `seize` (§2.8) |
| `PROCESSOR_ROLE`, `COMPLIANCE_ROLE` | capability-named role taxonomy (§2.8) |

Unchanged: the ERC-4626 core with async-redemption overrides (`withdraw`/`redeem` disabled;
`requestRedeem`'s limit becomes `minSharePrice`), deposit variants (permit/min-shares),
blacklist + `redistributeLockedAmount`, and `rescueTokens` (generalized, §2.2). Vault pause
remains scoped to vault and sUSDat mutations; queue-local pause separately gates queue-only
actions (§2.6).

### WithdrawalQueueERC721

| v1 | v2 |
|---|---|
| `processRequests(tokenIds, totalUsdatReceived, totalStrcSold, executionPrice)` — batch pro-rata against an attested STRC sale | `processRequests(tokenIds)` — whole-request settlement at current NAV from the vault's USDat buffer (§2.6) |
| `claim` + `claimBatch`/`claimAll`/`claimBatchFor`/`claimAllFor` | single `claim(tokenId)` (§2.6) |
| `_validateTotals`, `_isWithinTolerance`, `_validateAmount`, oracle/asset-sale reads | dropped — the queue never knows which backing asset funds the buffer; settlement pricing and fees live in the vault |
| `lockRequests` / `unlockRequests`, `InProgress` | dropped — settlement is atomic at the validated mark |
| `minUsdatReceived` (absolute payout bound) | `minSharePrice` (6-decimal minimum gross USDat per `1e18` shares, §2.6); the same storage slot is reinterpreted without conversion and legacy owners receive a grace period to update or cancel (§3.1) |
| dust flow (`approve` + `collectDust`) | dropped |
| `SlippageExceeded` revert on unmet limit | below-limit requests are skipped, not reverted |
| no cancellation | NFT owner may cancel an open request and recover all escrowed shares while the queue is unpaused; a vault pause makes the sUSDat return transfer revert |
| queue-local pause only | local pause remains authoritative for queue-only actions; vault pause indirectly blocks request creation, processing, and cancellation, but not funded claims, limit updates, or request-NFT transfers (§2.6) |

Retained with narrower surfaces: request creation and share escrow, single-request reads,
current-owner request enumeration, NFT ownership, and pause. Cancellation, compliance, and
roles change per §2.6–2.8.

### Removed functions

Flat list of deployed functions that do not exist in v2 (successor in parentheses).

**StakedUSDat:** `convertFromUsdat` / `convertFromStrc` (→ `buy`/`sell`),
`burnQueuedShares` (→ `redeemQueuedShares`), `collectDust`, `claim`, `claimBatch`,
`transferInRewards`, `getUnvestedAmount`, `setVestingPeriod`, `setMaxRewardsBps` (→ all four
move into STRCMirror), `setTolerance` (→ `StakedUSDat.setExecutionTolerance`),
`getStrcOracle` (→ per-module oracles),
`setDepositFee` (→ `setElevatedDepositFee`).

**WithdrawalQueueERC721:** `lockRequests`, `unlockRequests`, `claimBatch`, `claimAll`,
`claimBatchFor`, `claimAllFor` (→ single `claim`), `updateMinUsdatReceived`
(→ `updateMinSharePrice`), and the view surface — `getRequest`, `getStatus`, `isClaimable`,
`getPendingCount`, `getTotalRequests` (→ the `requests` / `nextTokenId` public getters),
`getMyRequests` (→ `getUserRequests(msg.sender)`), `getClaimable`, `getPending`,
`getTotalPendingShares`, `getPendingIdsInRange` (→ `getUserRequests` /
ERC721Enumerable views + multicall/events), plus the `pendingCount` variable (no on-chain
consumer). Remaining reads: the `requests` mapping, `nextTokenId`, `getUserRequests`, and
inherited ERC721Enumerable.

---

## 2. V2 specification

Normative. Present tense; rationale in Appendix A.

### 2.1 Vault accounting

```
totalAssets() = usdatBalance
              + (surplusVestingAmount − getUnvestedSurplus())
              + strcMirror.recognizedValue()
              + strconModule.recognizedValue()
```

`totalAssets()` uses 6-decimal USDat units and treats one USDat as one USD; it does not mark
a USDat/USD depeg. `usdatBalance` is idle USDat: the deposit inlet, redemption outlet, and
source/sink of rotations.

**Surplus inlet.** `transferInSurplus(amount)` (OPERATOR_ROLE) accepts discretionary USDat
surplus; no amount or schedule is owed to the vault. It enters a segregated
`surplusVestingAmount` leg — in the vault but outside
`usdatBalance` — and vests linearly over `surplusVestingPeriod` (default 24h, max ~7d).
Only one tranche may exist. A new transfer requires the prior tranche fully vested;
`_sweep()` folds it into `usdatBalance`, then the vault records pre-transfer
`navBefore = totalAssets()` and requires:

```
amount ≤ floor(navBefore × maxSurplusBps / 10_000)
```

`_sweep()` also precedes value-sensitive entrypoints and is a permissionless poke. Until
fully vested and swept into `usdatBalance`, surplus cannot fund rotations, redemptions,
custody-shortfall coverage, or emergency action; no pause or role accelerates, cancels, or
reclassifies it.

**Economic incidence.** Recognized gains and losses change per-share NAV for accounts
exposed to sUSDat at recognition. Open requests remain exposed; processed requests are
fixed USDat claims. There is no contractual loss reserve, insurance, redemption floor, or
recapitalization guarantee; recapitalization is discretionary. An unpriceable condition
halts pricing without a write-down; impairment enters NAV only through an approved
recovery price or governance upgrade.

**Physical USDat shortfall.** If actual USDat custody falls below
`usdatBalance + surplusVestingAmount`, the vault must pause immediately and remain paused
until a governance upgrade adjusts tracked USDat accounting to verified recoverable
custody. V2 has no ordinary shortfall write-down path.

Invariants:
- `totalAssets()` counts only the vested slice of the surplus leg.
- `usdatBalance` outflow paths never touch `surplusVestingAmount`.
- `USDat.balanceOf(address(this)) ≥ usdatBalance + surplusVestingAmount`.

### 2.2 Module framework

Modules are accounting adapters; custody and ERC20 settlement remain in the vault. Modules
hold no tokens or vault allowances. The v2 reinitializer sets two fixed slots:

```solidity
IAccountingModule public strcMirror;
ITradableModule public strconModule;
```

V2 has no module registry, registration function, loop, or allocation configuration. Both
modules are direct, non-proxy deployments. Each constructor fixes `VAULT`;
`STRConModule` also fixes `ASSET`. The vault slots have no post-reinitializer setter.
Replacing a module, its code, or a vault/asset binding requires a new module and timelocked
vault upgrade. Accounting counters and explicitly authorized oracle/numeric configuration
remain mutable.

```solidity
interface IAccountingModule {
    /// USD value (6 decimals) recognized now;
    /// reverts when a nonzero position cannot be reliably priced;
    /// returns zero without pricing when balance() == 0.
    function recognizedValue() external view returns (uint256);

    /// Recognized quantity, maintained as a counter rather than live custody.
    function balance() external view returns (uint256);
}

interface ITradableModule is IAccountingModule {
    /// ERC20 fixed by the concrete module at construction.
    function asset() external view returns (address);

    /// Validated 8-decimal USD price of one whole asset.
    function getPrice() external view returns (uint256);

    /// Recognize a completed inbound delivery.
    function buy(uint256 assetReceived) external;

    /// Derecognize an asset quantity before outbound delivery.
    function sell(uint256 assetSold) external;
}
```

Only the vault calls module `buy` and `sell`; they move no tokens and update `balance()`
from vault-measured deltas. `getPrice()` returns the validated module price; the vault
calculates execution price and enforces tolerance (§2.5). USDat and STRCon must be standard,
non-rebasing, non-fee-on-transfer ERC20s without transfer callbacks; each transfer must
produce the exact requested vault balance delta.

`STRCMirror` implements `IAccountingModule`; it is tokenless and is not accepted by the
generic trading entrypoints. `STRConModule` implements `ITradableModule`. In v2,
`_requireSupportedTradableModule(module)` accepts only the fixed `strconModule` address.
`STRConModule` stores the active STRCon oracle and immutable `VAULT` and `ASSET` addresses.
It has no local role administration; oracle rotation is authorized against the vault's role
registry:

```solidity
address public immutable VAULT;
address public immutable ASSET;
ISTRConPriceOracle public oracle;

event OracleUpdated(address indexed oldOracle, address indexed newOracle);

function asset() external view returns (address) {
    return ASSET;
}

function getPrice() external view returns (uint256) {
    return oracle.getPrice();
}

modifier onlyVaultRole(bytes32 role) {
    require(IAccessControl(VAULT).hasRole(role, msg.sender), Unauthorized());
    _;
}

function setOracle(address newOracle)
    external
    onlyVaultRole(PARAMETER_MANAGER_ROLE)
{
    require(newOracle != address(0) && newOracle.code.length != 0, InvalidOracle());
    address oldOracle = address(oracle);
    oracle = ISTRConPriceOracle(newOracle);
    emit OracleUpdated(oldOracle, newOracle);
}
```

The constructor sets the initial oracle. `setOracle` changes only the oracle used by
`recognizedValue()` and `getPrice()`, not the module, asset, vault, or recognized balance.

**Failure semantics — fail closed.** If a module cannot price, `recognizedValue()` reverts
through `totalAssets()`, halting every value-sensitive path, including mints, queue
processing, rotations, and downstream `convertToAssets`/`previewRedeem` use. Nonpricing
operations—share transfers, `requestRedeem`, `updateMinSharePrice`, `claim`, and
seizures—remain live. For ERC-4626 compliance, `maxDeposit`/`maxMint` catch
`totalAssets()` failure and return 0; `max*` functions must not revert. Manual vault pause
follows the STRCon impairment path in Appendix G.

**Rescue.** `rescueTokens(token, amount, to)` (`DEFAULT_ADMIN_ROLE`) sweeps only untracked
excess. Protected custody is `usdatBalance + surplusVestingAmount` for USDat and
`strconModule.balance()` for STRCon; STRCMirror is tokenless. Unsolicited transfers do not
change accounting or NAV, and only custody above the applicable protected amount is
rescuable.

Invariants:
- **Custody floor** (token-backed modules): `asset().balanceOf(vault) ≥ balance()`. Excess
  custody is unrecognized — an external transfer cannot move NAV.
- **Counter authority:** `STRCMirror.balance()` changes only through `seed`,
  `transferInRewards`, and `retire`; `STRConModule.balance()` only through
  vault-authorized `buy`, `sell`, and seed-once migration `setBalance`. NAV can also change
  as surplus or STRCMirror rewards vest or module prices move. STRCon's `sValue` affects
  STRCon oracle validation, not STRCMirror; NAV uses the returned Calculated price.
- `recognizedValue()` reverts when unpriceable — no value-sensitive operation, in the vault
  or downstream, can transact against an unreliable mark.
- A zero-balance module returns zero without reading its oracle. After migration,
  STRCMirror can remain fixed at zero without creating a pricing-liveness dependency.
- v2 has no on-chain STRCon allocation cap or minimum USDat buffer. Allocation and liquidity
  targets are operational policy, not contract-enforced limits.

### 2.3 Modules

**STRCMirror** (tokenless migration bridge). `balance()` is a processor-attested off-chain
STRC notional without a custody floor, priced by the deployed `StrcPriceOracle` (Chainlink
wrapper, staleness + $20–$150 bounds). It stores 6-decimal `balance`, `vestingAmount`,
`lastDistributionTimestamp`, `vestingPeriod`, and `maxRewardsBps`; immutable `VAULT` and
oracle bindings replace local role administration. Vesting and valuation preserve v1
rounding:

```solidity
unvested = retired || elapsed >= vestingPeriod
    ? 0
    : Math.mulDiv(vestingPeriod - elapsed, vestingAmount, vestingPeriod, Math.Rounding.Ceil);
recognizedValue = retired || balance == 0
    ? 0
    : Math.mulDiv(balance - unvested, price, 10 ** priceDecimals, Math.Rounding.Floor);
```

`transferInRewards(strcAmount)` requires initialized, non-retired state, vault
`OPERATOR_ROLE`, a nonzero amount, and no unvested reward. It limits the floor-rounded USD
reward value to `floor(VAULT.totalAssets() * maxRewardsBps / 10_000)`, then increases
`balance`, sets `vestingAmount = strcAmount`, and records the current timestamp.
`setVestingPeriod` requires vault `PARAMETER_MANAGER_ROLE`, no unvested reward, and
`0 < newPeriod ≤ 90 days`; it updates the period and clears `vestingAmount`.
`setMaxRewardsBps` requires vault
`PARAMETER_MANAGER_ROLE` and a nonzero value but has no upper bound. Both setters reject
retired state.

Beginning with Step 1, generic rotations reject `STRCMirror`; `balance()` can increase only
through `transferInRewards` until Step 2 retires it. Vault-only
`seed(initialBalance, initialVestingAmount, initialLastDistributionTimestamp,
initialVestingPeriod, initialMaxRewardsBps)` initializes the balance and reward state once;
it requires `0 < initialVestingPeriod ≤ 90 days`, nonzero `initialMaxRewardsBps`, and a
computed unvested amount no greater than `initialBalance`. Vault-only `retire()` requires no
unvested reward and permanently retires the module:

```solidity
bool public seeded;
bool public retired;

modifier whenActive() {
    if (!seeded || retired) revert STRCMirrorInactive();
    _;
}

function retire() external onlyVault whenActive {
    if (getUnvestedAmount() != 0) revert StillVesting();
    _balance = 0;
    retired = true;
    emit Retired();
}
```

`whenActive` applies to `transferInRewards`, `setVestingPeriod`, and
`setMaxRewardsBps`; none can mutate a retired module. `seed` is vault-only and rejects a
second call. Views do not use `whenActive`: after retirement, `balance()`,
`getUnvestedAmount()`, and `recognizedValue()` return zero, with `recognizedValue()`
checking retirement before reading the oracle. Other configuration getters remain
readable.

**STRCon** (durable; token `0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c`, 18 decimals) is
Ondo Global Markets' tokenized STRC, a structured note backed 1:1 by STRC shares.
Reinvested dividends accumulate in `sValue`
(`STRCon price = STRC price × sValue`), so yield is continuous in its price. `balance()` is
a tracked counter under the custody-floor invariant. The position is marked to market with
**no vesting**. With the 18-decimal counter and 8-decimal oracle price:

```solidity
if (balance() == 0) return 0;
return Math.mulDiv(balance(), oracle.getPrice(), 1e20, Math.Rounding.Floor); // 6-decimal USDat
```

#### STRCon price oracle

`STRConPriceOracle` validates two 8-decimal Chainlink feeds:

- **Calculated mark:** *STRCon-USD (Calculated)*,
  `0xC353ac4b425f818Ad87E228bf816E15c2173AC07`. This is the sole value-securing price
  returned for NAV, minting, queue processing, migration, and trade validation. Its value
  updates during regular market hours and can remain unchanged through premarket,
  postmarket, weekends, and holidays, so it has no short wall-clock staleness limit.
- **API reference:** *STRCon/USD (Ondo API)*,
  `0x67d4Ae9f265270aE123c08D2657536771D19cD91`. It updates through premarket and
  postmarket, uses an approximately 50 bps deviation trigger, and has an approximately
  24-hour heartbeat that continues over the weekend. It is a circuit-breaker reference and
  is never returned as the vault's price.

`getPrice()` reads both latest rounds and
`SyntheticSharesOracle.getSValue(STRCon)`, then reverts unless:

1. Both feed calls succeed and each round has `roundId != 0`, `answer > 0`,
   `updatedAt != 0`, `updatedAt <= block.timestamp`, and `answeredInRound >= roundId`.
2. `block.timestamp - api.updatedAt <= maxApiStaleness`. Initial
   `maxApiStaleness` is 26 hours (24-hour heartbeat plus grace), capped at 36 hours.
3. Ondo's per-asset pause flag is clear and `sValue` is nonzero.
4. `underlyingPrice = Math.mulDiv(calculatedPrice, 1e18, sValue, Math.Rounding.Floor)` is
   within `[minPrice, maxPrice]` (default $20–$150). `calculatedPrice`, `underlyingPrice`,
   `minPrice`, and `maxPrice` use 8 decimals; `sValue` uses 18.
5. The latest answers satisfy, rounding the full-precision deviation upward:

   ```
   Math.mulDiv(
       abs(calculatedPrice - apiPrice),
       10_000,
       calculatedPrice,
       Math.Rounding.Ceil
   )
       <= deviationBps
   ```

`getPrice()` returns the validated 8-decimal `calculatedPrice`. Each read recomputes
validity, so pricing recovers when all checks pass. The `deviationBps` launch value and hard
cap are set before audit freeze (§4).

Each `STRConPriceOracle` constructor permanently binds both feed addresses and rejects
feeds not reporting 8 decimals. Replacing either feed requires a new wrapper and
`STRConModule.setOracle(newOracle)`. Numeric setters use
`onlyVaultRole(PARAMETER_MANAGER_ROLE)` against immutable `VAULT` and emit configuration
events. STRCMirror keeps the deployed v1 `StrcPriceOracle`.

#### STRCon operations

- **Execution (`buy`/`sell`): atomic settlement against one execution vehicle.** The
  vehicle funds the non-vault workflow: acquiring or selling USDat, obtaining USDC,
  interacting with Ondo, handling USDon residuals, and carrying STRCon inventory. Its
  legs, balances, quotes, and liabilities stay outside vault accounting; on chain it is
  only the configured counterparty to an exact USDat↔STRCon exchange.
  `setExecutionVehicle(newVehicle)` is `PARAMETER_MANAGER_ROLE`, rejects zero, and emits
  `ExecutionVehicleUpdated(oldVehicle, newVehicle)`; replacing it does not replace the
  module.

  The vault pulls the vehicle's leg with `safeTransferFrom`, verifies the exact balance
  delta, performs the conservative accounting transition, then sends its leg directly to
  the configured vehicle. The vehicle approves the vault; the vault never approves the
  vehicle or module. A buy decreases `usdatBalance` before recognizing delivered STRCon; a
  sell derecognizes STRCon before increasing `usdatBalance`. Intermediate NAV may
  understate but never overstate. Later failure atomically reverts transfers and accounting.

  The vault checks the realized price from measured amounts against
  `STRConModule.getPrice()` (§2.5), then verifies final deltas and the custody floor. Only
  recognized STRCon is sellable; excess remains unrecognized.
- Migration setter: `setBalance(amount)` — vault-only, seed-once (`require(balance == 0)`),
  asserts the custody floor.

### 2.4 Deposits

Deposits are atomic, 24/7 when enabled, and enter the cash buffer at validated NAV. Regular
charges no fee; Elevated charges `elevatedDepositFeeBps`; Restricted disables deposits and
mints (`maxDeposit`/`maxMint` return 0, as under hard pause). The anti-dilution fee remains
in `usdatBalance`, never goes to legacy `feeRecipient`. Every deposit/mint variant adds
`whenNotRestricted` to its hard-pause guard and prices against pre-deposit NAV:

```
deposit(grossAssets):
  fee       = ceil(grossAssets × depositFeeBps() / 10_000)
  netAssets = grossAssets − fee
  shares    = convert netAssets to shares, rounding down

mint(shares):
  netAssets   = convert shares to assets, rounding up
  grossAssets = ceil(netAssets × 10_000 / (10_000 − depositFeeBps()))
```

Execution pulls and adds all `grossAssets` to `usdatBalance`; only `netAssets` determines
minted shares. `previewDeposit` and `previewMint` use the same formulas and rounding.

No backing asset is bought at deposit time; the buffer is deployed by rotations. When any
module cannot price, deposits revert and `maxDeposit`/`maxMint` report 0 (§2.2).

Instant redemptions are **deferred** (Appendix D — design final); `withdraw`/`redeem` stay
disabled in v2 and the queue is the only exit.

### 2.5 Rotations

All STRCon buying and selling is operator-driven (`OPERATOR_ROLE`), never user-triggered:

```solidity
uint16 public constant MAX_EXECUTION_TOLERANCE_BPS = 500;
uint16 public executionToleranceBps;

vault.buy(module, amountIn, amountOut, deadline)
// amountIn: exact USDat paid; amountOut: exact module asset received

vault.sell(module, amountIn, amountOut, deadline)
// amountIn: exact module asset sold; amountOut: exact USDat received
```

`setExecutionTolerance(newBps)` is `PARAMETER_MANAGER_ROLE`, requires
`newBps ≤ MAX_EXECUTION_TOLERANCE_BPS`, and emits
`ExecutionToleranceUpdated(oldBps, newBps)`. The initial value is approved before the
upgrade (§4). This global vault parameter is used only by `buy` and `sell`.

The vault compares the validated 8-decimal STRCon/USD `oraclePrice` from
`module.getPrice()` with the 8-decimal execution price in USDat per STRCon, treating one
USDat as one USD. The `1e20` factor converts 6-decimal USDat / 18-decimal STRCon to that
scale. Only adverse execution beyond `executionToleranceBps` is rejected:

```solidity
buyPrice = Math.mulDiv(usdatIn, 1e20, assetReceived, Math.Rounding.Ceil);
maxBuyPrice = Math.mulDiv(
    oraclePrice,
    10_000 + executionToleranceBps,
    10_000,
    Math.Rounding.Floor
);
require(buyPrice <= maxBuyPrice, ExecutionPriceMismatch());

sellPrice = Math.mulDiv(usdatReceived, 1e20, assetSold, Math.Rounding.Floor);
minSellPrice = Math.mulDiv(
    oraclePrice,
    10_000 - executionToleranceBps,
    10_000,
    Math.Rounding.Ceil
);
require(sellPrice >= minSellPrice, ExecutionPriceMismatch());
```

Buying below the oracle range and selling above it remain valid. V2 has no rolling
execution-loss accumulator; `OPERATOR_ROLE` is trusted not to repeat individually valid
trades to evade the per-trade bound.

```solidity
event AssetBought(
    address indexed module,
    address indexed vehicle,
    uint256 usdatPaid,
    uint256 assetReceived,
    uint256 oraclePrice
);

event AssetSold(
    address indexed module,
    address indexed vehicle,
    uint256 assetSold,
    uint256 usdatReceived,
    uint256 oraclePrice
);
```

Both functions are `whenNotPaused`, `whenNotRestricted`, and `nonReentrant`; reject zero
amounts, an expired deadline, and every module other than the fixed `strconModule`; and use
the current `executionVehicle`. They accept no USDC amount, Ondo quote or signature, route,
target, arbitrary calldata, or vehicle-reported result.

At execution, `buy` and `sell` resolve the current `executionVehicle`, `module.getPrice()`
(with its active wrapper), and `executionToleranceBps`; calldata does not snapshot them, so
a configuration change alone does not invalidate a pending call. The exact amounts and
`deadline` are the operator's commitment; v2 adds no freshness bound, so the deadline must
match the intended window.

**Buy order:** pull `amountOut` of `module.asset()` from the vehicle into the vault; require
the exact balance increase; get `oraclePrice` and apply the buy-price check above; decrement
`usdatBalance`; call `module.buy(actualAssetReceived)`; transfer exactly `amountIn` USDat
directly to the vehicle; assert final balance deltas and custody floor.

**Sell order:** pull `amountOut` USDat from the vehicle into the vault; require the exact
balance increase; get `oraclePrice` and apply the sell-price check above; call
`module.sell(amountIn)`; increment `usdatBalance`; transfer exactly `amountIn` of
`module.asset()` directly to the vehicle; assert final balance deltas and custody floor.

Relative to balances immediately before the first transfer, a successful call has these
exact deltas:

| Value | `buy` | `sell` |
|---|---:|---:|
| `USDat.balanceOf(vault)` | `−amountIn` | `+amountOut` |
| `usdatBalance` | `−amountIn` | `+amountOut` |
| `module.asset().balanceOf(vault)` | `+amountOut` | `−amountIn` |
| `module.balance()` | `+amountOut` | `−amountIn` |

The vehicle approves the incoming leg. Exact per-trade allowances are recommended for its
protection but are not a vault invariant. Allocation, liquidity, timing, and working-capital
source are off-chain strategy. Slow or failed acquisition only delays rotation; the vault
recognizes no off-chain receivable.

### 2.6 Withdrawal queue

The vault prices exits at current NAV, never the queue or a venue quote. Redeemers claim
value, not a backing asset. The queue knows only escrowed sUSDat, claimable USDat,
ownership, and request state; it never reads or receives STRC, STRCon, module, oracle, or
sale data.

**Request.** Vault `requestRedeem(shares, minSharePrice)` escrows shares in the queue and
mints an NFT. `MIN_REQUEST_SHARES` is 10 shares, not assets, because the function never
prices (§2.2; v1's 10-USDat minimum required `previewRedeem`):

```solidity
enum RequestStatus { NULL, Requested, InProgress, Processed, Claimed, Cancelled }

struct Request {
    uint256 shares;          // full escrowed amount; v2 does not partially fill
    uint256 usdatOwed;       // zero until the complete request is processed
    uint256 timestamp;
    uint256 minSharePrice;   // 6-decimal minimum gross USDat per 1e18 shares (reuses v1 slot)
    RequestStatus status;    // InProgress retained and Cancelled appended for storage compatibility
}
```

Lifecycle is `Requested → Processed → Claimed` or `Requested → Cancelled`. `InProgress`
only preserves v1 numbering; migration clears all v1 locks and v2 never creates it.
Processed USDat stays in the queue until claimed. There are no partial fills: the stored
`shares` value is never decremented; the corresponding escrowed shares are either burned
on complete settlement or returned on cancellation.

**Limit semantics.** `minSharePrice` is the minimum **gross** execution price in 6-decimal
USDat per `1e18` shares, checked before the redemption fee. A below-limit request is skipped
and remains open until NAV recovers, its owner changes the limit with
`updateMinSharePrice`, or cancels. The owner may raise or lower it while the request is open
and the queue active.

**Creation gate.** `addRequest` uses an `onlySUSDAT` modifier wrapping an immutable-address
check, not an AccessControl role:

```solidity
modifier onlySUSDAT() {
    require(msg.sender == STAKED_USDAT, OnlyStakedUSDat());
    _;
}
```

No administrator can re-point or widen it. The queue also rejects a user restricted by
either the sUSDat blacklist or USDat freeze list before minting the request NFT.

**Processing.** Funding and processing are separate. The vault tops up `usdatBalance` on
its own cadence; sales are not earmarked. The operator passes ordered token IDs, not
amounts. Each valid ID is offered for complete settlement through one vault primitive:

```solidity
enum RedemptionResult { Settled, BelowLimit, InsufficientLiquidity }

// WithdrawalQueueERC721: OPERATOR_ROLE, nonReentrant, queue-local whenNotPaused
processRequests(uint256[] tokenIds)
  for each request in caller-supplied order:
    require(request.status == RequestStatus.Requested, RequestNotOpen());
    (result, usdat) = vault.redeemQueuedShares(request.shares, request.minSharePrice)
    if result == BelowLimit → continue                 // request stays open
    if result == InsufficientLiquidity → continue      // a later smaller request may fit
    request.usdatOwed = usdat
    request.status = Processed
```

The queue does not inspect `marketMode()`. `redeemQueuedShares` owns the Restricted-mode
gate, so a non-empty batch reverts atomically in Restricted mode; an empty batch remains a
no-op.

Duplicate IDs need no separate validation. A skipped request may be retried later in the
same caller-supplied sequence. Once an occurrence settles, its status becomes `Processed`,
so any later duplicate fails the `Requested` check and atomically rolls back the complete
transaction. A duplicate therefore cannot burn shares or fund an obligation twice.

```solidity
// StakedUSDat — queue-only; price, check, burn, and transfer atomically
function redeemQueuedShares(uint256 shares, uint256 minSharePrice)
    external onlyWithdrawalQueue whenNotPaused whenNotRestricted
    returns (RedemptionResult result, uint256 usdat);
// gross = convertToAssets(shares), floor-rounded and priced before the burn
// maximumSharePrice = Math.mulDiv(gross, 1e18, shares)
// minSharePrice > maximumSharePrice → BelowLimit
// (equivalent to gross < ceil(shares * minSharePrice / 1e18), without limit overflow)
// fee = Math.mulDiv(gross, redemptionFeeBps(), 10_000, Math.Rounding.Ceil)
// net = gross - fee
// usdatBalance < net → InsufficientLiquidity
// otherwise burn every share, decrement usdatBalance by net,
// transfer net USDat to the queue, and return Settled
```

Expected no-settlement outcomes return a result without reverting the batch; invalid IDs or
states revert as operator errors. An insufficient request is skipped so a later smaller one
may settle. The operator selects and orders IDs; there is no FIFO guarantee.

Each successful settlement reprices the next request at the then-current NAV. When the
redemption fee is nonzero, only the net payout leaves the vault, so the retained fee accrues
to the remaining shares: a later request may receive a slightly higher gross share price or
cross its `minSharePrice` after an earlier request settles. This fee-accreted sequential
pricing and its ordering consequences are explicit and accepted; processing does not
snapshot one batch-wide price.

Even for a buggy queue, `redeemQueuedShares` burns only queue-held shares at current vault
NAV and fee, and settles only a complete, buffer-covered request while processing is
enabled. Backing-asset and liquidity-path changes do not touch the queue.

**Cancellation.** While active, the current NFT owner may call `cancelRequest(tokenId)` on
an open request. It is nonReentrant, returns all shares to that owner, marks `Cancelled`,
and burns the NFT without a fee. Restricted owners cannot cancel; enforcement handles
their positions. Queue pause blocks cancellation. Vault pause also causes cancellation to
revert when the queue attempts to return the escrowed sUSDat.

**Claiming.** `claim(tokenId)` is the only claim function. While active, the current owner
of a `Processed` request receives all `usdatOwed`; the request becomes `Claimed` and the NFT
burns. V2 has no `claimBatch`, `claimAll`, `claimBatchFor`, or `claimAllFor`. Pause blocks
claims only when the queue itself is paused; an already-funded claim remains available
during a vault pause.

**Owner request view.** `getUserRequests(user)` returns every live request NFT currently
owned by `user`, regardless of request status. Claimed and cancelled requests are excluded
because their NFTs are burned. The returned ERC721Enumerable order is not stable.

**Queue pause semantics.** The queue relies on its own `whenNotPaused` gate and does not
mirror `StakedUSDat.paused()`. Queue-local pause blocks `addRequest`,
`updateMinSharePrice`, `processRequests`, `cancelRequest`, `claim`, and ordinary NFT
movement. Vault pause independently blocks vault calls and sUSDat movement, so request
creation, processing, and cancellation revert without an extra queue-side pause check.
Already-funded claims, limit updates, and request-NFT transfers remain available during a
vault pause. Restricted mode blocks only non-empty processing among queue actions, through
the vault-side `redeemQueuedShares` gate; it is not a pause. Views remain available.
Separate `PAUSER_ROLE` and `UNPAUSER_ROLE` apply (§2.8). Queue enforcement uses
`whileUnpaused`: an active queue pause is temporarily lifted for the enforcement call and
restored afterward. A successful call while paused emits `Unpaused` followed by `Paused`;
a revert rolls back both pause-state changes and their events.

**Compliance.** The queue has no blacklist role or storage. It treats either the canonical
sUSDat blacklist or the USDat freeze list as a queue restriction:

```solidity
function _requireNotBlacklisted(address account) internal view {
    require(!STAKED_USDAT.isBlacklisted(account), AddressBlacklisted());
    require(!USDAT.isFrozen(account), AddressBlacklisted());
}

function _requireBlacklisted(address account) internal view {
    require(
        STAKED_USDAT.isBlacklisted(account) || USDAT.isFrozen(account),
        NotBlacklisted()
    );
}
```

A restricted owner cannot transfer the NFT, update its limit, cancel, or claim.
`seizeRequest(tokenId)` transfers an open NFT from that owner to
`StakedUSDat.recoveryAddress()`; `seize(tokenId)` pays a processed request's `usdatOwed`
there, marks it claimed, and burns the NFT. Neither accepts a destination. Both are
single-token `ENFORCER_ROLE` operations (§2.8).

Invariants:
- A request is settled completely or not at all; v2 never partially burns its shares.
- Every processed request is priced at current gross NAV, satisfies its `minSharePrice`, and
  pays that gross value net of the active redemption fee.
- Queue sUSDat custody is at least the sum of `shares` across open requests; queue USDat
  custody is at least the sum of `usdatOwed` across processed requests.
- Unsolicited sUSDat or USDat transfers are untracked excess: they do not change request
  accounting or NAV. V2 has no queue rescue path, so such excess remains in the queue.
- The queue never receives backing-asset or venue-execution data.
- Escrowed shares remain NAV-exposed until processed or cancelled — a request is a place in
  the settlement set, not a price commitment or FIFO guarantee.

### 2.7 Market modes and fees

Market mode is separate from hard protocol pause:

```solidity
enum MarketMode { REGULAR, ELEVATED, RESTRICTED }

MarketMode public marketMode;

modifier whenNotRestricted() {
    require(marketMode != MarketMode.RESTRICTED, MarketRestricted());
    _;
}

function setMarketMode(MarketMode newMode)
    external onlyRole(MARKET_MODE_MANAGER_ROLE);
```

`setMarketMode` sets an explicit target and emits
`MarketModeChanged(MarketMode oldMode, MarketMode newMode)`. It cannot price assets, move
funds, change NAV, or clear a hard pause. It remains callable while hard paused so the
time-appropriate mode can be installed before unpause. `MARKET_MODE_MANAGER_ROLE` initially
shares the `OPERATOR_ROLE` address; either may later be reassigned independently.

- **Regular:** deposits and mints have no deposit fee; queue processing uses the base
  redemption fee.
- **Elevated:** deposits and mints use `elevatedDepositFeeBps`; queue processing uses the
  elevated redemption fee.
- **Restricted:** deposits, mints, `redeemQueuedShares`, `buy`, and `sell` revert. Non-empty
  `processRequests` calls therefore revert through `redeemQueuedShares`; an empty batch is a
  no-op. New redemption requests, request updates, cancellations, funded claims, and sUSDat
  and request-NFT transfers remain available.
- **Vault hard pause:** independent `Pausable` overrides every mode for vault and sUSDat
  mutations (§2.3, §2.6). It also makes queue request creation, processing, and
  cancellation revert through their vault or sUSDat calls. Funded claims, limit updates,
  and request-NFT transfers remain available unless the queue is separately paused. Views,
  market-mode changes, governance, oracle recovery, upgrade, unpause, and enforcement
  remain available.

Mode transitions are an operational requirement; the vault has no market-hours calendar.
At each U.S. regular-session close—normally 4:00 p.m. ET, or the scheduled early
close—`MARKET_MODE_MANAGER_ROLE` sets Elevated. Elevated remains active through postmarket,
overnight, premarket, weekends, and holidays. Regular resumes only after the Calculated
feed publishes a valid update during the next regular-hours session and all wrapper checks
pass.

Restricted is reserved solely for a credible executable protocol arbitrage identified by
monitoring. Raw API/Calculated divergence alone does not trigger it; an identified
arbitrage triggers Restricted regardless of that divergence. Once the arbitrage is no
longer executable, `MARKET_MODE_MANAGER_ROLE` restores the time-appropriate mode.

Restricted is not an oracle fallback or last-known mark. Oracle validation remains
independent and reverts pricing in every mode when its checks fail. V2 imposes no
cumulative deposit-loss bound beyond these oracle and mode controls.

`depositFeeBps()` returns zero in Regular and `elevatedDepositFeeBps` otherwise; Restricted
execution stays disabled but previews remain conservative. `redemptionFeeBps()` returns
`baseRedemptionFeeBps` in Regular and `elevatedRedemptionFeeBps` otherwise. Requests use the
mode at processing; creation does not snapshot fees.

For storage compatibility, the v1 `depositFeeBps` slot stores
`elevatedDepositFeeBps`; its selector now returns the mode-derived fee. The v1
`feeRecipient` slot remains reserved, unused, and unrepurposed.

| Fee | Destination | Configuration and purpose |
|---|---|---|
| elevated deposit fee (`elevatedDepositFeeBps`) | stays in the vault | anti-dilution against higher-risk entry windows; `setElevatedDepositFee` (`PARAMETER_MANAGER_ROLE`), capped at 500 bps |
| redemption fee (`baseRedemptionFeeBps` / `elevatedRedemptionFeeBps`) | stays in the vault | exits process at cost on average; `setRedemptionFees` (`PARAMETER_MANAGER_ROLE`), `base ≤ elevated ≤ 500`; the gross limit check remains pre-fee |

The intended launch range for the redemption-fee tiers is approximately 5–10 bps; the exact
base and elevated values remain approved launch parameters.

`previewDeposit`/`previewMint` include `depositFeeBps()`. `previewRedeem` remains gross
(`convertToAssets`); `redeem()` is disabled and frontends use §2.6 for net queue proceeds.
Appendix F gives the permission matrix.

### 2.8 Roles

Capability-named (`keccak256("<NAME>_ROLE")`):

| Role | Definition | Scope | Permitted co-location | Timelocked |
|---|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles; authorize UUPS upgrades; rescue untracked vault excess; execute `migrateSTRCMirrorToSTRCon` | StakedUSDat and queue, with separate grants | No other role | Yes |
| `PARAMETER_MANAGER_ROLE` | Set fees, vesting/reward limits, oracle/trade/migration parameters, `recoveryAddress`, the execution vehicle and tolerance, and the active STRCon oracle wrapper | Vault role registry, including checks by bound modules and wrapper | No other role | Yes |
| `MARKET_MODE_MANAGER_ROLE` | Select `REGULAR`, `ELEVATED`, or `RESTRICTED`; cannot set fee amounts or clear hard pause | StakedUSDat | `OPERATOR_ROLE` only | No |
| `OPERATOR_ROLE` | Execute `buy`/`sell`, transfer surplus and STRCMirror rewards, and select/order queue requests for processing | StakedUSDat and queue, with separate grants | `MARKET_MODE_MANAGER_ROLE` only | No |
| `BLACKLISTER_ROLE` | Add/remove the canonical sUSDat blacklist; cannot move or destroy positions | StakedUSDat | No other role | No |
| `ENFORCER_ROLE` | Resolve blacklisted positions through redistribution or seizure; cannot blacklist | StakedUSDat and queue, with separate grants | No other role | Yes |
| `PAUSER_ROLE` | Invoke vault hard pause or queue-local pause; cannot unpause | StakedUSDat and queue, with separate grants | No other role | No |
| `UNPAUSER_ROLE` | Unpause the vault or queue after recovery approval; cannot pause | StakedUSDat and queue, with separate grants | No other role | Yes |

Co-location and delay columns are normative control-manifest constraints, not enforced by
`AccessControl`; deployment, role administration, and monitoring must enforce them. One
address holding different role IDs is co-location even if it is a timelock; holding the
same role on both proxies is not. Timelocked roles are granted only to timelock contracts.
The production manifest defines instances, proposers, executors, delays, signers, and
quorums.

Contract-to-contract gates are not roles: `redeemQueuedShares` uses
`onlyWithdrawalQueue`; `addRequest` uses `onlySUSDAT`. Each is an immutable address check
that no key can re-point or widen.

Deliberate separations: **freeze ≠ seize** (a compromised blacklister can freeze, never
move funds) and **pause ≠ unpause** (a compromised pauser can grief, not un-halt).

**Recovery destination.** StakedUSDat initializes one canonical `recoveryAddress` during
upgrade. `setRecoveryAddress(newAddress)` (`PARAMETER_MANAGER_ROLE`) rejects zero or
sUSDat/USDat-restricted addresses and emits
`RecoveryAddressUpdated(oldAddress, newAddress)`. Every seizure reads the current value and
accepts no destination; the queue stores no copy.

**`seize(from)`** (new, `ENFORCER_ROLE`) transfers a blacklisted holder's sUSDat to
`recoveryAddress` — moves shares, no burn, no liquidity needed. Queue
`seizeRequest(tokenId)` and `seize(tokenId)` send the request NFT or funded USDat to the
same address. `redistributeLockedAmount` remains a burn-and-redistribute operation and has
no recipient.

---

## 3. Migration

Migration has two timelocked transactions separated by a validation gate. Step 1 installs
v2 and moves the legacy mirror state into `STRCMirror` without changing NAV. Step 2 retires
the mirror and recognizes STRCon, subject to `migrateTolBps`.

### 3.1 Step 1 — framework upgrade

1. Deploy the new implementations, `STRCMirror`, `STRConPriceOracle`, and
   `STRConModule`. Bind `STRCMirror` to the sUSDat proxy and the oracle returned by the v1
   `getStrcOracle()`; bind `STRConModule` to the proxy, STRCon, and its new wrapper.
2. Rehearse the exact batch against current mainnet state. A storage-layout error, an
   accounting mismatch, or any v1 queue request still marked `InProgress` blocks
   scheduling; return such requests to `Requested` first.
3. Announce that each legacy `minUsdatReceived` value will become a 6-decimal
   `minSharePrice` per `1e18` shares. Leave requests unchanged and allow owners sufficient
   time after the upgrade to update or cancel before queue processing resumes.
4. Schedule the two `upgradeToAndCall` operations through the five-day timelock. The sUSDat
   reinitializer installs both modules, the approved nonzero `recoveryAddress`, parameters,
   and roles, then maps the legacy vault slots into the renamed `STRCMirror` state:

   ```solidity
   strcMirror.seed({
       initialBalance: strcBalance,
       initialVestingAmount: vestingAmount,
       initialLastDistributionTimestamp: lastDistributionTimestamp,
       initialVestingPeriod: vestingPeriod,
       initialMaxRewardsBps: maxRewardsBps
   });
   ```

   The legacy slots remain reserved. The queue reinitializer installs its approved v2
   configuration without rewriting existing requests.
5. After the delay, execute both upgrades atomically; failure of either reinitializer
   reverts the batch. From this point, the vault cannot buy or sell mirrored STRC, and
   reward and vesting calls target `STRCMirror`.
6. Confirm that pre/post `totalAssets()`, share conversion, and unvested rewards match; all
   five seeded values, module bindings, recovery address, roles, and initial parameters are
   correct; and `STRConModule.balance() == 0`. Any mismatch blocks the validation gate and
   Step 2.

### 3.2 Validation gate (before Step 2)

Run one small STRCon buy/sell round-trip through the execution vehicle. Step 2 remains
blocked until settlement, execution tolerance, custody, and oracle behavior match §2,
`STRCMirror` state is unchanged, and `STRConModule.balance() == 0`. Use the observed
STRCMirror/STRCon oracle basis to approve `migrateTolBps`.

### 3.3 Step 2 — `migrateSTRCMirrorToSTRCon()`

1. Stop `transferInRewards` and wait until `STRCMirror.getUnvestedAmount() == 0`; the live
   `vestingPeriod`, not a fixed 30 days, determines the wait. Any later reward blocks the
   migration.
2. Reconcile the final mirrored position. The execution vehicle obtains and approves the
   full corresponding STRCon amount; incomplete delivery blocks migration.
3. Ensure the approved `migrateTolBps` is active, then schedule
   `migrateSTRCMirrorToSTRCon(expectedStrcon, deadline)` through the
   `DEFAULT_ADMIN_ROLE` timelock.
4. Execute after the delay. The call reverts if the vault is paused, the deadline has
   passed, migration already ran, rewards remain unvested, `STRConModule` is nonzero, either
   position cannot be priced, the exact STRCon transfer fails, or post-migration NAV is
   outside `migrateTolBps`.
5. On success, the vault pulls the exact STRCon amount, calls `STRCMirror.retire()` before
   recognizing the same amount in `STRConModule`, verifies NAV, and marks migration
   complete. The transaction is atomic; failure leaves both positions unchanged.

The timelocked call attests to disposition of the off-chain STRC, which cannot be verified
on chain. After success, `STRCMirror` remains retired at zero and returns zero without an
oracle read; its reward and parameter mutations reject.

---

## 4. Open questions

| # | Question | Blocks | Resolution path |
|---|---|---|---|
| 1 | Execution-vehicle operations: exact vault and vehicle eligibility, funding source, STRCon inventory target, allowance workflow, USDon residual handling, and reconciliation | operational readiness; none of these change vault accounting or its trading ABI | Ondo onboarding + §3.2 |
---

## 5. Migration and launch risks

| Risk | Impact | Gate or mitigation |
|---|---|---|
| Step-1 state migration | Incorrect seeding changes NAV, share price, or reward vesting. | Exact five-field seed mapping, fork rehearsal, atomic upgrade, and pre/post accounting comparison. Any mismatch blocks Step 2. |
| Partner readiness | Although the sUSDat and queue proxy addresses remain, functions move or disappear and bots, indexers, and frontends need the new ABIs and module addresses. | Publish final ABIs, addresses, behavior changes, and upgrade timing; confirm critical partners are ready before Step 1. |
| Legacy queue limits | Reinterpreting `minUsdatReceived` as `minSharePrice` may park or unexpectedly execute an old request. | Announce the change and leave sufficient time to update or cancel before processing resumes; return every `InProgress` request to `Requested` before upgrade. |
| Transition liquidity | Mirrored STRC cannot be sold after Step 1, so queue funding depends on available USDat until STRCon is recognized. | Forecast the transition buffer and communicate that insufficient liquidity delays processing. |
| Step-2 execution | Unvested rewards, incomplete STRCon delivery, invalid pricing, or excessive oracle basis prevent conversion. | Timelock, zero-unvested and zero-STRCon preconditions, exact delivery, NAV tolerance, and atomic reversion. |
| Post-upgrade oracle liveness | Fail-closed pricing can make value-sensitive operations and partner integrations unavailable. | Partners test revert handling; monitoring and the Appendix G recovery runbook remain active. |

Durable product risks—including issuer impairment, after-hours marks, execution authority,
allocation policy, and eligibility—are addressed in §2, §4, and Appendices A, E, and G
rather than repeated here.

---

## Appendix A — Design rationale

Why the §2 choices were made, including rejected alternatives.

**Two fixed modules instead of a generic registry.** `strcBalance` as self-reported
bookkeeping was the largest trust assumption: the processor was constrained only by oracle
± tolerance. On-chain STRCon makes the durable position custody-verifiable. Modules still
isolate asset-specific pricing and recognition, but v2 needs only STRCMirror and
STRConModule; a registry would add runtime NAV authority and loop complexity. A future
asset requires a deliberate vault upgrade adding and authorizing its module.

**Custody and settlement in the vault, not modules.** This avoids fragmentation, centralizes
compliance/seizure, and prevents a NAV-authority module from also moving tokens. The vault
handles ERC20 delivery-versus-payment and execution validation; modules adapt accounting
and oracle prices.

**`balance()` as a counter, not `balanceOf`.** Live-custody recognition would let stray
transfers inflate NAV. STRCon's counter moves only through vault-authorized `buy`/`sell`
and one-shot migration; STRCMirror has enumerated reward/migration mutations. `balanceOf`
is only a custody floor.

**Revert on unpriceable, not a pause flag.** An `isPaused()`-and-last-mark design was
rejected. It adds only view liveness: transfers, `requestRedeem`, and `claim` already remain
live during oracle-only outages. It also requires a forgettable gate on every
value-sensitive path, whereas reverts propagate automatically, and v1 integrations already
treat unreadable price as halt. The last Calculated mark is valid only while the fresh API
reference stays within the approved deviation; otherwise `getPrice()` reverts. This matches
Midas's validated `DataFeed` reverting in mint/redeem while its raw aggregator stays
readable, and Morpho's documented fail-closed oracles for
`borrow`/`withdrawCollateral`/`liquidate`. Only `maxDeposit`/`maxMint` catch and report 0
for ERC-4626.

**Calculated mark with an API circuit breaker.** The Calculated feed is the
value-securing accounting source; the API feed is only a reference. Returning Calculated
keeps NAV unambiguous; continuous API comparison bounds its after-hours lag. Current reads
fully determine validity, so the wrapper needs no health state.

**Immutable feed pair with a rotatable wrapper.** Either feed changes the whole pricing
configuration, so wrappers bind both at deployment rather than edit them independently.
`PARAMETER_MANAGER_ROLE` installs replacements through `STRConModule.setOracle`;
vault-derived authorization avoids separate role graphs.

**Working-capital execution vehicle instead of an on-chain route.** USDat → USDC → STRCon
is not reliably atomic. Encoding it would bring USDC, USDon, quotes, venue changes, and
in-flight receivables into vault accounting. A pre-funded vehicle absorbs them; the vault
sees only an atomic USDat↔STRCon exchange. Backing, DEX, Ondo, or financing changes then
affect vehicle operations, not vault code.

**Vault settlement instead of module settlement.** Letting a module perform transfers would
require allowances and combine accounting with asset-moving authority. Deltas prove the
amount, not the recipient. The vault therefore verifies the incoming leg and sends directly
to the configured vehicle; the module receives only measured amounts for price validation
and counter updates. This reduces authority and token-approval assumptions.

**STRCMirror is not forced through the token-backed interface.** It has no ERC20 custody
delta, so generic `sell(module, ...)` cannot prove delivery. It remains a tokenless
migration bridge with no buys or sales from Step 1 onward; only reward recognition can
increase its balance before Step 2 retirement. This avoids weakening token-backed
settlement with a legacy attestation path.

**sValue-adjusted price bounds.** Static bounds on the STRCon mark compound out of range
(~1%/mo), creating maintenance and eventual halt. Bounding `price / sValue`, the
STRC-equivalent, keeps v1's $20–$150 bounds stationary and reuses the `getSValue` read that
carries the corporate-action pause.

**Mark-to-market for STRCon; no vesting.** Vesting exists to smooth *discrete* reward events
(preventing deposit-sniping around a jump). STRCon dividends already accrue continuously
through `sValue`; smoothing a live price would create exploitable lag. Defenses, in order,
are the Calculated mark, fresh-API after-hours bound, revert rather than mark substitution,
and async execution-priced redemption. The measured ~10–30 bps ex-date step occurs
off-hours, when Elevated applies; Restricted remains reserved for an identified executable
arbitrage. Continue measuring the step per §4.

**Deposits decoupled from buying.** Ondo's venue is 24/5 with spreads and pauses; coupling
would make deposits revert nights and weekends. The cost is cash drag — an allocation
problem, handled by rotations.

**`transferInSurplus` vault-native, not a module.** USDat is settlement, not backing;
vesting alone does not justify cross-contract writes around frequently changed
`usdatBalance`. A separate vesting leg avoids underflow guards on every USDat outflow. Its
bounded size is not expected to materially change an emergency outcome, so it stays
unavailable and needs no emergency accounting path.

**Funding ≠ processing.** A combined `fundAndProcessRedemptions(legs, tokenIds)` was
rejected. A sale precedes processing either way, so queued shares bear its delta and exit at
post-sale NAV. Fusion changes neither incidence nor fee; tooling can batch calls when
atomicity matters. It was also the only path to *exact* per-request realized cost (fee
Option 2); without it, the flat fee applies.

**Per-request settlement, not batch-and-sum.** v1's batch totals existed because one
external USDat pot was distributed pro rata. Vault-priced requests have exact amounts, no
pro-rata math or settlement-generated dust, and can skip unmet limits. Each request uses
current NAV. With a zero redemption fee, sequential fills share one price apart from
rounding because each removes assets and shares proportionally. With a nonzero fee, only
the net payout leaves, so the retained fee accrues to remaining shares and later requests
receive a slightly higher gross price. This order-dependence—including its interaction with
operator-selected ordering and `minSharePrice`—is accepted. The intended 5–10 bps launch
range keeps the effect small but does not eliminate it.

**Queue-side entry with a narrow vault primitive.** The alternative—vault-side processing
that loops queue state—must enforce queue invariants across contracts or delegate back.
Instead, `redeemQueuedShares` burns only queue-held shares at the vault's price when the
buffer covers the whole request. This narrow, one-way trust replaces v1
`burnQueuedShares`' trusted processor amounts.

**Locks removed.** `lockRequests`/`InProgress` protected an in-flight off-chain execution
window (lock → sell STRC over hours → settle at attested price). Atomic settlement at the
validated mark has no such window.

**`minSharePrice` instead of `minUsdatReceived`.** A per-share limit means the same thing
at every order size and compares directly with live share price. Gross execution is checked
before charging the active fee. Legacy values remain unchanged; a communicated grace period
lets owners overwrite or cancel without permanent token-ID/migration branches (§3.1).

**Whole requests instead of partial fills.** v2 closes a request completely or skips it.
This keeps lifecycle linear and `shares` constant, gives one claim per processing event, and
avoids simultaneous open/claimable state. Oversized requests may wait; owners can cancel
and resubmit smaller ones. Insufficient requests are skipped so later smaller ones may fit;
there is no FIFO guarantee.

**Cancellation.** With locks removed and settlement atomic, an open request can be unwound
without an execution race. The owner receives all escrowed shares and the NFT burns.
Pause and blacklist block cancellation, matching queue controls.

**One claim function.** The batch/`claimAll`/`*For` family multiplied every lifecycle change
across five functions. Whole-request settlement needs only `claim(tokenId)`, blocked by
queue-local pause but available during vault pause once USDat is already funded.

**Market mode separate from hard pause.** Regular, Elevated, and Restricted are reversible
operating choices, not incidents. Restricted blocks deposits, settlement, and rotations
while requests, funded claims, and transfers stay live. Vault hard pause contains vault and
sUSDat mutations; queue-local pause separately contains funded claims and queue-only state.
Separate `MARKET_MODE_MANAGER_ROLE` allows later separation from execution despite shared
initial holders. Both fees stay in the vault to offset dilution, not create revenue.
Elevated is the required off-hours mode; Restricted is reserved for identified executable
arbitrage rather than raw oracle divergence.

**Flat redemption fee, two tiers.** Exact per-request cost attribution is a policy choice
rather than a measurement (which module funded what buffer refill?) and requires fused
funding/processing. A measured-spread flat fee targets average cost; governance-set
base/elevated tiers cover normal versus off-hours/stress settlement. Mode selects, but
cannot set, the tier; `setMarketMode(mode)` names it explicitly. The operating runbook
enters Elevated at market close; on-chain session detection from Calculated freshness was
rejected as unnecessary calendar machinery.

**Role taxonomy.** Names follow the OZ/LayerZero capability convention (agent nouns /
`…_MANAGER`), not team/service names. Freeze ≠ seize and pause ≠ unpause limit compromised
keys. Renames change role IDs (`keccak256`), so §3.1 re-grants them. `addRequest` and
`redeemQueuedShares` use immutable counterpart checks because their proxy addresses never
change; roles would let a compromised admin widen access. Market-mode authority remains
separable despite sharing the initial operator address.

**One-shot in-kind `migrateSTRCMirrorToSTRCon()` over attrition.** Selling the mirrored position
over weeks pays spread on the whole book and extends tokenless trust. The vehicle carries
non-atomic acquisition outside NAV; the vault then pulls verifiable custody and atomically
swaps recognition. The NAV assert bounds oracle basis; partial or missing delivery reverts.

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

**Feed roles → Calculated as mark, API as circuit-breaker reference** (§2.3). The
Calculated feed (`0xC353ac4b…AC07`) is the sole value-securing answer even though its
economic value updates only in regular hours — it went **68h without an update** over the
Jun 15 weekend. The API feed (`0x67d4Ae9f…cD91`) tracks premarket and postmarket and
**heartbeats ~24h on a flat price through the weekend closure**. The wrapper always returns
Calculated and requires the latest API answer to be fresh and within `deviationBps`; it
never substitutes the API mark. Set `maxApiStaleness` at ~26h so the 24h heartbeat does not
false-trip. When both feeds update, their measured agreement is ~0.15%, which informs the
normal-basis floor but does not by itself size the always-on `deviationBps`: that parameter
also sets the maximum after-hours move Saturn accepts without halting. Overnight API print
density is sparse (~6.6h between prints in a quiet session), so its timestamp establishes
reference liveness rather than continuous price discovery.

**Session structure (Ondo).** STRC trades all sessions including overnight; the only
scheduled closure is **Friday 8pm ET – Sunday 8pm ET**. Ondo pauses trading for a few
minutes around session transitions. The API reference can continue updating outside
regular hours while Calculated remains at its last regular-hours value, so the wrapper is
defined against feed outputs rather than an on-chain market-hours calendar.

**Volatility.** STRC fell ~$100 → $93.40 over 2026-06-01..05 (−6.6%), recovered to ~$96–97;
the feeds oscillate continuously at their 0.5% deviation threshold. sUSDat NAV carries this
at feed granularity.

**Open (Jun 15 residue).** The ~10-minute window at the 8pm ET ex-event where the equity leg
may still carry the cum-dividend price while sValue has bumped. The wrapper continues to
return Calculated only if the API reference stays within `deviationBps`; a larger temporary
basis halts pricing. The measured residual was small, but pin the window's size with
Ondo/Chainlink as more ex-dates accumulate.

**Data sources.**

| What | Where |
|---|---|
| STRCon token (Ethereum) | `0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c`, 18 dec |
| STRCon/USD (Calculated) Chainlink feed — value-securing mark | `0xC353ac4b425f818Ad87E228bf816E15c2173AC07`, 8 dec, regular-hours economic updates |
| STRCon/USD (Ondo API) Chainlink feed — reference only | `0x67d4Ae9f265270aE123c08D2657536771D19cD91`, 8 dec, ~24h heartbeat, ~0.5% deviation |
| Ondo `SyntheticSharesOracle` (Ethereum) | `0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6` — `getSValue(asset)`, drift params (2% / 24h) |
| Ondo `GMTokenManager` (mint/redeem) | `0x2c158BC456e027b2AfFCCadF1BDBD9f5fC4c5C8c` |
| sValue history API (needs `x-api-key`) | `GET https://api.gm.ondo.finance/v1/assets/STRCon/shares-multiplier?range=all`; also the market-data endpoint |
| STRC daily OHLC | stockanalysis.com **raw** prices (Yahoo returns dividend-adjusted prices that erase ex-date drops — do not use) |

---

## Appendix C — Deferred: in-kind minting (`depositInKind`)

Minting sUSDat directly with STRCon is deferred. V2's UUPS vault permits a later module hook
reusing Appendix D's whitelist/fee pattern, but `ITradableModule` currently has no in-kind
credit hook. Build only for a concrete OTC counterparty.

**Anonymous users use periphery, not the vault:** a wrapper sells STRCon on venue and
deposits cash. The user bears spread/timing at real execution; the vault changes nothing and
extends no trust. Only large, whitelisted entries justify a native path.

**Agreed shape** — the mirror image of instant redemption (Appendix D):

```
// WHITELISTED only, per-period capped
depositInKind(address module, uint256 assetIn, uint256 minShares, address receiver)
  custodyBefore = asset.balanceOf(vault)
  asset.safeTransferFrom(caller, vault, assetIn)
  require(asset.balanceOf(vault) - custodyBefore == assetIn, IncorrectAssetAmount());
  usdValue = module.creditInKind(assetIn)        // validate price, then increment balance()
  shares = convertToShares(usdValue × (1 − inKindFeeBps))   // priced on pre-credit totalAssets
  require(shares >= minShares, SlippageExceeded());
  mint shares to receiver
```

Pricing stays in the module (`creditInKind` marks at the module's validated oracle, so a
tripped oracle reverts the whole path with no gating code); value is computed on pre-credit
`totalAssets()` — standard ERC-4626 deposit ordering. `creditInKind` is a second writer of
`balance()` beside `buy`/`sell` — the real cost of the feature: the §2.2 invariant weakens
from "buy/sell only" to "vault-authorized module calls only."

**Risks (why whitelisted, capped, and fee-floored).** The first three arise because a user
times a vault-priced oracle trade rather than venue execution. Residual risk never reaches
zero; unlike §2.5 rotations, the caller chooses when to trade against the oracle.

- **Stale-mark capture, both directions.** The vault buys STRCon at its own mark, not a
  venue execution; a depositor profits whenever the asset is marked high (movement inside
  the API circuit-breaker bound, sparse/flat reference reporting, common-mode stale pricing,
  or the ex-date window — Appendix B). Observable divergence beyond `deviationBps` reverts,
  but the residual inside the bound remains. Unlike cash deposits, the fee must cover the
  asset's mark error, not just NAV drift.
- **Round-trip arb with instant redemption.** A counterparty holding both permissions can
  in-kind mint at a stale-high mark and instant-redeem at the same NAV;
  `inKindFeeBps + instantExitFeeBps` becomes a hard floor sized to the worst plausible mark
  error, not to cost recovery.
- **Structural adverse selection.** Even honest counterparties route rationally: in-kind
  when the mark beats their venue execution, venue when it doesn't — a per-event-invisible
  drag on holders no fee level fully removes.
- **Second NAV-writer.** A bug in `creditInKind` is direct NAV inflation — mint-from-nothing;
  widens the §2.2 counter-authority invariant.
- **Liquidity degradation.** Adds backing without cash and dilutes the buffer ratio. Because
  v2 has no on-chain allocation or liquidity floor, any later implementation must decide
  whether the in-kind path needs its own cap.
- **Restricted-asset intake.** The vault receives STRCon from third parties rather than only
  buying via Ondo: vault-address eligibility, Ondo transfer restrictions/freezes, and
  post-delivery blacklisting of the depositor become intake-path questions.

---

## Appendix D — Deferred: instant redemptions (`withdraw`/`redeem`)

Whitelist-gated instant exits are deferred; `withdraw`/`redeem` stay disabled and the queue
is the only exit. The final design below ships as a self-contained upgrade only for a
curator/integrator accepting its cap and fee.

**Why deferred.** The cap paradox: a capped, first-come-first-served instant path cannot
assure liquidity at liquidation time, when exits cluster. A small cap is useless; a large
one recreates the buffer race; neither fixes FCFS stress. Calm-market convenience does not
justify adding a rolling cap, fee-bearing previews, a second buffer consumer, and
three-way `maxWithdraw`/`maxRedeem` rounding proofs to this migration. V2.1 ships it as an
isolated, auditable diff.

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

**Rationale retained.** Instant redemption alone is user-timed and value-sensitive:
deposits are atomic but passive, processing/rotations operator-timed, and claims unpriced.
Callers can select bad marks (weekend staleness or ex-date), so whitelist recourse makes a
flat fee sufficient while the queue preserves universal access. Because the operator
atomically batches `sell` and `processRequests`, instant exits touch only the standing
buffer and cannot front-run queue funding.

**Interaction with Appendix C:** shipping in-kind minting and instant redemption to the same
counterparty creates the round-trip arb (mint at a stale-high mark, exit at the same NAV) —
size `inKindFeeBps + instantExitFeeBps` to worst plausible mark error if both ever coexist.

---

## Appendix E — Economic loss reference

This table summarizes §2's economic-incidence rules and Appendix G's operational response;
it creates no reserve or guarantee.

| Event | Treatment |
|---|---|
| STRCon market-price movement | Changes NAV immediately through the Calculated price. |
| Successful buy/sell slippage | Changes NAV atomically; whoever is exposed to sUSDat shares at the trade bears or receives it. |
| Issuer/custodian/redemption impairment | Pause first; holders bear the approved write-down when a recovery price or upgrade recognizes it. |
| Oracle failure | Halts pricing but creates no write-down. Recovery pricing must be installed before resuming. |
| Vehicle/venue failure before settlement | Vehicle working-capital loss stays outside the vault; reverted trades cause only vault liveness loss. |
| USDat depeg | Holders bear the USD loss, but USDat-denominated `totalAssets()` cannot show the depeg. |
| Physical USDat shortfall | Pause immediately; resume only after a governance upgrade accounts for verified recoverable USDat custody. |

---

## Appendix F — Market-mode permissions

Vault hard pause is not a `MarketMode`; it overrides the selected mode for vault and sUSDat
mutations without automatically pausing queue-only actions.

| Operation | Regular | Elevated | Restricted | Vault hard paused |
|---|---|---|---|---|
| Deposit/mint | Yes — no deposit fee | Yes — elevated deposit fee | No | No |
| Create redemption request | Yes | Yes | Yes | No |
| Process redemption | Yes — base redemption fee | Yes — elevated redemption fee | No | No |
| Claim already-funded USDat | Yes | Yes | Yes | Yes |
| Cancel request | Yes | Yes | Yes | No |
| Update request limit | Yes | Yes | Yes | Yes |
| Transfer sUSDat | Yes | Yes | Yes | No |
| Transfer request NFT | Yes | Yes | Yes | Yes |
| Buy/sell STRCon | Yes | Yes | No | No |
| Set market mode | Yes | Yes | Yes | Yes |
| Governance/oracle recovery | Yes | Yes | Yes | Yes |

Read-only views remain available while hard paused as well as in every market mode, subject
to the existing fail-closed oracle checks. A local queue pause independently blocks queue
lifecycle actions and request-NFT movement, whether or not the vault is hard paused.

---

## Appendix G — STRCon impairment response

Asset health is distinct from oracle validity. Credible impairment means evidence that
STRCon's recoverable value may be below the validated Calculated mark, or that Saturn
cannot establish control because of issuer/custodian failure, indefinite freeze,
exact-address de-allowlisting, or unreconciled custody. Routine market closure,
`ASSET_LIMITED`/`ASSET_REDEEM_ONLY` status, or a temporary API/vehicle outage with ownership
and expected recovery intact is not impairment by itself.

The incident owner determines impairment under the runbook; `PAUSER_ROLE`, not
`OPERATOR_ROLE`, immediately pauses the vault. Vault pause blocks deposits, mints, sUSDat
transfers, new requests, rotations, migration, `redeemQueuedShares`, queue processing, and
cancellation. Already-funded claims, request-limit updates, and request-NFT transfers
remain available. Governance, oracle recovery, upgrades, unpause, and enforcement remain
available. Pause the queue separately when funded claims, request-NFT movement, the queue's
USDat, or a compliance incident also needs containment (§2.6).

While paused, the incident owner records custody reconciliation, issuer/custodian and
exact-address eligibility evidence, approved recoverable value and method, and
oracle/settlement validation. For a temporary condition without write-down,
`MARKET_MODE_MANAGER_ROLE` first installs the time-appropriate mode while the vault remains
paused; `UNPAUSER_ROLE` may then resume the vault only after risk approval and a successful
exact-address transfer or redemption test. Permanent impairment requires NAV to reflect
the approved recovery value before resumption: `PARAMETER_MANAGER_ROLE` may install a
reviewed recovery-value wrapper through `STRConModule.setOracle` when the loss is
expressible as a per-STRCon price; otherwise governance executes a timelocked forward
upgrade for the recovery instrument. V2 has no generic haircut setter. The incident record
references the `Paused`, applicable `MarketModeChanged`, `OracleUpdated`, governance, and
`Unpaused` transactions.
