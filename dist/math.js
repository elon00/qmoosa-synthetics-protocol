export const BPS_DIVISOR = 10000n;
export const WAD = 10n ** 18n;
export function calculateDebtSharesToMint(susdAmount, totalDebtShares, totalGlobalDebtValue) {
    if (susdAmount < 0n || totalDebtShares < 0n || totalGlobalDebtValue < 0n) {
        throw new RangeError("NEGATIVE_VALUE: Debt amounts and shares must be non-negative");
    }
    if (susdAmount === 0n)
        return 0n;
    if (totalDebtShares === 0n || totalGlobalDebtValue === 0n) {
        return susdAmount;
    }
    return (susdAmount * totalDebtShares) / totalGlobalDebtValue;
}
export function calculateDebtSharesToBurn(susdAmount, userDebtShares, userDebtValue) {
    if (susdAmount < 0n || userDebtShares < 0n || userDebtValue < 0n) {
        throw new RangeError("NEGATIVE_VALUE: Debt amounts and shares must be non-negative");
    }
    if (susdAmount === 0n || userDebtShares === 0n || userDebtValue === 0n) {
        return 0n;
    }
    const burnAmount = susdAmount > userDebtValue ? userDebtValue : susdAmount;
    return (burnAmount * userDebtShares) / userDebtValue;
}
export function calculateUserDebtValue(userDebtShares, totalDebtShares, totalGlobalDebtValue) {
    if (userDebtShares < 0n || totalDebtShares < 0n || totalGlobalDebtValue < 0n) {
        throw new RangeError("NEGATIVE_VALUE: Debt shares and global debt must be non-negative");
    }
    if (totalDebtShares === 0n || userDebtShares === 0n) {
        return 0n;
    }
    return (userDebtShares * totalGlobalDebtValue) / totalDebtShares;
}
export function calculateExchangeAmount(sourceAmount, sourcePriceWad, destPriceWad, exchangeFeeBps = 30n) {
    if (sourceAmount <= 0n) {
        throw new RangeError("INVALID_SOURCE_AMOUNT: Source amount must be strictly positive");
    }
    if (sourcePriceWad <= 0n || destPriceWad <= 0n) {
        throw new RangeError("INVALID_PRICE: Prices must be strictly positive");
    }
    if (exchangeFeeBps < 0n || exchangeFeeBps > 5000n) {
        throw new RangeError("INVALID_FEE: Exchange fee must be between 0 and 5000 bps");
    }
    const sourceValueUsd = (sourceAmount * sourcePriceWad) / WAD;
    const feeUsd = (sourceValueUsd * exchangeFeeBps) / BPS_DIVISOR;
    const netUsd = sourceValueUsd - feeUsd;
    const destAmount = (netUsd * WAD) / destPriceWad;
    return { destAmount, feeUsd };
}
export function calculateCollateralRatio(collateralAmount, collateralPriceWad, userDebtValueWad, collateralDecimals = 18) {
    if (collateralAmount < 0n || collateralPriceWad < 0n || userDebtValueWad < 0n) {
        throw new RangeError("NEGATIVE_VALUE: Inputs must be non-negative");
    }
    if (userDebtValueWad === 0n) {
        return 100000000n; // infinite ratio
    }
    const collateralValueWad = (collateralAmount * collateralPriceWad) / (10n ** BigInt(collateralDecimals));
    return (collateralValueWad * BPS_DIVISOR) / userDebtValueWad;
}
export function calculateLiquidation(debtToCover, userDebtValueWad, userCollateralAmount, collateralPriceWad, collateralDecimals = 18, liquidationPenaltyBps = 1000n) {
    if (debtToCover <= 0n) {
        throw new RangeError("INVALID_DEBT_TO_COVER: Debt to cover must be strictly positive");
    }
    if (collateralPriceWad <= 0n) {
        throw new RangeError("INVALID_PRICE: Collateral price must be strictly positive");
    }
    const actualCover = debtToCover > userDebtValueWad ? userDebtValueWad : debtToCover;
    const repayValueWithPenalty = (actualCover * (BPS_DIVISOR + liquidationPenaltyBps)) / BPS_DIVISOR;
    const theoreticalSeize = (repayValueWithPenalty * (10n ** BigInt(collateralDecimals))) / collateralPriceWad;
    if (theoreticalSeize <= userCollateralAmount) {
        return { actualCover, collateralToSeize: theoreticalSeize, badDebtShortfall: 0n };
    }
    const actualSeize = userCollateralAmount;
    const seizedValueWad = (actualSeize * collateralPriceWad) / (10n ** BigInt(collateralDecimals));
    const coveredDebt = (seizedValueWad * BPS_DIVISOR) / (BPS_DIVISOR + liquidationPenaltyBps);
    const badDebtShortfall = actualCover > coveredDebt ? actualCover - coveredDebt : 0n;
    return { actualCover, collateralToSeize: actualSeize, badDebtShortfall };
}
