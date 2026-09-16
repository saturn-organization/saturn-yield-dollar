# STRCon Execution Tolerance

`EXECUTION_TOLERANCE_BPS` limits adverse pricing on vault buys and sells, including
conversion costs reflected in the amounts settled with the vault.

## The manual trade

1. **USDat → USDC:** redeem with a minimum **5 bps** fee.
2. **USDC → STRCon:** USDC converts to USDon 1:1, then funds the STRCon purchase.
   Ondo estimates buying costs at **4.93 bps at p95**, approximately **5 bps**.
3. **Call the vault's `buy()`:** deliver STRCon and receive USDat. The vault checks
   the trade price against the oracle **at this point**, not at the earlier purchase.

This workflow currently takes **5–10 minutes**. The planning baseline is therefore
roughly **10 bps in buying costs**, before the oracle pricing gap and price movement
during the manual process. Ondo's p95 is not a maximum.

All calculations assume no rebate.

## Oracle pricing and the delay

Two things can change the comparison beyond those buying costs:

- **Oracle pricing:** the primary has a **10 bps update trigger**, but can stay
  unchanged outside regular market hours, including weekends. Our
  [feed analysis](./strcon-feed-deviation-findings.md) recorded a **54.24 bps
  overnight primary/reference gap** and a nearly **92-hour primary update gap**
  over September 4–8. Those are oracle observations, not extra trading fees.
- **Manual delay:** the market and oracle can move before `buy()` or `sell()`
  executes. For a completed purchase at a fixed cost, a falling oracle makes
  the later vault buy harder to pass; for a fixed-proceeds sale, a rising oracle
  makes the vault sell harder to pass.

The 10 bps trigger is not a hard limit on oracle error. The number we need to
measure is the **full trade-price difference from the oracle at vault settlement**.
That captures pricing and timing together; do not add the same gap twice.

## Quotes at practical trade sizes

Each group uses its supplied oracle reading. Buy-side USDat costs include **5 bps redemption**
and no rebate. Displayed prices and costs are rounded; gaps use the full raw quotes.

### Earlier samples

Oracle price: **103.28341107** (`10328341107` raw).

| STRCon tokens | Quote per token (USDon) | Estimated USDat cost | Quote-only gap (bps) | Gap with redemption (bps) | Minimum tolerance (bps) |
|---|---:|---:|---:|---:|---:|
| 1,000 (earlier) | 103.34194820 | 103,393.65 | 5.6676 | **10.6730** | **11** |
| 1,000 (later) | 103.16738703 | 103,219.00 | -11.2336 | **-6.2367** | **0** |
| 10,000 | 103.63097009 | 1,036,828.11 | 33.6510 | **38.6703** | **39** |
| 30,000 | 103.63097009 | 3,110,484.34 | 33.6510 | **38.6703** | **39** |

```text
Quoted USDon cost = token quantity × quoted price per token
USDat needed = quoted USDon cost / 0.9995
Oracle value = token quantity × oracle price per token
Quote-only gap = (quoted USDon cost / oracle value - 1) × 10,000
Buy premium = (USDat needed / oracle value of STRCon - 1) × 10,000
```

The 10,000- and 30,000-token requests returned the same per-token price, giving
the same **38.67 bps** all-in gap and **39 bps** minimum tolerance. The later
1,000-token quote is **6.24 bps below the oracle after redemption costs**, so
it passes the price check even at zero tolerance. Negative gaps favor the vault.

These are roughly **$100k, $1m, and $3m** trades, each within the configured
**6 million USDat capacity** when the bucket is full. Do not add another estimated
5 bps buying cost—the returned quote already includes its buy pricing.

The requests were sequential, so the lower 1,000-token quote does not by itself prove
a size-based discount; pricing may have changed between requests.

### Pre-market — September 14, 2026

The supplied pre-market requests all returned **103.471364871705895963 USDon
per token** (`103471364871705895963` raw). The oracle read was still **103.28341107**.

| STRCon tokens | Quote per token (USDon) | Estimated USDat cost | Quote-only gap (bps) | Gap with redemption (bps) | Minimum tolerance (bps) |
|---|---:|---:|---:|---:|---:|
| 1,000 | 103.47136487 | 103,523.13 | 18.1979 | **23.2095** | **24** |
| 10,000 | 103.47136487 | 1,035,231.26 | 18.1979 | **23.2095** | **24** |
| 30,000 | 103.47136487 | 3,105,693.79 | 18.1979 | **23.2095** | **24** |

All three require **24 bps** for the price check, including the 5 bps redemption
cost. The **23.21 bps** all-in gap is **15.46 bps lower** than the earlier
10,000-/30,000-token samples. It leaves **26.79 bps at 50 bps tolerance** or
**51.79 bps at 75 bps**, before any additional manual-settlement movement.

### Market open — September 14, 2026

The supplied oracle reading increased to **103.36049371** (`10336049371` raw).
The 10,000-/30,000-token quotes returned `103513307054467025227` raw; the
1,000-token quote returned `103534278145847589860` raw, both in 18-decimal USDon
per token.

| STRCon tokens | Quote per token (USDon) | Estimated USDat cost | Quote-only gap (bps) | Gap with redemption (bps) | Minimum tolerance (bps) |
|---|---:|---:|---:|---:|---:|
| 1,000 | 103.53427815 | 103,586.07 | 16.8134 | **21.8243** | **22** |
| 10,000 | 103.51330705 | 1,035,650.90 | 14.7845 | **19.7944** | **20** |
| 30,000 | 103.51330705 | 3,106,952.69 | 14.7845 | **19.7944** | **20** |

The all-in gaps narrowed from **23.21 bps pre-market** to **19.79 bps** for the
larger requests and **21.82 bps** for 1,000 tokens. Both the quotes and oracle rose,
but the oracle rose more proportionally. The higher 1,000-token quote does not
establish a size-based spread because the requests were sequential.

At the largest market-open gap, headroom is **28.18 bps at 50 bps tolerance** or
**53.18 bps at 75 bps**, before any additional manual-settlement movement.
The largest supplied gap remains **38.67 bps** from the earlier samples.

### Market-hours sells — September 14, 2026

These three sell quotes are compared with the later supplied oracle reading of
**103.46681641** (`10346681641` raw). Proceeds are quoted in USDon. The return
conversion to USDat has **no additional fee** (user-confirmed). The minimum
tolerances below use 1:1 conversion at the quoted proceeds; the buy route's
5 bps redemption fee is not applied to sells.

| STRCon tokens | Sell quote per token (USDon) | Quoted USDon proceeds | Below oracle (bps) | Minimum tolerance, no further costs (bps) |
|---|---:|---:|---:|---:|
| 1,000 | 103.39937041 | 103,399.37 | **6.5186** | **7** |
| 10,000 | 103.38889535 | 1,033,888.95 | **7.5310** | **8** |
| 30,000 | 103.37842028 | 3,101,352.61 | **8.5434** | **9** |

Raw 18-decimal quote prices: `103399370412815946566` for 1,000 tokens,
`103388895347431201764` for 10,000, and `103378420282046456961` for 30,000.

```text
Quoted USDon proceeds = token quantity × sell quote per token
Sell discount = (1 - sell quote per token / oracle price) × 10,000
```

**Selected base redemption fee: 10 bps (0.10%)** (`BASE_REDEMPTION_FEE_BPS = 10`).
It exceeds these quoted sell-side discounts, leaving
**1.46 bps** above the largest one. The fee-free return conversion adds no fee,
but price movement during manual settlement could exceed that margin.

**Selected Elevated fees: 25 bps (0.25%) deposit and 50 bps (0.50%) redemption.**
The lower deposit fee limits entry friction; the higher redemption fee provides a
larger liquidity allowance. These are initial policy choices, not proven cost
coverage: **25 bps does not cover the earlier 38.67 bps all-in buy gap**.

The earlier favorable 30,000-token comparison used the previous **103.36049371**
oracle reading; against this newer reading, it is **8.54 bps below** the oracle.
The quotes were sequential and the oracle was read afterward, so these are not
simultaneous spreads and do not establish a size-based pricing difference.

These are quote snapshots, not completed trades. No timed 5-/10-minute oracle
comparisons have been supplied yet; the snapshots do not measure the additional
manual-settlement delay.

## Comparing 50 and 75 bps

| Candidate | Price checks on supplied buy quotes | Headroom above the largest 38.67 bps gap |
|---|---|---:|
| 50 bps | Pass | 11.33 bps |
| 75 bps | Pass | 36.33 bps |

**Selected initial setting: 75 bps (0.75%).** Its **36.33 bps headroom** above the
observed **38.67 bps** gap provides room for the unmeasured **5–10 minute manual
delay**, at the cost of allowing more adverse execution. For 6 million USDat of
charged turnover, the oracle-relative
adverse-price allowance is up to **$30,000 at 50 bps** or **$45,000 at 75 bps**.
With a full bucket and refill, up to 12 million turnover over 24 hours doubles
those figures. These are not guarantees about total market losses.

Starting higher and reducing later is possible through
[`setExecutionTolerance()`](../../src/v2/STRConExecutionPolicy.sol), controlled by
the configured **two-day parameter-manager timelock**. Reassess **50 bps** after
timed buy and sell evidence. The selected 75 bps setting has not yet been validated
for the 5–10 minute delay.

## Test the manual workflow

1. Sample buys and sells around **$100k, $1m, $3m, and $5m** during regular hours,
   outside regular hours, and around weekend reopening when quotes are available.
2. For each buy, include the redemption cost (minimum 5 bps). For each sell, use its net
   USDat proceeds rather than assuming the buy-side fee also applies in reverse.
3. Keep the original trade amounts fixed. Read the oracle immediately, then
   **5 and 10 minutes later**. Record the block and time for each observation.
   This models buying first and settling with the vault later—not obtaining a
   new quote each time.
4. Calculate the adverse difference, rounded up to whole bps:

   ```text
   Buy:  max(0, all-in USDat price / oracle price - 1) × 10,000
   Sell: max(0, 1 - net USDat price / oracle price) × 10,000
   ```

5. Compare **50 and 75 bps** against the observed p95, p99, worst gap, and
   rejection rate for each delay. Confirm representative trades on a local
   upgraded-vault fork using the [policy's integer rounding](../../src/v2/STRConExecutionPolicy.sol).

Use the actual price-fix-to-vault interval when available. Soft quotes are
non-binding scenarios, not completed fills. Oracle read failures are separate
from execution tolerance. Earlier manual swaps remain completed if the vault
call later rejects.

### Commands

Request a soft quote for **1,000 tokens**, not $1,000. Change `side` to `sell`
for the other direction. [Ondo soft-quote API](https://docs.ondo.finance/api-reference/attestations/request-a-soft-attestation-quote)

```bash
source syncprod

curl --fail-with-body --silent --show-error \
  https://api.gm.ondo.finance/v1/attestations/soft \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ONDO_API_KEY" \
  --data '{
    "chainId": "ethereum-1",
    "symbol": "STRCon",
    "side": "buy",
    "tokenAmount": "1000",
    "duration": "short"
  }'
```

Run this oracle read immediately and again after 5 and 10 minutes:

```bash
EXECUTION_SAMPLE_BLOCK=$(cast block-number --rpc-url "$RPC_URL")
printf 'Oracle snapshot block: %s\n' "$EXECUTION_SAMPLE_BLOCK"

cast call 0x5f7bd5C95EE38706C4c4B609D44ABF63Ad8b2C4F \
  "getPrice()(uint256)" \
  --block "$EXECUTION_SAMPLE_BLOCK" --rpc-url "$RPC_URL"
```

The API price has **18 decimals**; the oracle result has **8 decimals**.
