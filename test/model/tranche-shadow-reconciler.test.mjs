import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

import {reconcile} from "./tranche-shadow-reconciler.mjs";

const fixtureUrl = new URL("./fixtures/tranche-shadow-synthetic.json", import.meta.url);

function fixture() {
  return JSON.parse(fs.readFileSync(fixtureUrl, "utf8"));
}

function hydrateObserved(input) {
  const first = reconcile(input);
  const hydrated = structuredClone(input);
  for (let index = 0; index < hydrated.transitions.length; index += 1) {
    hydrated.transitions[index].observedState = first.rows[index].expectedState;
  }
  return hydrated;
}

test("synthetic lifecycle produces deterministic V3 state and V3 projections", () => {
  const result = reconcile(fixture());
  assert.deepEqual(result.summary, {
    transitions: 10,
    observed: 0,
    matches: 0,
    mismatches: 0,
    unobserved: 10,
    mismatchIds: [],
  });
  assert.equal(result.rows[0].unitIncrement, "0");
  assert.equal(result.rows[1].unitIncrement, "0");
  assert.equal(result.rows[2].unitIncrement, "600000000000000");
  assert.equal(result.rows[3].unitIncrement, "500000000000000");
  assert.equal(result.rows[4].expectedState.pendingFundedUSDat, "100000000");
  assert.equal(result.rows[5].expectedState.recognizedUSDat, "40000000");
  assert.equal(result.rows[6].expectedState.crystallizationNonce, "1");
  assert.equal(result.rows[8].unitIncrement, "0", "neutral split cannot create eligible income");
  assert.equal(result.rows[8].expectedState.incomeState, "Active");
  assert.equal(result.rows.at(-1).expectedState.pendingFundedUSDat, "0");
  assert.equal(result.rows.at(-1).projections.length, 5);
});

test("fully observed expected snapshots reconcile exactly", () => {
  const result = reconcile(hydrateObserved(fixture()));
  assert.equal(result.summary.observed, 10);
  assert.equal(result.summary.matches, 10);
  assert.equal(result.summary.mismatches, 0);
});

test("supply-boundary income mismatch is classified", () => {
  const input = hydrateObserved(fixture());
  input.transitions[2].observedState.eligibleUnitsPerSUSDatShareWad = "59999999999999999";
  const result = reconcile(input);
  assert.equal(result.summary.mismatches, 1);
  assert.equal(result.rows[2].classification, "supply_boundary_mismatch");
});

test("cash recognition mismatch is classified", () => {
  const input = hydrateObserved(fixture());
  input.transitions[5].observedState.recognizedUSDat = "39999999";
  const result = reconcile(input);
  assert.equal(result.summary.mismatches, 1);
  assert.equal(result.rows[5].classification, "cash_recognition_mismatch");
});

test("crystallization mismatch is classified", () => {
  const input = hydrateObserved(fixture());
  input.transitions[6].observedState.liveUnitScaleWad = "750000000000000001";
  const result = reconcile(input);
  assert.equal(result.summary.mismatches, 1);
  assert.equal(result.rows[6].classification, "crystallization_mismatch");
});

test("partial observations compare only supplied state keys", () => {
  const input = fixture();
  const expected = reconcile(input);
  input.transitions[2].observedState = {
    eligibleUnitsPerSUSDatShareWad: expected.rows[2].expectedState.eligibleUnitsPerSUSDatShareWad,
  };
  const result = reconcile(input);
  assert.equal(result.rows[2].classification, "match");
  assert.equal(result.summary.observed, 1);
});
