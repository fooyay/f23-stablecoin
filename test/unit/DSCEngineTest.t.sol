// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine, IDSCEngineEvents} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DSCEngineTest is Test, IDSCEngineEvents {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

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

    function _deposit(address user, address token, uint256 amount) internal {
        vm.startPrank(user);
        ERC20Mock(token).approve(address(dscEngine), amount);
        dscEngine.depositCollateral(token, amount);
        vm.stopPrank();
    }

    function _depositExpectEvent(address user, address token, uint256 amount) internal {
        vm.startPrank(user);
        ERC20Mock(token).approve(address(dscEngine), amount);
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralDeposited(user, token, amount);
        dscEngine.depositCollateral(token, amount);
        vm.stopPrank();
    }
}
