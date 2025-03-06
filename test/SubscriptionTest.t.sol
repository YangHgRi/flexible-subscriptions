// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Subscription.sol";
import {AggregatorV3Interface} from "../src/AggregatorV3Interface.sol";

contract SubscriptionTest is Test {
    Subscription public sub;
    AggregatorV3Interface public priceFeed;

    function setUp() public {
        vm.createSelectFork("https://arbitrum-sepolia.drpc.org");
        sub = new Subscription(0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165);
        priceFeed = AggregatorV3Interface(
            0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165
        );
    }

    function testPriceFeedEthUsd() public view {
        (, int price, , , ) = priceFeed.latestRoundData();
        console.log("ETH/USD price: ", price);
        console.log("ETH/USD price without decimal: ", price / 1e8);
    }

    function testGetUsdByWei() public view {
        console.log(sub.getUSDByWei(1 ether));
    }
}
