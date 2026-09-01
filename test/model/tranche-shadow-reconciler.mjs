#!/usr/bin/env node

// Read-only/offline V3 ledger reconciler with V3 cohort projections.
// All integer arithmetic mirrors the Solidity implementation. Input snapshots
// use decimal strings so no onchain-sized value passes through JS Number.

import fs from "node:fs/promises";
import {pathToFileURL} from "node:url";

export const WAD = 10n ** 18n;
export const BPS = 10_000n;
export const VALUE_SCALE = 10n ** 12n;
export const US_DAT_PER_SHARE_SCALE = 10n ** 30n;

const STATE_KEYS = [
  "incomeState",
  "lastSettlementBlock",
  "lastAcceptedRawIndex",
  "lastEligibleUnitIndexWad",
  "cumulativeStructuralAdjustmentFactorWad",
  "eligibleUnitsPerSUSDatShareWad",
  "lastRoundingRemainder",
  "liveUnitScaleWad",
  "liveUnitsOffsetWad",
  "crystallizedValueScaleWad",
  "crystallizedValueOffsetWad",
  "crystallizationNonce",
  "fundedUSDat",
  "pendingFundedUSDat",
  "recognizedUSDat",
  "recognizedUSDatPerSUSDatShareWad",
  "lastUSDatRoundingRemainder",
];

const BIGINT_STATE_KEYS = new Set(STATE_KEYS.filter((key) => key !== "incomeState"));

function bi(value, label) {
  try {
    return BigInt(value);
  } catch {
    throw new Error(`invalid integer ${label}: ${value}`);
  }
}

function mulDivDown(a, b, denominator) {
  if (denominator <= 0n) throw new Error("zero denominator");
  return (a * b) / denominator;
}

function clone(value) {
  return structuredClone(value);
}

function serialize(value) {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(serialize);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, serialize(child)]));
  }
  return value;
}

function parseState(input = {}) {
  const result = {
    incomeState: input.incomeState ?? "Active",
    lastSettlementBlock: 0n,
    lastAcceptedRawIndex: 0n,
    lastEligibleUnitIndexWad: 0n,
    cumulativeStructuralAdjustmentFactorWad: WAD,
    eligibleUnitsPerSUSDatShareWad: 0n,
    lastRoundingRemainder: 0n,
    liveUnitScaleWad: WAD,
    liveUnitsOffsetWad: 0n,
    crystallizedValueScaleWad: 0n,
    crystallizedValueOffsetWad: 0n,
    crystallizationNonce: 0n,
    fundedUSDat: 0n,
    pendingFundedUSDat: 0n,
    recognizedUSDat: 0n,
    recognizedUSDatPerSUSDatShareWad: 0n,
    lastUSDatRoundingRemainder: 0n,
  };
  for (const key of BIGINT_STATE_KEYS) {
    if (input[key] !== undefined) result[key] = bi(input[key], key);
  }
  if (result.lastAcceptedRawIndex === 0n || result.lastEligibleUnitIndexWad === 0n) {
    throw new Error("initial raw and normalized indexes are required");
  }
  return result;
}

function parseContext(input) {
  return {
    supply: bi(input.supply, "supply"),
    exposure: bi(input.exposure, "exposure"),
    rawIndex: bi(input.rawIndex, "rawIndex"),
    backingValueUSDat6: bi(input.backingValueUSDat6, "backingValueUSDat6"),
    strconPrice8: bi(input.strconPrice8, "strconPrice8"),
  };
}

function validateGrowth(last, current, maxUnreviewedGrowthBps) {
  if (current < last) throw new Error("normalized index decreased");
  const maximum = last + mulDivDown(last, maxUnreviewedGrowthBps, BPS);
  if (current > maximum) throw new Error("unreviewed growth exceeded");
}

function materialize(state, context, blockNumber, maxUnreviewedGrowthBps, allowedState = "Active") {
  if (state.incomeState !== allowedState) throw new Error(`income state is ${state.incomeState}`);
  const normalized = mulDivDown(
    context.rawIndex,
    WAD,
    state.cumulativeStructuralAdjustmentFactorWad,
  );
  validateGrowth(state.lastEligibleUnitIndexWad, normalized, maxUnreviewedGrowthBps);
  const delta = normalized - state.lastEligibleUnitIndexWad;
  let increase = 0n;
  if (delta !== 0n && context.supply !== 0n) {
    increase = mulDivDown(context.exposure, delta, context.supply);
    state.eligibleUnitsPerSUSDatShareWad += increase;
    state.liveUnitsOffsetWad += increase;
    state.lastRoundingRemainder = (context.exposure * delta) % context.supply;
  }
  state.lastAcceptedRawIndex = context.rawIndex;
  state.lastEligibleUnitIndexWad = normalized;
  state.lastSettlementBlock = blockNumber;
  return increase;
}

function fundSurplus(state, amount) {
  state.fundedUSDat += amount;
  state.pendingFundedUSDat += amount;
}

function recognizeSurplus(state, amount, supply, blockNumber) {
  if (amount > state.pendingFundedUSDat) throw new Error("recognized surplus exceeds pending");
  state.pendingFundedUSDat -= amount;
  state.recognizedUSDat += amount;
  let increase = 0n;
  if (supply !== 0n) {
    increase = mulDivDown(amount, US_DAT_PER_SHARE_SCALE, supply);
    state.recognizedUSDatPerSUSDatShareWad += increase;
    state.crystallizedValueOffsetWad += increase;
    state.lastUSDatRoundingRemainder = (amount * US_DAT_PER_SHARE_SCALE) % supply;
  }
  state.lastSettlementBlock = blockNumber;
  return increase;
}

function crystallize(state, preExposure, delivered, usdatReceived) {
  if (delivered >= preExposure) throw new Error("complete exit requires review");
  const q = mulDivDown(preExposure - delivered, WAD, preExposure);
  const r = mulDivDown(usdatReceived, US_DAT_PER_SHARE_SCALE, preExposure);
  state.crystallizedValueScaleWad += mulDivDown(r, state.liveUnitScaleWad, WAD);
  state.crystallizedValueOffsetWad += mulDivDown(r, state.liveUnitsOffsetWad, WAD);
  state.liveUnitScaleWad = mulDivDown(state.liveUnitScaleWad, q, WAD);
  state.liveUnitsOffsetWad = mulDivDown(state.liveUnitsOffsetWad, q, WAD);
  state.crystallizationNonce += 1n;
}

function parseCohort(config, state) {
  if (!config) return [];
  return (config.alphasBps ?? []).map((alpha) => ({
    alphaBps: bi(alpha, "alphaBps"),
    backingAssets: bi(config.backingAssets, "backingAssets"),
    baseSeniorClaimValue: bi(config.baseSeniorClaimValueUSDat6, "baseSeniorClaimValueUSDat6"),
    seniorLiveUnitsWad: 0n,
    crystallizedSeniorValue: 0n,
    checkpointLiveScaleWad: state.liveUnitScaleWad,
    checkpointLiveOffsetWad: state.liveUnitsOffsetWad,
    checkpointCrystallizedScaleWad: state.crystallizedValueScaleWad,
    checkpointCrystallizedOffsetWad: state.crystallizedValueOffsetWad,
    checkpointCrystallizationNonce: state.crystallizationNonce,
  }));
}

function syncCohort(cohort, state, context) {
  const oldScale = cohort.checkpointLiveScaleWad;
  if (oldScale === 0n || state.liveUnitScaleWad > oldScale) throw new Error("invalid live scale");
  const crystallizedScaleIncrease =
    state.crystallizedValueScaleWad - cohort.checkpointCrystallizedScaleWad;

  if (cohort.seniorLiveUnitsWad !== 0n) {
    const existingCrystallizedWad = mulDivDown(
      cohort.seniorLiveUnitsWad,
      crystallizedScaleIncrease,
      oldScale,
    );
    cohort.seniorLiveUnitsWad = mulDivDown(
      cohort.seniorLiveUnitsWad,
      state.liveUnitScaleWad,
      oldScale,
    );
    cohort.crystallizedSeniorValue += existingCrystallizedWad / VALUE_SCALE;
  }

  const historicalLive = mulDivDown(
    state.liveUnitScaleWad,
    cohort.checkpointLiveOffsetWad,
    oldScale,
  );
  const relativeLivePerShareWad = state.liveUnitsOffsetWad - historicalLive;
  const historicalCrystallized = mulDivDown(
    crystallizedScaleIncrease,
    cohort.checkpointLiveOffsetWad,
    oldScale,
  );
  const relativeCrystallizedPerShareWad = state.crystallizedValueOffsetWad
    - cohort.checkpointCrystallizedOffsetWad
    - historicalCrystallized;

  const newLiveUnits = mulDivDown(cohort.backingAssets, relativeLivePerShareWad, WAD);
  cohort.seniorLiveUnitsWad += mulDivDown(newLiveUnits, cohort.alphaBps, BPS);
  const newCrystallizedWad = mulDivDown(
    cohort.backingAssets,
    relativeCrystallizedPerShareWad,
    WAD,
  );
  cohort.crystallizedSeniorValue +=
    mulDivDown(newCrystallizedWad, cohort.alphaBps, BPS) / VALUE_SCALE;

  cohort.checkpointLiveScaleWad = state.liveUnitScaleWad;
  cohort.checkpointLiveOffsetWad = state.liveUnitsOffsetWad;
  cohort.checkpointCrystallizedScaleWad = state.crystallizedValueScaleWad;
  cohort.checkpointCrystallizedOffsetWad = state.crystallizedValueOffsetWad;
  cohort.checkpointCrystallizationNonce = state.crystallizationNonce;

  const liveValue = mulDivDown(cohort.seniorLiveUnitsWad, context.strconPrice8, 10n ** 20n);
  const seniorClaimValue = cohort.baseSeniorClaimValue + cohort.crystallizedSeniorValue + liveValue;
  const backing = context.backingValueUSDat6;
  const markedSeniorValue = backing < seniorClaimValue ? backing : seniorClaimValue;
  const juniorResidualValue = backing - markedSeniorValue;
  const coverageWad = seniorClaimValue === 0n ? null : mulDivDown(backing, WAD, seniorClaimValue);
  return {
    alphaBps: cohort.alphaBps,
    seniorLiveUnitsWad: cohort.seniorLiveUnitsWad,
    crystallizedSeniorValue: cohort.crystallizedSeniorValue,
    seniorClaimValue,
    markedSeniorValue,
    juniorResidualValue,
    coverageWad,
  };
}

function observedState(input) {
  if (!input) return null;
  const result = {};
  for (const [key, value] of Object.entries(input)) {
    if (!STATE_KEYS.includes(key)) throw new Error(`unknown observed state key ${key}`);
    result[key] = BIGINT_STATE_KEYS.has(key) ? bi(value, `observed.${key}`) : value;
  }
  return result;
}

function classify(kind, differences) {
  if (differences.length === 0) return "match";
  const keys = new Set(differences.map((difference) => difference.key));
  if ([...keys].some((key) => key.includes("USDat") || key === "crystallizedValueOffsetWad")) {
    if (kind === "recognize_surplus" || kind === "fund_surplus") return "cash_recognition_mismatch";
  }
  if ([...keys].some((key) => key.includes("crystalliz") || key.includes("liveUnitScale"))) {
    if (kind === "sell") return "crystallization_mismatch";
  }
  if ([...keys].some((key) => key === "incomeState" || key.includes("Structural") || key.includes("RawIndex"))) {
    return "source_state_mismatch";
  }
  if ([...keys].some((key) => key.includes("eligibleUnits") || key.includes("liveUnitsOffset"))) {
    if (kind === "supply_change") return "supply_boundary_mismatch";
    if (kind === "buy" || kind === "sell") return "exposure_boundary_mismatch";
    return "income_materialization_mismatch";
  }
  return "unexplained_mismatch";
}

function compare(expected, observed, tolerances = {}) {
  if (!observed) return {classification: "not_observed", differences: []};
  const differences = [];
  for (const [key, actual] of Object.entries(observed)) {
    const wanted = expected[key];
    if (typeof actual === "bigint") {
      const tolerance = bi(tolerances[key] ?? 0, `tolerance.${key}`);
      const delta = actual >= wanted ? actual - wanted : wanted - actual;
      if (delta > tolerance) differences.push({key, expected: wanted, observed: actual, delta});
    } else if (actual !== wanted) {
      differences.push({key, expected: wanted, observed: actual});
    }
  }
  return {differences};
}

function applyTransition(state, context, transition, config) {
  const blockNumber = bi(transition.blockNumber, `${transition.id}.blockNumber`);
  const next = clone(state);
  const nextContext = clone(context);
  if (transition.rawIndex !== undefined) nextContext.rawIndex = bi(transition.rawIndex, `${transition.id}.rawIndex`);
  if (transition.strconPrice8 !== undefined) {
    nextContext.strconPrice8 = bi(transition.strconPrice8, `${transition.id}.strconPrice8`);
  }
  if (transition.backingValueUSDat6 !== undefined) {
    nextContext.backingValueUSDat6 = bi(transition.backingValueUSDat6, `${transition.id}.backingValueUSDat6`);
  }

  let recognizedIncrement = 0n;
  let unitIncrement = 0n;
  switch (transition.kind) {
    case "oracle_update":
    case "transfer":
    case "mark":
      break;
    case "materialize":
      unitIncrement = materialize(next, nextContext, blockNumber, config.maxUnreviewedGrowthBps);
      break;
    case "supply_change":
      unitIncrement = materialize(next, nextContext, blockNumber, config.maxUnreviewedGrowthBps);
      nextContext.supply = bi(transition.supplyAfter, `${transition.id}.supplyAfter`);
      break;
    case "buy":
      unitIncrement = materialize(next, nextContext, blockNumber, config.maxUnreviewedGrowthBps);
      nextContext.exposure += bi(transition.assetReceived, `${transition.id}.assetReceived`);
      break;
    case "sell": {
      unitIncrement = materialize(next, nextContext, blockNumber, config.maxUnreviewedGrowthBps);
      const delivered = bi(transition.assetDelivered, `${transition.id}.assetDelivered`);
      const usdatReceived = bi(transition.usdatReceived, `${transition.id}.usdatReceived`);
      crystallize(next, nextContext.exposure, delivered, usdatReceived);
      nextContext.exposure -= delivered;
      break;
    }
    case "fund_surplus":
      fundSurplus(next, bi(transition.amount, `${transition.id}.amount`));
      break;
    case "recognize_surplus":
      recognizedIncrement = recognizeSurplus(
        next,
        bi(transition.amount, `${transition.id}.amount`),
        nextContext.supply,
        blockNumber,
      );
      break;
    case "enter_review":
      if (transition.settleCurrent) {
        unitIncrement = materialize(next, nextContext, blockNumber, config.maxUnreviewedGrowthBps);
      }
      next.incomeState = "Review";
      break;
    case "resolve_structural":
      if (next.incomeState !== "Review") throw new Error("structural resolution requires review");
      next.cumulativeStructuralAdjustmentFactorWad = bi(
        transition.newFactorWad,
        `${transition.id}.newFactorWad`,
      );
      unitIncrement = materialize(next, nextContext, blockNumber, config.maxUnreviewedGrowthBps, "Review");
      next.incomeState = "Active";
      break;
    case "resume":
      unitIncrement = materialize(next, nextContext, blockNumber, config.maxUnreviewedGrowthBps, "Review");
      next.incomeState = "Active";
      break;
    default:
      throw new Error(`unsupported transition kind ${transition.kind}`);
  }
  return {state: next, context: nextContext, unitIncrement, recognizedIncrement};
}

export function reconcile(input) {
  if (input.schema !== "saturn-v3-shadow-v1") throw new Error("unsupported shadow schema");
  const config = {
    maxUnreviewedGrowthBps: bi(input.config.maxUnreviewedGrowthBps, "maxUnreviewedGrowthBps"),
    tolerances: input.config.tolerances ?? {},
  };
  let state = parseState(input.initial.state);
  let context = parseContext(input.initial.context);
  const cohorts = parseCohort(input.shadowCohort, state);
  const rows = [];

  for (const transition of input.transitions) {
    const beforeState = clone(state);
    const beforeContext = clone(context);
    const applied = applyTransition(state, context, transition, config);
    state = applied.state;
    context = applied.context;
    const observed = observedState(transition.observedState);
    const comparison = compare(state, observed, config.tolerances);
    const classification = observed
      ? classify(transition.kind, comparison.differences)
      : comparison.classification;
    const projections = cohorts.map((cohort) => syncCohort(cohort, state, context));
    rows.push({
      id: transition.id,
      kind: transition.kind,
      blockNumber: bi(transition.blockNumber, `${transition.id}.blockNumber`),
      beforeState,
      beforeContext,
      expectedState: clone(state),
      expectedContext: clone(context),
      observedState: observed,
      classification,
      differences: comparison.differences,
      unitIncrement: applied.unitIncrement,
      recognizedIncrement: applied.recognizedIncrement,
      projections,
    });
  }

  const mismatches = rows.filter((row) => !["match", "not_observed"].includes(row.classification));
  return serialize({
    schema: input.schema,
    source: input.source ?? "unspecified",
    rows,
    summary: {
      transitions: rows.length,
      observed: rows.filter((row) => row.observedState).length,
      matches: rows.filter((row) => row.classification === "match").length,
      mismatches: mismatches.length,
      unobserved: rows.filter((row) => row.classification === "not_observed").length,
      mismatchIds: mismatches.map((row) => row.id),
    },
  });
}

async function main() {
  const path = process.argv[2];
  if (!path) throw new Error("usage: node test/model/tranche-shadow-reconciler.mjs <input.json>");
  const input = JSON.parse(await fs.readFile(path, "utf8"));
  process.stdout.write(`${JSON.stringify(reconcile(input), null, 2)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
