// SPDX-License-Identifier: MIT

// Layout of contract:
// version
// imports
// errors
// interfaces, libraries, and contracts
// type declarations
// state variables
// events
// modifiers
// functions

// Layout of functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure

pragma solidity ^0.8.18;

/**
 * @title DSCEngine
 * @author Sean Coates - fooyay
 *
 * The engine is designed in a minimal way to have the DSC tokens maintain a
 * peg to the US dollar. That is, 1 token == $1.
 *
 * This stablecoin has the following properties:
 * - Collateral: Exogenous (ETH & BTC)
 * - Minting: Algorithmic
 * - Relative Stability: Pegged to USD
 *
 * Our DSC system should always be overcollateralized. This means that the
 * value of all collateral should always be greater than the dollar-backed
 * value of all DSC.
 *
 * There are similarities to MakerDAO's DAI, but has no governance, no fees, and
 * is only backed by wETH and wBTC.
 *
 * @notice This contract is the core of the DSC system. It handles the logic
 * for mining and redeeming DSC tokens, as well as depositing and withdrawing
 * collateral.
 * @notice This contract is loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine {
    function depositCollateralAndMintDsc() external {}

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) external {}

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external {}
}
