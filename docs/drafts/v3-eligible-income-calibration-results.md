# Saturn perpetual sUSDat tranching V3 — eligible-income calibration result

**Historical cutoff:** 2026-08-28
**Status:** local, non-deployable economics model. This is not a forecast, parameter approval, pilot authorization, or post-V2 vault observation.

## Judgment

The replay supports retaining `alpha = 50%` as the v0 test and shadow-accounting reference. It does not yet justify freezing 50% for launch.

At the frozen exact 2:1 Senior:Junior opening stack:

- the base case without any assumed funded-USDat surplus produces approximately **7.61% Senior accounting yield** and **15.21% Junior eligible-income yield** at 50% participation;
- adding a hypothetical 25 bps of recognized funded-USDat surplus produces approximately **7.79% Senior** and **15.59% Junior**;
- the historical downside case produces approximately **6.55% Senior** and **13.10% Junior**; and
- the upside reference produces approximately **8.85% Senior** and **17.71% Junior**.

The clean conclusion is not “50% produces 8%.” It is:

> 50% is a reasonable midpoint for testnet and shadow validation. An 8% expected Senior accounting yield requires roughly 52.6% participation in the no-cash base case, while a conservative path would require materially more and weaken Junior economics.

The replay also rejects a 30% Junior base expectation. None of the modeled cases reaches it.

## Evidence boundary

Verified historical inputs:

- 274 official Nasdaq STRC daily closes from 2025-07-29 through 2026-08-28;
- 14 Strategy STRC paid distribution periods included in the price window, totaling `$11.425` per opening share; and
- observed STRCon `sValue` events from 2026-05-15 through 2026-08-14.

Primary sources:

- [Strategy STRC dividends](https://www.strategy.com/strc/dividends);
- [Strategy August 3, 2026 Form 8-K](https://www.sec.gov/Archives/edgar/data/1050446/000119312526329565/mstr-20260803.htm); and
- [Nasdaq STRC historical data](https://www.nasdaq.com/market-activity/stocks/strc/historical).

Modeled inputs:

- pre-STRCon distributions reinvest at the first Nasdaq close on or after payout;
- post-2026-05-15 eligible accretion uses the observed STRCon multiplier series;
- STRCon exposure remains constant within each scenario;
- eligible costs are annual scenario deductions;
- funded-USDat income is zero unless explicitly included as a sensitivity; and
- price shocks are instantaneous deterministic sensitivities, not probabilities.

The counterfactual reinvestment series grew **12.55% over 395 days**, or **11.55% annualized**. Observed STRCon `sValue` grew **4.26% over 90.28 days**, mechanically **18.39% annualized**. The observed annualization is a short-window upside sensitivity, not an underwriting rate.

## Income and alpha sensitivity

| Scenario | STRCon weight | Eligible costs | Funded-USDat sensitivity | Modeled `y_eff` | `alpha` for 8% Senior |
| --- | ---: | ---: | ---: | ---: | ---: |
| Downside | 80% | 0.50% | 0% | 8.74% | 61.05% |
| Base without funded-USDat surplus | 90% | 0.25% | 0% | 10.14% | 52.59% |
| Base plus funded-USDat sensitivity | 90% | 0.25% | 0.25% | 10.39% | 51.33% |
| Upside reference | 98.79% | 0.10% | 0.50% | 11.81% | 45.18% |

The funded-USDat rows are sensitivities only. V3 recognizes only actual funded surplus as it vests; the model does not infer income from the USDat backing-layer recipient balance.

### Base case without funded-USDat surplus

| `alpha` | Senior accounting yield | Junior eligible-income yield |
| ---: | ---: | ---: |
| 35% | 5.32% | 19.77% |
| 40% | 6.08% | 18.25% |
| 45% | 6.85% | 16.73% |
| 50% | 7.61% | 15.21% |
| 60% | 9.13% | 12.17% |

These are accounting yields on opening class NAV. Market yields may differ because the class tokens trade and redeem subject to health, coverage, and market conditions.

## Coverage and impairment

All scenarios begin at exactly 150% coverage. At `alpha = 50%`:

| Scenario | Worst historical coverage | Date | End coverage | End-state STRC price decline to impairment |
| --- | ---: | --- | ---: | ---: |
| Downside | 127.76% | 2026-06-26 | 158.98% | 44.75% |
| Base without funded-USDat surplus | 125.30% | 2026-06-26 | 160.11% | 40.98% |
| Base plus funded-USDat sensitivity | 125.42% | 2026-06-26 | 160.19% | 41.11% |
| Upside reference | 123.39% | 2026-06-26 | 161.21% | 38.50% |

There were no Senior-impaired trading days in the replay. That is encouraging but not sufficient evidence: the realized path is one sample, and higher STRCon exposure increases income while also concentrating drawdown risk.

At the no-cash base and 50% participation:

- a 40% additional STRC price shock leaves approximately **101.44% coverage**, almost exhausting Junior;
- impairment begins at approximately a **40.98%** decline from the replay-end STRC mark; and
- a 50% shock creates Senior claim shortfall equal to approximately **9.58% of opening collateral**.

This confirms why preferred coverage and impairment are different boundaries. One-sided Senior deposits and Junior redemptions close below 150%, long before Senior is economically impaired.

## Capacity behavior

Historical eligible income and price recovery can create excess coverage. At 50% participation, the no-cash base reached maximum modeled capacity of approximately:

- **8.91% of opening collateral** for Junior redemption; or
- **17.83% of opening collateral** for new Senior deposits.

These are mutually consuming uses of the same excess and are first-come, not simultaneous promises. They are not proposed pilot limits.

## Decision consequence

1. Keep 50% as the testnet and shadow-accounting reference.
2. Do not freeze launch `alpha` until actual post-V2 exposure and recognized funded-USDat surplus are reconciled.
3. Underwrite the initial decision against the no-cash base and downside cases. Treat funded-USDat income and the 90-day observed multiplier annualization as upside.
4. Do not market 8% Senior or 30% Junior as guaranteed or proven.
5. Preserve the frozen $500,000 pilot cap as a risk bound, not a consequence of the historical replay.
6. Use 2–4 weeks of post-V2 shadow results to compare actual accumulator increments against this model before selecting immutable launch `alpha`.

## Remaining data gaps

- Actual post-V2 time-weighted STRCon exposure per sUSDat share.
- Actual recognized funded-USDat surplus per sUSDat share.
- Actual eligible costs and execution effects attributable to income.
- Production-period structural-event, review, and source-closure behavior.
- Investor demand for Junior at approximately 12–20% modeled accounting yield and the associated first-loss risk.
- Secondary market discount or premium to accounting NAV.

## Reproduction

Run the deterministic-cutoff replay:

```sh
node test/model/tranche-calibration-replay.mjs
```

Run focused model tests:

```sh
node --test test/model/tranche-calibration-replay.test.mjs
```

The script fetches Nasdaq data read-only but ignores rows after the fixed 2026-08-28 cutoff. Updating the cutoff or any scenario is an explicit model revision.
