#!/usr/bin/env node

// Non-deployable V3 economics calibration harness.
//
// Historical inputs:
// - STRC daily closes from Nasdaq's official historical endpoint;
// - Strategy's published/SEC-filed paid distribution schedule; and
// - observed STRCon SyntheticSharesOracle values reproduced from onchain logs.
//
// Everything else is explicitly a model assumption. This file does not read an
// RPC, mutate contracts, or select production parameters.

import assert from "node:assert/strict";
import {pathToFileURL} from "node:url";

export const NASDAQ_URL =
  "https://api.nasdaq.com/api/quote/STRC/historical?assetclass=stocks&fromdate=2025-07-29&limit=5000";
export const HISTORICAL_CUTOFF = "2026-08-28";

export const OPENING_SENIOR = 2 / 3;
export const OPENING_JUNIOR = 1 / 3;
export const PREFERRED_COVERAGE = 1.5;
export const ALPHAS = [0.35, 0.40, 0.45, 0.50, 0.60];

// Paid periods only through the historical price window used by this model.
export const DIVIDENDS = [
  {period: "Aug 2025", payout: "2025-08-31", rate: 0.09, amount: 0.80},
  {period: "Sep 2025", payout: "2025-09-30", rate: 0.10, amount: 0.833333333},
  {period: "Oct 2025", payout: "2025-10-31", rate: 0.1025, amount: 0.854166667},
  {period: "Nov 2025", payout: "2025-11-30", rate: 0.105, amount: 0.875},
  {period: "Dec 2025", payout: "2025-12-31", rate: 0.1075, amount: 0.895833333},
  {period: "Jan 2026", payout: "2026-01-31", rate: 0.11, amount: 0.916666667},
  {period: "Feb 2026", payout: "2026-02-28", rate: 0.1125, amount: 0.9375},
  {period: "Mar 2026", payout: "2026-03-31", rate: 0.115, amount: 0.958333333},
  {period: "Apr 2026", payout: "2026-04-30", rate: 0.115, amount: 0.958333333},
  {period: "May 2026", payout: "2026-05-31", rate: 0.115, amount: 0.958333333},
  {period: "Jun 2026", payout: "2026-06-30", rate: 0.115, amount: 0.958333333},
  {period: "Jun 2026 #2", payout: "2026-07-15", rate: 0.115, amount: 0.479166667},
  {period: "Jul 2026 #1", payout: "2026-07-31", rate: 0.12, amount: 0.50},
  {period: "Jul 2026 #2", payout: "2026-08-15", rate: 0.12, amount: 0.50},
];

export const STRCON_SVALUE = [
  {date: "2026-05-15T17:26:35Z", value: 1.000000000000000000, kind: "asset added"},
  {date: "2026-05-16T17:31:23Z", value: 1.009652696788825666, kind: "ordinary update"},
  {date: "2026-06-15T00:06:59Z", value: 1.019843070324219905, kind: "ordinary update"},
  {date: "2026-06-30T00:06:11Z", value: 1.025721974682337681, kind: "ordinary update"},
  {date: "2026-07-15T00:05:59Z", value: 1.031476806152773386, kind: "ordinary update"},
  {date: "2026-07-31T00:06:35Z", value: 1.037223195044989394, kind: "ordinary update"},
  {date: "2026-08-14T00:06:23Z", value: 1.042639450079795466, kind: "ordinary update"},
];

// Funded-USDat yield is a scenario until post-V2 vault history exists. It is
// never inferred from the backing-layer recipient balance.
export const PORTFOLIO_SCENARIOS = [
  {
    name: "downside",
    strconWeight: 0.80,
    annualEligibleCosts: 0.0050,
    annualRecognizedUSDatSurplus: 0,
  },
  {
    name: "base without funded-USDat surplus",
    strconWeight: 0.90,
    annualEligibleCosts: 0.0025,
    annualRecognizedUSDatSurplus: 0,
  },
  {
    name: "base plus funded-USDat sensitivity",
    strconWeight: 0.90,
    annualEligibleCosts: 0.0025,
    annualRecognizedUSDatSurplus: 0.0025,
  },
  {
    name: "upside reference",
    strconWeight: 0.9878870433,
    annualEligibleCosts: 0.0010,
    annualRecognizedUSDatSurplus: 0.0050,
  },
];

export const PRICE_SHOCKS = [0, -0.10, -0.20, -0.30, -0.40, -0.50];

function parseNasdaqDate(text) {
  const [month, day, year] = text.split("/").map(Number);
  return new Date(Date.UTC(year, month - 1, day));
}

function cleanNumber(text) {
  return Number(String(text).replace(/[$,]/g, ""));
}

export async function fetchNasdaqPrices(fetchImpl = fetch) {
  let lastError;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      const response = await fetchImpl(NASDAQ_URL, {
        headers: {accept: "application/json, text/plain, */*", "user-agent": "Mozilla/5.0"},
      });
      if (!response.ok) throw new Error(`Nasdaq HTTP ${response.status}`);
      const body = await response.json();
      const rows = body?.data?.tradesTable?.rows;
      if (!Array.isArray(rows) || rows.length === 0) throw new Error("Nasdaq returned no price rows");
      return rows.map((row) => ({
        date: parseNasdaqDate(row.date),
        close: cleanNumber(row.close),
      })).sort((a, b) => a.date - b.date);
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** attempt));
    }
  }
  throw lastError;
}

function daysBetween(a, b) {
  return (new Date(b) - new Date(a)) / 86_400_000;
}

function annualize(growth, days) {
  if (days <= 0) throw new Error("invalid annualization period");
  return (1 + growth) ** (365 / days) - 1;
}

function firstTradingCloseOnOrAfter(prices, isoDate) {
  const target = new Date(`${isoDate}T00:00:00Z`);
  return prices.find((point) => point.date >= target) ?? null;
}

function latestSValueAt(isoDate, sValues) {
  const target = new Date(`${isoDate}T23:59:59Z`);
  const available = sValues.filter((row) => new Date(row.date) <= target);
  return available.length === 0 ? null : available.at(-1).value;
}

export function capacity(backing, claim, preferredCoverage = PREFERRED_COVERAGE) {
  if (claim <= 0) {
    return {coverage: Infinity, juniorRedemption: backing, seniorDeposit: 0};
  }
  const excess = Math.max(0, backing - preferredCoverage * claim);
  return {
    coverage: backing / claim,
    juniorRedemption: excess,
    seniorDeposit: excess / (preferredCoverage - 1),
  };
}

export function classYields(yEff, alpha, openingSenior = OPENING_SENIOR) {
  const openingJunior = 1 - openingSenior;
  return {
    senior: alpha * yEff / openingSenior,
    junior: (1 - alpha) * yEff / openingJunior,
  };
}

export function runCalibration({
  prices,
  dividends = DIVIDENDS,
  sValues = STRCON_SVALUE,
  scenarios = PORTFOLIO_SCENARIOS,
  alphas = ALPHAS,
  priceShocks = PRICE_SHOCKS,
  cutoffDate = HISTORICAL_CUTOFF,
} = {}) {
  if (!Array.isArray(prices) || prices.length < 2) throw new Error("at least two prices required");
  const cutoff = cutoffDate ? new Date(`${cutoffDate}T23:59:59Z`) : null;
  const orderedPrices = prices.map((row) => ({date: new Date(row.date), close: Number(row.close)}))
    .filter((row) => !cutoff || row.date <= cutoff)
    .sort((a, b) => a.date - b.date);
  if (orderedPrices.length < 2) throw new Error("at least two prices required before cutoff");
  if (orderedPrices.some((row) => !Number.isFinite(row.close) || row.close <= 0)) {
    throw new Error("invalid price history");
  }
  if (sValues.some((row, index) => index > 0 && row.value <= sValues[index - 1].value)) {
    throw new Error("STRCon sValue fixture is not strictly increasing");
  }

  let counterfactualMultiplier = 1;
  const lastPriceDate = orderedPrices.at(-1).date;
  const dividendRows = dividends.map((dividend) => {
    const price = firstTradingCloseOnOrAfter(orderedPrices, dividend.payout);
    if (!price || price.date > lastPriceDate) return {...dividend, included: false};
    const reinvestmentReturn = dividend.amount / price.close;
    counterfactualMultiplier *= 1 + reinvestmentReturn;
    return {
      ...dividend,
      included: true,
      modeledReinvestmentDate: price.date.toISOString().slice(0, 10),
      modeledReinvestmentClose: price.close,
      reinvestmentReturn,
      cumulativeCounterfactualMultiplier: counterfactualMultiplier,
    };
  });
  const included = dividendRows.filter((row) => row.included);
  if (included.length === 0) throw new Error("no dividends overlap price history");

  const replayStart = orderedPrices[0].date;
  const replayEnd = orderedPrices.at(-1).date;
  const replayDays = daysBetween(replayStart, replayEnd);
  const counterfactualGrowth = counterfactualMultiplier - 1;
  const counterfactualAnnualized = annualize(counterfactualGrowth, replayDays);

  const strconStartDate = sValues[0].date.slice(0, 10);
  const counterfactualBeforeSTRCon = included
    .filter((row) => row.modeledReinvestmentDate < strconStartDate)
    .reduce((factor, row) => factor * (1 + row.reinvestmentReturn), 1);
  function hybridMultiplierAt(isoDate) {
    if (isoDate < strconStartDate) {
      return included
        .filter((row) => row.modeledReinvestmentDate <= isoDate)
        .reduce((factor, row) => factor * (1 + row.reinvestmentReturn), 1);
    }
    return counterfactualBeforeSTRCon * (latestSValueAt(isoDate, sValues) ?? 1);
  }

  const observedDays = daysBetween(sValues[0].date, sValues.at(-1).date);
  const observedGrowth = sValues.at(-1).value / sValues[0].value - 1;
  const observedAnnualized = annualize(observedGrowth, observedDays);
  const initialClose = orderedPrices[0].close;

  const scenarioResults = scenarios.map((scenario) => {
    const yEff = Math.max(
      0,
      scenario.strconWeight * counterfactualAnnualized
        - scenario.annualEligibleCosts
        + scenario.annualRecognizedUSDatSurplus,
    );
    const alphaForEightPercentSenior = 0.08 * OPENING_SENIOR / yEff;
    const alphaResults = alphas.map((alpha) => {
      const daily = orderedPrices.map((point) => {
        const isoDate = point.date.toISOString().slice(0, 10);
        const elapsedYears = daysBetween(replayStart, point.date) / 365;
        const multiplier = hybridMultiplierAt(isoDate);
        const markedSTRCon = scenario.strconWeight * (point.close / initialClose) * multiplier;
        const cashAndOtherOpening = 1 - scenario.strconWeight;
        const recognizedCash = scenario.annualRecognizedUSDatSurplus * elapsedYears;
        const eligibleCosts = scenario.annualEligibleCosts * elapsedYears;
        const fullStackNAV = cashAndOtherOpening + markedSTRCon + recognizedCash - eligibleCosts;
        const strconEligible = scenario.strconWeight * (multiplier - 1);
        const netEligible = Math.max(0, strconEligible + recognizedCash - eligibleCosts);
        const contractualSeniorClaim = OPENING_SENIOR + alpha * netEligible;
        const markedSeniorNAV = Math.min(fullStackNAV, contractualSeniorClaim);
        const markedJuniorNAV = Math.max(0, fullStackNAV - markedSeniorNAV);
        return {
          date: isoDate,
          fullStackNAV,
          contractualSeniorClaim,
          markedSeniorNAV,
          markedJuniorNAV,
          ...capacity(fullStackNAV, contractualSeniorClaim),
        };
      });
      const end = daily.at(-1);
      const worstCoverage = daily.reduce((a, b) => a.coverage < b.coverage ? a : b);
      const worstJunior = daily.reduce((a, b) => a.markedJuniorNAV < b.markedJuniorNAV ? a : b);
      const impairedDays = daily.filter((row) => row.fullStackNAV < row.contractualSeniorClaim).length;
      const endSTRConMark = scenario.strconWeight
        * (orderedPrices.at(-1).close / initialClose) * hybridMultiplierAt(end.date);
      const priceShockToImpairment = (end.contractualSeniorClaim - end.fullStackNAV) / endSTRConMark;
      const shocks = priceShocks.map((shock) => {
        const shockedBacking = end.fullStackNAV + endSTRConMark * shock;
        const markedSenior = Math.min(shockedBacking, end.contractualSeniorClaim);
        const juniorResidual = Math.max(0, shockedBacking - markedSenior);
        return {
          shock,
          backing: shockedBacking,
          claim: end.contractualSeniorClaim,
          markedSenior,
          juniorResidual,
          seniorShortfall: Math.max(0, end.contractualSeniorClaim - shockedBacking),
          ...capacity(shockedBacking, end.contractualSeniorClaim),
        };
      });
      return {
        alpha,
        accountingYields: classYields(yEff, alpha),
        end,
        worstCoverage,
        worstJunior,
        impairedTradingDays: impairedDays,
        minimumJuniorRedemptionCapacity: Math.min(...daily.map((row) => row.juniorRedemption)),
        maximumJuniorRedemptionCapacity: Math.max(...daily.map((row) => row.juniorRedemption)),
        maximumSeniorDepositCapacity: Math.max(...daily.map((row) => row.seniorDeposit)),
        priceShockToImpairment,
        shocks,
      };
    });
    return {...scenario, yEff, alphaForEightPercentSenior, alphaResults};
  });

  const closes = orderedPrices.map((row) => row.close);
  return {
    methodology: {
      openingSenior: OPENING_SENIOR,
      openingJunior: OPENING_JUNIOR,
      preferredCoverage: PREFERRED_COVERAGE,
      incomeRule: "fixed participation in eligible portfolio income; capitalized Senior NAV",
      cashIncomeRule: "actual recognized funded-USDat surplus only; scenario until post-V2 history exists",
    },
    evidence: {
      actual: [
        "Strategy/SEC STRC distribution amounts and rates",
        "official Nasdaq daily STRC closes",
        "observed May-August 2026 STRCon sValue events",
      ],
      modeled: [
        "pre-STRCon reinvestment at first Nasdaq close on or after payout",
        "constant STRCon portfolio exposure per scenario",
        "eligible costs and funded-USDat surplus scenarios",
        "post-window instantaneous STRC price shocks",
      ],
    },
    priceHistory: {
      sessions: orderedPrices.length,
      firstDate: replayStart.toISOString().slice(0, 10),
      lastDate: replayEnd.toISOString().slice(0, 10),
      firstClose: orderedPrices[0].close,
      lastClose: orderedPrices.at(-1).close,
      minimumClose: Math.min(...closes),
      maximumClose: Math.max(...closes),
    },
    counterfactualReplay: {
      days: replayDays,
      distributionsIncluded: included.length,
      cashDividendPerOpeningShare: included.reduce((sum, row) => sum + row.amount, 0),
      endingMultiplier: counterfactualMultiplier,
      cumulativeGrowth: counterfactualGrowth,
      annualizedGrowth: counterfactualAnnualized,
      dividendRows,
    },
    observedSTRCon: {
      days: observedDays,
      cumulativeGrowth: observedGrowth,
      annualizedGrowth: observedAnnualized,
      events: sValues,
    },
    scenarioResults,
    warnings: [
      "Historical replay is not post-V2 vault evidence and does not prove future income.",
      "Nasdaq closes proxy pre-STRCon reinvestment prices; they are not Ondo execution records.",
      "Recognized funded-USDat surplus is a scenario, not reconstructed history.",
      "Constant exposure omits actual deposit, withdrawal, and rotation timing.",
      "Stress shocks are deterministic sensitivities, not probabilistic loss estimates.",
      "Do not freeze alpha or pilot size from the upside case.",
    ],
  };
}

function assertResult(result) {
  assert.equal(result.methodology.openingSenior + result.methodology.openingJunior, 1);
  assert.equal(result.methodology.preferredCoverage, 1.5);
  for (const scenario of result.scenarioResults) {
    assert(scenario.yEff >= 0);
    for (const row of scenario.alphaResults) {
      assert(Math.abs(
        OPENING_SENIOR * row.accountingYields.senior
          + OPENING_JUNIOR * row.accountingYields.junior
          - scenario.yEff,
      ) < 1e-12, "income allocation must conserve eligible income");
      assert(row.end.markedSeniorNAV + row.end.markedJuniorNAV <= row.end.fullStackNAV + 1e-12);
      assert(row.shocks.every((shock) => shock.markedSenior + shock.juniorResidual <= shock.backing + 1e-12));
    }
  }
}

async function main() {
  const prices = await fetchNasdaqPrices();
  const result = runCalibration({prices});
  assertResult(result);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
