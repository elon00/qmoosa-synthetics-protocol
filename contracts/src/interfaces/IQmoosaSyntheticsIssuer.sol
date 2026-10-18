// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IQmoosaSyntheticsIssuer {
    struct SynthConfig {
        bytes32 currencyKey;
        address synthToken;
        bool isAllowed;
    }

    struct OraclePriceFeed {
        uint256 priceWad;
        uint256 updatedAt;
    }

    event CollateralStaked(address indexed user, uint256 amount);
    event CollateralUnstaked(address indexed user, uint256 amount);
    event SynthsIssued(address indexed user, uint256 susdAmount, uint256 debtSharesMinted);
    event SynthsBurned(address indexed user, uint256 susdAmount, uint256 debtSharesBurned);
    event SynthExchanged(
        address indexed user,
        bytes32 indexed fromCurrencyKey,
        uint256 fromAmount,
        bytes32 indexed toCurrencyKey,
        uint256 toAmount,
        uint256 feeAmount
    );
    event PositionLiquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtCovered,
        uint256 collateralSeized
    );
    event BadDebtDeficitRecorded(address indexed user, uint256 shortfallDebt);
    event OraclePriceUpdated(bytes32 indexed currencyKey, uint256 priceWad, uint256 updatedAt);

    function stakeCollateral(uint256 amount) external;
    function unstakeCollateral(uint256 amount) external;
    function issueSynths(uint256 susdAmount) external;
    function burnSynths(uint256 susdAmount) external;
    function exchange(bytes32 sourceCurrencyKey, uint256 sourceAmount, bytes32 destCurrencyKey) external returns (uint256 destAmount);
    function liquidatePosition(address user, uint256 debtToCover) external;

    function totalDebtShares() external view returns (uint256);
    function debtSharesOf(address user) external view returns (uint256);
    function totalGlobalDebtValue() external view returns (uint256);
    function userDebtValue(address user) external view returns (uint256);
    function userCollateralRatioBps(address user) external view returns (uint256);
}
