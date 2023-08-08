// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DecentralisedStableCoin dsc;
    DSCEngine engine;
    HelperConfig helper;
    Handler handler;

    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, helper) = deployer.run();
        (,, weth, wbtc,) = helper.activeNetworkConfig();

        handler = new Handler(engine,dsc);
        targetContract(address(handler));
        //targetContract(address(engine));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSuppy = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        assert(wethValue + wbtcValue >= totalSuppy);
    }

    /**
     * This is an invariant testing. Random parameters are passed. Since fail_on_revert is set to false, every test case passes because of revert.
     * This is inefficient because it sends random values which do not make sense
     */
    // function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
    //     uint256 totalSuppy = dsc.totalSupply();
    //     uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
    //     uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

    //     uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
    //     uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

    //     assert(wethValue + wbtcValue >= totalSuppy);
    // }
}
