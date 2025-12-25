# 9527 Deployment Guide

This guide explains how to deploy the 9527 Token Factory with **deterministic addresses** across multiple chains using [EIP-2470 Singleton Factory](https://eips.ethereum.org/EIPS/eip-2470).

## Why Deterministic Addresses?

Using EIP-2470, your nine527Factory will have the **same address on every EVM chain** (Ethereum, BNB Chain, Polygon, Arbitrum, etc.). This makes it easier for users to interact with your protocol across chains.

## Prerequisites

1. **Foundry** - Install from https://getfoundry.sh/
2. **Private key** with funds on target chain
3. **RPC URL** for target chain

## Quick Start (BNB Chain)

### Step 1: Deploy Singleton Factory (if needed)

The Singleton Factory (`0xce0042B868300000d44A59004Da54A005ffdcf9f`) may already be deployed on your target chain.

**Check if it exists:**
```bash
cast code 0xce0042B868300000d44A59004Da54A005ffdcf9f --rpc-url https://bsc-dataseed.binance.org/
```

If it returns `0x`, deploy it:

```bash
cd "smart contract/script"
./deploy-singleton-bnb.sh mainnet YOUR_PRIVATE_KEY
```

For testnet:
```bash
./deploy-singleton-bnb.sh testnet YOUR_PRIVATE_KEY
```

### Step 2: Deploy nine527Factory

```bash
./deploy-nine527-bnb.sh mainnet YOUR_PRIVATE_KEY
```

For testnet:
```bash
./deploy-nine527-bnb.sh testnet YOUR_PRIVATE_KEY
```

## Manual Deployment

### Option A: Using Foundry Scripts

**Deploy Singleton Factory check:**
```bash
forge script script/DeploySingletonFactory.s.sol:DeploySingletonFactoryScript \
  --rpc-url https://bsc-dataseed.binance.org/ \
  --broadcast
```

**Deploy nine527Factory with deterministic address:**
```bash
forge script script/Deploynine527Factory.s.sol:Deploynine527FactoryScript \
  --rpc-url https://bsc-dataseed.binance.org/ \
  --private-key YOUR_PRIVATE_KEY \
  --broadcast
```

**Deploy nine527Factory directly (without Singleton Factory):**
```bash
forge script script/Deploynine527Factory.s.sol:Deploynine527FactoryDirectScript \
  --rpc-url https://bsc-dataseed.binance.org/ \
  --private-key YOUR_PRIVATE_KEY \
  --broadcast
```

### Option B: Manual Singleton Factory Deployment

Following [EIP-2470](https://eips.ethereum.org/EIPS/eip-2470):

1. **Send exactly 0.0247 BNB** to the single-use deployer account:
   ```
   0xBb6e024b9cFFACB947A71991E386681B1Cd1477D
   ```

2. **Broadcast the raw deployment transaction:**
   ```bash
   cast publish --rpc-url https://bsc-dataseed.binance.org/ \
     0xf9016c8085174876e8008303c4d88080b90154608060405234801561001057600080fd5b50610134806100206000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80634af63f0214602d575b600080fd5b60cf60048036036040811015604157600080fd5b810190602081018135640100000000811115605b57600080fd5b820183602082011115606c57600080fd5b80359060200191846001830284011164010000000083111715608d57600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600092019190915250929550509135925060eb915050565b604080516001600160a01b039092168252519081900360200190f35b6000818351602085016000f5939250505056fea26469706673582212206b44f8a82cb6b156bfcc3dc6aadd6df4eefd204bc928a4397fd15dacf6d5320564736f6c634300060200331b83247000822470
   ```

3. **Verify deployment:**
   ```bash
   cast code 0xce0042B868300000d44A59004Da54A005ffdcf9f --rpc-url https://bsc-dataseed.binance.org/
   ```

## Supported Networks

| Network | Chain ID | RPC URL |
|---------|----------|---------|
| BNB Mainnet | 56 | https://bsc-dataseed.binance.org/ |
| BNB Testnet | 97 | https://data-seed-prebsc-1-s1.binance.org:8545/ |
| Ethereum Mainnet | 1 | https://eth.llamarpc.com |
| Sepolia Testnet | 11155111 | https://rpc.sepolia.org |

## Contract Addresses

| Contract | Address |
|----------|---------|
| Singleton Factory (EIP-2470) | `0xce0042B868300000d44A59004Da54A005ffdcf9f` |
| Single-use Deployer | `0xBb6e024b9cFFACB947A71991E386681B1Cd1477D` |
| nine527Factory | _Deterministic (calculated from salt)_ |

## After Deployment

1. **Update frontend config** (`frontend/src/config/wagmi.ts`):
   ```typescript
   export const FACTORY_ADDRESS = '0xYOUR_DEPLOYED_ADDRESS' as const
   ```

2. **Verify contract on BscScan:**
   ```bash
   forge verify-contract \
     --chain-id 56 \
     --num-of-optimizations 200 \
     --compiler-version v0.8.20 \
     YOUR_FACTORY_ADDRESS \
     src/nine527Factory.sol:nine527Factory
   ```

## Troubleshooting

### "Singleton Factory not deployed"
Deploy it first using the deploy-singleton-bnb.sh script.

### "Insufficient funds"
Ensure your wallet has enough BNB for gas fees.

### "Transaction failed"
Check that you're using the correct RPC URL and private key format.

## Security Notes

- The Singleton Factory deployment uses a "keyless" method where no one knows the private key
- The `r` and `s` signature values (`2470`) are human-determined, proving no one controls the deployer account
- All funds sent to the single-use deployer account are permanently locked

## References

- [EIP-2470: Singleton Factory](https://eips.ethereum.org/EIPS/eip-2470)
- [EIP-1014: CREATE2](https://eips.ethereum.org/EIPS/eip-1014)
- [Nick's Method (Keyless Deployment)](https://weka.medium.com/how-to-send-ether-to-11-440-people-using-one-smart-contract-cf8ed37b1db3)

