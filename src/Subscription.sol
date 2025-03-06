// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Subscription {
    AggregatorV3Interface private immutable priceFeed;

    constructor(address addressForChainLinkETHUSDAggregator) {
        priceFeed = AggregatorV3Interface(addressForChainLinkETHUSDAggregator);
    }

    mapping(address consumer => mapping(address merchant => uint256 amount)) subs;

    function pay() external payable {
        uint256 amount = msg.value;
        require(getUSDByWei(amount) > 1, "At least 1 USD value");
    }

    function getUSDByWei(uint256 amount) public view returns (uint256) {
        return (((getETHUSDPrice() / 1e8) * amount) / 1e18);
    }

    function getETHUSDPrice() public view returns (uint256) {
        (, int price, , , ) = priceFeed.latestRoundData();
        return uint256(price);
    }
}
