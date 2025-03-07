# Flexible Subscriptions Smart Contract

[![Solidity Version](https://img.shields.io/badge/Solidity-^0.8.20-blue.svg)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF6943.svg)](https://getfoundry.sh/)

A smart contract system for managing recurring USDT subscriptions with pro-rata fund release, refund capabilities, and EIP-712 signed authorizations.

## Features

- 🕒 **Pro-Rata Fund Release**: Merchants withdraw funds proportionally to elapsed subscription time
- 🔏 **EIP-712 Signed Subscriptions**: Support for off-chain authorization of subscriptions
- 🔄 **Subscription Merging**: Automatic renewal when adding to active subscriptions
- 📦 **Batch Operations**: Process multiple subscriptions/withdrawals in single transactions
- 💸 **USDT Integration**: Built for USDT (6 decimals) with token validation
- ⏳ **Early Cancellation**: Pro-rated refunds for unused subscription time

## Technical Overview

### Key Components

- **ERC-20 Standard**: Full compliance with ERC-20 token standards
- **EIP-712**: Secure off-chain signature validation for subscription approvals
- **SafeERC20**: Safe token transfer implementations from OpenZeppelin
- **Time-Based Math**: Precise pro-rata calculations using block timestamps

### Contract Structure

```solidity
FlexibleSubscription
├─ EIP712 Implementation
├─ Subscription Management
│  ├─ subscribe()          // Create/renew subscription
│  ├─ signedSubscribe()    // EIP-712 authorized subscription
│  └─ refund()             // Early cancellation with pro-rata refund
├─ Fund Withdrawal
│  ├─ withdraw()           // Single withdrawal
│  └─ batchWithdraw()      // Batch withdrawals
└─ View Functions
   ├─ getSubscriptionStatus() // Full subscription details
   └─ withdrawable()       // Calculates available funds
```

## Deployment with Foundry

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- RPC endpoint (e.g., Infura/Alchemy)
- Ethereum account with testnet funds

### 1. Set Up Environment

```bash
git clone https://github.com/YangHgRi/flexible-subscriptions.git
cd flexible-subscriptions
forge install
```

### 2. Configure Environment Variables

Create `.env` file:

```ini
RPC_URL=<RPC_ENDPOINT>
PRIVATE_KEY=<DEPLOYER_PRIVATE_KEY>
USDT_ADDRESS=0xUSDTContractAddress
```

### 3. Deploy Contract

```bash
source .env
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast --verify -vvvv
```

## Testing

Run comprehensive test suite:

```bash
forge test -vv --match-contract FlexibleSubscriptionTest
```

## License

MIT License - See [LICENSE](LICENSE) for details
