// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineLifecycle is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address weth;
    address wbtc;

    address user = makeAddr("user");
    uint256 constant STARTING_BAL = 10 ether;
    uint256 constant AMOUNT = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(user, STARTING_BAL);
        ERC20Mock(wbtc).mint(user, STARTING_BAL);
    }

    function testFullLifecycle_DepositMultiCollateralAndMint() public {
        // Deposit WETH & WBTC, then mint DSC and ensure accounting holds
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT);
        engine.depositCollateral(weth, AMOUNT); // 10 ETH @ $2k = $20k
        ERC20Mock(wbtc).approve(address(engine), AMOUNT);
        engine.depositCollateral(wbtc, AMOUNT); // 10 BTC @ $40k = $400k

        uint256 mintAmount = 100_000 * engine.USD_PRECISION();
        engine.mintDsc(mintAmount);
        vm.stopPrank();

        (uint256 minted, uint256 collateralUsd) = engine.getAccountInformation(user);
        assertEq(minted, mintAmount, "Minted DSC mismatch");
        assertEq(collateralUsd, (20_000 + 400_000) * engine.USD_PRECISION(), "Unexpected aggregated USD collateral");
    }
}
