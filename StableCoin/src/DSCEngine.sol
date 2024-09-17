// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Betsaleel Dakuyo
 * The system is designed to be as minimal as possible and have the tokens
 * maintain a 1 token = 1$ peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmic stable
 * It is similar to DAI if DAI had no governane, no fees and was only backed by
 * wETH and wBTC
 * Our DSC system should always be "overcollaterized". At no point, should the value
 * of all the collateral <= all the $ backed value of all DSC.
 *  @notice This contract is the core of the DSC system. Ithandles all the logic
 * for mining and redeeming DSC, as well as deposit and withdrawing collateral.
 *  @notice This contract is very loosely based on MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    /*****Errors******/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();
    /*****State variables*******/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //This mean 10% bonus
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /********Events***********/
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );
    /********Modifiers*******/
    modifier moreThanzero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*****Functions*******/
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddress,
        address dscAddress
    ) {
        //USD price feed
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // ETH / USD, BTC / USD, MKR / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /******External Functions******/
    /*Deposer une garantie pour avoir en retour des DSC. Celui qui depose
     la garantie est la meme personne qui peut retirer la garantie avec
     la fonction redeemCollateralForDsc dans ce cas.*/
    /**
     *
     * @param tokenCollateralAddress The address of the token  to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
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
     *
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral the amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
    }

    /**
     * 
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor 
       should be below MIN_HEALTH_FACTOR 
     * @param debtToCover The amount of DSC you want to burn to improve the users
       health factor
    * @notice you can partially liquidate a user
    * @notice you will get a liquidation bonus for taking the users funds
    * @notice this function working assumes the protocol will be roughly 200%
    * overcollaterized in order for this to work
    * @notice A known bug would be if the protocol were 100% or less collaterized,
    * then we wouldn't be able to incentive the liquidators.
    * For example, if the price of the collateral plummeted before anyone could
    * be liquidated. 
    * follows CEI: Checks,Effects,Interactions
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanzero(debtToCover) nonReentrant {
        //need to check health factor of the user
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }
        //We want to burn their DSC "debt"
        //And take their collateral
        //Bad user: $140 ETh, $100 DSC
        //debtToCover = $100
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );

        //Give them 10% bonus
        //So we are giving to liquidators $110 WETH for 100 DSC
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToRedeem
        );
        //we need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    /******Private and internal view Functions******/
    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf, // au compte de
        address dscFrom
    ) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        //_calculateHelaFactorAfter
        //IERC20.transfer(to, value) -> tranfer from yourself
        //IERC20.transferFrom(from, to, value) -> transer somebody else
        bool success = IERC20(tokenCollateralAddress).transfer(
            msg.sender,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        internal
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     *
     */
    function _healthFactor(address user) internal view returns (uint256) {
        //total DSC minted
        //total collateral value
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = ((collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION);
        return ((collateralAdjustedForThreshold * PRECISION) / totalDscMinted);
        //1000 ETH * 50 = 50,000 /100 = 50
        //$150 / 100 DSC = 1.5
        //150 * 50 = 7500 / 100 = (75/100) = 0.75 < 1
        // return (collateralValueInUsd / totalDscMinted);
    }

    //1.Check health factor (do they have enough collateral?)
    //2.Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHelathFactor = _healthFactor(user);
        if (userHelathFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHelathFactor);
        }
    }

    /******Public functions*******/

    /**
     * @notice follows CEI (Check Effects Interactions)
     * @param tokenCollateralAddress The address of the token  to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanzero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        /*En faisant IERC20.transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        ) cela signifie que cette fonction
          avait été dejà definie notamment dans 
          ERC20.sol*/
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    //1.Check if the collateral value is great the DSC amount
    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of DecentralizedStableCoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanzero(amountDscToMint) {
        s_DscMinted[msg.sender] += amountDscToMint;
        //if they minted too much ($150 DSC , $150 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool dscMinted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!dscMinted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanzero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*Rembourser la garantie deposée*/
    /* 
    In order to redeem collateral 
    1.Health factor must be over 1 after collateral pulled
    */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanzero(amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /******Public and External view Functions******/
    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        //Price of  (token)
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount they have deposited,
        //and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        //fror exemple 1ETH = $1000
        //En recuperant la valeur de l'ether en usd depuis chainlink je la recupère
        //avec 8 decimales c'est à dire avec 1e8 donc pour avoir la valeur en wei
        //je la multiplie par 1e10 et pour avoir la valeur finale je la divise par
        //1e18 qui correspond à la valeur de l'ether en usd
        return (((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) /
            PRECISION);
    }
}
