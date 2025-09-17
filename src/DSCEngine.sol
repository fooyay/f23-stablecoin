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

pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

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
contract DSCEngine is ReentrancyGuard {
    // Errors
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 healthFactor);
    error DSCEngine__MintFailed();

    // State variables
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    // Events
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    // Modifiers

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeeds[_tokenAddress] == address(0)) {
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
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
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
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external nonReentrant {}

    // 1. Check if the collateral is enough to cover the DSC, and for that
    // we'll need to use a price feed.
    /**
     * @notice Check if the value of the collateral is enough to cover the DSC,
     * and for that we'll need to use a price feed.
     * @param amountDscToMint The amount of DSC to mint.
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much, then revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external nonReentrant {}

    function getHealthFactor() external view {}

    // private & internal view functions
    function _getAccountInformation(address user)
        internal
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValue)
    {
        // we'll need the total DSC minted, and the collateral's current value
        totalDscMinted = s_DSCMinted[user];
        totalCollateralValue = getAccountCollateralValue(user);
        return (totalDscMinted, totalCollateralValue);
    }

    /**
     * @notice How close to liquidation the user is. If the health factor is
     * less than 1, then the user is liquidatable.
     * @param user The address of the user.
     * @return The health factor of the user.
     */
    function _healthFactor(address user) internal view returns (uint256) {
        // we'll need the total DSC minted, and the collateral's current value
        (uint256 totalDscMinted, uint256 totalCollateralValue) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (totalCollateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // BUG probably should be THRESHOLD_PRECISION, should catch in tests
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(userHealthFactor);
        }
    }

    // public & external view functions
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        // loop through each collateral token, get the amount they have deposited,
        // and map it to the price, to get the value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValue += getUsdValue(token, amount);
        }
        return totalCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // if 1 ETH == $2000, then the value from chainlink will be 2000 * 1e8
        // assume all of our chainlink price feeds have 8 decimals - this is
        // the case for ETH/USD and BTC/USD but could be a problem later.
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
