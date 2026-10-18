// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ISyntheticAsset.sol";
import "./interfaces/IQmoosaSyntheticsIssuer.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract QmoosaSyntheticsIssuer is IQmoosaSyntheticsIssuer {
    uint256 public constant BPS_DIVISOR = 10000;
    uint256 public constant WAD = 1e18;

    bytes32 public constant SUSD_KEY = bytes32("sUSD");

    address public owner;
    IERC20Minimal public immutable collateralToken;
    uint8 public immutable collateralDecimals;

    uint256 public minCollateralRatioBps = 20000; // 200% issuance ratio
    uint256 public liquidationPenaltyBps = 1000;  // 10% penalty
    uint256 public exchangeFeeBps = 30;          // 0.30% exchange fee
    uint256 public maxOracleStaleness = 3600;     // 1 hour
    uint256 public maxPriceDeviationBps = 5000;   // 50% max deviation
    uint256 public protocolBadDebt;

    uint256 public override totalDebtShares;
    mapping(address => uint256) public override debtSharesOf;
    mapping(address => uint256) public stakedCollateral;

    bytes32[] public synthKeys;
    mapping(bytes32 => address) public synths;
    mapping(bytes32 => OraclePriceFeed) public oracleFeeds;

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY_GUARD: REENTRANT_CALL");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "SYNTH_ISSUER: ONLY_OWNER");
        _;
    }

    constructor(address _collateralToken, uint8 _collateralDecimals) {
        require(_collateralToken != address(0), "SYNTH_ISSUER: ZERO_ADDRESS");
        owner = msg.sender;
        collateralToken = IERC20Minimal(_collateralToken);
        collateralDecimals = _collateralDecimals;
        _status = _NOT_ENTERED;
    }

    function addSynth(bytes32 currencyKey, address synthToken) external onlyOwner {
        require(synthToken != address(0), "SYNTH_ISSUER: ZERO_SYNTH");
        require(synths[currencyKey] == address(0), "SYNTH_ISSUER: ALREADY_REGISTERED");
        synths[currencyKey] = synthToken;
        synthKeys.push(currencyKey);
    }

    function setOraclePrice(bytes32 currencyKey, uint256 priceWad) external onlyOwner {
        _setOraclePriceInternal(currencyKey, priceWad, block.timestamp, false);
    }

    function setOraclePriceWithTimestamp(bytes32 currencyKey, uint256 priceWad, uint256 updatedAt) external onlyOwner {
        _setOraclePriceInternal(currencyKey, priceWad, updatedAt, false);
    }

    function overrideOraclePrice(bytes32 currencyKey, uint256 priceWad) external onlyOwner {
        _setOraclePriceInternal(currencyKey, priceWad, block.timestamp, true);
    }

    function _setOraclePriceInternal(
        bytes32 currencyKey,
        uint256 priceWad,
        uint256 updatedAt,
        bool bypassDeviationCheck
    ) internal {
        require(priceWad > 0, "SYNTH_ISSUER: ZERO_PRICE");
        require(updatedAt <= block.timestamp, "SYNTH_ISSUER: FUTURE_TIMESTAMP");
        require(block.timestamp - updatedAt <= maxOracleStaleness, "SYNTH_ISSUER: PRICE_STALE");

        OraclePriceFeed storage feed = oracleFeeds[currencyKey];
        if (!bypassDeviationCheck && feed.priceWad > 0) {
            uint256 prev = feed.priceWad;
            uint256 diff = priceWad > prev ? priceWad - prev : prev - priceWad;
            uint256 devBps = (diff * BPS_DIVISOR) / prev;
            require(devBps <= maxPriceDeviationBps, "SYNTH_ISSUER: PRICE_DEVIATION_EXCEEDED");
        }

        feed.priceWad = priceWad;
        feed.updatedAt = updatedAt;
        emit OraclePriceUpdated(currencyKey, priceWad, updatedAt);
    }

    function getOraclePrice(bytes32 currencyKey) public view returns (uint256) {
        OraclePriceFeed storage feed = oracleFeeds[currencyKey];
        require(feed.priceWad > 0, "SYNTH_ISSUER: ORACLE_NOT_SET");
        require(block.timestamp - feed.updatedAt <= maxOracleStaleness, "SYNTH_ISSUER: ORACLE_STALE");
        return feed.priceWad;
    }

    function stakeCollateral(uint256 amount) external override nonReentrant {
        require(amount > 0, "SYNTH_ISSUER: ZERO_AMOUNT");
        bool success = collateralToken.transferFrom(msg.sender, address(this), amount);
        require(success, "SYNTH_ISSUER: TRANSFER_FAILED");

        stakedCollateral[msg.sender] += amount;
        emit CollateralStaked(msg.sender, amount);
    }

    function unstakeCollateral(uint256 amount) external override nonReentrant {
        require(amount > 0 && amount <= stakedCollateral[msg.sender], "SYNTH_ISSUER: INVALID_AMOUNT");

        stakedCollateral[msg.sender] -= amount;
        if (debtSharesOf[msg.sender] > 0) {
            require(userCollateralRatioBps(msg.sender) >= minCollateralRatioBps, "SYNTH_ISSUER: UNSTAKE_BREAKS_RATIO");
        }

        bool success = collateralToken.transfer(msg.sender, amount);
        require(success, "SYNTH_ISSUER: TRANSFER_FAILED");

        emit CollateralUnstaked(msg.sender, amount);
    }

    function issueSynths(uint256 susdAmount) external override nonReentrant {
        require(susdAmount > 0, "SYNTH_ISSUER: ZERO_AMOUNT");
        address susdAddr = synths[SUSD_KEY];
        require(susdAddr != address(0), "SYNTH_ISSUER: SUSD_NOT_REGISTERED");

        uint256 currentTotalDebt = totalGlobalDebtValue();
        uint256 sharesToMint;

        if (totalDebtShares == 0 || currentTotalDebt == 0) {
            sharesToMint = susdAmount;
        } else {
            sharesToMint = (susdAmount * totalDebtShares) / currentTotalDebt;
        }

        debtSharesOf[msg.sender] += sharesToMint;
        totalDebtShares += sharesToMint;

        ISyntheticAsset(susdAddr).mint(msg.sender, susdAmount);
        require(userCollateralRatioBps(msg.sender) >= minCollateralRatioBps, "SYNTH_ISSUER: UNDERCOLLATERALIZED");

        emit SynthsIssued(msg.sender, susdAmount, sharesToMint);
    }

    function burnSynths(uint256 susdAmount) external override nonReentrant {
        require(susdAmount > 0, "SYNTH_ISSUER: ZERO_AMOUNT");
        address susdAddr = synths[SUSD_KEY];
        require(susdAddr != address(0), "SYNTH_ISSUER: SUSD_NOT_REGISTERED");

        uint256 userDebt = userDebtValue(msg.sender);
        require(userDebt > 0, "SYNTH_ISSUER: ZERO_DEBT");

        uint256 burnAmount = susdAmount > userDebt ? userDebt : susdAmount;
        uint256 sharesToBurn = (burnAmount * debtSharesOf[msg.sender]) / userDebt;

        debtSharesOf[msg.sender] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;

        ISyntheticAsset(susdAddr).burn(msg.sender, burnAmount);
        emit SynthsBurned(msg.sender, burnAmount, sharesToBurn);
    }

    function exchange(
        bytes32 sourceCurrencyKey,
        uint256 sourceAmount,
        bytes32 destCurrencyKey
    ) external override nonReentrant returns (uint256 destAmount) {
        require(sourceCurrencyKey != destCurrencyKey, "SYNTH_ISSUER: CANNOT_EXCHANGE_SAME_CURRENCY");
        require(sourceAmount > 0, "SYNTH_ISSUER: ZERO_SOURCE_AMOUNT");

        address sourceSynth = synths[sourceCurrencyKey];
        address destSynth = synths[destCurrencyKey];
        require(sourceSynth != address(0) && destSynth != address(0), "SYNTH_ISSUER: UNREGISTERED_SYNTH");

        uint256 sourcePrice = getOraclePrice(sourceCurrencyKey);
        uint256 destPrice = getOraclePrice(destCurrencyKey);

        // USD value of source synth: (sourceAmount * sourcePrice) / 1e18
        uint256 sourceValueUsd = (sourceAmount * sourcePrice) / WAD;
        uint256 feeUsd = (sourceValueUsd * exchangeFeeBps) / BPS_DIVISOR;
        uint256 netUsd = sourceValueUsd - feeUsd;

        // Destination amount: (netUsd * 1e18) / destPrice
        destAmount = (netUsd * WAD) / destPrice;

        ISyntheticAsset(sourceSynth).burn(msg.sender, sourceAmount);
        ISyntheticAsset(destSynth).mint(msg.sender, destAmount);

        emit SynthExchanged(msg.sender, sourceCurrencyKey, sourceAmount, destCurrencyKey, destAmount, feeUsd);
    }

    function liquidatePosition(address user, uint256 debtToCover) external override nonReentrant {
        require(user != address(0), "SYNTH_ISSUER: ZERO_USER");
        require(debtToCover > 0, "SYNTH_ISSUER: ZERO_DEBT_TO_COVER");
        require(userCollateralRatioBps(user) < minCollateralRatioBps, "SYNTH_ISSUER: POSITION_SOLVENT");

        address susdAddr = synths[SUSD_KEY];
        require(susdAddr != address(0), "SYNTH_ISSUER: SUSD_NOT_REGISTERED");

        uint256 userDebt = userDebtValue(user);
        require(userDebt > 0, "SYNTH_ISSUER: ZERO_USER_DEBT");

        uint256 actualCover = debtToCover > userDebt ? userDebt : debtToCover;
        uint256 sharesToBurn = (actualCover * debtSharesOf[user]) / userDebt;

        debtSharesOf[user] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;

        // Value to seize with liquidation penalty in USD WAD
        uint256 repayValueWithPenalty = (actualCover * (BPS_DIVISOR + liquidationPenaltyBps)) / BPS_DIVISOR;
        uint256 collateralPrice = getOraclePrice(bytes32("COLLATERAL"));
        uint256 collateralToSeize = (repayValueWithPenalty * (10 ** collateralDecimals)) / collateralPrice;

        uint256 userCollateral = stakedCollateral[user];
        if (collateralToSeize > userCollateral) {
            // Bad debt shortfall handling
            uint256 seizedValueWad = (userCollateral * collateralPrice) / (10 ** collateralDecimals);
            uint256 coveredDebt = (seizedValueWad * BPS_DIVISOR) / (BPS_DIVISOR + liquidationPenaltyBps);
            if (actualCover > coveredDebt) {
                uint256 shortfall = actualCover - coveredDebt;
                protocolBadDebt += shortfall;
                emit BadDebtDeficitRecorded(user, shortfall);
            }
            collateralToSeize = userCollateral;
        }

        stakedCollateral[user] -= collateralToSeize;

        // Burn liquidator sUSD
        ISyntheticAsset(susdAddr).burn(msg.sender, actualCover);

        // Transfer seized collateral to liquidator
        bool success = collateralToken.transfer(msg.sender, collateralToSeize);
        require(success, "SYNTH_ISSUER: TRANSFER_FAILED");

        emit PositionLiquidated(user, msg.sender, actualCover, collateralToSeize);
    }

    function totalGlobalDebtValue() public view override returns (uint256 totalDebt) {
        for (uint256 i = 0; i < synthKeys.length; i++) {
            bytes32 key = synthKeys[i];
            address synthAddr = synths[key];
            if (synthAddr != address(0)) {
                uint256 supply = ISyntheticAsset(synthAddr).totalSupply();
                if (supply > 0) {
                    uint256 price = getOraclePrice(key);
                    totalDebt += (supply * price) / WAD;
                }
            }
        }
    }

    function userDebtValue(address user) public view override returns (uint256) {
        if (totalDebtShares == 0 || debtSharesOf[user] == 0) return 0;
        return (debtSharesOf[user] * totalGlobalDebtValue()) / totalDebtShares;
    }

    function userCollateralRatioBps(address user) public view override returns (uint256) {
        uint256 debt = userDebtValue(user);
        if (debt == 0) return 100000000; // infinite ratio
        uint256 collAmount = stakedCollateral[user];
        if (collAmount == 0) return 0;

        uint256 price = getOraclePrice(bytes32("COLLATERAL"));
        uint256 collValueWad = (collAmount * price) / (10 ** collateralDecimals);
        return (collValueWad * BPS_DIVISOR) / debt;
    }
}
