export declare const BPS_DIVISOR = 10000n;
export declare const WAD: bigint;
export declare function calculateDebtSharesToMint(susdAmount: bigint, totalDebtShares: bigint, totalGlobalDebtValue: bigint): bigint;
export declare function calculateDebtSharesToBurn(susdAmount: bigint, userDebtShares: bigint, userDebtValue: bigint): bigint;
export declare function calculateUserDebtValue(userDebtShares: bigint, totalDebtShares: bigint, totalGlobalDebtValue: bigint): bigint;
export declare function calculateExchangeAmount(sourceAmount: bigint, sourcePriceWad: bigint, destPriceWad: bigint, exchangeFeeBps?: bigint): {
    destAmount: bigint;
    feeUsd: bigint;
};
export declare function calculateCollateralRatio(collateralAmount: bigint, collateralPriceWad: bigint, userDebtValueWad: bigint, collateralDecimals?: number): bigint;
export declare function calculateLiquidation(debtToCover: bigint, userDebtValueWad: bigint, userCollateralAmount: bigint, collateralPriceWad: bigint, collateralDecimals?: number, liquidationPenaltyBps?: bigint): {
    actualCover: bigint;
    collateralToSeize: bigint;
    badDebtShortfall: bigint;
};
