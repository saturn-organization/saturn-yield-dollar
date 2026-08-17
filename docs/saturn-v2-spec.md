# sUSDat v2 — Technical Specification

**Status:** Draft 2 (rewrite of [draft 1](./saturn-v2-upgrade-spec-draft1.md))
**Date:** 2026-07-24
**Scope:** The v2 upgrade of `StakedUSDat` and `WithdrawalQueueERC721`: fixed accounting
modules for the legacy STRC mirror and STRCon, a fixed STRCon execution policy, the
STRC → STRCon migration, and the withdrawal-queue rework. Arbitrary multi-asset support is
deferred.

Layout: §1 summarizes changes; §2 is normative; §3 is the migration runbook; §4–5 track
open questions and risks. Appendices A–G record rationale, empirical findings, deferred
features, economic/mode references, and incident response. After migration, archive §3 and
Appendix B; §2 and Appendices A and E–G remain durable.

---

## 1. What changes

v1 backs sUSDat with a processor-attested, single-oracle mirror of off-chain STRC and
settles redemptions against attested STRC sales. v2 uses two fixed accounting modules,
moves the position to on-chain STRCon, and settles redemptions at NAV from the vault's
buffer. `STRCMirrorModule` exists only to preserve and migrate the v1 position; `STRConModule` is
the sole token-backed tradable module.

### StakedUSDat

| v1 | v2 |
|---|---|
| `strcBalance` mirror accounting, `_strcTotalAssets()` | two fixed module slots plus one fixed STRCon execution-policy slot; `totalAssets()` explicitly includes `STRCMirrorModule.recognizedValue()` and `STRConModule.recognizedValue()` (§2.1–2.2) |
| `convertFromUsdat` / `convertFromStrc` + `_validateConversion` | exact-amount `buy(usdatPaid, assetReceived, expectedVehicle, deadline)` / `sell(assetDelivered, usdatReceived, expectedVehicle, deadline)` (§2.5); vault-context library code settles tokens and directs STRCon accounting, while the fixed policy validates price and rate-limits aggregate turnover |
| vault-global `toleranceBps`, `setTolerance` | fixed-policy `executionToleranceBps`, used only by `buy`/`sell` and capped at 500 bps, plus one policy-owned two-sided execution-capacity bucket |
| hard-wired `StrcPriceOracle`, `getStrcOracle()` | per-module oracles (§2.3) |
| `transferInRewards` + STRC vesting surface | moves into STRCMirrorModule (§2.3); retires with it |
| `burnQueuedShares(shares, strcAmount)` | `redeemQueuedShares(shares, minSharePrice)` (§2.6) |
| `collectDust` | dropped — per-request settlement leaves no dust |
| oracle failure reverts `totalAssets()` and pricing-dependent views | same fail-closed reverts, kept deliberately as an EIP-4626 deviation; `maxDeposit`/`maxMint` catch and report 0 (§2.2) |
| — | `transferInSurplus` cash surplus inlet (§2.1) |
| one configured deposit fee | market-mode fee: zero in Regular, elevated in Elevated, and deposits disabled in Restricted (§2.4, §2.7) |
| — | `MarketMode` selects Regular, Elevated, or Restricted operation; Regular authorization expires fail-safe to Elevated, and hard pause remains separate (§2.7) |
| — | `seize` (§2.8) |
| `PROCESSOR_ROLE`, `COMPLIANCE_ROLE` | capability-named role taxonomy (§2.8) |

Unchanged: the ERC-4626 core with async-redemption overrides (`withdraw`/`redeem` disabled;
`requestRedeem`'s limit becomes `minSharePrice`), deposit variants (permit/min-shares),
blacklist, and `rescueTokens` (generalized, §2.2). Vault pause remains scoped to vault and
sUSDat mutations; queue-local pause separately gates queue-only actions (§2.6).

### WithdrawalQueueERC721

| v1 | v2 |
|---|---|
| `processRequests(tokenIds, totalUsdatReceived, totalStrcSold, executionPrice)` — batch pro-rata against an attested STRC sale | `processRequests(tokenIds)` — whole-request settlement at current NAV from the vault's USDat buffer (§2.6) |
| `claim` + `claimBatch`/`claimAll`/`claimBatchFor`/`claimAllFor` | single `claim(tokenId)` (§2.6) |
| `_validateTotals`, `_isWithinTolerance`, `_validateAmount`, oracle/asset-sale reads | dropped — the queue never knows which backing asset funds the buffer; settlement pricing and fees live in the vault |
| `lockRequests` / `unlockRequests`, `InProgress` | operational locking dropped — settlement is atomic at the validated mark; `resetLegacyInProgressRequest` remains only as an operator recovery path for an inherited `InProgress` request |
| `minUsdatReceived` (absolute payout bound) | `minSharePrice` (6-decimal minimum net USDat payout per `1e18` shares after the active redemption fee, §2.6); the same storage slot is reinterpreted without conversion and legacy owners receive a grace period to update or cancel (§3.1) |
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
move into STRCMirrorModule), `setTolerance` (→ `STRConExecutionPolicy.setExecutionTolerance`),
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

V2 adds `resetLegacyInProgressRequest(tokenId)` as a distinct migration-recovery
selector; it does not restore either v1 locking selector.

---

## 2. V2 specification

Normative. Present tense; rationale in Appendix A.

### 2.1 Vault accounting

```
totalAssets() = usdatBalance
              + (surplusVestingAmount − getUnvestedSurplus() − _surplusSwept)
              + strcMirrorModule.recognizedValue()
              + strconModule.recognizedValue()
```

`totalAssets()` uses 6-decimal USDat units and treats one USDat as one USD; it does not mark
a USDat/USD depeg. `usdatBalance` is idle USDat: the deposit inlet, redemption outlet, and
source/sink of rotations.

**Surplus inlet.** `transferInSurplus(amount)` (`SURPLUS_MANAGER_ROLE`) accepts discretionary USDat
surplus; no amount or schedule is owed to the vault. It enters a segregated
`surplusVestingAmount` leg — in the vault but outside
`usdatBalance` — and vests linearly over `surplusVestingPeriod` (default 3 days, max 7d).
The private `_surplusSwept` checkpoint records the cumulative portion of the active tranche
already folded into `usdatBalance`; it is not an external accounting surface.
`MAX_SURPLUS_BPS` is a fixed 500 bps (5%) protocol constant with no storage slot or
administrative setter.
Only one tranche may exist. A new transfer requires the prior tranche fully vested;
`_sweep()` clears it, then the vault records pre-transfer
`navBefore = totalAssets()` and requires:

```
amount ≤ floor(navBefore × MAX_SURPLUS_BPS / 10_000)
```

The vault pulls its configured USDat asset from the current `surplusSource` with
`safeTransferFrom` before recognizing the tranche. The authorized surplus manager selects only the
amount; it cannot select or supply the source account. `surplusSource` is a dedicated wallet
that holds approved surplus and preapproves the vault to pull approved surplus tranches.

The public `sweep()` is a permissionless, NAV-neutral poke over the private `_sweep()` helper
and remains callable during a hard pause because it transfers no tokens and cannot accelerate
vesting. `_sweep()` also precedes value-sensitive entrypoints and folds only the newly vested
portion into `usdatBalance`. Swept surplus may fund rotations and redemptions; the remaining
segregated amount, `surplusVestingAmount − _surplusSwept`, may not. When vesting completes,
`_sweep()` releases the remainder and clears both tranche variables. No pause or role
accelerates or cancels vesting.

**Economic incidence.** Recognized gains and losses change per-share NAV for accounts
exposed to sUSDat at recognition. Open requests remain exposed; processed requests are
fixed USDat claims. There is no contractual loss reserve, insurance, redemption floor, or
recapitalization guarantee; recapitalization is discretionary. An unpriceable condition
halts pricing without a write-down; impairment enters NAV only through an approved
recovery price or governance upgrade.

**Physical USDat shortfall.** If actual USDat custody falls below
`usdatBalance + surplusVestingAmount − _surplusSwept`, the vault must pause immediately and
remain paused until a governance upgrade adjusts tracked USDat accounting to verified
recoverable custody. V2 has no ordinary shortfall write-down path.

Invariants:
- `totalAssets()` counts each vested unit exactly once, either as swept `usdatBalance` or as
  vested-but-unswept surplus.
- `_surplusSwept ≤ surplusVestingAmount − getUnvestedSurplus()` while a tranche is active.
- `USDat.balanceOf(address(this)) ≥ usdatBalance + surplusVestingAmount − _surplusSwept`.

### 2.2 Module framework

Modules are accounting adapters; custody and ERC20 settlement remain in the vault. Modules
hold no tokens or vault allowances. The v2 reinitializer sets two fixed module slots and
one fixed execution-policy slot:

```solidity
IAccountingModule public strcMirrorModule;
ITradableModule public strconModule;
ISTRConExecutionPolicy public executionPolicy;
```

V2 has no module registry, registration function, loop, or allocation configuration. Both
modules are direct, non-proxy deployments. Each constructor fixes `VAULT`;
`STRConModule` also fixes `ASSET`. `STRConExecutionPolicy` is likewise a direct, non-proxy
deployment whose constructor fixes `VAULT` and `STRCON_MODULE`. None of the three vault
slots has a post-reinitializer setter. Replacing a module, policy, its code, or an immutable
binding requires a new deployment and timelocked vault upgrade. Accounting counters and
explicitly authorized oracle/numeric configuration remain mutable.

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
    function sell(uint256 assetDelivered) external;
}
```

Only the vault calls module `buy` and `sell`; they move no tokens and update `balance()`
from vault-measured amounts. `getPrice()` returns the validated module price;
`STRConExecutionPolicy` calculates execution price, enforces tolerance, and consumes
capacity (§2.5). The vault entrypoints reject zero amounts before calling the module; the
accounting-only module callbacks do not duplicate that validation. USDat and STRCon must be
standard, non-rebasing, non-fee-on-transfer ERC20s without transfer callbacks; each transfer
must produce the exact requested vault balance delta.

`STRCMirrorModule` implements `IAccountingModule`; it is tokenless and has no vault trading
entrypoint. `STRConModule` implements `ITradableModule`. The vault's `buy` and `sell`
entrypoints are hardwired to the fixed `strconModule` and accept no module parameter.
`STRConModule` stores the active STRCon oracle and immutable `VAULT` and `ASSET` addresses.
It has no local role administration; oracle rotation is authorized against the vault's role
registry. The module's valuation and execution math use a fixed 8-decimal price unit, so its
constructor and every oracle rotation require `oracle.decimals() == 8`:

```solidity
interface ISTRConPriceOracle {
    function decimals() external view returns (uint8);
    function getPrice() external view returns (uint256);
}

interface ISTRConModule is ITradableModule {
    function oracle() external view returns (ISTRConPriceOracle);
    function setOracle(address newOracle) external;
}

address public immutable VAULT;
address public immutable ASSET;
ISTRConPriceOracle public oracle;

uint8 public constant ORACLE_DECIMALS = 8;

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
    require(
        ISTRConPriceOracle(newOracle).decimals() == ORACLE_DECIMALS,
        InvalidOracle()
    );
    address oldOracle = address(oracle);
    oracle = ISTRConPriceOracle(newOracle);
    emit OracleUpdated(oldOracle, newOracle);
}
```

The constructor applies the same nonzero, code, and 8-decimal validation when it sets the
initial oracle. A failed or malformed `decimals()` read is an invalid oracle. `setOracle`
changes only the oracle used by `recognizedValue()` and `getPrice()`, not the module, asset,
vault, or recognized balance. The public typed state variable provides the canonical
`oracle()` getter; there is no redundant `getOracle()` function.

**Failure semantics — fail closed; intentional EIP-4626 deviation.** If a module cannot
price, `recognizedValue()` reverts through `totalAssets()`, halting every value-sensitive
path, including mints, queue processing, rotations, and the pricing-dependent
`convertToAssets`, `convertToShares`, and `preview*` views. EIP-4626 requires
`totalAssets()` and its conversion surface not to revert, so this propagation is an
intentional deviation from the standard. Integrators must catch these reverts and treat NAV
as unavailable, not as zero or as authorization to use a cached price. Nonpricing
operations—share transfers, `requestRedeem`, `updateMinSharePrice`, `claim`, and
seizures—remain live. `maxDeposit` and `maxMint` alone normalize a pricing failure to 0.
Manual vault pause follows the STRCon impairment path in Appendix G.

**Rescue.** `rescueTokens(token, amount)` (`ENFORCER_ROLE`) sends only untracked
excess to the current `recoveryAddress`; it accepts no caller-selected destination.
Protected custody is `usdatBalance + surplusVestingAmount − _surplusSwept` for USDat and
`strconModule.balance()` for STRCon; STRCMirrorModule is tokenless. Unsolicited transfers do not
change accounting or NAV, and only custody above the applicable protected amount is
rescuable.

Invariants:
- **Custody floor** (token-backed modules): `asset().balanceOf(vault) ≥ balance()`. Excess
  custody is unrecognized — an external transfer cannot move NAV.
- **Counter authority:** `STRCMirrorModule.balance()` changes only through `seed`,
  `transferInRewards`, and `retire`; `STRConModule.balance()` only through
  vault-authorized `buy` and `sell`. Step 2 recognizes the exact migrated delivery through
  `buy`; it has no separate module balance setter. NAV can also change as surplus or
  STRCMirrorModule rewards vest or module prices move. STRCon's `sValue` affects STRCon
  oracle validation, not STRCMirrorModule; NAV uses the returned Calculated price.
- `recognizedValue()` reverts when unpriceable — no value-sensitive operation, in the vault
  or downstream, can transact against an unreliable mark.
- A zero-balance module returns zero without reading its oracle. After migration,
  STRCMirrorModule can remain fixed at zero without creating a pricing-liveness dependency.
- v2 has no on-chain STRCon allocation cap or minimum USDat buffer. Allocation and liquidity
  targets are operational policy, not contract-enforced limits.

### 2.3 Modules

**STRCMirrorModule** (tokenless migration bridge). `balance()` is a processor-attested off-chain
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

Beginning with Step 1, vault rotations address only `strconModule`;
`STRCMirrorModule.balance()` can increase only through `transferInRewards` until Step 2
retires it. Vault-only
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

`STRConPriceOracle` validates two 8-decimal Chainlink feeds. Its immutable public bindings
are named `primaryFeed()` and `referenceFeed()`. It exposes `decimals()` as the constant
value `8`, matching the scalar price returned by `getPrice()`:

- **Primary feed:** *STRCon-USD (Calculated)*,
  `0xC353ac4b425f818Ad87E228bf816E15c2173AC07`. This is the sole value-securing price
  returned for NAV, minting, queue processing, migration, and trade validation. Its value
  updates during regular market hours and can remain unchanged through premarket,
  postmarket, weekends, and holidays, so it has no short wall-clock staleness limit.
- **Reference feed:** *STRCon/USD (Ondo API)*,
  `0x67d4Ae9f265270aE123c08D2657536771D19cD91`. It updates through premarket and
  postmarket, uses an approximately 50 bps deviation trigger, and has an approximately
  24-hour heartbeat that continues over the weekend. It is a circuit-breaker reference and
  is never returned as the vault's price.

`getPrice()` reads both latest rounds and
`SyntheticSharesOracle.getSValue(STRCon)`, then reverts unless:

1. Both feed calls succeed and each round has `roundId != 0`, `answer > 0`,
   `updatedAt != 0`, `updatedAt <= block.timestamp`, and `answeredInRound >= roundId`.
2. `block.timestamp - reference.updatedAt <= maxApiStaleness`. Initial
   `maxApiStaleness` is 26 hours (24-hour heartbeat plus grace), capped at 36 hours.
3. Ondo's per-asset pause flag is clear and `sValue` is nonzero.
4. `underlyingPrice = Math.mulDiv(primaryPrice, 1e18, sValue, Math.Rounding.Floor)` is
   within `[minPrice, maxPrice]` (default $20–$150). `primaryPrice`, `underlyingPrice`,
   `minPrice`, and `maxPrice` use 8 decimals; `sValue` uses 18.
5. The latest answers satisfy, rounding the full-precision deviation upward:

   ```
   Math.mulDiv(
       abs(primaryPrice - referencePrice),
       10_000,
       primaryPrice,
       Math.Rounding.Ceil
   )
       <= deviationBps
   ```

`getPrice()` returns the validated 8-decimal `primaryPrice`. Each read recomputes
validity, so pricing recovers when all checks pass. The constructor receives the
deployment-approved initial `deviationBps` and immutable maximum deviation; ENG-25 supplies
both before audit freeze. Deleted prototype values are not defaults.

Each `STRConPriceOracle` constructor permanently binds `primaryFeed` and `referenceFeed` and
rejects feeds not reporting 8 decimals. Replacing either feed requires a new wrapper and
`STRConModule.setOracle(newOracle)`, which independently rejects a wrapper unless its
`decimals()` value is 8. Numeric setters use
`onlyVaultRole(PARAMETER_MANAGER_ROLE)` against immutable `VAULT` and emit configuration
events. Oracle rotation remains callable while the vault is paused or the current wrapper
cannot price because it does not require a successful read from the current wrapper.
STRCMirrorModule keeps the deployed v1 `StrcPriceOracle`.

There is no standby STRCon replacement price source or backup wrapper at launch. A permanent
failure or deprecation of the configured source requires Saturn to work with Chainlink to
establish a replacement source, deploy and review a compatible wrapper, and execute the
timelocked `setOracle` rotation. The contract therefore provides a recovery mechanism but
does not guarantee a bounded recovery time. Until a working source is available—or
governance executes a timelocked recovery upgrade—the vault remains fail closed.

#### STRCon operations

- **Execution (`buy`/`sell`): atomic settlement against one execution vehicle.** The
  vehicle funds the non-vault workflow: acquiring or selling USDat, obtaining USDC,
  interacting with Ondo, handling USDon residuals, and carrying STRCon inventory. Its
  legs, balances, quotes, and liabilities stay outside vault accounting; on chain it is
  only the configured counterparty to an exact USDat↔STRCon exchange.
  `STRConExecutionPolicy.setExecutionVehicle(newVehicle)` is authorized by reading
  `PARAMETER_MANAGER_ROLE` from the vault, rejects zero, and emits
  `ExecutionVehicleUpdated(oldVehicle, newVehicle)` from the policy. Replacing the vehicle
  does not replace the policy or module. Each rotation supplies `expectedVehicle`; the
  policy rejects a mismatch with its current vehicle, so a vehicle change invalidates
  pending transactions prepared for the prior counterparty.

  The vault applies the final `usdatBalance` delta before making exactly one linked
  `STRConTradeExecutionLogic.executeBuy` or `executeSell` call. The linked external library runs
  by `DELEGATECALL` in the vault context and therefore performs the complete token and
  module settlement from the vault address. It first calls the fixed policy normally;
  that policy validates the vehicle and realized price against `STRConModule.getPrice()`
  and consumes policy-owned capacity (§2.5). The policy cannot transfer vault assets or
  write vault storage. The library then pulls the vehicle's exact leg with
  `safeTransferFrom`, updates module accounting, sends the vault's exact leg directly to
  the vehicle, and verifies custody floors. The vehicle approves the vault; the vault never
  approves the vehicle, policy, or module. A revert at any point rolls back the vault
  pre-accounting, policy capacity consumption, module accounting, and all token transfers.
  Only recognized STRCon is sellable; excess remains unrecognized.
- **Migration recognition:** there is no migration-only module setter. Step 2 requires a
  zero `STRConModule.balance()`. After the vault's amount, deadline, and zero-balance guards,
  linked `STRConTradeExecutionLogic.executeMigration` runs by `DELEGATECALL` and completes the
  exact STRCon pull, mirror retirement, STRCon recognition, custody-floor check, and
  NAV-tolerance check in the vault context. Mirror retirement supplies the permanent
  one-shot gate.

### 2.4 Deposits

Deposits are atomic, 24/7 when enabled, and enter the cash buffer at validated NAV. Regular
charges no fee; Elevated charges `elevatedDepositFeeBps`; Restricted disables deposits and
mints (`maxDeposit`/`maxMint` return 0, as under hard pause). The anti-dilution fee remains
in `usdatBalance`, never goes to legacy `feeRecipient`. Every deposit/mint variant adds
`whenNotRestrictedMarketMode` to its hard-pause guard and prices against pre-deposit NAV:

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
ISTRConExecutionPolicy public executionPolicy;

function buy(
    uint256 usdatPaid,
    uint256 assetReceived,
    address expectedVehicle,
    uint256 deadline
) external;

function sell(
    uint256 assetDelivered,
    uint256 usdatReceived,
    address expectedVehicle,
    uint256 deadline
) external;
```

`buy` and `sell` return no values. Their caller supplies both exact amounts, successful
execution proves the specified deltas, and `AssetBought` / `AssetSold` record the validated
oracle price.

The production `OPERATOR_ROLE` holder is the Fireblocks wallet. A bot may initiate a
transaction, but Fireblocks policy requires a human to approve its decoded vault target,
`buy`/`sell` selector, exact amount arguments, `expectedVehicle`, and `deadline` before the
wallet signs and submits it. The two exact token legs define the execution price; a separate
price argument would be redundant. The resulting Ethereum transaction also binds the chain,
vault, and account nonce. The vault therefore adds no EIP-712 approval, approval hash, or
second on-chain signature path.

`STRConExecutionPolicy` is the fixed normal-call owner of the execution vehicle, tolerance,
price validation, and capacity:

```solidity
interface ISTRConExecutionPolicy {
    event ExecutionVehicleUpdated(address indexed oldVehicle, address indexed newVehicle);
    event ExecutionToleranceUpdated(uint16 oldBps, uint16 newBps);
    event ExecutionCapacityUpdated(uint128 maximum, uint128 refillPerDay);

    function VAULT() external view returns (address);
    function STRCON_MODULE() external view returns (ISTRConModule);
    function MAX_EXECUTION_TOLERANCE_BPS() external view returns (uint16);

    function executionVehicle() external view returns (address);
    function executionToleranceBps() external view returns (uint16);
    function executionCapacity()
        external
        view
        returns (
            uint128 maximum,
            uint128 available,
            uint128 refillPerDay,
            uint64 lastUpdated
        );

    function initialize(
        address vehicle,
        uint16 toleranceBps,
        uint128 maximum,
        uint128 refillPerDay
    ) external;

    function setExecutionVehicle(address newVehicle) external;
    function setExecutionTolerance(uint16 newBps) external;
    function setExecutionCapacity(uint128 newMaximum, uint128 newRefillPerDay) external;

    function validateBuy(
        uint256 usdatPaid,
        uint256 assetReceived,
        address expectedVehicle
    ) external returns (uint256 oraclePrice);

    function validateSell(
        uint256 assetDelivered,
        uint256 usdatReceived,
        address expectedVehicle
    ) external returns (uint256 oraclePrice);
}
```

The policy is a direct, non-proxy contract with immutable `VAULT` and `STRCON_MODULE`
bindings. `initialize`, `validateBuy`, and `validateSell` are callable only by that vault;
`initialize` is additionally one-shot. Its three setters are called directly on the policy;
each authorizes `msg.sender` by reading
`PARAMETER_MANAGER_ROLE` from the vault's role registry. The policy has no local
`AccessControl`. Its public getters and configuration events are likewise exposed and
emitted by the policy, not the vault. `setExecutionTolerance(newBps)` requires
`newBps ≤ MAX_EXECUTION_TOLERANCE_BPS`, where the maximum is 500 bps. The role is held by
the production timelock, so vehicle, tolerance, capacity, and active STRCon oracle-wrapper
changes are delayed and observable through their respective contracts' update events.

The policy compares the validated 8-decimal STRCon/USD `oraclePrice` from its immutable
`STRCON_MODULE.getPrice()` binding with the 8-decimal execution price in USDat per STRCon,
treating one USDat as one USD. The `1e20` factor converts 6-decimal USDat / 18-decimal
STRCon to that scale. Only adverse execution beyond the policy's
`executionToleranceBps` is rejected:

```solidity
buyPrice = Math.mulDiv(usdatPaid, 1e20, assetReceived, Math.Rounding.Ceil);
maxBuyPrice = Math.mulDiv(
    oraclePrice,
    10_000 + executionToleranceBps,
    10_000,
    Math.Rounding.Floor
);
require(buyPrice <= maxBuyPrice, ExecutionPriceMismatch());

sellPrice = Math.mulDiv(usdatReceived, 1e20, assetDelivered, Math.Rounding.Floor);
minSellPrice = Math.mulDiv(
    oraclePrice,
    10_000 - executionToleranceBps,
    10_000,
    Math.Rounding.Ceil
);
require(sellPrice >= minSellPrice, ExecutionPriceMismatch());
```

Buying below the oracle range and selling above it remain valid. The policy's single,
two-sided token bucket additionally bounds cumulative turnover across both functions.

When `validateBuy` or `validateSell` runs, the policy first accrues
`floor(refillPerDay × (block.timestamp − lastUpdated) / 1 days)`, capped at `maximum`.
The trade must fit within the resulting available capacity, then subtracts its charge and
sets `lastUpdated = block.timestamp`. Any later settlement failure rolls back the policy
call and its capacity consumption with the rest of the transaction.
Both buys and sells consume the same bucket, and reverse trades never refund capacity, so
splitting or alternating directions cannot evade the aggregate limit. The
`executionCapacity()` getter reports currently accrued `available` capacity without
mutating its stored checkpoint.

The charge is the greater of the exact USDat leg and the STRCon leg's oracle notional:

```solidity
uint256 buyOracleNotional = Math.mulDiv(
    assetReceived,
    oraclePrice,
    1e20,
    Math.Rounding.Ceil
);

uint256 sellOracleNotional = Math.mulDiv(
    assetDelivered,
    oraclePrice,
    1e20,
    Math.Rounding.Ceil
);

uint256 buyCharge = Math.max(usdatPaid, buyOracleNotional);
uint256 sellCharge = Math.max(usdatReceived, sellOracleNotional);
```

All values are 6-decimal USDat units after conversion. Charging the maximum prevents either
the actual USDat leg or its oracle value from understating measured turnover. Starting from
a full bucket, turnover over an interval of `T` is bounded by
`maximum + floor(refillPerDay × T / 1 days)`. Combined with the adverse-only per-trade
tolerance, cumulative adverse execution is conservatively bounded by that turnover
multiplied by `executionToleranceBps / 10_000`. A second loss accumulator is therefore not
added.

Policy function `setExecutionCapacity` first accrues under the old configuration, then
updates the maximum and refill rate and clamps `available` to the new maximum; it never
refills the bucket merely because configuration changed. Setting the maximum to zero
disables rotations. Policy initialization sets `maximum` and `available` to
`initialExecutionCapacity`, sets `refillPerDay` to
`initialExecutionRefillPerDay`, and sets `lastUpdated` to the initialization timestamp.

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
    uint256 assetDelivered,
    uint256 usdatReceived,
    uint256 oraclePrice
);
```

These two settlement events are declared by the linked library but, because it runs by
`DELEGATECALL`, are emitted from the vault address.

Both functions are `whenNotPaused`, `whenNotRestrictedMarketMode`, and `nonReentrant`; reject zero
amounts and an expired deadline; use the fixed `strconModule` and `executionPolicy`; and
accept no module parameter, USDC amount, Ondo quote or separate signature, route, target,
arbitrary calldata, or vehicle-reported result.

At execution, the linked library makes one ordinary call to the fixed policy. The policy
requires `expectedVehicle == executionVehicle`, reads the current module oracle price and
policy tolerance, validates the adverse execution bound, and consumes policy capacity.
`expectedVehicle` snapshots the counterparty, while the timelocked parameter paths govern
the oracle wrapper, tolerance, and capacity. The exact amounts, expected vehicle, and
`deadline` are the operator's commitment; v2 adds no freshness bound beyond the deadline,
so it must match the intended approval window.

After `_sweep()` releases newly vested surplus into `usdatBalance`, each rotation calls
`totalAssets()` before settlement so the fail-closed rule in §2.2 covers both fixed modules.
The settlement order below begins only after that pricing preflight succeeds. The vault then
applies its tracked-cash delta before exactly one linked-library call; all remaining policy
validation and settlement occurs inside that call.

**Buy order:** require `usdatBalance ≥ usdatPaid`; decrement `usdatBalance`; call linked
`STRConTradeExecutionLogic.executeBuy` once by `DELEGATECALL`; normally call
`executionPolicy.validateBuy`; pull exactly `assetReceived` of
`strconModule.asset()` from `expectedVehicle`; call
`strconModule.buy(assetReceived)`; transfer exactly `usdatPaid` USDat to
`expectedVehicle`; assert custody floors; emit `AssetBought`. The fixed
`STRConModule.buy` deterministically increases its accounting balance by `assetReceived`,
so the vault does not duplicate that module-internal transition with a before/after module
balance check.

**Sell order:** increment `usdatBalance` by `usdatReceived`; call linked
`STRConTradeExecutionLogic.executeSell` once by `DELEGATECALL`; normally call
`executionPolicy.validateSell`; pull exactly `usdatReceived` USDat from
`expectedVehicle`; call `strconModule.sell(assetDelivered)`; transfer exactly
`assetDelivered` of `strconModule.asset()` to `expectedVehicle`; assert custody floors;
emit `AssetSold`. The fixed `STRConModule.sell` enforces recognized balance and
deterministically decreases its accounting balance by `assetDelivered`, so the vault does
not duplicate that module-internal transition with a before/after module balance check.

The policy call is a normal `CALL`, so it executes against policy storage and cannot mutate
vault storage or move vault assets. The linked library executes in the vault context, so
its token calls move vault custody. It receives all required contracts and post-accounting
values as arguments and contains no direct vault-storage writes or hardcoded storage slots.
Any failure—including a later transfer, module, delta, or custody-floor failure—reverts the
whole Ethereum transaction, restoring the policy capacity, vault accounting, module
accounting, and token balances.

Relative to entry-state balances, a successful call has these exact deltas:

| Value | `buy` | `sell` |
|---|---:|---:|
| `USDat.balanceOf(vault)` | `−usdatPaid` | `+usdatReceived` |
| `usdatBalance` | `−usdatPaid` | `+usdatReceived` |
| `strconModule.asset().balanceOf(vault)` | `+assetReceived` | `−assetDelivered` |
| `strconModule.balance()` | `+assetReceived` | `−assetDelivered` |

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
prices (§2.2; v1's 10-USDat minimum required `previewRedeem`). `maxRedeem(owner)` returns
zero when the vault is paused or the owner is restricted, and otherwise returns the owner's
raw share balance; `requestRedeem` enforces that limit before escrowing shares:

```solidity
enum RequestStatus { NULL, Requested, InProgress, Processed, Claimed, Cancelled }

struct Request {
    uint256 shares;          // full escrowed amount; v2 does not partially fill
    uint256 usdatOwed;       // zero until the complete request is processed
    uint256 timestamp;
    uint256 minSharePrice;   // 6-decimal minimum net USDat per 1e18 shares (reuses v1 slot)
    RequestStatus status;    // InProgress retained and Cancelled appended for storage compatibility
}
```

Lifecycle is `Requested → Processed → Claimed` or `Requested → Cancelled`. `InProgress`
only preserves v1 numbering and v2 never creates it. `OPERATOR_ROLE` may atomically
return an explicitly selected legacy `InProgress` request to `Requested`, including while
the queue is paused; the selected request must have that exact status.
Processed USDat stays in the queue until claimed. There are no partial fills: the stored
`shares` value is never decremented; the corresponding escrowed shares are either burned
on complete settlement or returned on cancellation.

**Limit semantics.** `minSharePrice` is the minimum **net** USDat payout in 6-decimal USDat
per `1e18` shares, checked after deducting the active redemption fee selected at processing.
A below-limit request is skipped and remains open until its net payout price recovers, its
owner changes the limit with `updateMinSharePrice`, or cancels. The owner may raise or lower
it while the request is open and the queue active.

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
  empty input → return
  vault.beginRedemptionBatch()
  for each request in caller-supplied order:
    if token does not exist or status != Requested → continue
    (result, usdat) = vault.redeemQueuedShares(request.shares, request.minSharePrice)
    if result == BelowLimit → continue                 // request stays open
    if result == InsufficientLiquidity → continue      // a later smaller request may fit
    request.usdatOwed = usdat
    request.status = Processed
  vault.endRedemptionBatch()
```

The queue does not inspect `marketMode()`. `redeemQueuedShares` owns the Restricted-mode
gate, so a non-empty batch reverts atomically in Restricted mode; an empty batch remains a
no-op.

Duplicate IDs need no separate validation. A skipped request may be retried later in the
same caller-supplied sequence. Once an occurrence settles, its status becomes `Processed`,
so any later duplicate is skipped. Missing, cancelled, closed, and already-settled IDs likewise
cannot block otherwise valid requests or burn shares twice.

```solidity
// StakedUSDat — queue-only; price, check, burn, and transfer atomically
function beginRedemptionBatch() external onlyWithdrawalQueue;
// assetBasis = totalAssets() + 1 after _sweep()
// shareBasis = totalSupply() + 10 ** _decimalsOffset()
// both values are held in transaction-scoped transient storage
function redeemQueuedShares(uint256 shares, uint256 minSharePrice)
    external onlyWithdrawalQueue whenNotPaused whenNotRestrictedMarketMode
    returns (RedemptionResult result, uint256 usdat);
// require an active batch
// gross = Math.mulDiv(shares, assetBasis, shareBasis, Math.Rounding.Floor)
// feeBps = redemptionFeeBps(); stable throughout this processRequests execution
// fee = Math.mulDiv(gross, feeBps, 10_000, Math.Rounding.Ceil)
// net = gross - fee
// netSharePrice = Math.mulDiv(net, 1e18, shares, Math.Rounding.Floor)
// netSharePrice < minSharePrice → BelowLimit
// (equivalent to net < ceil(shares * minSharePrice / 1e18), without limit overflow)
// usdatBalance < net → InsufficientLiquidity
// otherwise burn every share, decrement usdatBalance by net,
// transfer net USDat to the queue, retain the fee in the vault, and return Settled
function endRedemptionBatch() external onlyWithdrawalQueue;
// explicitly clears the transient snapshot
```

Expected no-settlement outcomes return a result without reverting the batch. Missing and
non-Requested IDs are skipped before calling the vault. An insufficient request is skipped so a
later smaller one may settle. Unexpected pricing, accounting, authorization, or transfer failures
still revert the complete batch. The operator selects and orders IDs; there is no FIFO guarantee.

The vault snapshots the exact ERC4626 asset and share bases once before processing. Every request
in that `processRequests` call uses the same rational price even though each successful settlement
raises the live accounting PPS. The active fee tier is read for each request but cannot change
during that `processRequests` execution. Per-request floor/ceil rounding still applies. The next
`processRequests` call takes a fresh price snapshot that includes prior retained fees. The operator
selects batch composition and order; there is no FIFO guarantee.

The snapshot uses EIP-1153 transient storage, which is separate from persistent proxy storage and
is automatically cleared at transaction end. The queue also explicitly closes the snapshot so two
`processRequests` calls in one outer transaction form separate batches. V2 deployment tooling pins
Solidity 0.8.36 and targets Cancun or newer. Any future change to this vault/queue batch interface
upgrades both proxies atomically.

Even for a buggy queue, `redeemQueuedShares` burns only queue-held shares at the batch-snapshotted
vault NAV and fee, and settles only a complete, buffer-covered request while processing is
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
function _requireNotRestricted(address account) internal view {
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

A restricted owner cannot update its limit, cancel, or claim. Every ordinary request-NFT
transfer, including both `safeTransferFrom` overloads, requires the caller/operator, `from`,
and `to` to be unrestricted. This does not apply to enforcement transfers.
`seizeRequest(tokenId)` transfers an open NFT from that owner to
`StakedUSDat.recoveryAddress()`; `seize(tokenId)` pays a processed request's `usdatOwed`
there, marks it claimed, and burns the NFT. Neither accepts a destination. Both are
single-token `ENFORCER_ROLE` operations (§2.8). For these queue seizures, either a local
sUSDat blacklist or a USDat freeze establishes eligibility because the NFT represents a
claim through the USDat redemption path. This is intentionally broader than seizure of
directly held sUSDat, which requires an explicit local sUSDat blacklist; a USDat freeze
alone restricts the holder's ordinary vault activity but does not authorize seizure of its
directly held shares.

Invariants:
- A request is settled completely or not at all; v2 never partially burns its shares.
- Every processed request is priced at current gross NAV, pays that gross value net of the
  active redemption fee, and satisfies its `minSharePrice` on that net payout per share.
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
enum MarketMode { Regular, Elevated, Restricted }

uint64 public constant MAX_REGULAR_MODE_VALIDITY = 8 hours;
uint64 public regularModeValidUntil;
/// @custom:oz-renamed-from marketMode
MarketMode private _configuredMarketMode;

function marketMode() public view returns (MarketMode);

event MarketModeChanged(MarketMode oldMode, MarketMode newMode);
event RegularModeAuthorized(uint64 validUntil);

modifier whenNotRestrictedMarketMode() {
    require(marketMode() != MarketMode.Restricted, MarketRestricted());
    _;
}

function setMarketMode(MarketMode newMode)
    external onlyRole(MARKET_MODE_MANAGER_ROLE);

function authorizeRegularMode(uint64 validUntil)
    external onlyRole(MARKET_MODE_MANAGER_ROLE);
```

The vault stores a configured mode separately from the effective mode returned by
`marketMode()`. Configured Elevated and Restricted are always effective. Configured Regular
is effective only while `block.timestamp < regularModeValidUntil`; at
`block.timestamp >= regularModeValidUntil`, `marketMode()` returns Elevated. Expiry is a
view-time rule: it does not mutate storage and emits no event. Every internal mode check,
fee getter, preview, `maxDeposit`, and `maxMint` uses the effective `marketMode()`.

`setMarketMode` accepts only Elevated or Restricted. Passing Regular reverts with
`InvalidRegularModeAuthorization()`. It emits
`MarketModeChanged(MarketMode oldEffectiveMode, MarketMode newMode)`.
`authorizeRegularMode(validUntil)` is the only route to configured Regular. It requires
`block.timestamp < validUntil <= block.timestamp + MAX_REGULAR_MODE_VALIDITY`; an invalid,
expired, or too-distant deadline reverts with `InvalidRegularModeAuthorization()`. Every
successful authorization or renewal sets `regularModeValidUntil`, configures Regular,
emits `MarketModeChanged(oldEffectiveMode, MarketMode.Regular)`, and emits
`RegularModeAuthorized(uint64 validUntil)`.

Both functions remain callable while hard paused so the time-appropriate mode can be
installed before unpause. Neither can price assets, move funds, change NAV, or clear a hard
pause. `MARKET_MODE_MANAGER_ROLE` initially shares the `OPERATOR_ROLE` address; either may
later be reassigned independently.

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
  market-mode changes, permissionless surplus `sweep()`, governance, oracle recovery,
  upgrade, unpause, and enforcement remain available.

Mode transitions are an operational requirement; the vault has no market-hours calendar.
While the U.S. regular session is confirmed open, an authorized keeper may authorize
Regular only through a future deadline no more than eight hours away. The deadline should
not extend beyond the confirmed session. At each regular-session close—normally 4:00 p.m.
ET, or the scheduled early close—`MARKET_MODE_MANAGER_ROLE` still sets Elevated. If that
transaction is missed, Regular expires to effective Elevated at its deadline on the next
view or interaction. Elevated remains active through postmarket, overnight, premarket,
weekends, and holidays.

Returning from effective Elevated or Restricted to Regular requires a fresh
`authorizeRegularMode` transaction based on the keeper's confirmation that the regular
session is open. The existing STRCon oracle and its freshness/divergence checks are pricing
controls; they do not prove that the market is open. On-chain Regular authorization records
the authorized keeper's market-open attestation, not independent oracle evidence.
Monitoring indexes every `RegularModeAuthorized` event, alerts before
`regularModeValidUntil`, and alerts when effective mode becomes Elevated without an
explicit `MarketModeChanged` transaction. The production control manifest names the
primary monitoring owner, fallback keeper, and risk approver.

Restricted is reserved solely for a credible executable protocol arbitrage identified by
monitoring. Raw API/Calculated divergence alone does not trigger it; an identified
arbitrage triggers Restricted regardless of that divergence. Once the arbitrage is no
longer executable, `MARKET_MODE_MANAGER_ROLE` restores Elevated with `setMarketMode` or
authorizes Regular with fresh evidence, as time-appropriate.

Restricted is not an oracle fallback or last-known mark. Oracle validation remains
independent and reverts pricing in every mode when its checks fail. V2 imposes no
cumulative deposit-loss budget or mode-dependent deposit cap beyond these oracle and mode
controls.

`depositFeeBps()` returns zero when effective `marketMode()` is Regular and
`elevatedDepositFeeBps` otherwise; Restricted execution stays disabled but previews remain
conservative. `redemptionFeeBps()` returns `baseRedemptionFeeBps` in effective Regular and
`elevatedRedemptionFeeBps` otherwise. Requests use the effective mode at processing;
creation does not snapshot fees.

For storage compatibility, the v1 `depositFeeBps` slot stores
`elevatedDepositFeeBps`; its selector now returns the mode-derived fee. The v1
`feeRecipient` slot remains reserved, unused, and unrepurposed.

| Fee | Destination | Configuration and purpose |
|---|---|---|
| elevated deposit fee (`elevatedDepositFeeBps`) | stays in the vault | anti-dilution against higher-risk entry windows; `setElevatedDepositFee` (`PARAMETER_MANAGER_ROLE`), capped at 500 bps |
| redemption fee (`baseRedemptionFeeBps` / `elevatedRedemptionFeeBps`) | stays in the vault | protects remaining holders against liquidity-sensitive exits; `setRedemptionFees` (`PARAMETER_MANAGER_ROLE`), `base ≤ elevated ≤ 500`; the net payout limit is checked after the active fee; each retained fee immediately accrues to remaining shares |

The intended launch range for the redemption-fee tiers is approximately 5–10 bps; the exact
base and elevated values remain approved launch parameters.

`previewDeposit`/`previewMint` include `depositFeeBps()`. `previewWithdraw` returns zero because
`withdraw()` is disabled. `previewRedeem(shares)` returns the same net payout used by
`redeemQueuedShares`: gross `convertToAssets(shares)` less the active redemption fee rounded up.
`redeem()` remains disabled. The fee is not snapshotted at request creation. Appendix F gives the
permission matrix.

### 2.8 Roles

Capability-named (`keccak256("<NAME>_ROLE")`):

| Role | Definition | Scope | Permitted co-location | Timelocked |
|---|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles; authorize UUPS upgrades; execute `migrate` | StakedUSDat and queue, with separate grants | No other role | Yes |
| `PARAMETER_MANAGER_ROLE` | Set vault fees, vesting/reward limits, migration parameters, `recoveryAddress`, and `surplusSource`; directly set the fixed policy's execution vehicle, tolerance and capacity; set the active STRCon oracle wrapper | Vault role registry, including direct authorization reads by the fixed policy, bound modules, and wrapper | No other role | Yes |
| `MARKET_MODE_MANAGER_ROLE` | Set Elevated or Restricted and grant expiring Regular authorization for at most eight hours; cannot set fee amounts or clear hard pause | StakedUSDat | `OPERATOR_ROLE` only | No |
| `OPERATOR_ROLE` | Execute `buy`/`sell`, transfer STRCMirrorModule rewards, and select/order queue requests for processing | StakedUSDat and queue, with separate grants | `MARKET_MODE_MANAGER_ROLE` only | No |
| `SURPLUS_MANAGER_ROLE` | Start a capped surplus tranche from the configured `surplusSource`; cannot select the source or destination | StakedUSDat | No other role | No |
| `BLACKLISTER_ROLE` | Add/remove the canonical sUSDat blacklist; cannot move or destroy positions | StakedUSDat | No other role | No |
| `ENFORCER_ROLE` | Seize locally blacklisted sUSDat positions, seize queue claims eligible under the sUSDat blacklist or USDat freeze list, and rescue untracked vault excess; cannot blacklist or freeze | StakedUSDat and queue, with separate grants | No other role | Yes |
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

Deliberate separations: for directly held sUSDat, **USDat freeze ≠ sUSDat seizure** (only
the local sUSDat blacklist authorizes seizure of shares), and **pause ≠ unpause** (a
compromised pauser can grief, not un-halt). Queue claims are the deliberate exception:
either restriction list authorizes their seizure because they resolve through USDat.

For ordinary vault activity, an account is restricted when it is either on the canonical
sUSDat blacklist or frozen on USDat. Deposits, share transfers, request-NFT transfers, and
redemption requests reject restricted callers, owners, senders, and receivers. In every
delegated sUSDat or request-NFT transfer, the caller/operator is checked independently from
`from` and `to`. `isBlacklisted(account)` reports only the local sUSDat list;
`isRestricted(account)` reports the union of both systems.
Removing the local blacklist does not override an active USDat freeze.

The execution policy's parameter setters are not vault forwarding functions. The authorized
timelock calls the fixed policy directly, and the policy verifies the caller with
`IAccessControl(VAULT).hasRole(PARAMETER_MANAGER_ROLE, msg.sender)`.

**Recovery destination.** StakedUSDat initializes one canonical `recoveryAddress` during
upgrade. `setRecoveryAddress(newAddress)` (`PARAMETER_MANAGER_ROLE`) rejects zero or
sUSDat/USDat-restricted addresses and emits
`RecoveryAddressUpdated(oldAddress, newAddress)`. Every seizure and token rescue reads the
current value and accepts no destination; the queue stores no copy.

**Surplus source.** StakedUSDat initializes one `surplusSource` used as the source of future
surplus tranches. `setSurplusSource(newSource)`
(`PARAMETER_MANAGER_ROLE`) remains callable while paused, rejects zero, the vault, the withdrawal
queue, or an sUSDat/USDat-restricted address, and emits
`SurplusSourceUpdated(oldSource, newSource)`. Each surplus transfer reads the current value;
`SURPLUS_MANAGER_ROLE` cannot rotate it.

**`seize(from)`** (new, `ENFORCER_ROLE`) transfers a blacklisted holder's sUSDat to
`recoveryAddress` — moves shares, no burn, no liquidity needed. Queue
`seizeRequest(tokenId)` and `seize(tokenId)` send the request NFT or funded USDat to the
same address. V2 removes the v1 `redistributeLockedAmount` burn-and-redistribute path.

### 2.9 V2 initialization and migration tolerance

The Step 1 vault upgrade uses one reinitializer with two statically typed configuration
structs:

```solidity
struct V2Config {
    ISTRCMirrorModule strcMirrorModule;
    ISTRConModule strconModule;
    ISTRConExecutionPolicy executionPolicy;
    address recoveryAddress;
    address surplusSource;
    address executionVehicle;
    uint16 baseRedemptionFeeBps;
    uint16 elevatedRedemptionFeeBps;
    uint16 elevatedDepositFeeBps;
    uint16 executionToleranceBps;
    uint16 migrationToleranceBps;
    uint128 initialExecutionCapacity;
    uint128 initialExecutionRefillPerDay;
}

struct V2Roles {
    address parameterManager;
    address marketModeManager;
    address operator;
    address surplusManager;
    address blacklister;
    address enforcer;
    address pauser;
    address unpauser;
}

function initializeV2(V2Config calldata config, V2Roles calldata roles)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
    reinitializer(2);
```

`initializeV2` validates both modules' immutable `VAULT` bindings, the policy's immutable
`VAULT` and `STRCON_MODULE` bindings, a zero initial `STRConModule.balance()`, and a
`surplusSource` that satisfies the same destination checks as later rotations. It
permanently binds the two module slots and the execution-policy slot, installs vault-owned
configuration through the same internal setters used after initialization, grants each role
in `V2Roles`, sets `surplusVestingPeriod = 3 days`, configures Elevated, and sets
`regularModeValidUntil = 0`. The vault therefore begins in effective Elevated mode.
The initializer requires `config.migrationToleranceBps <=
MAX_MIGRATION_TOLERANCE_BPS` and installs that reviewed Step 1 value.
Entering Regular after the upgrade requires a separate fresh `authorizeRegularMode`
transaction whose deadline is strictly in the future and no more than
`MAX_REGULAR_MODE_VALIDITY` after authorization.

Within that same reinitializer, the vault calls
`config.executionPolicy.initialize(config.executionVehicle,
config.executionToleranceBps, config.initialExecutionCapacity,
config.initialExecutionRefillPerDay)`. Policy initialization is one-shot and sets
`maximum = available = initialExecutionCapacity`,
`refillPerDay = initialExecutionRefillPerDay`, and `lastUpdated` to the current timestamp.
The upgrade, mirror seeding, vault configuration, policy initialization, and role grants
are one Ethereum transaction; any failure rolls all of them back. The reinitializer
preserves the existing `DEFAULT_ADMIN_ROLE` holders and hard-pause state.

The caller does not supply the legacy mirror state. The reinitializer reads
`strcBalance`, `vestingAmount`, `lastDistributionTimestamp`, `vestingPeriod`, and
`maxRewardsBps` directly from their preserved proxy slots and passes those exact values to
`STRCMirrorModule.seed`. Oracle-wrapper parameters remain properties of the separately deployed
wrapper rather than initializer calldata.

Migration tolerance is a reviewed Step 1 initializer argument:

```solidity
uint16 public constant MAX_MIGRATION_TOLERANCE_BPS = 500;
uint16 public migrationToleranceBps;

event MigrationToleranceUpdated(uint16 oldBps, uint16 newBps);

function setMigrationTolerance(uint16 newBps)
    external
    onlyRole(PARAMETER_MANAGER_ROLE);
```

Both initialization and `setMigrationTolerance` require the supplied value to be at most
`MAX_MIGRATION_TOLERANCE_BPS`, store the new value, and emit
`MigrationToleranceUpdated`. The active value may be materially below the 500-bps
governance ceiling. Completion is recorded by the fixed mirror's permanent `retired` state
rather than a duplicate vault boolean.

After its role, pause, deadline, nonzero-amount, and zero-STRCon-balance guards, the vault
makes exactly one linked-library call:

```solidity
STRConTradeExecutionLogic.executeMigration(
    strcMirrorModule,
    strconModule,
    executionPolicy.executionVehicle(),
    expectedStrcon,
    migrationToleranceBps
);
```

`executeMigration` runs by `DELEGATECALL` in the vault context and completes the migration.
It measures the absolute whole-vault NAV change against pre-migration NAV:

```solidity
uint256 navBefore = totalAssets();
require(navBefore != 0, ZeroNAV());

uint256 strconCustody = _pullExact(strcon, executionVehicle, expectedStrcon);
strcMirrorModule.retire();
strconModule.buy(expectedStrcon);

uint256 navAfter = totalAssets();
uint256 delta =
    navAfter >= navBefore ? navAfter - navBefore : navBefore - navAfter;
require(
    delta <= Math.mulDiv(navBefore, migrationToleranceBps, 10_000),
    MigrationNAVMismatch()
);

require(strconCustody >= strconModule.balance(), CustodyShortfall());
```

The allowed-delta comparison is equivalent to requiring the upward-rounded basis-point
difference to be no greater than `migrationToleranceBps`. It bounds both upward and
downward discontinuities, and a zero active tolerance requires exact pre/post NAV equality.
`STRCMirrorModule.retire()` enforces completed vesting and permanently makes `migrate`
one-shot; any later call rejects, while a failed transaction rolls retirement back.

---

## 3. Migration

Migration has two timelocked transactions separated by a validation gate. Step 1 installs
v2 and moves the legacy mirror state into `STRCMirrorModule` without changing NAV. Step 2 retires
the mirror and recognizes STRCon, subject to `migrationToleranceBps`.

### 3.1 Step 1 — framework upgrade

1. Deploy the new implementations, `STRCMirrorModule`, `STRConPriceOracle`,
   `STRConModule`, and `STRConExecutionPolicy`. Bind `STRCMirrorModule` to the sUSDat proxy
   and the oracle returned by the v1 `getStrcOracle()`; bind `STRConModule` to the proxy,
   STRCon, and its new wrapper; bind `STRConExecutionPolicy` to the proxy and that exact
   `STRConModule`.
2. Rehearse the exact batch against current mainnet state. A storage-layout error or an
   accounting mismatch blocks scheduling. Record every v1 queue request still marked
   `InProgress`; either unlock it in v1 before the upgrade or prepare an operator
   `resetLegacyInProgressRequest` call for each ID after the upgrade.
3. Announce that each legacy `minUsdatReceived` value will become a 6-decimal minimum net
   `minSharePrice` per `1e18` shares after the active redemption fee. Leave requests
   unchanged and allow owners sufficient time after the upgrade to update or cancel before
   queue processing resumes.
4. Schedule the two `upgradeToAndCall` operations through the five-day timelock. The sUSDat
   `initializeV2(config, roles)` call defined in §2.9 installs both modules and the fixed
   execution policy, installs the approved valid `recoveryAddress` and `surplusSource`, parameters, and roles,
   initializes effective Elevated with no outstanding Regular authorization, atomically
   initializes the migration tolerance and the policy's vehicle, execution tolerance,
   capacity, and refill rate, and maps the legacy vault slots into the renamed
   `STRCMirrorModule` state:

   ```solidity
   strcMirrorModule.seed({
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
   reward and vesting calls target `STRCMirrorModule`. The reinitializer preserves the prior hard
   pause state. If the vault is unpaused, Elevated-mode deposit and settlement permissions
   apply immediately; operators still
   withhold queue processing for the communicated legacy-request grace period.
6. Confirm that pre/post `totalAssets()`, share conversion, and unvested rewards match; all
   five seeded values, module and policy bindings, recovery address, roles, vault
   parameters, and policy vehicle/tolerance/capacity values are correct; and
   `STRConModule.balance() == 0`. Any mismatch blocks the validation gate and Step 2.

### 3.2 Validation gate (before Step 2)

1. Run one small STRCon buy/sell round-trip through the execution vehicle.
2. Confirm from the observed STRCMirrorModule/STRCon oracle basis that the initialized
   `migrationToleranceBps` remains conservative and sufficient. Any approved adjustment
   must be active before scheduling Step 2 and remain at or below the 500-bps hard cap
   defined in §2.9.
3. Call `resetLegacyInProgressRequest` once for each inherited `InProgress` ID and rescan
   the complete inventory. The selector preserves the queue's current pause state; do not
   process requests until no `InProgress` entries remain.

### 3.3 Step 2 — `migrate()`

1. Stop `transferInRewards` and wait until `STRCMirrorModule.getUnvestedAmount() == 0`; the live
   `vestingPeriod`, not a fixed 30 days, determines the wait. Any later reward blocks the
   migration.
2. Reconcile the final mirrored position. The execution vehicle obtains and approves the
   full corresponding STRCon amount; incomplete delivery blocks migration.
3. Ensure the approved `migrationToleranceBps` is active, then schedule
   `migrate(expectedStrcon, deadline)` through the
   `DEFAULT_ADMIN_ROLE` timelock.
4. Execute after the delay. The call reverts if the vault is paused, the deadline has
   passed, `expectedStrcon` is zero, the mirror is retired, rewards remain unvested,
   `STRConModule.balance()` is nonzero, either position cannot be priced, the exact STRCon
   transfer fails, or post-migration NAV is outside the upward-rounded `migrationToleranceBps`
   comparison defined in §2.9.
5. On success, linked `STRConTradeExecutionLogic.executeMigration`, running by `DELEGATECALL` in
   the vault context, pulls and verifies the exact STRCon amount, calls
   `STRCMirrorModule.retire()` before `STRConModule.buy(expectedStrcon)`, and verifies final
   custody and NAV. The transaction is atomic; failure leaves the transfer and both module
   positions unchanged.

The timelocked call attests to disposition of the off-chain STRC, which cannot be verified
on chain. After success, `STRCMirrorModule` remains retired at zero and returns zero without an
oracle read; its reward and parameter mutations reject.

---

## 4. Open questions

| # | Question | Blocks | Resolution path |
|---|---|---|---|
| 1 | Execution-vehicle operations and launch values: exact vault and vehicle eligibility, funding source, STRCon inventory target, allowance workflow, USDon residual handling, reconciliation, executable-quote tolerance, and execution capacity/refill | operational readiness; none of these change vault accounting or its trading ABI | Ondo onboarding + §3.2 |
---

## 5. Migration and launch risks

| Risk | Impact | Gate or mitigation |
|---|---|---|
| Step-1 state migration | Incorrect seeding changes NAV, share price, or reward vesting. | Exact five-field seed mapping, fork rehearsal, atomic upgrade, and pre/post accounting comparison. Any mismatch blocks Step 2. |
| Partner readiness | Although the sUSDat and queue proxy addresses remain, functions move or disappear and bots, indexers, and frontends need the new ABIs and module addresses. | Publish final ABIs, addresses, behavior changes, and upgrade timing; confirm critical partners are ready before Step 1. |
| Legacy queue limits | Reinterpreting `minUsdatReceived` as a net-of-fee per-share `minSharePrice` may park or unexpectedly execute an old request. | Announce the change and leave sufficient time to update or cancel before processing resumes; reset every inherited `InProgress` request and verify the full inventory before processing resumes. |
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
isolate asset-specific pricing and recognition, but v2 needs only STRCMirrorModule and
STRConModule; a registry would add runtime NAV authority and loop complexity. A future
asset requires a deliberate vault upgrade adding and authorizing its module.

**Custody and settlement in the vault, not modules.** This avoids fragmentation, centralizes
compliance/seizure, and prevents a NAV-authority module from also moving tokens. The vault
applies tracked-cash accounting, and linked `STRConTradeExecutionLogic` performs complete ERC20
delivery-versus-payment by `DELEGATECALL` in the vault context. The fixed execution policy
validates price and capacity through a normal call; modules adapt accounting and oracle
prices.

**`balance()` as a counter, not `balanceOf`.** Live-custody recognition would let stray
transfers inflate NAV. STRCon's counter moves only through vault-authorized `buy`/`sell`
and Step 2 reuses `buy` behind the vault's one-shot migration gate. STRCMirrorModule has
enumerated reward/migration mutations. `balanceOf` is only a custody floor.

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

**Fixed oracle output unit instead of per-read decimals.** Module valuation and vault
execution math standardize STRCon prices to 8 decimals. `ISTRConPriceOracle.decimals()`
makes that compatibility explicit at initial installation and rotation, while `getPrice()`
remains scalar. Returning decimals with every price would spread dynamic normalization,
rounding, and exponent bounds through value-sensitive paths without making an oracle's
reported price more trustworthy.

**Working-capital execution vehicle instead of an on-chain route.** USDat → USDC → STRCon
is not reliably atomic. Encoding it would bring USDC, USDon, quotes, venue changes, and
in-flight receivables into vault accounting. A pre-funded vehicle absorbs them; the vault
sees only an atomic USDat↔STRCon exchange. Backing, DEX, Ondo, or financing changes then
affect vehicle operations, not vault code.

**Vault settlement instead of module settlement.** Letting a module perform transfers would
require allowances and combine accounting with asset-moving authority. Deltas prove the
amount, not the recipient. The linked library therefore verifies the incoming leg and sends
directly to the configured vehicle while executing as the vault; the module receives only
exact amounts for counter updates. The policy receives only trade amounts and the expected
vehicle for validation, has no vault allowance, and cannot write vault storage. This reduces
authority and token-approval assumptions.

**One two-sided capacity bucket instead of a loss oracle.** Exact settlement and per-trade
tolerance do not prevent repeated individually valid adverse trades. A global
USDat-denominated bucket limits both directions, charges the greater of actual and oracle
notional, and never refunds a reverse trade. This creates an on-chain aggregate loss bound
without deciding whether a price movement after execution was market movement or execution
loss. The fixed `STRConExecutionPolicy` owns capacity state, one-shot initialization,
getter, timelocked setter authorization, and consumption. Settlement uses one complete
linked-library call; the library normally calls the policy, then completes
delivery-versus-payment by `DELEGATECALL` in the vault context. It receives the
post-accounting values as arguments and does not hardcode vault storage slots.

**STRCMirrorModule is not forced through the token-backed interface.** It has no ERC20 custody
delta, and the vault's fixed `buy` and `sell` paths address only `strconModule`. It remains a
tokenless migration bridge with no buys or sales from Step 1 onward; only reward recognition
can increase its balance before Step 2 retirement. This avoids weakening token-backed
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
vested portion is folded incrementally into tracked cash, while the remaining segregated
portion stays protected by the custody floor and rescue rules.

**Funding ≠ processing.** A combined `fundAndProcessRedemptions(legs, tokenIds)` was
rejected. A sale precedes processing either way, so queued shares bear its delta and exit at
post-sale NAV. Fusion changes neither incidence nor fee; tooling can batch calls when
atomicity matters. It was also the only path to *exact* per-request realized cost (fee
Option 2); without it, the flat fee applies.

**Per-request settlement, not batch-and-sum.** v1's batch totals existed because one
external USDat pot was distributed pro rata. Vault-priced requests have exact amounts, no
pro-rata math or settlement-generated dust, and can skip unmet limits. The vault snapshots one
exact conversion basis per processor-selected batch and applies the transaction-stable active fee
tier to each request. Each fill removes only its net payout while burning the request's complete
shares, so retained fees raise live PPS but do not reprice later requests in that batch. A later
batch snapshots the resulting higher PPS. Per-request conversion and ceil rounding apply
independently.

**Queue-side entry with a narrow vault primitive.** The alternative—vault-side processing
that loops queue state—must enforce queue invariants across contracts or delegate back.
Instead, `redeemQueuedShares` burns only queue-held shares at the vault's price when the
buffer covers the whole request. This narrow, one-way trust replaces v1
`burnQueuedShares`' trusted processor amounts.

**Locks removed.** `lockRequests`/`InProgress` protected an in-flight off-chain execution
window (lock → sell STRC over hours → settle at attested price). Atomic settlement at the
validated mark has no such window. V2 never creates `InProgress`; the operator-only,
pause-independent `resetLegacyInProgressRequest` selector exists solely to recover any
inherited request omitted from pre-upgrade cleanup.

**`minSharePrice` instead of `minUsdatReceived`.** A per-share limit means the same thing
at every order size and directly protects the payout per share. The net payout price is
checked after charging the active fee. Legacy values remain unchanged; a communicated grace
period lets owners overwrite or cancel without permanent token-ID/migration branches
(§3.1).

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
initial holders. Deposit and redemption fees stay in the vault and accrue to remaining shares.
Regular authorization expires after at most eight hours, so a missed close transaction
fails safe to effective Elevated. Elevated is the required off-hours mode; Restricted is
reserved for identified executable arbitrage rather than raw oracle divergence.

**Flat redemption fee, two tiers.** Exact per-request cost attribution is a policy choice
rather than a measurement (which module funded what buffer refill?) and requires fused
funding/processing. A measured-spread flat fee targets average cost; governance-set
base/elevated tiers cover normal versus off-hours/stress settlement. Mode selects, but
cannot set, the tier. `setMarketMode` explicitly selects Elevated or Restricted;
`authorizeRegularMode` selects Regular only through a bounded deadline. The operating
runbook enters Elevated at market close, while expiration provides a fail-safe if that
transaction is missed. Treating Calculated freshness as on-chain market-open evidence was
rejected because freshness validates a price update, not the trading session.

**Role taxonomy.** Names follow the OZ/LayerZero capability convention (agent nouns /
`…_MANAGER`), not team/service names. Freeze ≠ seize and pause ≠ unpause limit compromised
keys. Renames change role IDs (`keccak256`), so §3.1 re-grants them. `addRequest` and
`redeemQueuedShares` use immutable counterpart checks because their proxy addresses never
change; roles would let a compromised admin widen access. Market-mode authority remains
separable despite sharing the initial operator address.

**One-shot in-kind `migrate()` over attrition.** Selling the mirrored position
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

**Feed roles → `primaryFeed()` as mark, `referenceFeed()` as circuit breaker** (§2.3). The
primary Calculated feed (`0xC353ac4b…AC07`) is the sole value-securing answer even though its
economic value updates only in regular hours — it went **68h without an update** over the
Jun 15 weekend. The reference API feed (`0x67d4Ae9f…cD91`) tracks premarket and postmarket and
**heartbeats ~24h on a flat price through the weekend closure**. The wrapper always returns
the primary answer and requires the latest reference answer to be fresh and within
`deviationBps`; it never substitutes the reference mark. Set `maxApiStaleness` at ~26h so
the 24h heartbeat does not
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
- Flow: sweep → consume per-period cap → pay net from the buffer; the fee difference remains in
  the vault and immediately accrues to remaining shares. Cap in net USDat per fixed period;
  `instantExitFeeBps ≥ baseRedemptionFeeBps` (same cost plus immediacy), hard cap 500.
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

Vault hard pause is not a `MarketMode`; it overrides the effective mode for vault and
sUSDat mutations without automatically pausing queue-only actions. In this table, Regular
means configured Regular before `regularModeValidUntil`; after that deadline the Elevated
column applies.

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
| Set Elevated/Restricted | Yes | Yes | Yes | Yes |
| Authorize Regular | Yes | Yes | Yes | Yes |
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
paused: Elevated or Restricted through `setMarketMode`, or Regular through a fresh bounded
`authorizeRegularMode`. `UNPAUSER_ROLE` may then resume the vault only after risk approval
and a successful exact-address transfer or redemption test. Permanent impairment requires
NAV to reflect the approved recovery value before resumption: `PARAMETER_MANAGER_ROLE` may
install a reviewed recovery-value wrapper through `STRConModule.setOracle` when the loss
is expressible as a per-STRCon price; otherwise governance executes a timelocked forward
upgrade for the recovery instrument. V2 has no generic haircut setter. The incident record
references the `Paused`, applicable `MarketModeChanged` and `RegularModeAuthorized`,
`OracleUpdated`, governance, and `Unpaused` transactions.
