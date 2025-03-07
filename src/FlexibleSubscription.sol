// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title Flexible subscription management contract with USDT payments
/// @notice Handles recurring payments with pro-rata fund release and refund capabilities
contract FlexibleSubscription is EIP712 {
    using SafeERC20 for IERC20;

    /// @dev EIP-712 type hash for subscription authorization
    bytes32 private constant _SUBSCRIPTION_AUTH_TYPEHASH =
        keccak256(
            "SubscriptionAuth(address consumer,address merchant,uint256 amount,uint256 period,uint256 nonce,uint256 deadline)"
        );

    /// @notice Track signature nonces for each address
    mapping(address => uint256) public nonces;

    /// @notice USDT token contract interface (6 decimals required)
    IERC20 public immutable usdtToken;

    /// @notice Nested mapping tracking subscriptions: consumer -> merchant -> Subscription
    mapping(address consumer => mapping(address merchant => Subscription))
        public subscriptions;

    /// @notice Subscription structure tracking payment details
    /// @param totalAmount Total USDT amount committed to subscription
    /// @param startTime Subscription start timestamp
    /// @param endTime Subscription end timestamp
    /// @param withdrawn Accumulated withdrawn amount by merchant
    struct Subscription {
        uint256 totalAmount;
        uint256 startTime;
        uint256 endTime;
        uint256 withdrawn;
    }

    // Event declarations
    /// @notice Emitted when a new subscription is created/renewed
    event Subscribe(
        address indexed consumer,
        address indexed merchant,
        uint256 totalAmount,
        uint256 startTime,
        uint256 endTime
    );

    /// @notice Emitted when merchant withdraws available funds
    event Withdraw(
        address indexed merchant,
        address indexed consumer,
        uint256 amount
    );

    /// @notice Emitted for batch withdrawals by merchants
    event BatchWithdraw(
        address indexed merchant,
        uint256 indexed consumersNumber,
        uint256 totalAmount
    );

    /// @notice Emitted when consumer cancels subscription and gets refund
    event Refund(
        address indexed consumer,
        address indexed merchant,
        uint256 refundAmount
    );

    // Custom error definitions
    error InvalidAddress();
    error InsufficientAmount();
    error NonPositivePeriod();
    error InsufficientBalance();
    error SubExpired();
    error EmptyConsumers();
    error TooManyConsumers();
    error SignatureExpired();
    error InvalidSignature();

    /// @notice Initializes contract with USDT token address
    /// @dev Verifies token has 6 decimals and USDT symbol
    /// @param usdtTokenAddress Address of USDT ERC20 token contract
    constructor(address usdtTokenAddress) EIP712("FlexibleSubscription", "1") {
        if (usdtTokenAddress == address(0)) revert InvalidAddress();
        usdtToken = IERC20(usdtTokenAddress);

        _validateToken(usdtTokenAddress);
    }

    /// @dev Internal validation of token decimals and symbol
    /// @param tokenAddress Address of token contract to validate
    function _validateToken(address tokenAddress) private view {
        uint8 decimals = IERC20Metadata(tokenAddress).decimals();
        require(decimals == 6, "Invalid token decimals");

        string memory symbol = IERC20Metadata(tokenAddress).symbol();
        require(
            keccak256(bytes(symbol)) == keccak256(bytes("USDT")),
            "Invalid token symbol"
        );
    }

    /// @notice Returns detailed status of a subscription
    /// @param consumer Subscriber address
    /// @param merchant Recipient address
    /// @return totalAmount Total committed funds
    /// @return withdrawn Already withdrawn amount
    /// @return remainingFunds Currently available funds
    /// @return timeRemaining Seconds until subscription expiration
    function getSubscriptionStatus(
        address consumer,
        address merchant
    )
        external
        view
        returns (
            uint256 totalAmount,
            uint256 withdrawn,
            uint256 remainingFunds,
            uint256 timeRemaining
        )
    {
        Subscription memory sub = subscriptions[consumer][merchant];
        remainingFunds = sub.totalAmount - sub.withdrawn;
        timeRemaining = sub.endTime > block.timestamp
            ? sub.endTime - block.timestamp
            : 0;
        return (sub.totalAmount, sub.withdrawn, remainingFunds, timeRemaining);
    }

    /// @notice Creates or renews a subscription
    /// @dev Merges with existing active subscription if present
    /// @param merchant Recipient address
    /// @param totalAmount USDT amount (6 decimals)
    /// @param periodSeconds Subscription duration in seconds
    function subscribe(
        address merchant,
        uint256 totalAmount,
        uint256 periodSeconds
    ) public {
        if (merchant == address(0)) revert InvalidAddress();
        if (periodSeconds <= 0) revert NonPositivePeriod();
        if (totalAmount < 1e6) revert InsufficientAmount();

        Subscription storage sub = subscriptions[msg.sender][merchant];

        // Extend existing active subscription
        if (sub.endTime > block.timestamp) {
            uint256 remaining = sub.totalAmount - sub.withdrawn;
            sub.totalAmount = remaining + totalAmount;
            sub.endTime += periodSeconds;
        } else {
            // Create new subscription
            subscriptions[msg.sender][merchant] = Subscription({
                totalAmount: totalAmount,
                startTime: block.timestamp,
                endTime: block.timestamp + periodSeconds,
                withdrawn: 0
            });
        }

        usdtToken.safeTransferFrom(msg.sender, address(this), totalAmount);

        emit Subscribe(
            msg.sender,
            merchant,
            totalAmount,
            block.timestamp,
            block.timestamp + periodSeconds
        );
    }

    /// @notice Process off-chain signed subscription authorization
    /// @dev Implements EIP-712 signature verification
    /// @param consumer Subscriber address (must match signature)
    /// @param amount USDT amount (6 decimals)
    /// @param periodSeconds Subscription duration
    /// @param deadline Signature expiration timestamp
    /// @param signature EIP-712 compliant signature
    function signedSubscribe(
        address consumer,
        uint256 amount,
        uint256 periodSeconds,
        uint256 deadline,
        bytes calldata signature
    ) public {
        if (block.timestamp > deadline) revert SignatureExpired();

        // Construct signature digest
        bytes32 structHash = keccak256(
            abi.encode(
                _SUBSCRIPTION_AUTH_TYPEHASH,
                consumer,
                msg.sender,
                amount,
                periodSeconds,
                nonces[consumer],
                deadline
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);

        if (signer != consumer) revert InvalidSignature();
        if (consumer == address(0)) revert InvalidAddress();

        nonces[consumer]++;

        // Process the subscription
        subscribe(msg.sender, amount, periodSeconds);
    }

    /// @notice Batch process multiple signed subscriptions
    /// @param consumers Array of subscriber addresses
    /// @param amounts Array of USDT amounts
    /// @param periods Array of subscription durations
    /// @param deadlines Array of signature expiration times
    /// @param signatures Array of EIP-712 signatures
    function batchProcessSubscriptions(
        address[] calldata consumers,
        uint256[] calldata amounts,
        uint256[] calldata periods,
        uint256[] calldata deadlines,
        bytes[] calldata signatures
    ) external {
        require(
            consumers.length == amounts.length &&
                consumers.length == signatures.length,
            "Array length mismatch"
        );

        for (uint i = 0; i < consumers.length; ) {
            signedSubscribe(
                consumers[i],
                amounts[i],
                periods[i],
                deadlines[i],
                signatures[i]
            );
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Calculates currently withdrawable funds (pro-rata basis)
    /// @param consumer Subscriber address
    /// @param merchant Recipient address
    /// @return amount Withdrawable USDT amount
    function withdrawable(
        address consumer,
        address merchant
    ) public view returns (uint256) {
        Subscription memory sub = subscriptions[consumer][merchant];

        if (sub.endTime == 0) return 0;
        if (block.timestamp >= sub.endTime) {
            // Full amount available after expiration
            return sub.totalAmount - sub.withdrawn;
        } else if (block.timestamp <= sub.startTime) {
            return 0;
        }

        // Calculate pro-rata release
        uint256 elapsed = block.timestamp - sub.startTime;
        uint256 totalPeriod = sub.endTime - sub.startTime;
        uint256 releasable = (sub.totalAmount * elapsed * 1e18) /
            totalPeriod /
            1e18;

        return releasable - sub.withdrawn;
    }

    /// @notice Withdraw available funds from specific consumer
    /// @param consumer Subscriber address to withdraw from
    function withdraw(address consumer) external {
        Subscription storage sub = subscriptions[consumer][msg.sender];
        uint256 amount = withdrawable(consumer, msg.sender);
        if (amount <= 0) revert InsufficientBalance();
        sub.withdrawn += amount;
        usdtToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, consumer, amount);
    }

    /// @notice Batch withdraw from multiple consumers
    /// @param consumers Array of subscriber addresses (max 100)
    function batchWithdraw(address[] calldata consumers) external {
        if (consumers.length == 0) revert EmptyConsumers();
        if (consumers.length > 100) revert TooManyConsumers();

        uint256 totalAmount;

        for (uint256 i = 0; i < consumers.length; ) {
            address consumer = consumers[i];
            if (consumer == address(0)) revert InvalidAddress();
            Subscription storage sub = subscriptions[consumer][msg.sender];

            if (sub.endTime == 0) continue;

            uint256 available = withdrawable(consumer, msg.sender);
            sub.withdrawn += available;
            totalAmount += available;

            unchecked {
                ++i;
            }
        }

        if (totalAmount <= 0) revert InsufficientBalance();
        usdtToken.safeTransfer(msg.sender, totalAmount);
        emit BatchWithdraw(msg.sender, consumers.length, totalAmount);
    }

    /// @notice Cancel subscription and refund unearned funds
    /// @param merchant Recipient address to cancel subscription with
    function refund(address merchant) external {
        Subscription storage sub = subscriptions[msg.sender][merchant];
        if (sub.endTime <= block.timestamp) revert SubExpired();

        uint256 releasable = withdrawable(msg.sender, merchant);
        uint256 refundAmount = sub.totalAmount - releasable;

        // Immediately expire subscription
        sub.endTime = block.timestamp;
        sub.totalAmount = releasable;

        usdtToken.safeTransfer(msg.sender, refundAmount);

        emit Refund(msg.sender, merchant, refundAmount);
    }
}
