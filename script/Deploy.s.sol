// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/FlexibleSubscription.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        new FlexibleSubscription(vm.envAddress("USDT_ADDRESS"));
        vm.stopBroadcast();
    }
}
