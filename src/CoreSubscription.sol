// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CoreSubscription {
    using SafeERC20 for IERC20;

    struct Plan {
        IERC20 token; // 支付代币
        uint256 valuePerSecond; // 每秒费用（精度为1e18）
        uint256 minDuration; // 最低订阅时长（秒）
    }

    struct Subscription {
        uint256 startTime; // 订阅开始时间
        uint256 lastPaid; // 最近结算时间点
        uint256 balance; // 预存余额
    }

    // 商户地址 => 订阅方案
    mapping(address => Plan) public merchantPlans;

    // 用户地址 => 商户地址 => 订阅状态
    mapping(address => mapping(address => Subscription)) public userSubs;

    event PlanUpdated(address merchant, uint256 perSecondRate);
    event Subscribed(address user, address merchant, uint256 amount);
    event Withdrawn(address merchant, uint256 amount);

    /* 核心方法 */

    // 商家设置订阅方案（需预存初始资金）
    function setPlan(
        IERC20 _token,
        uint256 _monthlyRate, // 每月费用（以代币最小单位计）
        uint256 _minDuration
    ) external {
        merchantPlans[msg.sender] = Plan({
            token: _token,
            valuePerSecond: _monthlyRate / (30 days),
            minDuration: _minDuration
        });

        emit PlanUpdated(msg.sender, _monthlyRate / (30 days));
    }

    // 用户订阅（需提前approve代币）
    function subscribe(address merchant, uint256 prepay) external {
        Plan memory plan = merchantPlans[merchant];
        require(
            prepay >= plan.valuePerSecond * plan.minDuration,
            "Prepay insufficient"
        );

        // 转移预存金至合约
        plan.token.safeTransferFrom(msg.sender, address(this), prepay);

        // 初始化订阅（若已有订阅则累加余额）
        Subscription storage sub = userSubs[msg.sender][merchant];
        sub.balance += prepay;
        if (sub.startTime == 0) {
            sub.startTime = block.timestamp;
            sub.lastPaid = block.timestamp;
        }

        emit Subscribed(msg.sender, merchant, prepay);
    }

    // 费用结算（可由任意外部账户调用）
    function settle(address user, address merchant) public {
        Subscription storage sub = userSubs[user][merchant];
        Plan memory plan = merchantPlans[merchant];
        require(sub.balance > 0, "No active subscription");

        uint256 deltaTime = block.timestamp - sub.lastPaid;
        uint256 fee = deltaTime * plan.valuePerSecond;

        if (fee > sub.balance) {
            fee = sub.balance;
            deltaTime = fee / plan.valuePerSecond;
        }

        sub.balance -= fee;
        sub.lastPaid += deltaTime;

        // 将费用转至商户（每日限额释放机制可在此扩展）
        plan.token.safeTransfer(merchant, fee);
    }

    // 用户主动解约（需满足最低时长）
    function unsubscribe(address merchant) external {
        Subscription storage sub = userSubs[msg.sender][merchant];
        Plan memory plan = merchantPlans[merchant];

        settle(msg.sender, merchant); // 先结算
        require(
            block.timestamp >= sub.startTime + plan.minDuration,
            "Min duration not met"
        );

        uint256 refund = sub.balance;
        delete userSubs[msg.sender][merchant];

        plan.token.safeTransfer(msg.sender, refund);
    }
}
