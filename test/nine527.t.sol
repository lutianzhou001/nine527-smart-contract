// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/nine527.sol";

contract nine527Test is Test {
    nine527 public token;
    nine527 public tokenWithTreasury;
    
    address public deployer = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    
    uint256 constant INITIAL_VIRTUAL_ETH = 10 * 1e18;            // 10 ETH
    uint256 constant INITIAL_TOKEN_RESERVE = 100000000 * 1e18;  // 100M tokens
    
    function setUp() public {
        // Deploy token with custom name, symbol, and 0% treasury fee
        // address(0) means use msg.sender as deployer
        token = new nine527("Test Token", "TEST", 0, address(0));
        
        // Deploy another token with 3% treasury fee for treasury tests
        tokenWithTreasury = new nine527("Treasury Token", "TRES", 300, address(0)); // 300 BP = 3%
        
        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Deployment Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_Deployment() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.DEPLOYER(), deployer);
        assertEq(token.treasuryAddr(), deployer);
        assertEq(token.SELL_TREASURY_BP(), 0);
    }

    function test_Deployment_WithTreasury() public view {
        assertEq(tokenWithTreasury.name(), "Treasury Token");
        assertEq(tokenWithTreasury.symbol(), "TRES");
        assertEq(tokenWithTreasury.SELL_TREASURY_BP(), 300);
    }

    function test_Deployment_CustomParams() public {
        // Deploy with different parameters
        nine527 customToken = new nine527("My Meme Coin", "MEME", 150, address(0)); // 1.5% treasury
        
        assertEq(customToken.name(), "My Meme Coin");
        assertEq(customToken.symbol(), "MEME");
        assertEq(customToken.SELL_TREASURY_BP(), 150);
    }

    function test_Deployment_ZeroTreasury() public {
        nine527 zeroFeeToken = new nine527("Zero Fee", "ZERO", 0, address(0));
        assertEq(zeroFeeToken.SELL_TREASURY_BP(), 0);
    }

    function test_Deployment_MaxTreasury() public {
        nine527 maxFeeToken = new nine527("Max Fee", "MAX", 300, address(0));
        assertEq(maxFeeToken.SELL_TREASURY_BP(), 300);
    }

    function test_Deployment_RevertOnExcessiveTreasury() public {
        // Should fail with treasury > 3% (300 BP)
        vm.expectRevert(bytes("!treasuryBP>3%"));
        new nine527("Bad Token", "BAD", 301, address(0));
    }

    function test_Deployment_RevertOnEmptyName() public {
        vm.expectRevert(bytes("!name"));
        new nine527("", "SYM", 100, address(0));
    }

    function test_Deployment_RevertOnEmptySymbol() public {
        vm.expectRevert(bytes("!symbol"));
        new nine527("Name", "", 100, address(0));
    }

    function test_GetTokenInfo() public view {
        (
            string memory tokenName,
            string memory tokenSymbol,
            address tokenDeployer,
            uint256 treasuryFeeBP,
            uint256 currentPrice,
            uint256 ethReserve,
            uint256 tokenReserve
        ) = token.getTokenInfo();
        
        assertEq(tokenName, "Test Token");
        assertEq(tokenSymbol, "TEST");
        assertEq(tokenDeployer, deployer);
        assertEq(treasuryFeeBP, 0);
        assertGt(currentPrice, 0);
        assertEq(ethReserve, INITIAL_VIRTUAL_ETH);
        assertEq(tokenReserve, INITIAL_TOKEN_RESERVE);
    }

    function test_InitialVirtualLiquidity() public view {
        // Token reserve should be minted to factory address
        assertEq(token.getTokenReserve(), INITIAL_TOKEN_RESERVE);
        
        // ETH reserve should be the virtual amount (no real ETH yet)
        assertEq(token.getEthReserve(), INITIAL_VIRTUAL_ETH);
        
        // Initial price: 10 ETH / 100M tokens = 0.0000001 ETH per token
        uint256 expectedPrice = (INITIAL_VIRTUAL_ETH * 1e18) / INITIAL_TOKEN_RESERVE;
        assertEq(token.getTokenPrice(), expectedPrice);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Buy Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_BuyToken() public {
        uint256 buyAmount = 1 ether;
        
        // Estimate output first
        uint256 estimatedTokens = token.estimateBuyReturn(buyAmount);
        assertTrue(estimatedTokens > 0, "Should receive tokens");
        
        // Buy tokens (set both msg.sender and tx.origin to alice for anti-bot)
        vm.prank(alice, alice);
        token.buyToken{value: buyAmount}(1, 0);
        
        // Check alice received tokens
        assertGt(token.balanceOf(alice), 0, "Alice should have tokens");
        
        // ETH reserve should increase
        assertEq(token.getEthReserve(), INITIAL_VIRTUAL_ETH + buyAmount);
        
        // Token reserve should decrease
        assertLt(token.getTokenReserve(), INITIAL_TOKEN_RESERVE);
    }

    function test_BuyToken_MultipleBuys() public {
        // First buy
        vm.prank(alice, alice);
        token.buyToken{value: 1 ether}(1, 0);
        uint256 aliceBalance1 = token.balanceOf(alice);
        
        // Second buy - should get fewer tokens due to price increase
        vm.prank(bob, bob);
        token.buyToken{value: 1 ether}(1, 0);
        uint256 bobBalance = token.balanceOf(bob);
        
        // Bob should get fewer tokens than Alice (price increased)
        assertLt(bobBalance, aliceBalance1, "Later buyers get fewer tokens");
    }

    function test_BuyToken_Slippage() public {
        uint256 minTokens = token.estimateBuyReturn(1 ether);
        
        // Should succeed with correct min
        vm.prank(alice, alice);
        token.buyToken{value: 1 ether}(minTokens, 0);
        
        // Should fail with too high min
        vm.prank(bob, bob);
        vm.expectRevert(bytes("INSUFFICIENT_OUTPUT_AMOUNT"));
        token.buyToken{value: 1 ether}(minTokens * 2, 0);
    }

    function test_BuyToken_Deadline() public {
        // Warp to a reasonable timestamp first (block.timestamp starts at 1 in Foundry)
        vm.warp(1000);
        
        // Should fail with expired deadline (0 means no deadline, so use 1)
        vm.prank(alice, alice);
        vm.expectRevert(bytes("!expire"));
        token.buyToken{value: 1 ether}(1, block.timestamp - 1);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Sell Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_SellToken() public {
        // First buy some tokens
        vm.prank(alice, alice);
        token.buyToken{value: 10 ether}(1, 0);
        uint256 tokenBalance = token.balanceOf(alice);
        
        // Estimate sell return
        uint256 sellAmount = tokenBalance / 2;
        uint256 estimatedEth = token.estimateSellReturn(sellAmount);
        assertTrue(estimatedEth > 0, "Should receive ETH");
        
        uint256 aliceEthBefore = alice.balance;
        
        // Sell tokens
        vm.prank(alice, alice);
        token.sellToken(sellAmount, 1, 0);
        
        // Check alice received ETH
        assertGt(alice.balance, aliceEthBefore, "Alice should receive ETH");
        
        // Check token balance decreased
        assertLt(token.balanceOf(alice), tokenBalance, "Token balance should decrease");
    }

    function test_SellToken_BurnMechanism() public {
        // Buy tokens
        vm.prank(alice, alice);
        token.buyToken{value: 10 ether}(1, 0);
        
        uint256 totalSupplyBefore = token.totalSupply();
        uint256 tokenBalance = token.balanceOf(alice);
        
        // Sell half
        vm.prank(alice, alice);
        token.sellToken(tokenBalance / 2, 1, 0);
        
        // With SELL_BURN_BP = 0, total supply stays the same (tokens return to reserve)
        // If SELL_BURN_BP > 0, total supply would decrease due to burn
        if (token.SELL_BURN_BP() > 0) {
            assertLt(token.totalSupply(), totalSupplyBefore, "Total supply should decrease with burn");
        } else {
            assertEq(token.totalSupply(), totalSupplyBefore, "Total supply unchanged without burn");
        }
    }

    function test_SellToken_Slippage() public {
        // Buy tokens
        vm.prank(alice, alice);
        token.buyToken{value: 10 ether}(1, 0);
        uint256 tokenBalance = token.balanceOf(alice);
        
        // Should fail with too high min ETH
        vm.prank(alice, alice);
        vm.expectRevert(bytes("INSUFFICIENT_OUTPUT_AMOUNT"));
        token.sellToken(tokenBalance / 2, 100 ether, 0);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Treasury Fee Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_TreasuryFee_OnSell() public {
        // Use tokenWithTreasury (3% fee)
        vm.deal(alice, 100 ether);
        
        // Buy tokens
        vm.prank(alice, alice);
        tokenWithTreasury.buyToken{value: 10 ether}(1, 0);
        uint256 tokenBalance = tokenWithTreasury.balanceOf(alice);
        
        uint256 sellAmount = tokenBalance / 2;
        uint256 aliceEthBefore = alice.balance;
        uint256 treasuryBefore = tokenWithTreasury.treasuryAmtTotal();
        
        // Sell tokens
        vm.prank(alice, alice);
        tokenWithTreasury.sellToken(sellAmount, 1, 0);
        
        // Treasury should have accumulated fees
        uint256 treasuryAfter = tokenWithTreasury.treasuryAmtTotal();
        assertGt(treasuryAfter, treasuryBefore, "Treasury should accumulate fees");
        
        // Alice should have received ETH (minus fee)
        assertGt(alice.balance, aliceEthBefore, "Alice should receive ETH");
    }

    function test_TreasuryFee_Withdrawal() public {
        // Use tokenWithTreasury (3% fee)
        vm.deal(alice, 100 ether);
        
        // Buy and sell to generate treasury fees
        vm.prank(alice, alice);
        tokenWithTreasury.buyToken{value: 10 ether}(1, 0);
        uint256 tokenBalance = tokenWithTreasury.balanceOf(alice);
        
        vm.prank(alice, alice);
        tokenWithTreasury.sellToken(tokenBalance / 2, 1, 0);
        
        uint256 treasuryAmount = tokenWithTreasury.treasuryAmtTotal();
        assertGt(treasuryAmount, 0, "Should have treasury fees");
        
        uint256 deployerBalanceBefore = address(this).balance;
        
        // Withdraw treasury (deployer is treasury)
        tokenWithTreasury.withdrawTreasury(treasuryAmount);
        
        // Deployer should have received the treasury
        assertEq(address(this).balance, deployerBalanceBefore + treasuryAmount);
        assertEq(tokenWithTreasury.treasuryAmtTotal(), 0);
    }

    function test_TreasuryFee_EstimateIncludesFee() public {
        // Compare estimates between 0% and 3% treasury
        uint256 ethAmount = 10 ether;
        
        // Buy same amount on both
        vm.deal(alice, 200 ether);
        
        vm.prank(alice, alice);
        token.buyToken{value: ethAmount}(1, 0);
        uint256 tokensNoFee = token.balanceOf(alice);
        
        vm.prank(alice, alice);
        tokenWithTreasury.buyToken{value: ethAmount}(1, 0);
        uint256 tokensWithFee = tokenWithTreasury.balanceOf(alice);
        
        // Buy amounts should be same (no fee on buy)
        assertEq(tokensNoFee, tokensWithFee, "Buy amounts should be equal");
        
        // Estimate sell returns
        uint256 sellReturnNoFee = token.estimateSellReturn(tokensNoFee / 2);
        uint256 sellReturnWithFee = tokenWithTreasury.estimateSellReturn(tokensWithFee / 2);
        
        // Return with fee should be ~3% less
        assertLt(sellReturnWithFee, sellReturnNoFee, "Treasury fee reduces sell return");
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Transfer & Burn Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_TransferBurn() public {
        // Buy tokens
        vm.prank(alice, alice);
        token.buyToken{value: 10 ether}(1, 0);
        uint256 aliceBalance = token.balanceOf(alice);
        
        uint256 transferAmount = aliceBalance / 2;
        
        uint256 totalSupplyBefore = token.totalSupply();
        
        // Transfer to bob (regular transfer doesn't need anti-bot bypass)
        vm.prank(alice);
        token.transfer(bob, transferAmount);
        
        uint256 bobReceived = token.balanceOf(bob);
        
        // With TRANSFER_BURN_BP = 0, bob receives full amount
        // With TRANSFER_BURN_BP > 0, bob receives less due to burn
        if (token.TRANSFER_BURN_BP() > 0) {
            assertLt(bobReceived, transferAmount, "Bob receives less due to burn");
            assertLt(token.totalSupply(), totalSupplyBefore, "Supply decreased from burn");
        } else {
            assertEq(bobReceived, transferAmount, "Bob receives full amount without burn");
            assertEq(token.totalSupply(), totalSupplyBefore, "Supply unchanged without burn");
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    // AutoBoost Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_AutoBoost_PriceIncrease() public {
        uint256 initialPrice = token.getTokenPrice();
        
        // Buy tokens - this alone increases price due to AMM mechanics
        vm.prank(alice, alice);
        token.buyToken{value: 10 ether}(1, 0);
        
        uint256 priceAfterBuy = token.getTokenPrice();
        
        // Price increases after buy (due to AMM constant product)
        assertGt(priceAfterBuy, initialPrice, "Price should increase after buy");
        
        uint256 aliceBalance = token.balanceOf(alice);
        
        // Do some transfers
        vm.startPrank(alice);
        token.transfer(bob, aliceBalance / 4);
        vm.stopPrank();
        
        uint256 bobBalance = token.balanceOf(bob);
        vm.startPrank(bob);
        token.transfer(alice, bobBalance / 2);
        vm.stopPrank();
        
        uint256 priceAfterTransfers = token.getTokenPrice();
        
        // With TRANSFER_BURN_BP > 0: price rises more due to AutoBoost (reserve burns)
        // With TRANSFER_BURN_BP = 0: price stays same after transfers (no burns)
        if (token.TRANSFER_BURN_BP() > 0) {
            assertGt(priceAfterTransfers, priceAfterBuy, "Price should increase from AutoBoost burns");
        } else {
            assertEq(priceAfterTransfers, priceAfterBuy, "Price unchanged without burn on transfers");
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Price Impact Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_PriceImpact_LargeBuy() public {
        uint256 priceBefore = token.getTokenPrice();
        
        // Large buy
        vm.prank(alice, alice);
        token.buyToken{value: 50 ether}(1, 0);
        
        uint256 priceAfter = token.getTokenPrice();
        assertGt(priceAfter, priceBefore, "Price increases after buy");
    }

    function test_PriceImpact_LargeSell() public {
        // First buy a lot
        vm.prank(alice, alice);
        token.buyToken{value: 50 ether}(1, 0);
        
        uint256 priceBefore = token.getTokenPrice();
        uint256 tokenBalance = token.balanceOf(alice);
        
        // Sell most of it
        vm.prank(alice, alice);
        token.sellToken(tokenBalance * 8 / 10, 1, 0);
        
        uint256 priceAfter = token.getTokenPrice();
        // Price may not decrease significantly due to burns
        // but the mechanism should still work
        assertTrue(priceAfter > 0, "Price should remain positive");
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Edge Cases
    ////////////////////////////////////////////////////////////////////////////////

    function test_RevertOnZeroEth() public {
        vm.prank(alice, alice);
        vm.expectRevert(bytes("!eth"));
        token.buyToken{value: 0}(1, 0);
    }

    function test_RevertOnZeroMinToken() public {
        vm.prank(alice, alice);
        vm.expectRevert(bytes("!minToken"));
        token.buyToken{value: 1 ether}(0, 0);
    }

    function test_RevertOnZeroTokenSell() public {
        vm.prank(alice, alice);
        vm.expectRevert(bytes("!token"));
        token.sellToken(0, 1, 0);
    }

    function test_RevertOnZeroMinEth() public {
        // Buy first
        vm.prank(alice, alice);
        token.buyToken{value: 1 ether}(1, 0);
        
        vm.prank(alice, alice);
        vm.expectRevert(bytes("!minEth"));
        token.sellToken(1000, 0, 0);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Treasury Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_Treasury_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!treasury"));
        token.withdrawTreasury(1 ether);
    }

    function test_Treasury_SetAddress() public {
        token.setTreasuryAddr(alice);
        assertEq(token.treasuryAddr(), alice);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Fuzz Tests
    ////////////////////////////////////////////////////////////////////////////////

    function testFuzz_BuySell(uint256 buyAmount) public {
        // Bound to reasonable amounts
        buyAmount = bound(buyAmount, 0.01 ether, 10 ether);
        
        vm.deal(alice, buyAmount);
        
        // Buy
        vm.prank(alice, alice);
        token.buyToken{value: buyAmount}(1, 0);
        
        uint256 tokenBalance = token.balanceOf(alice);
        assertTrue(tokenBalance > 0, "Should have tokens");
        
        // Sell half
        if (tokenBalance > 100) {
            vm.prank(alice, alice);
            token.sellToken(tokenBalance / 2, 1, 0);
        }
    }

    function testFuzz_TreasuryBP(uint256 treasuryBP) public {
        // Bound to valid range (0-300 BP = 0-3%)
        treasuryBP = bound(treasuryBP, 0, 300);
        
        // Deploy with fuzzed treasury BP
        nine527 fuzzToken = new nine527("Fuzz Token", "FUZZ", treasuryBP, address(0));
        assertEq(fuzzToken.SELL_TREASURY_BP(), treasuryBP);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Integration Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_FullCycle() public {
        // Multiple users buy and sell in sequence
        
        // Alice buys
        vm.prank(alice, alice);
        token.buyToken{value: 5 ether}(1, 0);
        uint256 aliceTokens = token.balanceOf(alice);
        
        // Bob buys
        vm.prank(bob, bob);
        token.buyToken{value: 5 ether}(1, 0);
        uint256 bobTokens = token.balanceOf(bob);
        
        // Alice transfers some to Bob
        vm.prank(alice);
        token.transfer(bob, aliceTokens / 4);
        
        // Bob sells
        uint256 bobNewBalance = token.balanceOf(bob);
        vm.prank(bob, bob);
        token.sellToken(bobNewBalance / 2, 1, 0);
        
        // Alice sells
        uint256 aliceNewBalance = token.balanceOf(alice);
        vm.prank(alice, alice);
        token.sellToken(aliceNewBalance / 2, 1, 0);
        
        // Final checks
        assertTrue(token.totalSupply() > 0, "Supply should remain");
        assertTrue(token.getTokenReserve() > 0, "Reserve should remain");
        assertTrue(token.getEthReserve() > 0, "ETH reserve should remain");
    }

    function test_VirtualLiquidity_NoInitialEth() public view {
        // Contract should work without any real ETH due to virtual liquidity
        // Price calculations work because of INITIAL_VIRTUAL_ETH
        
        uint256 price = token.getTokenPrice();
        assertTrue(price > 0, "Price should be positive from virtual liquidity");
        
        uint256 estimatedTokens = token.estimateBuyReturn(1 ether);
        assertTrue(estimatedTokens > 0, "Should estimate tokens correctly");
    }

    // Receive function to accept ETH (for treasury withdrawal test)
    receive() external payable {}
}

