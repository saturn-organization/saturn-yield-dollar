# V3 model tools

These offline JavaScript tools provide supporting economic and accounting evidence. They do
not execute production bytecode, prove deployed state, select launch parameters, or authorize
deployment.

## Calibration replay

`tranche-calibration-replay.mjs` combines the checked-in STRCon multiplier and distribution
series with official Nasdaq STRC closes to evaluate fixed scenarios and candidate Senior
participation values. Its output is a model, not a forecast or launch recommendation. Running
the script requires network access; its tests use deterministic inputs.

```sh
node test/model/tranche-calibration-replay.mjs
node --test test/model/tranche-calibration-replay.test.mjs
```

## Shadow reconciler

`tranche-shadow-reconciler.mjs` independently advances an expected eligible-income ledger
through an ordered JSON snapshot. All onchain-sized integers are base-10 strings and are
processed as `BigInt`; WAD values use 18 decimals, USDat values use 6 decimals, and STRCon
prices use 8 decimals.

The input uses schema `saturn-v3-shadow-v1` and contains:

- `config.maxUnreviewedGrowthBps` and optional field-specific `config.tolerances`;
- `initial.context`: `supply`, `exposure`, `rawIndex`, `backingValueUSDat6`, and
  `strconPrice8`;
- `initial.state`: the complete eligible-income state, including accepted indexes, affine
  scales and offsets, crystallization state, and funded-USDat state;
- optional `shadowCohort`: `backingAssets`, `baseSeniorClaimValueUSDat6`, and `alphasBps`;
  and
- ordered `transitions`, each with `id`, `kind`, `blockNumber`, the fields required by that
  transition, and an optional partial or complete `observedState`.

Supported transition order is modeled explicitly: oracle updates and transfers do not settle;
supply changes and buys settle before mutation; sells settle before exposure reduction and
then crystallize once; surplus funding precedes recognition; review precedes structural
resolution or resumption; and `mark` changes projection inputs without changing the ledger.

Each transition may update `rawIndex`, `strconPrice8`, or `backingValueUSDat6`. Additional
transition fields are:

| Kind | Additional fields |
| --- | --- |
| `oracle_update`, `transfer`, `mark`, `materialize`, `resume` | none beyond `id`, `kind`, and `blockNumber` |
| `supply_change` | `supplyAfter` |
| `buy` | `assetReceived` |
| `sell` | `assetDelivered`, `usdatReceived` |
| `fund_surplus`, `recognize_surplus` | `amount` |
| `enter_review` | optional `settleCurrent` |
| `resolve_structural` | `newFactorWad` |

Expected state is always computed independently. Missing observations are classified
`not_observed`, never as matches. Other results are `match`, `source_state_mismatch`,
`income_materialization_mismatch`, `supply_boundary_mismatch`,
`exposure_boundary_mismatch`, `cash_recognition_mismatch`, `crystallization_mismatch`, or
`unexplained_mismatch`. Any tolerance must be field-specific and must not mask state-machine,
funding, exposure, or double-recognition errors.

Collection remains separate from reconciliation:

```text
RPC/event collector -> immutable ordered snapshot -> reconciler -> review report
```

The checked-in fixture is `test/model/fixtures/tranche-shadow-synthetic.json`. It contains no
production address, credential, or live-state claim.

```sh
node test/model/tranche-shadow-reconciler.mjs test/model/fixtures/tranche-shadow-synthetic.json
node --test test/model/tranche-shadow-reconciler.test.mjs
```

Run both deterministic test files together with:

```sh
node --test test/model/tranche-calibration-replay.test.mjs test/model/tranche-shadow-reconciler.test.mjs
```
