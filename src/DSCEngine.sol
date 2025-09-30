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
 * @title IDSCEngineEvents
 * @dev Interface defining all events emitted by the DSCEngine contract
 * This interface can be imported by test contracts to avoid event duplication
 */
interface IDSCEngineEvents {
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
}

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
contract DSCEngine is ReentrancyGuard, IDSCEngineEvents {
    // Errors
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    // State variables
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    // Generic precision for internal math when scaling values
    uint256 private constant PRECISION = 1e18;
    // Public constant explicitly representing the USD (1e18) scaling used for
    // all USD-denominated values returned by view functions. Tests and external
    // integrators can reference this for clarity instead of duplicating 1e18 literals.
    uint256 public constant USD_PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

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

    /**
     * @notice Deposit collateral and mint DSC in a single transaction.
     * @param tokenCollateralAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of DSC to mint.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Deposit collateral to the DSC system.
     * @param tokenCollateralAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     */

    /**
     * @notice This function burns DSC and redeems collateral in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC to burn.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        moreThanZero(amountCollateral)
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // In order to redeem collateral:
    // 1. The health factor needs to be above the minimum threshold after
    // the collateral is redeemed.
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 1. Check if the collateral is enough to cover the DSC, and for that
    // we'll need to use a price feed.
    /**
     * @notice Check if the value of the collateral is enough to cover the DSC,
     * and for that we'll need to use a price feed.
     * @param amountDscToMint The amount of DSC to mint.
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much, then revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) external moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // not needed?
            // burning DSC improves your health factor, so this will never revert
    }

    /**
     * @notice If someone is almost undercollateralized, we will pay you to liquidate them.
     * @param collateral The address of the collateral token to liquidate.
     * @param user The address of the user who has broken the health factor. Their _healthFactor should be < MIN_HEALTH_FACTOR.
     * @param debtToCover The amount of DSC you want to burn to improve the user's health factor.
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the user's funds.
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn their DSC "debt" and take their collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Convenience: fetch the caller's current health factor.
     * @dev If caller has no debt (minted == 0), returns type(uint256).max to indicate "infinite" safety.
     */
    function getHealthFactor() external view returns (uint256) {
        return _externalHealthFactor(msg.sender);
    }

    /**
     * @notice Fetch any user's health factor.
     * @param user The account to query.
     * @dev If user has no debt (minted == 0), returns type(uint256).max.
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _externalHealthFactor(user);
    }

    function _externalHealthFactor(address user) internal view returns (uint256) {
        uint256 minted = s_DSCMinted[user];
        if (minted == 0) {
            return type(uint256).max;
        }
        return _healthFactor(user);
    }

    // public functions
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
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

    // private & internal view functions

    /**
     * @notice Burns DSC on behalf of a user.
     * @param amount The amount of DSC to burn.
     * @param onBehalfOf The address of the user on behalf of whom to burn the DSC.
     * @param dscFrom The address from which to burn the DSC.
     * @dev low-level internal function, do not call unless the function calling it is
     * checking for health factor.
     */
    function _burnDsc(uint256 amount, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amount;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        // note: transferFrom reverts on failure, so this is just a double-check
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        // automatically reverts if this would go negative because of uint and safe math built-ins
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

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
        return (collateralAdjustedForThreshold * USD_PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(userHealthFactor);
        }
    }

    // public & external view functions

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // if 1 ETH == $2000, then the value from chainlink will be 2000 * 1e8
        // assume all of our chainlink price feeds have 8 decimals - this is
        // the case for ETH/USD and BTC/USD but could be a problem later.
        return (usdAmountInWei * USD_PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

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
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / USD_PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    /**
     * @notice Returns how much of a specific collateral token a user has deposited.
     * @param user The address of the user.
     * @param token The collateral token address.
     */
    function getUserCollateralBalance(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
