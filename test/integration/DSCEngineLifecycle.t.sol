// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {BaseDSCTest} from "../utils/BaseDSCTest.t.sol";

contract DSCEngineLifecycle is BaseDSCTest {
    uint256 constant AMOUNT = 10 ether; // reuse same nominal amount for each collateral

    function setUp() public override {
        super.setUp();
        // Provide WBTC to user for integration scenario
        ERC20Mock(wbtc).mint(USER, AMOUNT_COLLATERAL);
    }

    function testFullLifecycle_DepositMultiCollateralAndMint() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT);
        dscEngine.depositCollateral(weth, AMOUNT); // 10 ETH @ $2k = $20k
        ERC20Mock(wbtc).approve(address(dscEngine), AMOUNT);
        dscEngine.depositCollateral(wbtc, AMOUNT); // 10 BTC @ $40k = $400k

        uint256 mintAmount = 100_000 * dscEngine.USD_PRECISION();
        dscEngine.mintDsc(mintAmount);
        vm.stopPrank();

        (uint256 minted, uint256 collateralUsd) = dscEngine.getAccountInformation(USER);
        assertEq(minted, mintAmount, "Minted DSC mismatch");
        assertEq(collateralUsd, (20_000 + 400_000) * dscEngine.USD_PRECISION(), "Unexpected aggregated USD collateral");
    }
}
