export interface SynthConfig {
    currencyKey: string;
    name: string;
    symbol: string;
    priceWad: bigint;
    totalSupply: bigint;
}
export interface StakerPosition {
    user: string;
    stakedCollateral: bigint;
    debtShares: bigint;
    debtValueUsd: bigint;
    collateralValueUsd: bigint;
    collateralRatioBps: bigint;
    isSolvent: boolean;
    isLiquidatable: boolean;
}
export interface ExchangeQuote {
    sourceCurrencyKey: string;
    sourceAmount: bigint;
    destCurrencyKey: string;
    destAmount: bigint;
    feeUsd: bigint;
    effectiveRateWad: bigint;
}
export interface LiquidationQuote {
    user: string;
    debtToCover: bigint;
    collateralToSeize: bigint;
    penaltyCollateral: bigint;
    badDebtShortfall: bigint;
}
