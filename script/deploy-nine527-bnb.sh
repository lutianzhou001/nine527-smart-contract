#!/bin/bash

# ============================================================================
# nine527Factory Deployment Script for BNB Chain
# Uses EIP-2470 Singleton Factory for deterministic addresses
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# EIP-2470 Singleton Factory
SINGLETON_FACTORY="0xce0042B868300000d44A59004Da54A005ffdcf9f"

# BNB Chain RPC URLs
BNB_MAINNET_RPC="https://bsc-dataseed.binance.org/"
BNB_TESTNET_RPC="https://data-seed-prebsc-1-s1.binance.org:8545/"

echo -e "${CYAN}"
echo "============================================================"
echo "   nine527 Factory Deployment - BNB Chain"
echo "============================================================"
echo -e "${NC}"

# Parse arguments
NETWORK="${1:-testnet}"
PRIVATE_KEY="${2:-}"

if [ "$NETWORK" == "mainnet" ]; then
    RPC_URL="$BNB_MAINNET_RPC"
    echo -e "${YELLOW}Network: BNB Mainnet${NC}"
elif [ "$NETWORK" == "testnet" ]; then
    RPC_URL="$BNB_TESTNET_RPC"
    echo -e "${YELLOW}Network: BNB Testnet${NC}"
else
    RPC_URL="$NETWORK"
    echo -e "${YELLOW}Network: Custom RPC - $RPC_URL${NC}"
fi

echo ""

# Check for required tools
if ! command -v forge &> /dev/null; then
    echo -e "${RED}Error: 'forge' command not found. Please install Foundry.${NC}"
    exit 1
fi

if ! command -v cast &> /dev/null; then
    echo -e "${RED}Error: 'cast' command not found. Please install Foundry.${NC}"
    exit 1
fi

# Step 1: Check if Singleton Factory exists
echo -e "${CYAN}Step 1: Checking Singleton Factory...${NC}"
CODE=$(cast code $SINGLETON_FACTORY --rpc-url $RPC_URL 2>/dev/null || echo "0x")

if [ "$CODE" == "0x" ] || [ -z "$CODE" ]; then
    echo -e "${RED}Singleton Factory not deployed on this network!${NC}"
    echo ""
    echo "Please deploy it first using:"
    echo "  ./deploy-singleton-bnb.sh $NETWORK YOUR_PRIVATE_KEY"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ Singleton Factory found at $SINGLETON_FACTORY${NC}"
echo ""

# Step 2: Calculate predicted address
echo -e "${CYAN}Step 2: Calculating deterministic address...${NC}"

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# Build the contracts first
echo "Building contracts..."
forge build --quiet

# Calculate predicted address using the script
PREDICTED=$(forge script script/Deploynine527Factory.s.sol:Deploynine527FactoryScript \
    --rpc-url $RPC_URL \
    --sig "getPredictedAddress()(address)" 2>/dev/null | tail -1 || echo "")

if [ -z "$PREDICTED" ]; then
    echo -e "${YELLOW}Could not calculate predicted address, will deploy anyway...${NC}"
else
    echo -e "Predicted Address: ${GREEN}$PREDICTED${NC}"
    
    # Check if already deployed
    EXISTING_CODE=$(cast code $PREDICTED --rpc-url $RPC_URL 2>/dev/null || echo "0x")
    
    if [ "$EXISTING_CODE" != "0x" ] && [ -n "$EXISTING_CODE" ]; then
        echo -e "${GREEN}✓ nine527Factory already deployed at $PREDICTED${NC}"
        echo ""
        exit 0
    fi
fi

echo ""

# Step 3: Deploy
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${YELLOW}No private key provided.${NC}"
    echo ""
    echo "To deploy nine527Factory, run:"
    echo "  ./deploy-nine527-bnb.sh $NETWORK YOUR_PRIVATE_KEY"
    echo ""
    echo "Or deploy directly with forge:"
    echo "  forge script script/Deploynine527Factory.s.sol:Deploynine527FactoryScript \\"
    echo "    --rpc-url $RPC_URL \\"
    echo "    --private-key YOUR_PRIVATE_KEY \\"
    echo "    --broadcast"
    echo ""
    exit 0
fi

echo -e "${CYAN}Step 3: Deploying nine527Factory...${NC}"

forge script script/Deploynine527Factory.s.sol:Deploynine527FactoryScript \
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
        echo -e "${GREEN}✓ nine527Factory verified at $PREDICTED${NC}"
    fi
fi

echo ""
echo "Next steps:"
echo "1. Update frontend/src/config/wagmi.ts with the factory address"
echo "2. Deploy tokens using the factory!"
echo ""

