// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/nine527.sol";
import "../src/nine527Factory.sol";

contract nine527Test is Test {
    nine527 public token;
    nine527 public tokenWithTreasury;
    nine527Factory public factory;
    
    address public deployer = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public admin = address(0xAD1111);
    
    // USD-equivalent virtual native (~$2,600 worth at $3,000/ETH)
    // TARGET_USD_CENTS = 260000, ETH price = 300000 cents
    // virtualNative = (260000 * 1e18) / 300000 = 0.8666... ETH
    uint256 constant VIRTUAL_NATIVE = 866666666666666666; // ~0.867 ETH (260000 * 1e18 / 300000)
    uint256 constant INITIAL_TOKEN_RESERVE = 1000000000 * 1e18; // 1B tokens
    
    function setUp() public {
        // Deploy factory with admin address (for EIP-2470 compatibility)
        factory = new nine527Factory(admin);

        // Deploy token with custom name, symbol, 0% treasury fee, and virtual native
        // address(0) means use msg.sender as deployer
        token = new nine527("Test Token", "TEST", 0, address(0), VIRTUAL_NATIVE);

        // Deploy another token with 3% treasury fee for treasury tests
        tokenWithTreasury = new nine527("Treasury Token", "TRES", 300, address(0), VIRTUAL_NATIVE); // 300 BP = 3%

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(admin, 100 ether);
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
        assertEq(token.INITIAL_VIRTUAL_NATIVE(), VIRTUAL_NATIVE);
    }

    function test_Deployment_WithTreasury() public view {
        assertEq(tokenWithTreasury.name(), "Treasury Token");
        assertEq(tokenWithTreasury.symbol(), "TRES");
        assertEq(tokenWithTreasury.SELL_TREASURY_BP(), 300);
    }

    function test_Deployment_CustomParams() public {
        // Deploy with different parameters
        nine527 customToken = new nine527("My Meme Coin", "MEME", 150, address(0), VIRTUAL_NATIVE); // 1.5% treasury
        
        assertEq(customToken.name(), "My Meme Coin");
        assertEq(customToken.symbol(), "MEME");
        assertEq(customToken.SELL_TREASURY_BP(), 150);
    }

    function test_Deployment_ZeroTreasury() public {
        nine527 zeroFeeToken = new nine527("Zero Fee", "ZERO", 0, address(0), VIRTUAL_NATIVE);
        assertEq(zeroFeeToken.SELL_TREASURY_BP(), 0);
    }

    function test_Deployment_MaxTreasury() public {
        nine527 maxFeeToken = new nine527("Max Fee", "MAX", 300, address(0), VIRTUAL_NATIVE);
        assertEq(maxFeeToken.SELL_TREASURY_BP(), 300);
    }

    function test_Deployment_RevertOnExcessiveTreasury() public {
        // Should fail with treasury > 3% (300 BP)
        vm.expectRevert(bytes("!treasuryBP>3%"));
        new nine527("Bad Token", "BAD", 301, address(0), VIRTUAL_NATIVE);
    }

    function test_Deployment_RevertOnEmptyName() public {
        vm.expectRevert(bytes("!name"));
        new nine527("", "SYM", 100, address(0), VIRTUAL_NATIVE);
    }

    function test_Deployment_RevertOnEmptySymbol() public {
        vm.expectRevert(bytes("!symbol"));
        new nine527("Name", "", 100, address(0), VIRTUAL_NATIVE);
    }
    
    function test_Deployment_RevertOnZeroVirtualNative() public {
        vm.expectRevert(bytes("!virtualNative"));
        new nine527("Bad Token", "BAD", 100, address(0), 0);
    }

    function test_GetTokenInfo() public view {
        (
            string memory tokenName,
            string memory tokenSymbol,
            address tokenDeployer,
            uint256 treasuryFeeBP,
            uint256 currentPrice,
            uint256 nativeReserve,
            uint256 tokenReserve
        ) = token.getTokenInfo();
        
        assertEq(tokenName, "Test Token");
        assertEq(tokenSymbol, "TEST");
        assertEq(tokenDeployer, deployer);
        assertEq(treasuryFeeBP, 0);
        assertGt(currentPrice, 0);
        assertEq(nativeReserve, VIRTUAL_NATIVE);
        assertEq(tokenReserve, INITIAL_TOKEN_RESERVE);
    }

    function test_InitialVirtualLiquidity() public view {
        // Token reserve should be minted to factory address
        assertEq(token.getTokenReserve(), INITIAL_TOKEN_RESERVE);
        
        // Native reserve should be the virtual amount (no real native yet)
        assertEq(token.getEthReserve(), VIRTUAL_NATIVE);
        
        // Initial price calculation
        uint256 expectedPrice = (VIRTUAL_NATIVE * 1e18) / INITIAL_TOKEN_RESERVE;
        assertEq(token.getTokenPrice(), expectedPrice);
    }
    
    function test_VirtualReserveGetter() public view {
        assertEq(token.getVirtualReserve(), VIRTUAL_NATIVE);
    }
    
    function test_NativeReserveGetter() public view {
        // Before any trades, real native reserve is 0
        assertEq(token.getNativeReserve(), 0);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Factory Tests
    ////////////////////////////////////////////////////////////////////////////////

    function test_Factory_Deployment() public view {
        // Verify admin is set as feeRecipient
        assertEq(factory.feeRecipient(), admin);
    }

    function test_Factory_Deployment_RevertOnZeroAdmin() public {
        vm.expectRevert(bytes("!admin"));
        new nine527Factory(address(0));
    }

    function test_Factory_GetVirtualNativeForChain() public view {
        // On mainnet fork or localhost (chainid 31337), should return ~0.867 ETH
        uint256 virtualNative = factory.getVirtualNativeForChain();
        assertGt(virtualNative, 0);
        // Should be approximately 0.867 ETH for ETH-priced chains
        assertApproxEqRel(virtualNative, VIRTUAL_NATIVE, 0.01e18); // 1% tolerance
    }

    function test_Factory_CreateToken() public {
        vm.deal(address(this), 1 ether);

        bytes32 salt = bytes32(uint256(12345));

        address tokenAddr = factory.createToken{value: 0.01 ether}(
            "Test",
            "TST",
            100,
            salt
        );

        assertTrue(tokenAddr != address(0));
        assertTrue(factory.isValidToken(tokenAddr));
        assertEq(factory.totalTokens(), 1);

        nine527 createdToken = nine527(payable(tokenAddr));
        assertEq(createdToken.name(), "Test");
        assertEq(createdToken.DEPLOYER(), address(this));

        // Verify the address matches prediction
        (address predicted, ) = factory.predictAddress("Test", "TST", 100, address(this), salt);
        assertEq(tokenAddr, predicted, "Address should match prediction");
    }

    function test_Factory_CreateTokenAndBuy() public {
        vm.deal(address(this), 2 ether);

        bytes32 salt = bytes32(uint256(67890));

        (address tokenAddr, uint256 tokensReceived) = factory.createTokenAndBuy{value: 1 ether}(
            "Test",
            "TST",
            100,
            salt,
            1 // minTokenAmt
        );

        assertTrue(tokenAddr != address(0));
        assertGt(tokensReceived, 0);

        nine527 createdToken = nine527(payable(tokenAddr));
        assertEq(createdToken.balanceOf(address(this)), tokensReceived);

        // Verify the address matches prediction
        (address predicted, ) = factory.predictAddress("Test", "TST", 100, address(this), salt);
        assertEq(tokenAddr, predicted, "Address should match prediction");
    }

    function test_Factory_CreateTokenSimple() public {
        vm.deal(address(this), 1 ether);

        address tokenAddr = factory.createTokenSimple{value: 0.01 ether}(
            "Simple Token",
            "SIMP",
            100
        );

        assertTrue(tokenAddr != address(0));
        assertTrue(factory.isValidToken(tokenAddr));
    }

    function test_Factory_AccumulatedFees() public {
        vm.deal(address(this), 1 ether);

        // Default fee for unknown chains is 0.01 ether
        uint256 expectedFee = factory.getCreationFee();
        factory.createTokenSimple{value: expectedFee}("Fee Test", "FEE", 100);

        assertEq(factory.accumulatedFees(), expectedFee);
    }

    function test_Factory_WithdrawFees() public {
        vm.deal(address(this), 1 ether);

        // Default fee for unknown chains is 0.01 ether
        uint256 expectedFee = factory.getCreationFee();
        factory.createTokenSimple{value: expectedFee}("Fee Test", "FEE", 100);

        uint256 adminBalanceBefore = admin.balance;

        // Only admin can withdraw
        vm.prank(admin);
        factory.withdrawFees();

        assertEq(factory.accumulatedFees(), 0);
        assertEq(admin.balance, adminBalanceBefore + expectedFee);
    }

    function test_Factory_WithdrawFees_RevertNonAdmin() public {
        vm.deal(address(this), 1 ether);

        uint256 expectedFee = factory.getCreationFee();
        factory.createTokenSimple{value: expectedFee}("Fee Test", "FEE", 100);

        // Non-admin should fail
        vm.prank(alice);
        vm.expectRevert(bytes("!auth"));
        factory.withdrawFees();
    }

    function test_Factory_WithdrawFees_RevertNoFees() public {
        // No fees accumulated, should fail
        vm.prank(admin);
        vm.expectRevert(bytes("!fees"));
        factory.withdrawFees();
    }

    function test_Factory_WithdrawFees_MultipleTimes() public {
        vm.deal(address(this), 10 ether);

        uint256 expectedFee = factory.getCreationFee();

        // Create first token
        factory.createTokenSimple{value: expectedFee}("Token1", "TK1", 100);
        assertEq(factory.accumulatedFees(), expectedFee);

        // Admin withdraws first batch
        uint256 adminBalanceBefore = admin.balance;
        vm.prank(admin);
        factory.withdrawFees();
        assertEq(admin.balance, adminBalanceBefore + expectedFee);
        assertEq(factory.accumulatedFees(), 0);

        // Create second token
        factory.createTokenSimple{value: expectedFee}("Token2", "TK2", 100);
        assertEq(factory.accumulatedFees(), expectedFee);

        // Admin withdraws second batch
        adminBalanceBefore = admin.balance;
        vm.prank(admin);
        factory.withdrawFees();
        assertEq(admin.balance, adminBalanceBefore + expectedFee);
        assertEq(factory.accumulatedFees(), 0);
    }

    function test_Factory_WithdrawFees_AfterMultipleCreations() public {
        vm.deal(address(this), 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        uint256 expectedFee = factory.getCreationFee();

        // Multiple users create tokens
        factory.createTokenSimple{value: expectedFee}("Token1", "TK1", 100);

        vm.prank(alice);
        factory.createTokenSimple{value: expectedFee}("Token2", "TK2", 100);

        vm.prank(bob);
        factory.createTokenSimple{value: expectedFee}("Token3", "TK3", 100);

        // Total fees should be 3x
        assertEq(factory.accumulatedFees(), expectedFee * 3);

        // Admin withdraws all
        uint256 adminBalanceBefore = admin.balance;
        vm.prank(admin);
        factory.withdrawFees();

        assertEq(factory.accumulatedFees(), 0);
        assertEq(admin.balance, adminBalanceBefore + expectedFee * 3);
    }

    function test_Factory_SetFeeRecipient() public {
        address newRecipient = address(0x123456);

        vm.prank(admin);
        factory.setFeeRecipient(newRecipient);

        assertEq(factory.feeRecipient(), newRecipient);
    }

    function test_Factory_SetFeeRecipient_RevertNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!auth"));
        factory.setFeeRecipient(alice);
    }

    function test_Factory_SetFeeRecipient_RevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(bytes("!auth"));
        factory.setFeeRecipient(address(0));
    }

    function test_Factory_SetCreationFee() public {
        uint256 newFee = 0.05 ether;
        uint256 testChainId = 999;

        vm.prank(admin);
        factory.setCreationFee(testChainId, newFee);

        assertEq(factory.creationFee(testChainId), newFee);
    }

    function test_Factory_SetCreationFee_RevertNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!auth"));
        factory.setCreationFee(999, 0.05 ether);
    }

    function test_Factory_SetNativePrice() public {
        vm.prank(admin);
        factory.setNativePrice(999, 50000); // Custom chain at $500
        assertEq(factory.nativePriceUSDCents(999), 50000);
    }

    function test_Factory_SetNativePrice_RevertNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!auth"));
        factory.setNativePrice(999, 50000);
    }

    function test_Factory_SetNativePrice_RevertZeroPrice() public {
        vm.prank(admin);
        vm.expectRevert(bytes("!price"));
        factory.setNativePrice(999, 0);
    }

    function test_Factory_SetNativePricesBatch() public {
        uint256[] memory chainIds = new uint256[](2);
        uint256[] memory prices = new uint256[](2);

        chainIds[0] = 888;
        chainIds[1] = 777;
        prices[0] = 100000; // $1,000
        prices[1] = 200000; // $2,000

        vm.prank(admin);
        factory.setNativePricesBatch(chainIds, prices);

        assertEq(factory.nativePriceUSDCents(888), 100000);
        assertEq(factory.nativePriceUSDCents(777), 200000);
    }

    function test_Factory_SetNativePricesBatch_RevertNonAdmin() public {
        uint256[] memory chainIds = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        chainIds[0] = 888;
        prices[0] = 100000;

        vm.prank(alice);
        vm.expectRevert(bytes("!auth"));
        factory.setNativePricesBatch(chainIds, prices);
    }

    function test_Factory_SetNativePricesBatch_RevertLengthMismatch() public {
        uint256[] memory chainIds = new uint256[](2);
        uint256[] memory prices = new uint256[](1);
        chainIds[0] = 888;
        chainIds[1] = 777;
        prices[0] = 100000;

        vm.prank(admin);
        vm.expectRevert(bytes("!length"));
        factory.setNativePricesBatch(chainIds, prices);
    }

    function test_Factory_SetNativePricesBatch_RevertZeroPrice() public {
        uint256[] memory chainIds = new uint256[](2);
        uint256[] memory prices = new uint256[](2);
        chainIds[0] = 888;
        chainIds[1] = 777;
        prices[0] = 100000;
        prices[1] = 0; // Invalid

        vm.prank(admin);
        vm.expectRevert(bytes("!price"));
        factory.setNativePricesBatch(chainIds, prices);
    }

    function test_Factory_GetInitCodeHash() public view {
        bytes32 hash = factory.getInitCodeHash("Test", "TST", 100, address(this));
        assertTrue(hash != bytes32(0), "Init code hash should not be zero");
    }

    function test_Factory_PredictAddress() public view {
        bytes32 salt = bytes32(uint256(1));
        (address predicted, bool isVanity) = factory.predictAddress("Test", "TST", 100, address(this), salt);
        assertTrue(predicted != address(0), "Predicted address should not be zero");
        // isVanity depends on whether the predicted address ends with 9527
        if (_endsWithNine527(predicted)) {
            assertTrue(isVanity, "Should be marked as vanity");
        } else {
            assertFalse(isVanity, "Should not be marked as vanity");
        }
    }

    function test_Factory_PredictVanityAddress() public view {
        // Test the prediction function correctly identifies vanity addresses
        bytes32 salt = bytes32(uint256(12345));
        (address predicted, bool isVanity) = factory.predictAddress("Test", "TST", 100, address(this), salt);

        assertTrue(predicted != address(0), "Should predict an address");
        // isVanity should match our helper function
        assertEq(isVanity, _endsWithNine527(predicted), "isVanity should match actual check");
    }

    function test_Factory_SaltReuse() public {
        vm.deal(address(this), 2 ether);

        bytes32 salt = bytes32(uint256(99999));

        // First creation should succeed
        factory.createToken{value: 0.01 ether}("Token1", "TK1", 100, salt);

        // Same salt should fail (even with different params)
        vm.expectRevert(bytes("!salt"));
        factory.createToken{value: 0.01 ether}("Token2", "TK2", 100, salt);
    }

    function test_Factory_ReceiveNative() public {
        // Factory should accept native via receive()
        uint256 sendAmount = 1 ether;
        vm.deal(alice, sendAmount);

        uint256 feesBefore = factory.accumulatedFees();

        vm.prank(alice);
        (bool success, ) = address(factory).call{value: sendAmount}("");
        assertTrue(success, "Should accept native");

        assertEq(factory.accumulatedFees(), feesBefore + sendAmount);
    }

    function test_Factory_WithdrawTokenFees() public {
        vm.deal(address(this), 10 ether);

        // Create a token with treasury fee via factory
        bytes32 salt = bytes32(uint256(111222));
        (address tokenAddr, ) = factory.createTokenAndBuy{value: 1 ether}(
            "Treasury",
            "TRES",
            300, // 3% treasury fee
            salt,
            1
        );

        nine527 createdToken = nine527(payable(tokenAddr));

        // Buy and sell to generate factory fees
        vm.deal(alice, 100 ether);
        vm.prank(alice, alice);
        createdToken.buyToken{value: 10 ether}(1, 0);

        uint256 aliceTokens = createdToken.balanceOf(alice);
        vm.prank(alice, alice);
        createdToken.sellToken(aliceTokens / 2, 1, 0);

        // Check factory fees accrued on token
        uint256 factoryFees = createdToken.factoryFeesAccrued();
        assertGt(factoryFees, 0, "Should have factory fees");

        // Admin can withdraw token fees
        uint256 factoryBalanceBefore = address(factory).balance;
        vm.prank(admin);
        factory.withdrawTokenFees(tokenAddr);

        // Factory should have received the fees
        assertEq(address(factory).balance, factoryBalanceBefore + factoryFees);
        assertEq(createdToken.factoryFeesAccrued(), 0);
    }

    function test_Factory_WithdrawTokenFees_RevertNonAdmin() public {
        vm.deal(address(this), 1 ether);
        address tokenAddr = factory.createTokenSimple{value: 0.01 ether}("Test", "TST", 100);

        vm.prank(alice);
        vm.expectRevert(bytes("!auth"));
        factory.withdrawTokenFees(tokenAddr);
    }

    function test_Factory_WithdrawTokenFees_RevertInvalidToken() public {
        vm.prank(admin);
        vm.expectRevert(bytes("!token"));
        factory.withdrawTokenFees(address(0x123));
    }

    // Helper to check if address ends with 9527 (0x9527)
    function _endsWithNine527(address addr) internal pure returns (bool) {
        return (uint160(addr) & 0xFFFF) == 0x9527;
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
        
        // Native reserve should increase
        assertEq(token.getEthReserve(), VIRTUAL_NATIVE + buyAmount);
        
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
        uint256 estimatedNative = token.estimateSellReturn(sellAmount);
        assertTrue(estimatedNative > 0, "Should receive native");
        
        uint256 aliceNativeBefore = alice.balance;
        
        // Sell tokens
        vm.prank(alice, alice);
        token.sellToken(sellAmount, 1, 0);
        
        // Check alice received native
        assertGt(alice.balance, aliceNativeBefore, "Alice should receive native");
        
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
        
        // Should fail with too high min native
        vm.prank(alice, alice);
        vm.expectRevert(bytes("INSUFFICIENT_OUTPUT_AMOUNT"));
        token.sellToken(tokenBalance / 2, 100 ether, 0);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Treasury Fee Tests (with Factory Fee Share)
    ////////////////////////////////////////////////////////////////////////////////

    function test_TreasuryFee_OnSell() public {
        // Use tokenWithTreasury (3% fee)
        vm.deal(alice, 100 ether);
        
        // Buy tokens
        vm.prank(alice, alice);
        tokenWithTreasury.buyToken{value: 10 ether}(1, 0);
        uint256 tokenBalance = tokenWithTreasury.balanceOf(alice);
        
        uint256 sellAmount = tokenBalance / 2;
        uint256 aliceNativeBefore = alice.balance;
        uint256 treasuryBefore = tokenWithTreasury.treasuryAmtTotal();
        uint256 factoryFeesBefore = tokenWithTreasury.factoryFeesAccrued();
        
        // Sell tokens
        vm.prank(alice, alice);
        tokenWithTreasury.sellToken(sellAmount, 1, 0);
        
        // Treasury should have accumulated fees (90% of 3%)
        uint256 treasuryAfter = tokenWithTreasury.treasuryAmtTotal();
        assertGt(treasuryAfter, treasuryBefore, "Treasury should accumulate fees");
        
        // Factory should have accumulated fees (10% of 3%)
        uint256 factoryFeesAfter = tokenWithTreasury.factoryFeesAccrued();
        assertGt(factoryFeesAfter, factoryFeesBefore, "Factory should accumulate fees");
        
        // Alice should have received native (minus fee)
        assertGt(alice.balance, aliceNativeBefore, "Alice should receive native");
    }
    
    function test_TreasuryFee_FeeShareRatio() public {
        // Use tokenWithTreasury (3% fee)
        vm.deal(alice, 100 ether);
        
        // Buy and sell to generate fees
        vm.prank(alice, alice);
        tokenWithTreasury.buyToken{value: 10 ether}(1, 0);
        uint256 tokenBalance = tokenWithTreasury.balanceOf(alice);
        
        vm.prank(alice, alice);
        tokenWithTreasury.sellToken(tokenBalance / 2, 1, 0);
        
        uint256 treasuryFees = tokenWithTreasury.treasuryAmtTotal();
        uint256 factoryFees = tokenWithTreasury.factoryFeesAccrued();
        
        // Factory gets 10%, treasury gets 90%
        // So factoryFees should be ~1/9 of treasuryFees (10/90 = 1/9)
        // Allow some tolerance for rounding
        assertApproxEqRel(factoryFees * 9, treasuryFees, 0.01e18); // 1% tolerance
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
        uint256 nativeAmount = 10 ether;
        
        // Buy same amount on both
        vm.deal(alice, 200 ether);
        
        vm.prank(alice, alice);
        token.buyToken{value: nativeAmount}(1, 0);
        uint256 tokensNoFee = token.balanceOf(alice);
        
        vm.prank(alice, alice);
        tokenWithTreasury.buyToken{value: nativeAmount}(1, 0);
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

    function test_RevertOnZeroNative() public {
        vm.prank(alice, alice);
        vm.expectRevert(bytes("!native"));
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

    function test_RevertOnZeroMinNative() public {
        // Buy first
        vm.prank(alice, alice);
        token.buyToken{value: 1 ether}(1, 0);
        
        vm.prank(alice, alice);
        vm.expectRevert(bytes("!minNative"));
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
        nine527 fuzzToken = new nine527("Fuzz Token", "FUZZ", treasuryBP, address(0), VIRTUAL_NATIVE);
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
        assertTrue(token.getEthReserve() > 0, "Native reserve should remain");
    }

    function test_VirtualLiquidity_NoInitialNative() public view {
        // Contract should work without any real native due to virtual liquidity
        // Price calculations work because of INITIAL_VIRTUAL_NATIVE
        
        uint256 price = token.getTokenPrice();
        assertTrue(price > 0, "Price should be positive from virtual liquidity");
        
        uint256 estimatedTokens = token.estimateBuyReturn(1 ether);
        assertTrue(estimatedTokens > 0, "Should estimate tokens correctly");
    }

    // Receive function to accept native (for treasury withdrawal test)
    receive() external payable {}
}
