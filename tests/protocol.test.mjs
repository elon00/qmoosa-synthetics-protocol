import { test } from "node:test";
import assert from "node:assert/strict";
import {
  calculateDebtSharesToMint,
  calculateDebtSharesToBurn,
  calculateUserDebtValue,
  calculateExchangeAmount,
  calculateCollateralRatio,
  calculateLiquidation,
  BPS_DIVISOR,
  WAD
} from "../dist/index.js";

test("1. Initial synth issuance mints 1:1 debt shares", () => {
  // First minter: 10,000 sUSD with 0 existing shares and 0 existing debt
  const shares = calculateDebtSharesToMint(10_000n * WAD, 0n, 0n);
  assert.equal(shares, 10_000n * WAD);

  // User debt value is 10,000 USD
  const debt = calculateUserDebtValue(shares, shares, 10_000n * WAD);
  assert.equal(debt, 10_000n * WAD);
});

test("2. Dynamic pooled debt tracking when synth prices appreciate", () => {
  // Alice minted 10,000 sUSD (10,000 shares). Bob minted 10,000 sUSD (10,000 shares).
  // Total shares = 20,000. Total debt = 20,000 USD.
  const totalShares = 20_000n * WAD;
  const aliceShares = 10_000n * WAD;

  // Alice exchanges 10,000 sUSD for sETH at $2000/ETH -> gets 5 sETH (ignoring fee for now).
  // Now global synths in circulation: 10,000 sUSD + 5 sETH.
  // ETH price surges to $4000/ETH!
  // Global debt = 10,000 (sUSD) + 5 * 4000 (sETH) = 30,000 USD!
  const newGlobalDebt = 30_000n * WAD;

  // Alice's debt share is 50% (10,000 / 20,000). Her debt in USD is now 50% of 30,000 = 15,000 USD!
  const aliceDebt = calculateUserDebtValue(aliceShares, totalShares, newGlobalDebt);
  assert.equal(aliceDebt, 15_000n * WAD);

  // Bob held sUSD, but because debt is pooled, Bob's debt also increased to 15,000 USD!
  const bobShares = 10_000n * WAD;
  const bobDebt = calculateUserDebtValue(bobShares, totalShares, newGlobalDebt);
  assert.equal(bobDebt, 15_000n * WAD);
});

test("3. Zero-slippage synthetic exchange with dynamic fee deduction", () => {
  // Exchange 10,000 sUSD to sBTC
  // sUSD price: $1.00 (WAD)
  // sBTC price: $50,000 (50000 * WAD)
  // Fee: 30 bps (0.30%) -> $30 fee -> $9,970 net USD
  const { destAmount, feeUsd } = calculateExchangeAmount(
    10_000n * WAD,
    1n * WAD,
    50_000n * WAD,
    30n
  );

  assert.equal(feeUsd, 30n * WAD); // $30
  // Dest amount = (9970 * 1e18) / 50000 = 0.1994 sBTC
  assert.equal(destAmount, (9970n * WAD) / 50000n);
});

test("4. Collateral ratio calculation across decimal precisions (18-dec SNX, 8-dec WBTC)", () => {
  // 1000 SNX at $10 = $10,000 collateral against $2500 debt -> 400% ratio (40000 bps)
  const ratio18 = calculateCollateralRatio(1000n * WAD, 10n * WAD, 2500n * WAD, 18);
  assert.equal(ratio18, 40000n);

  // 1 WBTC (8 decimals) at $60,000 against $20,000 debt -> 300% ratio (30000 bps)
  const ratio8 = calculateCollateralRatio(1n * 10n ** 8n, 60_000n * WAD, 20_000n * WAD, 8);
  assert.equal(ratio8, 30000n);
});

test("5. Liquidation with 10% penalty and bad debt deficit tracking on shortfall", () => {
  // Case A: Solvent collateral cover
  // Debt to cover: 5000 USD, Collateral price: $10, Available: 1000 collateral tokens ($10,000)
  // At 10% penalty: 5000 * 1.1 = $5500 / 10 = 550 collateral tokens seized
  const liqA = calculateLiquidation(5000n * WAD, 5000n * WAD, 1000n * WAD, 10n * WAD, 18, 1000n);
  assert.equal(liqA.actualCover, 5000n * WAD);
  assert.equal(liqA.collateralToSeize, 550n * WAD);
  assert.equal(liqA.badDebtShortfall, 0n);

  // Case B: Severe underwater shortfall
  // Debt to cover: 5000 USD, Collateral price: $2, Available: only 1000 tokens ($2000 value)
  const liqB = calculateLiquidation(5000n * WAD, 5000n * WAD, 1000n * WAD, 2n * WAD, 18, 1000n);
  assert.equal(liqB.actualCover, 5000n * WAD);
  assert.equal(liqB.collateralToSeize, 1000n * WAD); // capped at available
  assert.ok(liqB.badDebtShortfall > 3000n * WAD);
});

test("6. Fail-closed validation on invalid parameters", () => {
  assert.throws(() => calculateDebtSharesToMint(-1n, 100n, 100n), /NEGATIVE_VALUE/);
  assert.throws(() => calculateExchangeAmount(0n, 100n, 100n), /INVALID_SOURCE_AMOUNT/);
  assert.throws(() => calculateExchangeAmount(100n, 0n, 100n), /INVALID_PRICE/);
  assert.throws(() => calculateLiquidation(0n, 100n, 100n, 100n), /INVALID_DEBT_TO_COVER/);
});
