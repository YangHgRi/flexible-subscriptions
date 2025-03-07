// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/FlexibleSubscription.sol";

contract FlexibleSubscriptionTest is Test {
    FlexibleSubscription public sub;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"));
        sub = new FlexibleSubscription(vm.envAddress("USDT_ADDRESS"));
    }

    function test_nothing() public pure {
        console.log("foo bar");
    }
}
