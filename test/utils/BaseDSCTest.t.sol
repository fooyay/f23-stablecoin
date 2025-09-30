// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine, IDSCEngineEvents} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract BaseDSCTest is Test, IDSCEngineEvents {
    DeployDSC internal deployer;
    DecentralizedStableCoin internal dsc;
    DSCEngine internal dscEngine;
    HelperConfig internal config;
    address internal ethUsdPriceFeed;
    address internal btcUsdPriceFeed;
    address internal weth;
    address internal wbtc;

    address internal USER;
    uint256 internal constant AMOUNT_COLLATERAL = 10 ether;
    uint256 internal constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public virtual {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        USER = makeAddr("user");
        // Provide initial WETH only; tests can mint WBTC as needed
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
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
