# STRCon Feed Deviation Findings

Historical comparison of the primary and reference feeds in
[strcon_feed_prices_25718399_25933619.csv](./strcon_feed_prices_25718399_25933619.csv),
collected with [strcon_feed_pull.py](./strcon_feed_pull.py).

This document records the historical findings and the selected initial deviation
threshold of **100 bps (1%)**, with its rationale and deployment conditions below.

## Summary

- The maximum observed absolute deviation was **196.3521 bps (1.963521%)**. The oracle's rounded-up value would be **197 bps**.
- The maximum began on **August 12, 2026 at 8:00:35 p.m. EDT** and lasted **36 seconds** according to the recorded event timestamps.
- The three largest gaps, and the fourth-largest, began just after **8 p.m. EDT**. Each involved a reference-price excursion followed by another reference update that substantially reduced the gap. The primary did not change during those excursions.
- Time-weighted median deviation was **19.91 bps**, and the time-weighted 99th percentile was **54.2440 bps**.
- A hypothetical **50 bps** threshold would have rejected pricing on deviation grounds for **2.1854%** of the measured time. A **100 bps** threshold would have rejected it for **96 seconds** across three episodes.

## Dataset and coverage

| Feed | Proxy address | Updates | Aggregator round IDs |
|---|---|---:|---|
| Primary — Calculated | `0xC353ac4b425f818Ad87E228bf816E15c2173AC07` | 36 | 595–630 |
| Reference — Ondo API | `0x67d4Ae9f265270aE123c08D2657536771D19cD91` | 90 | 1331–1420 |

- Requested block range: **25,718,399–25,933,619**, inclusive.
- Source records: **126**, each from a distinct transaction. Both feeds report 8 decimals and phase ID 1 in the CSV.
- First recorded event: **August 9, 2026, 15:52:23 UTC**.
- Last recorded event: **September 8, 2026, 13:30:23 UTC**.
- Comparable window: **August 10, 2026, 13:30:35 UTC through September 8, 2026, 13:30:23 UTC**.
- Time-weighting denominator: **2,505,588 seconds**, or **28 days, 23 hours, 59 minutes, 48 seconds**.
- Comparable post-update states: **124**, with **123 positive-duration intervals**. The final state has no measured interval after it.

There are no gaps in either feed's captured round-ID sequence, duplicate event IDs,
nonpositive answers, or event-timestamp reversals. Raw integer answers agree exactly
with the CSV's eight-decimal USD prices. These checks establish internal consistency
of the supplied file, not independent completeness against the chain.

The CSV does not include a primary-price seed preceding its first primary update.
Consequently, the first two reference events cannot be paired with a known primary
price. The initial unpaired period and the tail after the final recorded event are
excluded from time-weighted statistics. No missing prices or boundary times are inferred.

## Calculation method

Updates are ordered by block number, transaction index, and log index. After each
transaction, the latest recorded primary price is compared with the latest recorded
reference price. Each price is carried forward until that feed next updates. Prices
are not interpolated, and rounds are not matched by round number or nearest timestamp.

The calculation follows the primary-price denominator in
[STRConPriceOracle.getPrice()](../../src/v2/modules/STRCon/STRConPriceOracle.sol):

```text
raw_deviation_bps = abs(primary_price - reference_price) * 10,000 / primary_price
contract_deviation_bps = ceil(raw_deviation_bps)
reject_on_deviation = contract_deviation_bps > configured_threshold_bps
```

Equality with the configured threshold passes the deviation check. Statistics use
the unrounded ratio; threshold comparisons use the exact integer ceiling. One basis
point is 0.01%.

Time-weighted statistics weight each price pair by the interval between its event
timestamp and the next update's event timestamp. Percentiles are weighted empirical
quantiles: the smallest observed deviation whose cumulative duration reaches the
specified share of the measured window.

All durations below are derived from the CSV's `updated_at` values. The file does
not contain separately fetched block timestamps, so these are not independently
verified transaction-inclusion durations. All local times below are **EDT (UTC−4)**.

## Deviation distribution

| Time-weighted statistic | Deviation, bps | Deviation, percent |
|---|---:|---:|
| Average | 20.22 | 0.2022% |
| 25th percentile | 11.83 | 0.1183% |
| Median | 19.91 | 0.1991% |
| 75th percentile | 26.23 | 0.2623% |
| 90th percentile | 37.42 | 0.3742% |
| 95th percentile | 44.74 | 0.4474% |
| 99th percentile | 54.24 | 0.5424% |
| Maximum observed | 196.35 | 1.9635% |

The distribution has a relatively narrow body and occasional larger, short-lived
gaps. Giving every update equal weight would describe a different distribution:
the update-weighted 99th percentile is **163.07 bps**, compared with **54.24 bps**
when weighted by time. The time-weighted result describes how long the recorded
prices disagreed, not how frequently a user traded during those intervals.

## Largest gaps and how they closed

| Start time, EDT, 2026 | Peak deviation, bps | Contract ceiling, bps | Duration until next update | Source CSV line |
|---|---:|---:|---:|---:|
| August 12, 20:00:35 | 196.3521 | 197 | 36 seconds | 28 |
| August 13, 20:00:35 | 163.0745 | 164 | 24 seconds | 32 |
| August 27, 20:00:47 | 113.4091 | 114 | 36 seconds | 95 |
| August 24, 20:00:47 | 99.3522 | 100 | 36 seconds | 82 |

CSV line numbers include the header as line 1. The table is ranked by peak deviation,
not by date. Each next update was another reference update; the primary remained
unchanged between the peak and that update.

| Date, EDT | Primary price, unchanged | Reference before excursion | Reference at peak gap | Next reference price | Deviation after next update, bps |
|---|---:|---:|---:|---:|---:|
| August 12 | $98.88367329 | $98.72196086 | $96.94207134 | $98.68832994 | 19.7549 |
| August 13 | $99.40726356 | $99.19320351 | $97.78618432 | $99.05673606 | 35.2618 |
| August 27 | $101.84017321 | $101.85759780 | $102.99513308 | $101.97013821 | 12.7617 |
| August 24 | $101.46941062 | $101.33785141 | $100.46128983 | $101.39668652 | 7.1671 |

### Maximum-gap detail

The largest gap began with reference round **1349** at block **25,742,369**,
on **August 13 at 00:00:35 UTC / August 12 at 20:00:35 EDT**.

- Primary round **602** remained at **$98.88367329**. Its recorded update was **7 hours, 10 minutes, 24 seconds** earlier.
- The reference moved from **$98.72196086** to **$96.94207134**, increasing deviation from approximately **16.35 bps** to **196.35 bps**.
- Reference round **1350**, at block **25,742,372**, arrived **36 seconds** later and reported **$98.68832994**. Deviation fell to approximately **19.75 bps**.

The two largest excursions were downward moves in the reference; the third-largest
was upward. The fourth-largest was also downward. The repeated timing and reversals
are observations, not an explanation of their cause. The CSV does not establish an
upstream update delay, an erroneous quote, or which feed reflected executable market
prices. None of these four gaps closed because the primary updated to catch up.

## Hypothetical deviation-threshold replay

The following settings are historical comparison cases; the selected initial
setting is discussed in the final recommendation section. Rejection means the
deviation condition alone would fail, assuming the other oracle checks pass.
An episode is an uninterrupted measured interval above the specified threshold.

| Threshold | Tolerance | Measured time rejected | Total rejection duration | Episodes |
|---|---:|---:|---:|---:|
| 25 bps | 0.25% | 33.7487% | 234 hours, 53 minutes, 24 seconds | 47 |
| 50 bps | 0.50% | 2.1854% | 15 hours, 12 minutes, 36 seconds | 18 |
| 60 bps | 0.60% | 0.1341% | 56 minutes | 12 |
| 75 bps | 0.75% | 0.1293% | 54 minutes | 11 |
| 100 bps | 1.00% | 0.00383% | 96 seconds | 3 |
| 200 bps | 2.00% | 0% | None | 0 |

The 100 bps case rejects only the three largest excursions listed above. The
fourth-largest excursion rounds to exactly 100 bps and therefore passes at that
setting. A 200 bps setting passes every comparable state in this sample, including
the maximum; this is not evidence that it bounds economic loss or prevents arbitrage.

## Persistent disagreement and update gaps

Not all material disagreement was brief. A **54.2440 bps** gap persisted from
**August 26 at 21:34:23 EDT through August 27 at 09:33:11 EDT**:

- Primary: **$101.30806215**.
- Reference: **$101.85759780**.
- Duration: **11 hours, 58 minutes, 48 seconds**.
- Source CSV lines: **92–94**. The gap ended when the primary updated to **$101.84017321**.

This was the longest continuous rejection episode in the 50 bps replay. Unlike the
largest transient excursions, this gap did close through a primary update.

Within the captured sequences, the primary's longest gap between updates was
**91 hours, 58 minutes, 24 seconds**, from **September 4 at 17:31:59 UTC** to
**September 8 at 13:30:23 UTC**. The reference's longest update gap was
**24 hours, 36 seconds**. Its recorded age did not exceed the oracle's initial
**26-hour** reference-staleness limit during the comparable window.

## Limitations

- Results describe this feed pair and this sample only. They do not establish the behavior of a replacement primary feed or future market conditions.
- The initial primary seed and the requested range's exact boundary timestamps are missing. Statistics therefore cover the narrower comparable window, not the entire requested block range.
- Event timestamps provide the time basis. Block inclusion timestamps and the CSV's contents were not independently verified against an RPC during this analysis.
- Round continuity and consistent metadata support internal consistency, but do not prove that no observations were omitted outside the first and last captured rounds.
- The replay does not include historical `sValue`, asset pause state, underlying-price bounds, or every round-validity field. It is not a full replay of `getPrice()` availability.
- Neither feed is independent evidence of executable market prices. Both may lag together while showing little disagreement. A deviation threshold is not a demonstrated bound on NAV error, dollar loss, or arbitrage profitability.
- The cause of the repeated reference excursions around 20:00 EDT remains unconfirmed.

## Recommendation

Use **100 bps (1%)** as the initial deviation threshold. The deployment script
sets `V2_ORACLE_INITIAL_DEVIATION_BPS = 100` as a Solidity constant, rather than
reading it from the environment. See the
[deployment input document](../v2-deployment/DeployV2Dependencies.md).

This setting balances rejection of the largest observed disagreements against
pricing availability in this sample:

- The time-weighted 99th percentile was **54.2440 bps**, below the selected threshold.
- At **100 bps**, the deviation check would reject pricing for **96 seconds** across **three episodes**, or **0.00383%** of the measured time.
- At **50 bps**, rejection would total **15 hours, 12 minutes, 36 seconds**, including the almost 12-hour persistent gap.
- The selected setting still allows disagreements up to **1%**. The fourth-largest excursion, **99.3522 bps**, rounds to **100 bps** and passes.

This is an availability/risk tradeoff supported by the observed feed pair, not
proof that 100 bps is optimal or prevents arbitrage. Both feeds can be stale
together, and feed disagreement does not establish executable market prices or
bound NAV error or losses. The cause of the short reference excursions remains
unconfirmed.

Before launch, confirm this setting against the replacement Chainlink primary
feed's update behavior and pricing checks. The historical primary analyzed here
is `0xC353ac4b425f818Ad87E228bf816E15c2173AC07`; the deployment script's
`PRIMARY_FEED` is still pending a replacement address. These results must not be
treated as measured availability for that replacement feed.
