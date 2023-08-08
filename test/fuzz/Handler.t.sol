// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralisedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    address[] public usersWithCollateralDeposited;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _engine, DecentralisedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDsc(uint256 _addressSeed, uint256 _amount) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[_addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);

        if (maxDscToMint < 0) {
            return;
        }
        _amount = bound(_amount, 0, uint256(maxDscToMint));

        if (_amount == 0) {
            return;
        }

        vm.startPrank(sender);
        engine.mintDSC(_amount);
        vm.stopPrank();
    }

    function depositCollateral(uint256 _collateralSeed, uint256 _amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        _amountCollateral = bound(_amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, _amountCollateral);
        collateral.approve(address(engine), _amountCollateral);
        engine.depositCollateral(address(collateral), _amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 _collateralSeed, uint256 _amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        _amountCollateral = bound(_amountCollateral, 0, maxCollateralToRedeem);
        if (_amountCollateral == 0) {
            return;
        }

        engine.redeemCollateral(address(collateral), _amountCollateral);
    }

    function updateCollateralPrice(uint96 _newPrice) public {
        int256 newPriceInt = int256(uint256(_newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    // Helper Functions
    function _getCollateralFromSeed(uint256 _collateralSeed) private view returns (ERC20Mock) {
        if (_collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
