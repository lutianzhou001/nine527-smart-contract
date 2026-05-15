#!/bin/bash

# ============================================================================
# nine527Factory Deployment Script for X Layer (OKX Layer 2)
# Chain ID: 196 (mainnet) / 195 (testnet)
# Native token: OKB
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# EIP-2470 Singleton Factory (already deployed on X Layer)
SINGLETON_FACTORY="0xce0042B868300000d44A59004Da54A005ffdcf9f"

# X Layer RPC URLs
XLAYER_MAINNET_RPC="https://rpc.xlayer.tech"
XLAYER_TESTNET_RPC="https://testrpc.xlayer.tech"

# OKLink explorer API for contract verification
OKLINK_MAINNET_VERIFIER_URL="https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER"
OKLINK_TESTNET_VERIFIER_URL="https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER_TESTNET"

echo -e "${CYAN}"
echo "============================================================"
echo "   nine527 Factory Deployment - X Layer (OKX L2)"
echo "============================================================"
echo -e "${NC}"

# Parse arguments
NETWORK="${1:-testnet}"
PRIVATE_KEY="${2:-}"
OKLINK_API_KEY="${3:-}"

if [ "$NETWORK" == "mainnet" ]; then
    RPC_URL="$XLAYER_MAINNET_RPC"
    CHAIN_ID=196
    EXPLORER_URL="https://www.oklink.com/xlayer"
    VERIFIER_URL="$OKLINK_MAINNET_VERIFIER_URL"
    echo -e "${YELLOW}Network: X Layer Mainnet (Chain ID: 196)${NC}"
elif [ "$NETWORK" == "testnet" ]; then
    RPC_URL="$XLAYER_TESTNET_RPC"
    CHAIN_ID=195
    EXPLORER_URL="https://www.oklink.com/xlayer-test"
    VERIFIER_URL="$OKLINK_TESTNET_VERIFIER_URL"
    echo -e "${YELLOW}Network: X Layer Testnet (Chain ID: 195)${NC}"
else
    RPC_URL="$NETWORK"
    CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "unknown")
    EXPLORER_URL="https://www.oklink.com/xlayer"
    VERIFIER_URL="$OKLINK_MAINNET_VERIFIER_URL"
    echo -e "${YELLOW}Network: Custom RPC - $RPC_URL (Chain ID: $CHAIN_ID)${NC}"
fi

echo ""

# Check for required tools
if ! command -v forge &> /dev/null; then
    echo -e "${RED}Error: 'forge' not found. Install Foundry: https://getfoundry.sh${NC}"
    exit 1
fi

if ! command -v cast &> /dev/null; then
    echo -e "${RED}Error: 'cast' not found. Install Foundry: https://getfoundry.sh${NC}"
    exit 1
fi

# Step 1: Check Singleton Factory
echo -e "${CYAN}Step 1: Checking EIP-2470 Singleton Factory...${NC}"
CODE=$(cast code $SINGLETON_FACTORY --rpc-url $RPC_URL 2>/dev/null || echo "0x")

if [ "$CODE" == "0x" ] || [ -z "$CODE" ]; then
    echo -e "${RED}Singleton Factory not deployed on this network!${NC}"
    echo ""
    echo "Deploy it by funding the single-use deployer account:"
    echo "  Address: 0xBb6e024b9cFFACB947A71991E386681B1Cd1477D"
    echo "  Amount:  0.0247 OKB"
    echo ""
    echo "Then broadcast the raw deployment tx:"
    echo "  cast publish --rpc-url $RPC_URL \\"
    echo "    0xf9016c8085174876e8008303c4d88080b90154608060405234801561001057600080fd5b50610134806100206000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80634af63f0214602d575b600080fd5b60cf60048036036040811015604157600080fd5b810190602081018135640100000000811115605b57600080fd5b820183602082011115606c57600080fd5b80359060200191846001830284011164010000000083111715608d57600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600092019190915250929550509135925060eb915050565b604080516001600160a01b039092168252519081900360200190f35b6000818351602085016000f5939250505056fea26469706673582212206b44f8a82cb6b156bfcc3dc6aadd6df4eefd204bc928a4397fd15dacf6d5320564736f6c634300060200331b83247000822470"
    exit 1
fi

echo -e "${GREEN}✓ Singleton Factory found at $SINGLETON_FACTORY${NC}"
echo ""

# Step 2: Build contracts
echo -e "${CYAN}Step 2: Building contracts...${NC}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
forge build --quiet
echo -e "${GREEN}✓ Contracts compiled${NC}"
echo ""

# Step 3: Calculate predicted factory address
echo -e "${CYAN}Step 3: Calculating deterministic address...${NC}"
PREDICTED=$(forge script script/DeployNine527Factory.s.sol:Deploynine527FactoryScript \
    --rpc-url $RPC_URL \
    --sig "getPredictedAddress()(address)" 2>/dev/null | tail -1 || echo "")

if [ -n "$PREDICTED" ]; then
    echo -e "Predicted Factory Address: ${GREEN}$PREDICTED${NC}"

    EXISTING_CODE=$(cast code $PREDICTED --rpc-url $RPC_URL 2>/dev/null || echo "0x")
    if [ "$EXISTING_CODE" != "0x" ] && [ -n "$EXISTING_CODE" ]; then
        echo -e "${GREEN}✓ nine527Factory already deployed at $PREDICTED${NC}"
        echo ""
        echo "Explorer: $EXPLORER_URL/address/$PREDICTED"
        exit 0
    fi
else
    echo -e "${YELLOW}Could not calculate predicted address, will deploy anyway...${NC}"
fi

echo ""

# Step 4: Deploy
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${YELLOW}No private key provided. Dry-run complete.${NC}"
    echo ""
    echo "To deploy, run:"
    echo "  ./script/deploy-nine527-xlayer.sh $NETWORK YOUR_PRIVATE_KEY [OKLINK_API_KEY]"
    echo ""
    echo "Or use forge directly:"
    echo "  forge script script/DeployNine527Factory.s.sol:Deploynine527FactoryScript \\"
    echo "    --rpc-url $RPC_URL \\"
    echo "    --private-key YOUR_PRIVATE_KEY \\"
    echo "    --broadcast"
    echo ""
    exit 0
fi

echo -e "${CYAN}Step 4: Deploying nine527Factory to X Layer...${NC}"

forge script script/DeployNine527Factory.s.sol:Deploynine527FactoryScript \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast

echo ""
echo -e "${GREEN}"
echo "============================================================"
echo "   ✓ DEPLOYMENT COMPLETE!"
echo "============================================================"
echo -e "${NC}"

# Verify deployment
if [ -n "$PREDICTED" ]; then
    echo "Verifying deployment..."
    sleep 5
    FINAL_CODE=$(cast code $PREDICTED --rpc-url $RPC_URL 2>/dev/null || echo "0x")
    if [ "$FINAL_CODE" != "0x" ] && [ -n "$FINAL_CODE" ]; then
        echo -e "${GREEN}✓ nine527Factory confirmed at $PREDICTED${NC}"
        echo ""
        echo "Explorer: $EXPLORER_URL/address/$PREDICTED"
    fi
fi

# Step 5: Verify source code (open source)
echo ""
if [ -n "$OKLINK_API_KEY" ] && [ -n "$PREDICTED" ]; then
    echo -e "${CYAN}Step 5: Verifying source code on OKLink (open sourcing)...${NC}"

    # Verify nine527Factory
    forge verify-contract \
        --chain-id $CHAIN_ID \
        --verifier etherscan \
        --verifier-url "$VERIFIER_URL" \
        --etherscan-api-key "$OKLINK_API_KEY" \
        --compiler-version 0.8.20 \
        --num-of-optimizations 1 \
        $PREDICTED \
        src/nine527Factory.sol:nine527Factory \
        && echo -e "${GREEN}✓ nine527Factory source verified${NC}" \
        || echo -e "${YELLOW}Factory verification failed — try manually on OKLink${NC}"

    echo ""
else
    echo -e "${YELLOW}To open-source (verify) the contracts on OKLink:${NC}"
    echo ""
    echo "1. Get an OKLink API key at: https://www.oklink.com/account/my-api"
    echo ""
    echo "2. Verify nine527Factory:"
    echo "   forge verify-contract \\"
    echo "     --chain-id $CHAIN_ID \\"
    echo "     --verifier etherscan \\"
    echo "     --verifier-url \"$VERIFIER_URL\" \\"
    echo "     --etherscan-api-key YOUR_OKLINK_API_KEY \\"
    echo "     --compiler-version 0.8.20 \\"
    echo "     --num-of-optimizations 1 \\"
    echo "     $PREDICTED \\"
    echo "     src/nine527Factory.sol:nine527Factory"
    echo ""
    echo "3. Verify nine527 token implementation — use the address of any deployed token."
    echo ""
fi

echo "Next steps:"
echo "  1. Update your frontend with the factory address: $PREDICTED"
echo "  2. Verify contracts on OKLink for open-source visibility"
echo "  3. Create your first meme token via the factory!"
echo ""
