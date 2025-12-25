# 9527 Smart Contracts

Customizable ERC20 tokens with deep virtual floor liquidity and built-in AMM (Automated Market Maker).

## Overview

The 9527 system consists of two contracts:

1. **nine527Factory** - Factory contract for deploying meme tokens
2. **nine527** - The token contract with virtual liquidity AMM

### Features

- **Custom name and symbol**
- **Configurable treasury fee (0-3%)**
- **Virtual liquidity mechanism** - No initial ETH required
- **Factory deployment** - Easy token creation via factory
- **Token tracking** - All tokens indexed and queryable

### Virtual Liquidity Mechanism

Each token starts with **virtual ETH (10 ETH)** and **token reserves (100,000,000 tokens / 100M total supply)**. Initial price is **0.0000001 ETH per token**. As users buy, real ETH flows in and mixes with virtual reserves. The constant product formula (`x * y = k`) ensures fair price discovery.

---

## nine527Factory Contract

The factory makes it easy to deploy meme tokens.

### `createToken(string name, string symbol, uint256 treasuryFeeBP)`

Create a new 9527 meme token.
- `name` - Token name (e.g., "Doge To The Moon")
- `symbol` - Token symbol (e.g., "DOGE")
- `treasuryFeeBP` - Treasury fee in basis points (0-300 = 0-3%)

**Returns:** Address of the newly created token

### View Functions

| Function | Description |
|----------|-------------|
| `totalTokens()` | Total number of tokens created |
| `allTokens(uint256 index)` | Get token address by index |
| `getTokensByDeployer(address)` | Get all tokens created by an address |
| `getRecentTokens(uint256 count)` | Get most recent tokens |
| `getTokensPaginated(offset, limit)` | Paginated token list |
| `isValidToken(address)` | Check if address is a valid 9527 token |

---

## nine527 Token Contract Functions

### Constructor

```solidity
constructor(string memory tokenName_, string memory tokenSymbol_, uint256 treasuryBP_, address deployer_)
```

Deploy a new token with custom parameters:
- `tokenName_` - The name of the token (e.g., "My Token")
- `tokenSymbol_` - The symbol of the token (e.g., "MTK")  
- `treasuryBP_` - Treasury fee in basis points (0-300, i.e., 0-3%)
- `deployer_` - Address of the token deployer/treasury (use address(0) for msg.sender)

---

### View Functions

#### `getEthReserve()`
```solidity
function getEthReserve() public view returns (uint256)
```
Returns the effective ETH reserve (virtual + real ETH - treasury). Used for AMM price calculations.

#### `getTokenReserve()`
```solidity
function getTokenReserve() public view returns (uint256)
```
Returns the token reserve held by the factory address.

#### `getTokenPrice()`
```solidity
function getTokenPrice() public view returns (uint256)
```
Calculates and returns the current token price in ETH (per token, scaled by 1e18).

#### `estimateBuyReturn(uint256 ethAmount)`
```solidity
function estimateBuyReturn(uint256 ethAmount) public view returns (uint256)
```
Estimate how many tokens you'll receive for a given ETH amount.
- `ethAmount` - Amount of ETH to spend

#### `estimateSellReturn(uint256 tokenAmount)`
```solidity
function estimateSellReturn(uint256 tokenAmount) public view returns (uint256)
```
Estimate how much ETH you'll receive for selling tokens (after treasury fee).
- `tokenAmount` - Amount of tokens to sell

#### `getTokenInfo()`
```solidity
function getTokenInfo() external view returns (
    string memory tokenName,
    string memory tokenSymbol,
    address deployer,
    uint256 treasuryFeeBP,
    uint256 currentPrice,
    uint256 ethReserve,
    uint256 tokenReserve
)
```
Returns comprehensive token configuration info including name, symbol, deployer address, treasury fee, current price, and reserves.

---

### Trading Functions

#### `buyToken(uint256 minTokenAmt, uint256 expireTimestamp)`
```solidity
function buyToken(uint256 minTokenAmt, uint256 expireTimestamp) external payable
```
Buy tokens with ETH.
- `minTokenAmt` - Minimum tokens to receive (slippage protection)
- `expireTimestamp` - Transaction deadline (use `0` for no deadline)
- Send ETH with the transaction (`msg.value`)

**Emits:** `BuyToken(address indexed user, uint256 tokenAmt, uint256 ethAmt)`

#### `sellToken(uint256 tokenAmt, uint256 minEthAmt, uint256 expireTimestamp)`
```solidity
function sellToken(uint256 tokenAmt, uint256 minEthAmt, uint256 expireTimestamp) external
```
Sell tokens for ETH.
- `tokenAmt` - Amount of tokens to sell
- `minEthAmt` - Minimum ETH to receive (slippage protection)
- `expireTimestamp` - Transaction deadline (use `0` for no deadline)

**Emits:** `SellToken(address indexed user, uint256 tokenAmt, uint256 ethAmt)`

---

### Treasury Functions

#### `setTreasuryAddr(address newTreasury)`
```solidity
function setTreasuryAddr(address newTreasury) external
```
Change the treasury address. Only callable by current treasury.
- `newTreasury` - New treasury address (cannot be zero address)

#### `withdrawTreasury(uint256 amt)`
```solidity
function withdrawTreasury(uint256 amt) external
```
Withdraw accumulated treasury fees. Only callable by treasury.
- `amt` - Amount of ETH to withdraw

---

## Configuration Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `INITIAL_VIRTUAL_ETH` | 10 ETH | Virtual ETH reserve at start |
| `INITIAL_TOKEN_RESERVE` | 100,000,000 tokens (100M) | Initial token supply (total supply) |
| `MAX_TREASURY_BP` | 300 (3%) | Maximum treasury fee allowed |
| `TRANSFER_BURN_BP` | 0 | Burn on transfers (disabled) |
| `SELL_BURN_BP` | 0 | Burn on sells (disabled) |
| `CONTRACT_CHECK_BUY_LEVEL` | 3 | Anti-bot: checks extcodesize + tx.origin |
| `CONTRACT_CHECK_SELL_LEVEL` | 3 | Anti-bot: checks extcodesize + tx.origin |

---

## Security Features

- **ReentrancyGuard** - Protects against reentrancy attacks
- **Anti-bot protection** - Contract and tx.origin checks
- **Slippage protection** - Minimum output amounts on buy/sell
- **Transaction deadlines** - Expiration timestamps to prevent stale transactions

---

## Development with Foundry

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Local Node (Anvil)

```shell
anvil
```

### Deploy

```shell
forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Interact with Cast

```shell
# Get token price
cast call <contract_address> "getTokenPrice()(uint256)"

# Estimate buy return for 1 ETH
cast call <contract_address> "estimateBuyReturn(uint256)(uint256)" 1000000000000000000

# Buy tokens
cast send <contract_address> "buyToken(uint256,uint256)" <min_tokens> 0 --value 1ether
```

### Help

```shell
forge --help
anvil --help
cast --help
```

---

## License

MIT
