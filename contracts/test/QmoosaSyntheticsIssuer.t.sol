// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Test.sol";
import "../src/SyntheticAsset.sol";
import "../src/QmoosaSyntheticsIssuer.sol";
import "../src/test/MockERC20.sol";

contract QmoosaSyntheticsIssuerTest is Test {
    QmoosaSyntheticsIssuer public issuer;
    MockERC20 public snxCollateral;
    SyntheticAsset public susd;
    SyntheticAsset public seth;
    SyntheticAsset public sbtc;

    bytes32 public constant SUSD = bytes32("sUSD");
    bytes32 public constant SETH = bytes32("sETH");
    bytes32 public constant SBTC = bytes32("sBTC");
    bytes32 public constant COLLATERAL = bytes32("COLLATERAL");

    address public owner = address(this);
    address public alice = address(0xAA11);
    address public bob = address(0xBB22);
    address public liquidator = address(0xCC33);

    uint256 public constant WAD = 1e18;

    function setUp() public {
        snxCollateral = new MockERC20("Synthetix Network Token", "SNX", 18);
        issuer = new QmoosaSyntheticsIssuer(address(snxCollateral), 18);

        susd = new SyntheticAsset("Synthetic USD", "sUSD", SUSD, address(issuer));
        seth = new SyntheticAsset("Synthetic Ether", "sETH", SETH, address(issuer));
        sbtc = new SyntheticAsset("Synthetic Bitcoin", "sBTC", SBTC, address(issuer));

        issuer.addSynth(SUSD, address(susd));
        issuer.addSynth(SETH, address(seth));
        issuer.addSynth(SBTC, address(sbtc));

        // Initial oracle prices:
        // COLLATERAL = $10.00
        // sUSD = $1.00
        // sETH = $2,000.00
        // sBTC = $50,000.00
        issuer.setOraclePrice(COLLATERAL, 10 * 1e18);
        issuer.setOraclePrice(SUSD, 1 * 1e18);
        issuer.setOraclePrice(SETH, 2000 * 1e18);
        issuer.setOraclePrice(SBTC, 50000 * 1e18);

        // Fund Alice, Bob, and Liquidator
        snxCollateral.mint(alice, 10_000 * 1e18); // 10,000 SNX = $100k
        snxCollateral.mint(bob, 10_000 * 1e18);
        snxCollateral.mint(liquidator, 50_000 * 1e18);

        vm.prank(alice);
        snxCollateral.approve(address(issuer), type(uint256).max);

        vm.prank(bob);
        snxCollateral.approve(address(issuer), type(uint256).max);

        vm.prank(liquidator);
        snxCollateral.approve(address(issuer), type(uint256).max);
    }

    function testStakeAndIssueSynths() public {
        vm.prank(alice);
        issuer.stakeCollateral(1000 * 1e18); // $10,000 value

        // 200% min ratio -> Max debt = 10,000 / 2 = 5000 sUSD. Issue 2000 sUSD (500% ratio)
        vm.prank(alice);
        issuer.issueSynths(2000 * 1e18);

        assertEq(susd.balanceOf(alice), 2000 * 1e18);
        assertEq(issuer.debtSharesOf(alice), 2000 * 1e18);
        assertEq(issuer.totalDebtShares(), 2000 * 1e18);
        assertEq(issuer.userDebtValue(alice), 2000 * 1e18);
        assertEq(issuer.userCollateralRatioBps(alice), 50000); // 500%
    }

    function testUndercollateralizedIssueReverts() public {
        vm.prank(alice);
        issuer.stakeCollateral(1000 * 1e18); // $10,000 value

        // Attempting to issue 6000 sUSD requires $12,000 collateral -> Reverts
        vm.prank(alice);
        vm.expectRevert("SYNTH_ISSUER: UNDERCOLLATERALIZED");
        issuer.issueSynths(6000 * 1e18);
    }

    function testZeroSlippageExchange() public {
        vm.prank(alice);
        issuer.stakeCollateral(1000 * 1e18);
        vm.prank(alice);
        issuer.issueSynths(2000 * 1e18);

        // Alice exchanges 2000 sUSD for sETH at $2000/ETH
        // Fee = 30 bps (0.3%) = $6 -> Net USD = $1994 -> 0.997 sETH
        vm.prank(alice);
        uint256 destAmount = issuer.exchange(SUSD, 2000 * 1e18, SETH);

        assertEq(destAmount, (1994 * 1e18) / 2000); // 0.997 sETH
        assertEq(susd.balanceOf(alice), 0);
        assertEq(seth.balanceOf(alice), destAmount);
    }

    function testDynamicDebtPoolAppreciation() public {
        // Alice stakes and issues 2000 sUSD
        vm.prank(alice);
        issuer.stakeCollateral(5000 * 1e18); // $50,000 collateral
        vm.prank(alice);
        issuer.issueSynths(2000 * 1e18);

        // Bob stakes and issues 2000 sUSD
        vm.prank(bob);
        issuer.stakeCollateral(5000 * 1e18);
        vm.prank(bob);
        issuer.issueSynths(2000 * 1e18);

        // Total shares = 4000. Alice = 50%, Bob = 50%
        assertEq(issuer.totalDebtShares(), 4000 * 1e18);

        // Alice exchanges 2000 sUSD for sETH (0.997 sETH)
        vm.prank(alice);
        issuer.exchange(SUSD, 2000 * 1e18, SETH);

        // ETH price surges from $2000 to $4000 (100% surge with override)
        issuer.overrideOraclePrice(SETH, 4000 * 1e18);

        // Global debt is now: 2000 sUSD (Bob) + 0.997 * 4000 sETH (~$3988) = ~$5988
        uint256 globalDebt = issuer.totalGlobalDebtValue();
        assertGt(globalDebt, 5900 * 1e18);

        // Alice's 50% share of debt is now ~2994 USD (up from 2000 USD)
        uint256 aliceDebt = issuer.userDebtValue(alice);
        assertGt(aliceDebt, 2900 * 1e18);

        // Bob's 50% share of debt is also ~2994 USD even though Bob only held sUSD!
        uint256 bobDebt = issuer.userDebtValue(bob);
        assertEq(bobDebt, aliceDebt);
    }

    function testLiquidationUndercollateralizedPosition() public {
        vm.prank(alice);
        issuer.stakeCollateral(1000 * 1e18); // 1000 SNX at $10 = $10,000 value
        vm.prank(alice);
        issuer.issueSynths(4000 * 1e18); // 4000 sUSD (250% ratio)

        // Collateral price drops to $4.00 -> 1000 SNX = $4,000 value. Ratio = 4000/4000 = 100% (< 200% threshold)
        issuer.overrideOraclePrice(COLLATERAL, 4 * 1e18);
        assertLt(issuer.userCollateralRatioBps(alice), 20000);

        // Liquidator issues sUSD to perform liquidation
        vm.prank(liquidator);
        issuer.stakeCollateral(10000 * 1e18); // $40,000
        vm.prank(liquidator);
        issuer.issueSynths(5000 * 1e18);

        uint256 liqSnxBefore = snxCollateral.balanceOf(liquidator);

        // Liquidator covers 2000 sUSD of Alice's debt
        vm.prank(liquidator);
        issuer.liquidatePosition(alice, 2000 * 1e18);

        uint256 liqSnxAfter = snxCollateral.balanceOf(liquidator);
        // Debt covered: 2000. With 10% penalty = $2200 value. At $4/SNX = 550 SNX seized
        assertEq(liqSnxAfter - liqSnxBefore, 550 * 1e18);
    }

    function testOracleFreshnessAndDeviationBounds() public {
        // Fast forward beyond max staleness (3600 seconds)
        vm.warp(block.timestamp + 3601);

        vm.expectRevert("SYNTH_ISSUER: ORACLE_STALE");
        issuer.getOraclePrice(SUSD);

        // Setting a price with 60% jump without override fails closed
        issuer.setOraclePrice(SUSD, 1 * 1e18); // refresh
        vm.expectRevert("SYNTH_ISSUER: PRICE_DEVIATION_EXCEEDED");
        issuer.setOraclePrice(SUSD, 16 * 1e17); // 1.60 (+60%)

        // Emergency override succeeds
        issuer.overrideOraclePrice(SUSD, 16 * 1e17);
        assertEq(issuer.getOraclePrice(SUSD), 16 * 1e17);
    }
}
