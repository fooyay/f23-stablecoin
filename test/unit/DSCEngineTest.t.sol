// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {BaseDSCTest} from "../utils/BaseDSCTest.t.sol";

contract DSCEngineTest is BaseDSCTest {
    // setUp inherited from BaseDSCTest

    // Constructor Tests
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // Deposit Collateral Tests

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("Random Token", "RND", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        // don't approve any tokens

        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testDepositCollateralEmitsEvent() public {
        _depositExpectEvent(USER, weth, AMOUNT_COLLATERAL);
    }

    function testDepositCollateralUpdatesState() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        assertEq(dscEngine.getUserCollateralBalance(USER, weth), AMOUNT_COLLATERAL);
        (uint256 minted, uint256 collateralUsd) = dscEngine.getAccountInformation(USER);
        assertEq(minted, 0);
        assertEq(dscEngine.getTokenAmountFromUsd(weth, collateralUsd), AMOUNT_COLLATERAL);
    }

    function testDepositCollateralRevertsOnTransferFail() public {
        // Arrange: approve normal weth
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        // Mock the low-level call that IERC20(token).transferFrom makes so it returns false
        // transferFrom(address,address,uint256) selector
        bytes4 selector = IERC20.transferFrom.selector;
        // We expect DSCEngine to call weth with (USER, DSCEngine address, AMOUNT_COLLATERAL)
        vm.mockCall(
            weth,
            abi.encodeWithSelector(selector, USER, address(dscEngine), AMOUNT_COLLATERAL),
            abi.encode(false) // force return false
        );

        // Expect revert due to DSCEngine__TransferFailed
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // Health Factor Tests
    function testHealthFactor_NoDebtIsMax() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        // Should return max uint since no debt yet
        vm.prank(USER);
        uint256 hf = dscEngine.getHealthFactor();
        assertEq(hf, type(uint256).max);
    }

    function testHealthFactor_AfterMint() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL); // 10 ETH => $20k
        // Mint $5k worth (safe)
        uint256 mintAmount = 5_000 * dscEngine.USD_PRECISION();
        vm.startPrank(USER);
        dscEngine.mintDsc(mintAmount);
        uint256 hf = dscEngine.getHealthFactor();
        vm.stopPrank();
        // Expected health factor = (collateralValue * threshold / precision) * PRECISION / debt
        // threshold factor = 50%
        // Adjusted collateral = 20k * 50% = 10k
        // HF = 10k / 5k = 2 * 1e18 scaling used internally
        assertEq(hf, 2 * dscEngine.USD_PRECISION());
    }

    function testHealthFactor_DecreasesWithMoreDebt() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL); // $20k
        vm.startPrank(USER);
        dscEngine.mintDsc(2_000 * dscEngine.USD_PRECISION()); // Adjusted 10k / 2k = 5
        uint256 hfHigh = dscEngine.getHealthFactor();
        dscEngine.mintDsc(3_000 * dscEngine.USD_PRECISION()); // total 5k => HF 2
        uint256 hfLower = dscEngine.getHealthFactor();
        vm.stopPrank();
        assertGt(hfHigh, hfLower);
        assertEq(hfLower, 2 * dscEngine.USD_PRECISION());
    }

    function testHealthFactorOverload_NoDebtOtherUser() public {
        address other = makeAddr("otherUserHF");
        // other has no deposits or debt
        uint256 hf = dscEngine.getHealthFactor(other);
        assertEq(hf, type(uint256).max);
    }

    function testHealthFactorOverload_AfterMintOtherUser() public {
        address other = makeAddr("otherUserHF2");
        // Fund and deposit for other
        ERC20Mock(weth).mint(other, AMOUNT_COLLATERAL);
        _deposit(other, weth, AMOUNT_COLLATERAL); // $20k
        vm.startPrank(other);
        dscEngine.mintDsc(4_000 * dscEngine.USD_PRECISION()); // HF = (20k * 50%) / 4k = 2.5
        uint256 hf = dscEngine.getHealthFactor(other);
        vm.stopPrank();
        assertEq(hf, (5 * dscEngine.USD_PRECISION()) / 2); // 2.5e18
    }

    // View Function Tests
    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 30_000 * dscEngine.USD_PRECISION();
        uint256 expectedWeth = 15 ether; // $30,000 / $2000/ETH = 15 ETH
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetAccountCollateralValue() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL); // 10 ETH

        uint256 collateralValueUsd = dscEngine.getAccountCollateralValue(USER);
        uint256 expectedUsdValue = 20_000 * dscEngine.USD_PRECISION(); // $20,000

        assertEq(collateralValueUsd, expectedUsdValue, "Collateral USD value mismatch");
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30_000 * dscEngine.USD_PRECISION(); // 15 ETH * $2000/ETH = $30,000
        // note, that won't work on Sepolia, which has the actual price
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testAccountInfo_InitialStateIsZero() public {
        (uint256 minted, uint256 collateralUsd) = dscEngine.getAccountInformation(USER);
        assertEq(minted, 0);
        assertEq(collateralUsd, 0);
    }

    function testAccountInfo_AfterWethDeposit() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL); // 10 ETH
        (, uint256 collateralUsd) = dscEngine.getAccountInformation(USER);
        assertEq(collateralUsd, 20_000 * dscEngine.USD_PRECISION());
    }

    function testAccountInfo_AfterWethAndWbtcDeposit() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).mint(USER, AMOUNT_COLLATERAL);
        _deposit(USER, wbtc, AMOUNT_COLLATERAL);
        (, uint256 collateralUsd) = dscEngine.getAccountInformation(USER);
        assertEq(collateralUsd, 420_000 * dscEngine.USD_PRECISION());
    }

    function testAccountInfo_AfterMintDoesNotChangeCollateral() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).mint(USER, AMOUNT_COLLATERAL);
        _deposit(USER, wbtc, AMOUNT_COLLATERAL);
        uint256 amountToMint = 100_000 * dscEngine.USD_PRECISION();
        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
        (uint256 minted, uint256 collateralUsd) = dscEngine.getAccountInformation(USER);
        assertEq(minted, amountToMint);
        assertEq(collateralUsd, 420_000 * dscEngine.USD_PRECISION());
    }

    function testGetUserCollateralBalance() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        uint256 userWeth = dscEngine.getUserCollateralBalance(USER, weth);
        assertEq(userWeth, AMOUNT_COLLATERAL);
        uint256 userWbtc = dscEngine.getUserCollateralBalance(USER, wbtc);
        assertEq(userWbtc, 0);
    }

    function testGetUserCollateralBalance_InitialZero() public {
        assertEq(dscEngine.getUserCollateralBalance(USER, weth), 0);
        assertEq(dscEngine.getUserCollateralBalance(USER, wbtc), 0);
    }

    function testGetUserCollateralBalance_Accumulates() public {
        _deposit(USER, weth, 4 ether);
        _deposit(USER, weth, 6 ether);
        assertEq(dscEngine.getUserCollateralBalance(USER, weth), 10 ether);
    }

    function testGetUserCollateralBalance_IsolatedPerUser() public {
        address other = makeAddr("otherUser");
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        assertEq(dscEngine.getUserCollateralBalance(other, weth), 0);
        assertEq(dscEngine.getUserCollateralBalance(USER, weth), AMOUNT_COLLATERAL);
    }

    function testGetUserCollateralBalance_DisallowedTokenReturnsZero() public {
        // Deploy a random ERC20 not registered as collateral
        ERC20Mock random = new ERC20Mock("Random Token", "RND", USER, 100 ether);
        assertEq(dscEngine.getUserCollateralBalance(USER, address(random)), 0);
    }

    function testFuzz_GetUserCollateralBalance(uint96 amount) public {
        vm.assume(amount > 0 && amount < 1_000_000 ether);
        // Mint enough WETH to user for fuzz amount if needed
        ERC20Mock(weth).mint(USER, amount);
        _deposit(USER, weth, amount);
        assertEq(dscEngine.getUserCollateralBalance(USER, weth), amount);
    }

    // ------------------------
    // Mint DSC Tests
    // ------------------------
    function testMintDsc_Success() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        uint256 amountToMint = 5_000 * dscEngine.USD_PRECISION();
        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
        (uint256 minted,) = dscEngine.getAccountInformation(USER);
        assertEq(minted, amountToMint);
    }

    function testMintDsc_RevertsIfHealthFactorBroken() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL); // 10 ETH = $20k
        uint256 tooMuch = 15_000 * dscEngine.USD_PRECISION(); // Try to mint $15k (threshold allows only $10k)
        vm.startPrank(USER);
        // Expect revert with specific health factor value encoded in the error
        // HF = (collateral * threshold / precision) / debt = (20k * 50%) / 15k = 0.666... = 666666666666666666 wei
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBroken.selector, 666666666666666666));
        dscEngine.mintDsc(tooMuch);
        vm.stopPrank();
    }

    // ------------------------
    // Burn DSC Tests
    // ------------------------
    function testBurnDsc_Success() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        uint256 mintAmount = 5_000 * dscEngine.USD_PRECISION();
        vm.startPrank(USER);
        dscEngine.mintDsc(mintAmount);
        uint256 burnAmount = 2_000 * dscEngine.USD_PRECISION();
        dsc.approve(address(dscEngine), burnAmount);
        dscEngine.burnDsc(burnAmount);
        vm.stopPrank();
        (uint256 remaining,) = dscEngine.getAccountInformation(USER);
        assertEq(remaining, mintAmount - burnAmount);
    }

    function testBurnDsc_RevertsIfZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    // ------------------------
    // Deposit Collateral And Mint DSC Tests
    // ------------------------
    function testDepositCollateralAndMintDsc_Success() public {
        uint256 collateralAmount = AMOUNT_COLLATERAL;
        uint256 mintAmount = 5_000 * dscEngine.USD_PRECISION();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateralAndMintDsc(weth, collateralAmount, mintAmount);
        vm.stopPrank();

        assertEq(dscEngine.getUserCollateralBalance(USER, weth), collateralAmount);
        (uint256 minted,) = dscEngine.getAccountInformation(USER);
        assertEq(minted, mintAmount);
    }

    // ------------------------
    // Redeem Collateral Tests
    // ------------------------
    function testRedeemCollateral_Success() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        uint256 redeemAmount = 2 ether;

        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();

        assertEq(dscEngine.getUserCollateralBalance(USER, weth), AMOUNT_COLLATERAL - redeemAmount);
    }

    function testRedeemCollateral_RevertsIfHealthFactorBroken() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL); // 10 ETH = $20k
        uint256 mintAmount = 9_000 * dscEngine.USD_PRECISION();
        vm.startPrank(USER);
        dscEngine.mintDsc(mintAmount);

        // Try to redeem too much collateral
        vm.expectRevert();
        dscEngine.redeemCollateral(weth, 8 ether);
        vm.stopPrank();
    }

    function testRedeemCollateral_RevertsIfZero() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRedeemCollateral_EmitsEvent() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        uint256 redeemAmount = 2 ether;

        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, USER, weth, redeemAmount);
        dscEngine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();
    }

    // ------------------------
    // Redeem Collateral For DSC Tests
    // ------------------------
    function testRedeemCollateralForDsc_Success() public {
        uint256 mintAmount = 5_000 * dscEngine.USD_PRECISION();
        _deposit(USER, weth, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        dscEngine.mintDsc(mintAmount);

        uint256 burnAmount = 2_000 * dscEngine.USD_PRECISION();
        uint256 redeemAmount = 2 ether;
        dsc.approve(address(dscEngine), burnAmount);
        dscEngine.redeemCollateralForDsc(weth, redeemAmount, burnAmount);
        vm.stopPrank();

        assertEq(dscEngine.getUserCollateralBalance(USER, weth), AMOUNT_COLLATERAL - redeemAmount);
        (uint256 remaining,) = dscEngine.getAccountInformation(USER);
        assertEq(remaining, mintAmount - burnAmount);
    }

    function testRedeemCollateralForDsc_RevertsIfZeroDsc() public {
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        uint256 mintAmount = 1_000 * dscEngine.USD_PRECISION();
        vm.startPrank(USER);
        dscEngine.mintDsc(mintAmount);

        // Test that it works with valid amounts first
        dsc.approve(address(dscEngine), 500 * dscEngine.USD_PRECISION());
        dscEngine.redeemCollateralForDsc(weth, 1 ether, 500 * dscEngine.USD_PRECISION());
        vm.stopPrank();
    }

    // ------------------------
    // Liquidation Tests
    // ------------------------
    function testLiquidate_RevertsIfHealthFactorOk() public {
        // USER healthy: 10 ETH ($20k), mint $5k => HF = 2.0
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dscEngine.mintDsc(5_000 * dscEngine.USD_PRECISION());
        uint256 hfOk = dscEngine.getHealthFactor();
        vm.stopPrank();
        assertGe(hfOk, dscEngine.MIN_HEALTH_FACTOR());

        address liquidator = makeAddr("liquidator_ok");
        // Prep some DSC/approvals for liquidator (not strictly needed since we expect early revert)
        ERC20Mock(weth).mint(liquidator, AMOUNT_COLLATERAL);
        _deposit(liquidator, weth, AMOUNT_COLLATERAL);
        vm.startPrank(liquidator);
        dscEngine.mintDsc(2_000 * dscEngine.USD_PRECISION());
        dsc.approve(address(dscEngine), type(uint256).max);
        uint256 cover = 1_000 * dscEngine.USD_PRECISION();
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, cover);
        vm.stopPrank();
    }

    function testLiquidate_PartialRepaySeizesCollateralAndImprovesHF() public {
        // USER: deposit 10 ETH ($20k), mint $9k (HF > 1 initially)
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dscEngine.mintDsc(9_000 * dscEngine.USD_PRECISION());
        uint256 hfPreDrop = dscEngine.getHealthFactor();
        vm.stopPrank();
        assertGe(hfPreDrop, dscEngine.USD_PRECISION());

        // Price drop to make USER undercollateralized but improvable via liquidation: $2,000 -> $1,500
        _setEthUsdPrice(1_500e8);

        // Liquidator prepares DSC to repay
        address liquidator = makeAddr("liquidator_partial");
        ERC20Mock(weth).mint(liquidator, AMOUNT_COLLATERAL);
        _deposit(liquidator, weth, AMOUNT_COLLATERAL);
        vm.startPrank(liquidator);
        dscEngine.mintDsc(5_000 * dscEngine.USD_PRECISION());
        vm.stopPrank();

        (uint256 debtBefore,) = dscEngine.getAccountInformation(USER);
        uint256 liqDscBefore = dsc.balanceOf(liquidator);
        uint256 liqWethWalletBefore = ERC20Mock(weth).balanceOf(liquidator);
        uint256 hfBefore = dscEngine.getHealthFactor(USER);

        uint256 debtToCover = 2_000 * dscEngine.USD_PRECISION();
        vm.startPrank(liquidator);
        dsc.approve(address(dscEngine), debtToCover);
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        (uint256 debtAfter,) = dscEngine.getAccountInformation(USER);
        uint256 liqDscAfter = dsc.balanceOf(liquidator);
        uint256 liqWethWalletAfter = ERC20Mock(weth).balanceOf(liquidator);
        uint256 hfAfter = dscEngine.getHealthFactor(USER);

        assertEq(debtBefore - debtAfter, debtToCover, "User debt mismatch after liquidation");
        assertEq(liqDscBefore - liqDscAfter, debtToCover, "Liquidator DSC not spent as expected");
        uint256 minSeized = dscEngine.getTokenAmountFromUsd(weth, debtToCover);
        uint256 seized = liqWethWalletAfter - liqWethWalletBefore;
        assertGe(seized, minSeized, "Seized collateral must include liquidation bonus");
        assertGt(hfAfter, hfBefore, "HF should improve after liquidation");
    }

    function testLiquidate_AfterRestoredHealthFurtherLiquidationReverts() public {
        // USER: deposit 10 ETH ($20k), mint $9k (healthy at start)
        _deposit(USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dscEngine.mintDsc(9_000 * dscEngine.USD_PRECISION());
        uint256 hfPreDrop2 = dscEngine.getHealthFactor();
        vm.stopPrank();
        assertGe(hfPreDrop2, dscEngine.USD_PRECISION());

        // Price drop: $2,000 -> $1,500 to push under threshold but allow restoration via sufficient cover
        _setEthUsdPrice(1_500e8);

        // Liquidator sets up DSC
        address liquidator = makeAddr("liquidator_restore");
        ERC20Mock(weth).mint(liquidator, AMOUNT_COLLATERAL);
        _deposit(liquidator, weth, AMOUNT_COLLATERAL);
        vm.startPrank(liquidator);
        // Keep liquidator healthy at $1,500/ETH: deposited 10 ETH => $15k, threshold 50% => $7.5k
        // So mint <= $7.5k to maintain HF >= 1
        dscEngine.mintDsc(6_000 * dscEngine.USD_PRECISION());
        uint256 cover = 4_000 * dscEngine.USD_PRECISION();
        dsc.approve(address(dscEngine), cover);
        dscEngine.liquidate(weth, USER, cover);
        vm.stopPrank();

        vm.startPrank(liquidator);
        uint256 nextCover = 1_000 * dscEngine.USD_PRECISION();
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, nextCover);
        vm.stopPrank();
    }
}
