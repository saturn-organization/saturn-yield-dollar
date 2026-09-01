import assert from "node:assert/strict";
import test from "node:test";

import {
  capacity,
  classYields,
  runCalibration,
} from "./tranche-calibration-replay.mjs";

const PRICES = [
  {date: new Date("2025-07-29T00:00:00Z"), close: 100},
  {date: new Date("2025-08-31T00:00:00Z"), close: 100},
  {date: new Date("2026-05-16T00:00:00Z"), close: 90},
  {date: new Date("2026-08-28T00:00:00Z"), close: 95},
];

const DIVIDENDS = [
  {period: "one", payout: "2025-08-31", rate: 0.12, amount: 1},
  {period: "two", payout: "2026-05-16", rate: 0.12, amount: 1},
];

const SVALUES = [
  {date: "2026-05-15T00:00:00Z", value: 1, kind: "asset added"},
  {date: "2026-05-16T00:00:00Z", value: 1.01, kind: "ordinary update"},
  {date: "2026-08-14T00:00:00Z", value: 1.02, kind: "ordinary update"},
];

test("150% coverage capacity equations match the selected V3 design", () => {
  const result = capacity(1.20, 0.75);
  assert(Math.abs(result.coverage - 1.6) < 1e-12);
  assert(Math.abs(result.juniorRedemption - 0.075) < 1e-12);
  assert(Math.abs(result.seniorDeposit - 0.15) < 1e-12);
});

test("class accounting yields conserve eligible portfolio income", () => {
  const result = classYields(0.12, 0.45);
  assert(Math.abs((2 / 3) * result.senior + (1 / 3) * result.junior - 0.12) < 1e-12);
});

test("calibration separates historical evidence, cash scenarios, and shocks", () => {
  const result = runCalibration({
    prices: PRICES,
    dividends: DIVIDENDS,
    sValues: SVALUES,
    scenarios: [{
      name: "test",
      strconWeight: 0.90,
      annualEligibleCosts: 0.0025,
      annualRecognizedUSDatSurplus: 0.0025,
    }],
    alphas: [0.35, 0.50, 0.60],
    priceShocks: [0, -0.20, -0.40],
  });

  assert.equal(result.priceHistory.sessions, 4);
  assert.equal(result.counterfactualReplay.distributionsIncluded, 2);
  assert.equal(result.scenarioResults.length, 1);
  assert.equal(result.scenarioResults[0].alphaResults.length, 3);
  assert.equal(result.scenarioResults[0].alphaResults[0].shocks.length, 3);
  assert(result.scenarioResults[0].yEff > 0);
  assert(result.warnings.some((warning) => warning.includes("funded-USDat surplus")));
});

test("higher alpha increases Senior yield and decreases Junior yield", () => {
  const result = runCalibration({
    prices: PRICES,
    dividends: DIVIDENDS,
    sValues: SVALUES,
    scenarios: [{
      name: "test",
      strconWeight: 0.90,
      annualEligibleCosts: 0,
      annualRecognizedUSDatSurplus: 0,
    }],
    alphas: [0.35, 0.60],
    priceShocks: [0],
  });
  const [low, high] = result.scenarioResults[0].alphaResults;
  assert(high.accountingYields.senior > low.accountingYields.senior);
  assert(high.accountingYields.junior < low.accountingYields.junior);
});

test("rejects malformed histories", () => {
  assert.throws(() => runCalibration({prices: [{date: new Date(), close: 100}]}));
  assert.throws(() => runCalibration({prices: [
    {date: new Date("2026-01-01"), close: 100},
    {date: new Date("2026-01-02"), close: 0},
  ]}));
});
