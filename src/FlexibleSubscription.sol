// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title Flexible Subscription Management Contract with USDT Payments
/// @notice Enables recurring payment agreements with pro-rata fund release and refund capabilities
/// @dev Inherits from EIP-712 for typed signature verification
contract FlexibleSubscription is EIP712 {
    using SafeERC20 for IERC20;

    /// @dev EIP-712 type hash for subscription authorization signatures
    bytes32 private constant _SUBSCRIPTION_AUTH_TYPEHASH = keccak256(
        "SubscriptionAuth(address consumer,address merchant,uint256 amount,uint256 period,uint256 nonce,uint256 deadline)"
    );

    /// @notice Tracks used signature nonces to prevent replay attacks
    mapping(address => uint256) public nonces;

    /// @notice USDT token contract interface (must have 6 decimals)
    IERC20 public immutable usdtToken;

    /// @notice Nested mapping structure tracking all active subscriptions
    /// @dev First mapping: consumer address, Second mapping: merchant address
    mapping(address consumer => mapping(address merchant => Subscription)) public subscriptions;

    /// @notice Subscription payment details structure
    /// @param totalAmount Total committed funds in USDT (6 decimals)
    /// @param startTime UNIX timestamp of subscription start
    /// @param endTime UNIX timestamp of subscription expiration
    /// @param withdrawn Accumulated amount already withdrawn by merchant
    struct Subscription {
        uint256 totalAmount;
        uint256 startTime;
        uint256 endTime;
        uint256 withdrawn;
    }

    // Events
    /// @notice Emitted when new subscription is created or renewed
    /// @param consumer Subscriber wallet address
    /// @param merchant Recipient wallet address
    /// @param totalAmount Total committed USDT amount
    /// @param startTime Subscription start timestamp
    /// @param endTime Subscription expiration timestamp
    event Subscribe(
        address indexed consumer, address indexed merchant, uint256 totalAmount, uint256 startTime, uint256 endTime
    );

    /// @notice Emitted when merchant withdraws available funds
    /// @param merchant Recipient wallet address
    /// @param consumer Subscriber wallet address
    /// @param amount Withdrawn USDT amount
    event Withdraw(address indexed merchant, address indexed consumer, uint256 amount);

    /// @notice Emitted for batch withdrawal operations
    /// @param merchant Recipient wallet address
    /// @param consumersNumber Number of consumers processed
    /// @param totalAmount Total withdrawn USDT amount
    event BatchWithdraw(address indexed merchant, uint256 indexed consumersNumber, uint256 totalAmount);

    /// @notice Emitted when consumer cancels subscription and receives refund
    /// @param consumer Subscriber wallet address
    /// @param merchant Recipient wallet address
    /// @param refundAmount Refunded USDT amount
    event Refund(address indexed consumer, address indexed merchant, uint256 refundAmount);

    // Custom Errors
    /// @dev Reverts when zero address is provided
    error InvalidAddress();
    /// @dev Reverts when provided amount < 1 USDT (1e6)
    error InsufficientAmount();
    /// @dev Reverts when subscription period <= 0
    error NonPositivePeriod();
    /// @dev Reverts when withdrawal amount = 0
    error InsufficientBalance();
    /// @dev Reverts when operating on expired subscription
    error SubExpired();
    /// @dev Reverts on empty consumer array
    error EmptyConsumers();
    /// @dev Reverts when batch size exceeds 100
    error TooManyConsumers();
    /// @dev Reverts when signature timestamp expired
    error SignatureExpired();
    /// @dev Reverts when signature verification fails
    error InvalidSignature();

    /// @notice Contract constructor initializes USDT token
    /// @dev Performs ERC20 metadata validation (6 decimals, USDT symbol)
    /// @param usdtTokenAddress Address of USDT ERC20 contract
    constructor(address usdtTokenAddress) EIP712("FlexibleSubscription", "1") {
        if (usdtTokenAddress == address(0)) revert InvalidAddress();
        usdtToken = IERC20(usdtTokenAddress);
        _validateToken(usdtTokenAddress);
    }

    /// @notice Returns EIP-712 domain separator
    /// @dev Used for signature verification
    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev Validates token decimals and symbol
    /// @param tokenAddress ERC20 token contract address
    function _validateToken(address tokenAddress) private view {
        uint8 decimals = IERC20Metadata(tokenAddress).decimals();
        require(decimals == 6, "Invalid token decimals");

        string memory symbol = IERC20Metadata(tokenAddress).symbol();
        require(keccak256(bytes(symbol)) == keccak256(bytes("USDT")), "Invalid token symbol");
    }

    /// @notice Returns detailed subscription status
    /// @param consumer Subscriber wallet address
    /// @param merchant Recipient wallet address
    /// @return totalAmount Total committed funds
    /// @return withdrawn Already withdrawn amount
    /// @return remainingFunds Currently available funds
    /// @return timeRemaining Seconds until subscription expiration
    function getSubscriptionStatus(address consumer, address merchant)
        external
        view
        returns (uint256 totalAmount, uint256 withdrawn, uint256 remainingFunds, uint256 timeRemaining)
    {
        Subscription memory sub = subscriptions[consumer][merchant];
        remainingFunds = sub.totalAmount - sub.withdrawn;
        timeRemaining = sub.endTime > block.timestamp ? sub.endTime - block.timestamp : 0;
        return (sub.totalAmount, sub.withdrawn, remainingFunds, timeRemaining);
    }

    /// @notice Creates or renews subscription agreement
    /// @dev Merges with existing active subscription if present
    /// @param merchant Recipient wallet address
    /// @param totalAmount USDT amount (6 decimals)
    /// @param periodSeconds Subscription duration in seconds
    function subscribe(address merchant, uint256 totalAmount, uint256 periodSeconds) public {
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

        emit Subscribe(msg.sender, merchant, totalAmount, block.timestamp, block.timestamp + periodSeconds);
    }

    /// @notice Processes off-chain signed subscription authorization
    /// @dev Implements EIP-712 signature verification with nonce protection
    /// @param consumer Subscriber wallet address (must match signer)
    /// @param amount USDT amount (6 decimals)
    /// @param periodSeconds Subscription duration in seconds
    /// @param deadline Signature expiration timestamp
    /// @param signature ECDSA signature bytes
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
                _SUBSCRIPTION_AUTH_TYPEHASH, consumer, msg.sender, amount, periodSeconds, nonces[consumer], deadline
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);

        if (signer != consumer) revert InvalidSignature();
        if (consumer == address(0)) revert InvalidAddress();

        nonces[consumer]++;

        // Process subscription as merchant (msg.sender)
        subscribe(msg.sender, amount, periodSeconds);
    }

    /// @notice Batch processes multiple signed subscriptions
    /// @dev All input arrays must have equal length
    /// @param consumers Array of subscriber addresses
    /// @param amounts Array of USDT amounts (6 decimals)
    /// @param periods Array of subscription durations (seconds)
    /// @param deadlines Array of signature expiration timestamps
    /// @param signatures Array of ECDSA signature bytes
    function batchProcessSubscriptions(
        address[] calldata consumers,
        uint256[] calldata amounts,
        uint256[] calldata periods,
        uint256[] calldata deadlines,
        bytes[] calldata signatures
    ) external {
        require(consumers.length == amounts.length && consumers.length == signatures.length, "Array length mismatch");

        for (uint256 i = 0; i < consumers.length;) {
            signedSubscribe(consumers[i], amounts[i], periods[i], deadlines[i], signatures[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Calculates currently withdrawable funds (pro-rata basis)
    /// @dev Uses linear time-based release schedule
    /// @param consumer Subscriber wallet address
    /// @param merchant Recipient wallet address
    /// @return amount Withdrawable USDT amount (6 decimals)
    function withdrawable(address consumer, address merchant) public view returns (uint256) {
        Subscription memory sub = subscriptions[consumer][merchant];

        if (sub.endTime == 0) return 0;
        if (block.timestamp >= sub.endTime) {
            // Full amount available after expiration
            return sub.totalAmount - sub.withdrawn;
        } else if (block.timestamp <= sub.startTime) {
            return 0;
        }

        // Pro-rata calculation with fixed-point math
        uint256 elapsed = block.timestamp - sub.startTime;
        uint256 totalPeriod = sub.endTime - sub.startTime;
        uint256 releasable = (sub.totalAmount * elapsed * 1e18) / totalPeriod / 1e18;

        return releasable - sub.withdrawn;
    }

    /// @notice Withdraws available funds from specific consumer
    /// @param consumer Subscriber wallet address to withdraw from
    function withdraw(address consumer) external {
        Subscription storage sub = subscriptions[consumer][msg.sender];
        uint256 amount = withdrawable(consumer, msg.sender);
        if (amount <= 0) revert InsufficientBalance();
        sub.withdrawn += amount;
        usdtToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, consumer, amount);
    }

    /// @notice Batch withdraws from multiple consumers
    /// @dev Maximum 100 consumers per transaction
    /// @param consumers Array of subscriber addresses
    function batchWithdraw(address[] calldata consumers) external {
        if (consumers.length == 0) revert EmptyConsumers();
        if (consumers.length > 100) revert TooManyConsumers();

        uint256 totalAmount;

        for (uint256 i = 0; i < consumers.length;) {
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

    /// @notice Cancels subscription and refunds unearned funds
    /// @dev Immediately expires subscription and transfers remaining balance
    /// @param merchant Recipient wallet address to cancel
    function refund(address merchant) external {
        Subscription storage sub = subscriptions[msg.sender][merchant];
        if (sub.endTime <= block.timestamp) revert SubExpired();

        uint256 releasable = withdrawable(msg.sender, merchant);
        uint256 refundAmount = sub.totalAmount - releasable;

        // Expire subscription immediately
        sub.endTime = block.timestamp;
        sub.totalAmount = releasable;

        usdtToken.safeTransfer(msg.sender, refundAmount);

        emit Refund(msg.sender, merchant, refundAmount);
    }
}
