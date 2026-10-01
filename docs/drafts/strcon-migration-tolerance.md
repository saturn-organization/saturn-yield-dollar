# STRC → STRCon Migration Tolerance

Findings from the supplied September 14, 2026 readings. The selected setting is
`MIGRATION_TOLERANCE_BPS = 200` (**2%**), with the migration configuration expecting
the same value. This records deployment configuration, not a live on-chain setting.

## What the tolerance checks

Migration replaces the legacy STRC module's recognized value with the delivered
STRCon position. It checks **whole-vault NAV immediately before and after that
change, within the same transaction**:

```text
Maximum difference = NAV before migration × tolerance bps / 10,000
Pass if |NAV after migration − NAV before migration| ≤ maximum difference
```

The limit applies to both increases and decreases. It checks NAV continuity,
**not the sValue conversion ratio**, and does not measure ordinary market movement
from today until execution. It is separate from the 75 bps execution tolerance
used for subsequent buys and sells.

Source: [migration check](../../src/v2/libraries/STRConTradeExecutionLogic.sol)
and [vault NAV calculation](../../src/v2/StakedUSDat.sol).

## Supplied inputs

| Input | Value |
|---|---:|
| Physical STRC shares | 715,099.677059 |
| sValue | 1.048030553751355939 |
| sValue paused | `false` |
| Legacy STRC oracle price per share | $98.6599 |
| STRCon oracle price per token | $103.46681641 |

The sValue came from `getSValue(STRCON)` on
`0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6`, with raw value
`1048030553751355939` (18 decimals). STRCon is
`0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c`.

The STRCon price came from `getPrice()` on module
`0x5f7bd5C95EE38706C4c4B609D44ABF63Ad8b2C4F`, with raw value
`10346681641` (8 decimals). The legacy STRC oracle is
`0x5f7eCD0D045c393da6cb6c933c671AC305A871BF`.

These are user-supplied snapshots, not independently verified same-block readings.

## Conversion and valuation

Using the supplied conversion rule:

```text
STRCon tokens = STRC shares / sValue
              = 715,099.677059 / 1.048030553751355939
              = 682,327.127295428629136321 STRCon
```

The quantity is rounded down to 18 decimals. Its raw token amount is
`682327127295428629136321`.

| Position | Calculation | Recognized value |
|---|---|---:|
| Legacy STRC | 715,099.677059 × $98.6599 | $70,551,662.63 |
| Converted STRCon | 682,327.127295428629136321 × $103.46681641 | $70,598,215.61 |
| Difference | STRCon value − legacy STRC value | **+$46,552.98** |

The increase is **0.065984%**, or **6.5984 bps**, relative to the legacy STRC
position. This assumes the supplied shares equal the fully vested legacy module
balance and the calculated STRCon quantity is delivered without deductions.

The smaller token count is not itself a loss: each STRCon token represents more
than one underlying share at this sValue. The two supplied oracle marks produce
the remaining valuation gap.

## What 2% permits

Using the **$70,551,662.63 legacy position as the NAV baseline**:

| Tolerance | Maximum absolute NAV difference |
|---|---:|
| 1% — 100 bps | $705,516.63 |
| **2% — 200 bps** | **$1,411,033.25** |
| 3% — 300 bps | $2,116,549.88 |

At 2%, this illustrative NAV could move down to **$69,140,629.38** or up to
**$71,962,695.88** and still pass the NAV check. The allowance is approximately
**30.3 times** the observed $46,552.98 gap.

The actual denominator is **full vault NAV**, including recognized USDat cash
and vested surplus, not just the STRC position. Additional cash increases the
dollar allowance; every additional $1 million of NAV adds **$20,000** at 2%.
The $1.41 million figure is therefore a position-based estimate, not a fixed cap.

## Conclusion

**Selected initial migration tolerance: 200 bps (2%).** This substantially covers
the supplied snapshot's 6.6 bps gap while reducing the allowance from approximately
$2.12 million at 3% to **$1.41 million at 2%**, using the same baseline.

This is a broad maximum accepted difference, not an expected migration cost.
It also permits an adverse recognized-NAV change of that size; the supplied
snapshot does not establish that 2% is necessary.

Before scheduling, confirm the actual STRCon quantity and recalculate against
the full vault NAV and both oracle marks. Repeat the comparison before execution.
sValue and prices can change, but the STRCon amount in the scheduled operation
is fixed: changing that amount requires a new operation. The
[migration builder](../../script/v2/migrate/BuildV2Migration.s.sol) checks the
projected NAV difference, and the contract enforces it again during execution.
