// SPDX-License-Identifier: MIT

// Layout of contract:
// version
// imports
// interfaces, libraries, and contracts
// errors
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

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

// import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
    // Errors
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();

    // State variables
    mapping(address token => address priceFeed) private s_priceFeedds;
    mapping(address user => mapping(address token => uint256)) private s_collateralDeposited;

    DecentralizedStableCoin private immutable i_dsc;

    // Events
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    // Modifiers

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeedds[_tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    // Functions
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // for example, ETH/USD, BTC/USD price feeds
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeedds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // - external functions
    function depositCollateralAndMintDsc() external {}

    /**
     * @notice Deposit collateral to the DSC system.
     * @param tokenCollateralAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external {}
}
