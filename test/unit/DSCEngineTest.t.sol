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
}
