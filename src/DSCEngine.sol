// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralisedStableCoin} from "./DecentralisedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSC Engine
 * @author Nitheesh Raaja R
 *
 * The System is designed as minimal as possible and have the tokens maintain a 1 token == $1.00 peg.
 * This stable coin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////
    // Errors    //
    //////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////
    // Types     //
    //////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////
    // State    //
    //////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;
    DecentralisedStableCoin private immutable i_dsc;

    ///////////////
    // Events    //
    //////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    ///////////////
    // Modifiers //
    //////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////
    //  Functions //
    ///////////////
    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address dscAddress) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentralisedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions  //
    ////////////////////////

    /**
     *
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral Amount of collateral to be deposited
     * @param _amountDscToMint Amount of DSC to be minted
     * @notice This function will deposit and mint DSC in 1 transaction
     */
    function depositCollateralAndMintDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDSC(_amountDscToMint);
    }

    /**
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param _tokenCollateralAddress The collateral address to redeem
     * @param _amountCollateral The amount of collateral to redeem
     * @param _burnAmount The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in 1 transaction
     */
    function redeemCollateralForDSC(address _tokenCollateralAddress, uint256 _amountCollateral, uint256 _burnAmount)
        external
    {
        burnDSC(_burnAmount);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
    }

    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        nonReentrant
    {
        _redeemCollateral(_tokenCollateralAddress, _amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param _amountDscToMint Amount of DSC to be minted requested by user
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDSC(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += _amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 _amount) public moreThanZero(_amount) {
        _burnDSC(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param _collateral The erc20 collateral address to liquidate from user
     * @param _user The user who has broken their health factor
     * @param _debtToCover The amount of DSC you want to burn to improve the user's health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users fund
     * @notice This function working assums protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we would'nt be able to incentive the liquidators.
     */
    function liquidate(address _collateral, address _user, uint256 _debtToCover)
        external
        moreThanZero(_debtToCover)
        nonReentrant
    {
        // Check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(_collateral, _debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(_collateral, totalCollateralToRedeem, _user, msg.sender);
        _burnDSC(_debtToCover, _user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(_user);
        if (endingHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    /////////////////////////
    // Private Functions   //
    ////////////////////////

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        totalDSCMinted = s_dscMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address _user) private view returns (uint256) {
        (uint256 totalDscAmount, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((collateralAdjustedForThreshold * PRECISION) / totalDscAmount);
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral, address _from, address _to)
        private
    {
        s_collateralDeposited[_from][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _amountCollateral);

        bool success = IERC20(_tokenCollateralAddress).transfer(_to, _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev Low-Level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDSC(uint256 _amountToBurn, address _onBehalfOf, address _dscFrom) private {
        s_dscMinted[_onBehalfOf] -= _amountToBurn;
        bool success = i_dsc.transferFrom(_dscFrom, address(this), _amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(_amountToBurn);
    }

    //////////////////////////////
    // View & Pure Functions   //
    ////////////////////////////
    function getAccountCollateralValue(address _user) public view returns (uint256) {
        uint256 totalCollateralValueInUs = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUs += getUsdValue(token, amount);
        }

        return totalCollateralValueInUs;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.stalePriceCheck();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address _token, uint256 _usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.stalePriceCheck();
        return (_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    // DELETE IN PROD
    // Getters and setters for testing
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address _user, address _token) external view returns (uint256) {
        return s_collateralDeposited[_user][_token];
    }

    function getAccountInformation(address _user) external view returns (uint256, uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        return (totalDscMinted, collateralValueInUsd);
    }

    function getCollateralTokenPriceFeed(address _token) external view returns (address) {
        return s_priceFeeds[_token];
    }
}
