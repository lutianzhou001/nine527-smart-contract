#!/bin/bash

# ============================================================================
# nine527Factory Deployment Script for BNB Chain
# Uses EIP-2470 Singleton Factory for deterministic addresses
#
# Usage:
#   ./deploy-nine527-bnb.sh <network> <admin_address> [private_key]
#
# Examples:
#   ./deploy-nine527-bnb.sh testnet 0xYourAdminAddress
#   ./deploy-nine527-bnb.sh mainnet 0xYourAdminAddress 0xYourPrivateKey
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
ADMIN_ADDRESS="${2:-}"
PRIVATE_KEY="${3:-}"

# Validate admin address
if [ -z "$ADMIN_ADDRESS" ]; then
    echo -e "${RED}Error: Admin address is required!${NC}"
    echo ""
    echo "Usage: ./deploy-nine527-bnb.sh <network> <admin_address> [private_key]"
    echo ""
    echo "Examples:"
    echo "  ./deploy-nine527-bnb.sh testnet 0xYourAdminAddress"
    echo "  ./deploy-nine527-bnb.sh mainnet 0xYourAdminAddress 0xYourPrivateKey"
    echo ""
    exit 1
fi

# Validate admin address format
if [[ ! "$ADMIN_ADDRESS" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo -e "${RED}Error: Invalid admin address format!${NC}"
    echo "Address must be a valid Ethereum address (0x followed by 40 hex characters)"
    exit 1
fi

echo -e "${GREEN}Admin Address: $ADMIN_ADDRESS${NC}"

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

# Step 2: Build contracts
echo -e "${CYAN}Step 2: Building contracts...${NC}"

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

forge build --quiet
echo -e "${GREEN}✓ Contracts built successfully${NC}"
echo ""

# Step 3: Deploy
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${YELLOW}No private key provided.${NC}"
    echo ""
    echo "To deploy nine527Factory, run:"
    echo "  ./deploy-nine527-bnb.sh $NETWORK $ADMIN_ADDRESS YOUR_PRIVATE_KEY"
    echo ""
    echo "Or deploy directly with forge:"
    echo "  ADMIN=$ADMIN_ADDRESS forge script script/DeployNine527Factory.s.sol:Deploynine527FactoryDirectScript \\"
    echo "    --rpc-url $RPC_URL \\"
    echo "    --private-key YOUR_PRIVATE_KEY \\"
    echo "    --broadcast"
    echo ""
    exit 0
fi

echo -e "${CYAN}Step 3: Deploying nine527Factory...${NC}"
echo -e "Admin: ${GREEN}$ADMIN_ADDRESS${NC}"

ADMIN=$ADMIN_ADDRESS forge script script/DeployNine527Factory.s.sol:Deploynine527FactoryDirectScript \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast

echo ""
echo -e "${GREEN}"
echo "============================================================"
echo "   ✓ DEPLOYMENT COMPLETE!"
echo "============================================================"
echo -e "${NC}"

echo ""
echo "Next steps:"
echo "1. Copy the deployed factory address from the output above"
echo "2. Update frontend/src/config/wagmi.ts with the factory address"
echo "3. The admin ($ADMIN_ADDRESS) can now:"
echo "   - Withdraw creation fees: factory.withdrawFees()"
echo "   - Update native prices: factory.setNativePrice(chainId, priceUSDCents)"
echo "   - Change fee recipient: factory.setFeeRecipient(newAddress)"
echo ""

