// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title nine527
 * @dev A customizable token with deep virtual floor liquidity
 * 
 * Anyone can deploy their own token with:
 * - Custom name and symbol
 * - Configurable treasury fee (0-3%)
 * 
 * Virtual Liquidity Mechanism (Four.meme Style):
 * - Uses USD-equivalent virtual reserves (~$2,600 worth)
 * - Chain-aware pricing for fair launches across all EVM chains
 * - As users buy, real native tokens flow in and mix with virtual reserves
 * - The constant product formula (x * y = k) ensures price discovery
 * 
 * Fee Structure:
 * - Treasury fee on sells: 0-3% (set by deployer)
 * - Factory fee share: 10% of treasury fee goes to factory
 */
contract nine527 is ERC20, ReentrancyGuard {
    address public immutable DEPLOYER;
    address public immutable FACTORY;
    
    // Virtual liquidity parameters - USD-equivalent (~$2,600 worth of native token)
    // This is passed from the factory based on chain ID
    uint256 public immutable INITIAL_VIRTUAL_NATIVE;
    
    // Token supply: 1 billion tokens
    uint256 public constant INITIAL_TOKEN_RESERVE = 1000000000 * (10 ** 18); // 1B tokens

    ////////////////////////////////////////////////////////////////////////////////
    // Market Configuration
    ////////////////////////////////////////////////////////////////////////////////

    uint256 public constant MARKET_OPEN_STAGE = 1; // Market is open
    uint256 public constant MARKET_BUY_ETH_LIMIT = 0; // No limit per buy

    // Whitelist configuration (disabled by default)
    address public constant MARKET_WHITELIST_TOKEN = address(0);
    uint256 public constant MARKET_WHITELIST_TOKEN_BP = 0; // No whitelist
    uint256 public constant MARKET_WHITELIST_BASE_AMT = 10 * (10 ** 18);

    ////////////////////////////////////////////////////////////////////////////////
    // Fee Configuration (in basis points, 1 BP = 0.01%)
    ////////////////////////////////////////////////////////////////////////////////

    uint256 public constant TRANSFER_BURN_BP = 0;   // 0% burn on transfers
    uint256 public constant SELL_BURN_BP = 0;       // 0% burn on sells
    
    // Treasury fee on sells - set by deployer (0-300 BP = 0-3%)
    uint256 public immutable SELL_TREASURY_BP;
    uint256 public constant MAX_TREASURY_BP = 300;  // Max 3%
    
    // Factory fee share: 10% of treasury fees go to factory
    uint256 public constant FACTORY_FEE_SHARE_BP = 1000; // 10% in basis points

    ////////////////////////////////////////////////////////////////////////////////
    // Anti-bot Configuration
    ////////////////////////////////////////////////////////////////////////////////

    uint256 public constant CONTRACT_CHECK_BUY_LEVEL = 3;  // 0: no check; 1: extcodesize; 2: tx.origin; 3: both
    uint256 public constant CONTRACT_CHECK_SELL_LEVEL = 3;

    ////////////////////////////////////////////////////////////////////////////////
    // State Variables
    ////////////////////////////////////////////////////////////////////////////////

    address internal constant TOKEN_FACTORY_ADDR = 0x1111111111111111111111111111111111111111;

    address public treasuryAddr;
    uint256 public treasuryAmtTotal;
    uint256 public factoryFeesAccrued;

    // Flag to skip burn during internal transfers (buy/sell operations)
    bool private _skipBurn;
    
    // Flag to bypass anti-bot for deployer's initial buy
    bool private _isDeployerBuy;

    // Store token metadata for display
    string private _tokenName;
    string private _tokenSymbol;

    ////////////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////////////

    event BuyToken(address indexed user, uint256 tokenAmt, uint256 nativeAmt);
    event SellToken(address indexed user, uint256 tokenAmt, uint256 nativeAmt);
    event FactoryFeesWithdrawn(address indexed factory, uint256 amount);

    ////////////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Deploy a new token with custom parameters
     * @param tokenName_ The name of the token (e.g., "My Token")
     * @param tokenSymbol_ The symbol of the token (e.g., "MTK")
     * @param treasuryBP_ Treasury fee in basis points (0-300, i.e., 0-3%)
     * @param deployer_ Address of the token deployer/treasury
     * @param virtualNative_ USD-equivalent virtual native reserve (from factory)
     */
    constructor(
        string memory tokenName_,
        string memory tokenSymbol_,
        uint256 treasuryBP_,
        address deployer_,
        uint256 virtualNative_
    ) ERC20(tokenName_, tokenSymbol_) {
        require(bytes(tokenName_).length > 0, "!name");
        require(bytes(tokenSymbol_).length > 0, "!symbol");
        require(treasuryBP_ <= MAX_TREASURY_BP, "!treasuryBP>3%");
        require(virtualNative_ > 0, "!virtualNative");
        
        _tokenName = tokenName_;
        _tokenSymbol = tokenSymbol_;
        
        // If deployer_ is zero address, use msg.sender (for direct deployment)
        // Otherwise use the provided address (for factory deployment)
        address actualDeployer = deployer_ == address(0) ? msg.sender : deployer_;
        
        DEPLOYER = actualDeployer;
        FACTORY = msg.sender;
        treasuryAddr = actualDeployer;
        SELL_TREASURY_BP = treasuryBP_;
        INITIAL_VIRTUAL_NATIVE = virtualNative_;
        
        // Mint initial token supply to the factory address (virtual reserve)
        _mint(TOKEN_FACTORY_ADDR, INITIAL_TOKEN_RESERVE);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // View Functions
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Returns the virtual native reserve (for display)
     */
    function getVirtualReserve() public view returns (uint256) {
        return INITIAL_VIRTUAL_NATIVE;
    }

    /**
     * @dev Returns the actual native token balance (real liquidity)
     */
    function getNativeReserve() public view returns (uint256) {
        return address(this).balance - treasuryAmtTotal - factoryFeesAccrued;
    }

    /**
     * @dev Returns the effective native reserve (virtual + real - fees)
     * This is used for AMM price calculations
     */
    function getEthReserve() public view returns (uint256) {
        return INITIAL_VIRTUAL_NATIVE + address(this).balance - treasuryAmtTotal - factoryFeesAccrued;
    }

    /**
     * @dev Returns the token reserve held by the factory
     */
    function getTokenReserve() public view returns (uint256) {
        return balanceOf(TOKEN_FACTORY_ADDR);
    }

    /**
     * @dev Calculate current token price in native token (per token)
     */
    function getTokenPrice() public view returns (uint256) {
        uint256 nativeReserve = getEthReserve();
        uint256 tokenReserve = getTokenReserve();
        if (tokenReserve == 0) return 0;
        return (nativeReserve * 1e18) / tokenReserve;
    }

    /**
     * @dev Estimate tokens received for a given native amount
     */
    function estimateBuyReturn(uint256 nativeAmount) public view returns (uint256) {
        if (nativeAmount == 0) return 0;
        
        uint256 oldNativeReserve = getEthReserve();
        uint256 newNativeReserve = oldNativeReserve + nativeAmount;
        uint256 oldTokenReserve = getTokenReserve();
        
        // Constant product formula: x * y = k
        // newTokenReserve = (oldNativeReserve * oldTokenReserve) / newNativeReserve
        uint256 newTokenReserve = (oldNativeReserve * oldTokenReserve + newNativeReserve / 2) / newNativeReserve;
        
        return oldTokenReserve - newTokenReserve;
    }

    /**
     * @dev Estimate native received for selling tokens (after treasury fee)
     */
    function estimateSellReturn(uint256 tokenAmount) public view returns (uint256) {
        if (tokenAmount == 0) return 0;
        
        uint256 burnAmt = (tokenAmount * SELL_BURN_BP) / 10000;
        uint256 tokenAmtAfterBurn = tokenAmount - burnAmt;
        
        uint256 oldNativeReserve = getEthReserve();
        uint256 oldTokenReserve = getTokenReserve();
        
        uint256 newTokenReserve = oldTokenReserve + tokenAmtAfterBurn;
        uint256 newNativeReserve = (oldNativeReserve * oldTokenReserve + newTokenReserve / 2) / newTokenReserve;
        
        uint256 grossNative = oldNativeReserve - newNativeReserve;
        
        // Deduct treasury fee from output
        if (SELL_TREASURY_BP > 0) {
            uint256 treasuryAmt = (grossNative * SELL_TREASURY_BP) / 10000;
            return grossNative - treasuryAmt;
        }
        return grossNative;
    }

    /**
     * @dev Get token configuration info
     */
    function getTokenInfo() external view returns (
        string memory tokenName,
        string memory tokenSymbol,
        address deployer,
        uint256 treasuryFeeBP,
        uint256 currentPrice,
        uint256 nativeReserve,
        uint256 tokenReserve
    ) {
        return (
            _tokenName,
            _tokenSymbol,
            DEPLOYER,
            SELL_TREASURY_BP,
            getTokenPrice(),
            getEthReserve(),
            getTokenReserve()
        );
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Trading Functions
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Buy tokens with native token
     * @param minTokenAmt Minimum tokens to receive (slippage protection)
     * @param expireTimestamp Transaction deadline (0 for no deadline)
     */
    function buyToken(uint256 minTokenAmt, uint256 expireTimestamp) external payable nonReentrant {
        _buyToken(msg.sender, minTokenAmt, expireTimestamp, false);
    }
    
    /**
     * @dev Internal buy function called by factory for deployer's initial buy
     * @param buyer Address receiving the tokens
     * @param minTokenAmt Minimum tokens to receive
     * @param expireTimestamp Transaction deadline
     * @param bypassAntiBot Whether to bypass anti-bot (true for deployer initial buy)
     */
    function buyTokenFor(
        address buyer,
        uint256 minTokenAmt,
        uint256 expireTimestamp,
        bool bypassAntiBot
    ) external payable nonReentrant {
        require(msg.sender == FACTORY, "!factory");
        _buyToken(buyer, minTokenAmt, expireTimestamp, bypassAntiBot);
    }
    
    function _buyToken(
        address user,
        uint256 minTokenAmt,
        uint256 expireTimestamp,
        bool bypassAntiBot
    ) internal {
        // Anti-bot checks (can be bypassed for deployer's initial buy)
        if (!bypassAntiBot) {
            if (CONTRACT_CHECK_BUY_LEVEL % 2 == 1) require(!_isContract(user), "!human");
            if (CONTRACT_CHECK_BUY_LEVEL >= 2) require(user == tx.origin, "!human");
        }

        require(MARKET_OPEN_STAGE > 0, "!market");
        require(msg.value > 0, "!native");
        require(minTokenAmt > 0, "!minToken");
        require(expireTimestamp == 0 || block.timestamp <= expireTimestamp, "!expire");
        require(MARKET_BUY_ETH_LIMIT == 0 || msg.value <= MARKET_BUY_ETH_LIMIT, "!nativeLimit");

        // Calculate output using constant product formula
        uint256 newNativeReserve = INITIAL_VIRTUAL_NATIVE + address(this).balance - treasuryAmtTotal - factoryFeesAccrued;
        uint256 oldNativeReserve = newNativeReserve - msg.value;

        uint256 oldTokenReserve = balanceOf(TOKEN_FACTORY_ADDR);
        uint256 newTokenReserve = (oldNativeReserve * oldTokenReserve + newNativeReserve / 2) / newNativeReserve;

        uint256 outTokenAmt = oldTokenReserve - newTokenReserve;
        require(outTokenAmt > 0, "!outToken");
        require(outTokenAmt >= minTokenAmt, "INSUFFICIENT_OUTPUT_AMOUNT");

        // Whitelist check (if enabled)
        if (MARKET_WHITELIST_TOKEN_BP > 0 && MARKET_WHITELIST_TOKEN != address(0)) {
            uint256 amtWhitelistToken = IERC20(MARKET_WHITELIST_TOKEN).balanceOf(user);
            uint256 amtLimit = (amtWhitelistToken * MARKET_WHITELIST_TOKEN_BP) / 10000;
            if (amtLimit < MARKET_WHITELIST_BASE_AMT) {
                amtLimit = MARKET_WHITELIST_BASE_AMT;
            }
            require(balanceOf(user) + outTokenAmt <= amtLimit, "!need-more-whitelist-token");
        }

        // Transfer tokens from factory to user (no burn on buy)
        _transferNoBurn(TOKEN_FACTORY_ADDR, user, outTokenAmt);

        emit BuyToken(user, outTokenAmt, msg.value);
    }

    /**
     * @dev Sell tokens for native token
     * @param tokenAmt Amount of tokens to sell
     * @param minNativeAmt Minimum native to receive (slippage protection)
     * @param expireTimestamp Transaction deadline (0 for no deadline)
     */
    function sellToken(uint256 tokenAmt, uint256 minNativeAmt, uint256 expireTimestamp) external nonReentrant {
        address user = msg.sender;

        // Anti-bot checks
        if (CONTRACT_CHECK_SELL_LEVEL % 2 == 1) require(!_isContract(user), "!human");
        if (CONTRACT_CHECK_SELL_LEVEL >= 2) require(user == tx.origin, "!human");

        require(tokenAmt > 0, "!token");
        require(minNativeAmt > 0, "!minNative");
        require(expireTimestamp == 0 || block.timestamp <= expireTimestamp, "!expire");

        // Apply sell burn (if any)
        uint256 burnAmt = (tokenAmt * SELL_BURN_BP) / 10000;
        _burnWithAutoBoost(user, burnAmt);
        uint256 tokenAmtAfterBurn = tokenAmt - burnAmt;

        // Calculate native output using constant product formula
        uint256 oldNativeReserve = INITIAL_VIRTUAL_NATIVE + address(this).balance - treasuryAmtTotal - factoryFeesAccrued;
        uint256 oldTokenReserve = balanceOf(TOKEN_FACTORY_ADDR);

        uint256 newTokenReserve = oldTokenReserve + tokenAmtAfterBurn;
        uint256 newNativeReserve = (oldNativeReserve * oldTokenReserve + newTokenReserve / 2) / newTokenReserve;

        uint256 outNativeAmt = oldNativeReserve - newNativeReserve;
        require(outNativeAmt > 0, "!outNative");

        // Transfer tokens from user to factory (no additional burn)
        _transferNoBurn(user, TOKEN_FACTORY_ADDR, tokenAmtAfterBurn);

        // Calculate and distribute fees
        uint256 userReceives = outNativeAmt;
        if (SELL_TREASURY_BP > 0) {
            uint256 totalFee = (outNativeAmt * SELL_TREASURY_BP) / 10000;
            uint256 factoryShare = (totalFee * FACTORY_FEE_SHARE_BP) / 10000; // 10% to factory
            uint256 treasuryShare = totalFee - factoryShare; // 90% to deployer
            
            factoryFeesAccrued += factoryShare;
            treasuryAmtTotal += treasuryShare;
            userReceives = outNativeAmt - totalFee;
        }
        
        require(userReceives >= minNativeAmt, "INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Safe transfer using call instead of transfer
        (bool success, ) = payable(user).call{value: userReceives}("");
        require(success, "!transfer");

        emit SellToken(user, tokenAmt, outNativeAmt);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Internal Transfer Functions
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Override _update to implement burn on transfers
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);

        // Skip burn for minting, burning, or internal operations
        if (from == address(0) || to == address(0) || _skipBurn) {
            return;
        }

        // Apply burn on regular transfers
        if (TRANSFER_BURN_BP > 0) {
            uint256 burnAmt = (value * TRANSFER_BURN_BP) / 10000;
            _burnWithAutoBoost(to, burnAmt);
        }
    }

    /**
     * @dev Internal transfer that bypasses the burn mechanism
     * Used for buy/sell operations where burn is handled separately
     */
    function _transferNoBurn(address sender, address recipient, uint256 amount) internal {
        _skipBurn = true;
        _update(sender, recipient, amount);
        _skipBurn = false;
    }

    /**
     * @dev Burns tokens with AutoBoost mechanism
     * When tokens are burned, a proportional amount is also burned from the reserve
     * This creates upward price pressure (rising floor price)
     */
    function _burnWithAutoBoost(address account, uint256 amount) internal {
        if (amount == 0) return;
        if (balanceOf(account) == 0) return;

        if (account != TOKEN_FACTORY_ADDR) {
            _burn(account, amount);

            // AutoBoost: proportionally reduce token reserve to boost floor price
            // This ensures the price floor rises with each burn
            uint256 tokenReserve = balanceOf(TOKEN_FACTORY_ADDR);
            uint256 circulatingSupply = totalSupply() - tokenReserve;

            if (circulatingSupply > 0 && tokenReserve > 0) {
                uint256 extraBurn = (tokenReserve * amount) / circulatingSupply;
                if (extraBurn > 0) {
                    _burn(TOKEN_FACTORY_ADDR, extraBurn);
                }
            }
        }
    }

    /**
     * @dev Check if an address is a contract
     */
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Treasury Functions
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyTreasury() {
        require(msg.sender == treasuryAddr, "!treasury");
        _;
    }

    function setTreasuryAddr(address newTreasury) external onlyTreasury {
        require(newTreasury != address(0), "!zero");
        treasuryAddr = newTreasury;
    }

    function withdrawTreasury(uint256 amt) external onlyTreasury {
        require(amt <= treasuryAmtTotal, "amt exceeds treasury");
        treasuryAmtTotal -= amt;
        
        // Safe transfer using call instead of transfer
        (bool success, ) = payable(treasuryAddr).call{value: amt}("");
        require(success, "!transfer");
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    // Factory Fee Functions
    ////////////////////////////////////////////////////////////////////////////////
    
    /**
     * @dev Withdraw accumulated factory fees (only callable by factory)
     */
    function withdrawFactoryFees() external {
        require(msg.sender == FACTORY, "!factory");
        uint256 amount = factoryFeesAccrued;
        require(amount > 0, "!fees");
        
        factoryFeesAccrued = 0;
        
        // Safe transfer using call
        (bool success, ) = payable(FACTORY).call{value: amount}("");
        require(success, "!transfer");
        
        emit FactoryFeesWithdrawn(FACTORY, amount);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Receive Native Token (for adding liquidity or donations)
    ////////////////////////////////////////////////////////////////////////////////

    receive() external payable {}
}
