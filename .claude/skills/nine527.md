# nine527 Token Skill

A skill for interacting with the nine527 token system on **X Layer** only: create tokens, buy tokens, and sell tokens using **onchainOS** (`onchainos` CLI).

## Trigger

Use this skill when the user asks to:
- Create / deploy a token
- Buy tokens / purchase tokens
- Sell tokens
- Check token price or info

---

## Network: X Layer Only

| Field | Value |
|-------|-------|
| Chain name (onchainos) | `xlayer` |
| Chain ID | `196` |
| Native token | **OKB** |
| Mainnet RPC | `https://rpc.xlayer.tech` |
| Explorer | `https://www.oklink.com/xlayer` |

> This skill **only** supports X Layer. Do not use any other network.

---

## How to Use This Skill

When invoked, determine which action the user wants and follow the matching workflow below.

### Environment Setup

Before any on-chain action, confirm the following are set:

```bash
export RPC_URL="https://rpc.xlayer.tech"
export FACTORY_ADDR="0x5AeA8C284a3e162C04e926fa8Db69d726754f1Fd"
```

Check onchainOS wallet status (must be logged in):
```bash
onchainos wallet status
```

Get your X Layer wallet address:
```bash
onchainos wallet addresses
```

---

## Action: Create Token

Creates a new nine527 token via the factory's `createTokenSimple` function.

**Ask the user for:**
| Field | Description | Example |
|-------|-------------|---------|
| `TOKEN_NAME` | Full token name | `"Moon Cat"` |
| `TOKEN_SYMBOL` | Ticker symbol | `"MCAT"` |
| `TREASURY_BP` | Treasury fee in basis points (0–300) | `100` = 1% |

**Step 1 — Encode calldata:**
```bash
CALLDATA=$(cast calldata \
  "createTokenSimple(string,string,uint256)" \
  "$TOKEN_NAME" "$TOKEN_SYMBOL" $TREASURY_BP)
echo "Calldata: $CALLDATA"
```

**Step 2 — Send via onchainOS:**
```bash
onchainos wallet contract-call \
  --to $FACTORY_ADDR \
  --chain xlayer \
  --input-data $CALLDATA \
  --amt 0 \
  --biz-type dapp \
  --strategy nine527-create-token
```

**Step 3 — Extract the new token address from the emitted event:**
```bash
# Get the transaction hash from the onchainos output, then:
TX_HASH="<tx-hash-from-above>"
RECEIPT=$(cast receipt $TX_HASH --rpc-url $RPC_URL --json)

TOKEN_ADDR=$(echo $RECEIPT | jq -r '.logs[0].topics[1]' | \
  python3 -c "import sys; a=sys.stdin.read().strip(); print('0x'+a[-40:])")
echo "New token address: $TOKEN_ADDR"
```

**Step 4 — Verify the new token:**
```bash
cast call $TOKEN_ADDR \
  "getTokenInfo()(string,string,address,uint256,uint256,uint256,uint256)" \
  --rpc-url $RPC_URL
```

---

## Action: Buy Token

Buys tokens from a deployed nine527 token contract by spending OKB.
> **Note:** `--to` is the **token contract address** (`TOKEN_ADDR`), not the factory.

**Ask the user for:**
| Field | Description | Example |
|-------|-------------|---------|
| `TOKEN_ADDR` | nine527 token contract address | `0x...9527` |
| `OKB_AMOUNT` | OKB to spend (in ether units) | `0.1` |
| `SLIPPAGE_PCT` | Acceptable slippage % | `5` |

**Step 1 — Estimate output:**
```bash
OKB_WEI=$(cast to-wei $OKB_AMOUNT)
ESTIMATED=$(cast call $TOKEN_ADDR \
  "estimateBuyReturn(uint256)(uint256)" $OKB_WEI \
  --rpc-url $RPC_URL)
echo "Estimated tokens: $(cast from-wei $ESTIMATED)"
```

**Step 2 — Apply slippage to get minTokenAmt:**
```bash
MIN_TOKEN=$(python3 -c "print(int($ESTIMATED * (100 - $SLIPPAGE_PCT) / 100))")
echo "Min tokens (with ${SLIPPAGE_PCT}% slippage): $MIN_TOKEN"
```

**Step 3 — Set a deadline (10 min from now):**
```bash
DEADLINE=$(( $(date +%s) + 600 ))
```

**Step 4 — Encode calldata:**
```bash
CALLDATA=$(cast calldata "buyToken(uint256,uint256)" $MIN_TOKEN $DEADLINE)
```

**Step 5 — Send via onchainOS (attach OKB value in wei):**
```bash
onchainos wallet contract-call \
  --to $TOKEN_ADDR \
  --chain xlayer \
  --input-data $CALLDATA \
  --amt $OKB_WEI \
  --biz-type dapp \
  --strategy nine527-buy-token
```

**Step 6 — Confirm balance:**
```bash
MY_ADDR=$(onchainos wallet addresses | grep -i "xlayer" -A2 | grep "0x" | head -1 | tr -d ' ')
BALANCE=$(cast call $TOKEN_ADDR "balanceOf(address)(uint256)" $MY_ADDR --rpc-url $RPC_URL)
echo "Token balance: $(cast from-wei $BALANCE)"
```

---

## Action: Sell Token

Sells nine527 tokens back for OKB.
> **Note:** `--to` is the **token contract address** (`TOKEN_ADDR`), not the factory.

**Ask the user for:**
| Field | Description | Example |
|-------|-------------|---------|
| `TOKEN_ADDR` | nine527 token contract address | `0x...9527` |
| `SELL_PERCENT` | % of balance to sell (1–100) | `50` |
| `SLIPPAGE_PCT` | Acceptable slippage % | `5` |

**Step 1 — Check current balance:**
```bash
MY_ADDR=$(onchainos wallet addresses | grep -i "xlayer" -A2 | grep "0x" | head -1 | tr -d ' ')
BALANCE=$(cast call $TOKEN_ADDR "balanceOf(address)(uint256)" $MY_ADDR --rpc-url $RPC_URL)
echo "Current balance: $(cast from-wei $BALANCE) tokens"
```

**Step 2 — Calculate sell amount:**
```bash
SELL_AMT=$(python3 -c "print(int($BALANCE * $SELL_PERCENT / 100))")
echo "Selling: $(cast from-wei $SELL_AMT) tokens"
```

**Step 3 — Estimate OKB return:**
```bash
ESTIMATED_OKB=$(cast call $TOKEN_ADDR \
  "estimateSellReturn(uint256)(uint256)" $SELL_AMT \
  --rpc-url $RPC_URL)
echo "Estimated OKB: $(cast from-wei $ESTIMATED_OKB)"
```

**Step 4 — Apply slippage to get minOkbAmt:**
```bash
MIN_OKB=$(python3 -c "print(int($ESTIMATED_OKB * (100 - $SLIPPAGE_PCT) / 100))")
echo "Min OKB (with ${SLIPPAGE_PCT}% slippage): $(cast from-wei $MIN_OKB)"
```

**Step 5 — Set a deadline (10 min from now):**
```bash
DEADLINE=$(( $(date +%s) + 600 ))
```

**Step 6 — Encode calldata:**
```bash
CALLDATA=$(cast calldata "sellToken(uint256,uint256,uint256)" $SELL_AMT $MIN_OKB $DEADLINE)
```

**Step 7 — Send via onchainOS (no OKB value needed for sell):**
```bash
onchainos wallet contract-call \
  --to $TOKEN_ADDR \
  --chain xlayer \
  --input-data $CALLDATA \
  --amt 0 \
  --biz-type dapp \
  --strategy nine527-sell-token
```

**Step 8 — Confirm OKB balance:**
```bash
onchainos wallet balance --chain xlayer
```

---

## Utility: Check Token Price & Info

```bash
# Full token info
cast call $TOKEN_ADDR \
  "getTokenInfo()(string,string,address,uint256,uint256,uint256,uint256)" \
  --rpc-url $RPC_URL

# Current price in OKB per token (18-decimal fixed point)
cast call $TOKEN_ADDR "getTokenPrice()(uint256)" --rpc-url $RPC_URL

# OKB and token reserves
cast call $TOKEN_ADDR "getEthReserve()(uint256)" --rpc-url $RPC_URL
cast call $TOKEN_ADDR "getTokenReserve()(uint256)" --rpc-url $RPC_URL
```

---

## Contract Constants (for reference)

| Constant | Value | Meaning |
|----------|-------|---------|
| `INITIAL_VIRTUAL_ETH` | 21 OKB | Virtual OKB in the AMM at launch |
| `INITIAL_TOKEN_RESERVE` | 1,000,000,000 tokens | Total supply, all in reserve |
| `MAX_TREASURY_BP` | 300 | Max sell fee = 3% |
| `SELL_BURN_BP` | 0 | No burn on sell |
| `TRANSFER_BURN_BP` | 0 | No burn on transfer |
| Anti-bot | Level 0 | No checks (ERC-4337 / smart contract wallet compatible) |

---

## onchainOS Wallet Reference

| Command | Purpose |
|---------|---------|
| `onchainos wallet status` | Check login status |
| `onchainos wallet addresses` | Show your X Layer address |
| `onchainos wallet balance --chain xlayer` | Show OKB balance |
| `onchainos wallet contract-call --to <ADDR> --chain xlayer --input-data <HEX> --amt <WEI>` | Send a contract transaction |
| `onchainos gateway gas --chain xlayer` | Check current gas prices |
