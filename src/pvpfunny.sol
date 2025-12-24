// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PVP20
 * @dev A customizable token with deep virtual floor liquidity
 * 
 * Anyone can deploy their own token with:
 * - Custom name and symbol
 * - Configurable treasury fee (0-3%)
 * 
 * Virtual Liquidity Mechanism:
 * - The contract starts with VIRTUAL ETH and TOKEN reserves
 * - No actual ETH is required at deployment - it's "virtual"
 * - As users buy, real ETH flows in and mixes with virtual reserves
 * - The constant product formula (x * y = k) ensures price discovery
 */
contract pvp20 is ERC20, ReentrancyGuard {
    address public immutable DEPLOYER;
    
    // Virtual liquidity parameters - these create the initial price curve
    uint256 public constant INITIAL_VIRTUAL_ETH = 2100 * (10 ** 18);      // 2100 virtual ETH
    uint256 public constant INITIAL_TOKEN_RESERVE = 21000 * (10 ** 18);   // 21000 tokens

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

    // Flag to skip burn during internal transfers (buy/sell operations)
    bool private _skipBurn;

    // Store token metadata for display
    string private _tokenName;
    string private _tokenSymbol;

    ////////////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////////////

    event BuyToken(address indexed user, uint256 tokenAmt, uint256 ethAmt);
    event SellToken(address indexed user, uint256 tokenAmt, uint256 ethAmt);

    ////////////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Deploy a new token with custom parameters
     * @param tokenName_ The name of the token (e.g., "My Token")
     * @param tokenSymbol_ The symbol of the token (e.g., "MTK")
     * @param treasuryBP_ Treasury fee in basis points (0-300, i.e., 0-3%)
     */
    constructor(
        string memory tokenName_,
        string memory tokenSymbol_,
        uint256 treasuryBP_
    ) ERC20(tokenName_, tokenSymbol_) {
        require(bytes(tokenName_).length > 0, "!name");
        require(bytes(tokenSymbol_).length > 0, "!symbol");
        require(treasuryBP_ <= MAX_TREASURY_BP, "!treasuryBP>3%");
        
        _tokenName = tokenName_;
        _tokenSymbol = tokenSymbol_;
        
        DEPLOYER = msg.sender;
        treasuryAddr = msg.sender;
        SELL_TREASURY_BP = treasuryBP_;
        
        // Mint initial token supply to the factory address (virtual reserve)
        _mint(TOKEN_FACTORY_ADDR, INITIAL_TOKEN_RESERVE);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // View Functions
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Returns the effective ETH reserve (virtual + real ETH - treasury)
     * This is used for AMM price calculations
     */
    function getEthReserve() public view returns (uint256) {
        return INITIAL_VIRTUAL_ETH + address(this).balance - treasuryAmtTotal;
    }

    /**
     * @dev Returns the token reserve held by the factory
     */
    function getTokenReserve() public view returns (uint256) {
        return balanceOf(TOKEN_FACTORY_ADDR);
    }

    /**
     * @dev Calculate current token price in ETH (per token)
     */
    function getTokenPrice() public view returns (uint256) {
        uint256 ethReserve = getEthReserve();
        uint256 tokenReserve = getTokenReserve();
        if (tokenReserve == 0) return 0;
        return (ethReserve * 1e18) / tokenReserve;
    }

    /**
     * @dev Estimate tokens received for a given ETH amount
     */
    function estimateBuyReturn(uint256 ethAmount) public view returns (uint256) {
        if (ethAmount == 0) return 0;
        
        uint256 oldEthReserve = getEthReserve();
        uint256 newEthReserve = oldEthReserve + ethAmount;
        uint256 oldTokenReserve = getTokenReserve();
        
        // Constant product formula: x * y = k
        // newTokenReserve = (oldEthReserve * oldTokenReserve) / newEthReserve
        uint256 newTokenReserve = (oldEthReserve * oldTokenReserve + newEthReserve / 2) / newEthReserve;
        
        return oldTokenReserve - newTokenReserve;
    }

    /**
     * @dev Estimate ETH received for selling tokens (after treasury fee)
     */
    function estimateSellReturn(uint256 tokenAmount) public view returns (uint256) {
        if (tokenAmount == 0) return 0;
        
        uint256 burnAmt = (tokenAmount * SELL_BURN_BP) / 10000;
        uint256 tokenAmtAfterBurn = tokenAmount - burnAmt;
        
        uint256 oldEthReserve = getEthReserve();
        uint256 oldTokenReserve = getTokenReserve();
        
        uint256 newTokenReserve = oldTokenReserve + tokenAmtAfterBurn;
        uint256 newEthReserve = (oldEthReserve * oldTokenReserve + newTokenReserve / 2) / newTokenReserve;
        
        uint256 grossEth = oldEthReserve - newEthReserve;
        
        // Deduct treasury fee from output
        if (SELL_TREASURY_BP > 0) {
            uint256 treasuryAmt = (grossEth * SELL_TREASURY_BP) / 10000;
            return grossEth - treasuryAmt;
        }
        return grossEth;
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
        uint256 ethReserve,
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
     * @dev Buy tokens with ETH
     * @param minTokenAmt Minimum tokens to receive (slippage protection)
     * @param expireTimestamp Transaction deadline (0 for no deadline)
     */
    function buyToken(uint256 minTokenAmt, uint256 expireTimestamp) external payable nonReentrant {
        address user = msg.sender;

        // Anti-bot checks
        if (CONTRACT_CHECK_BUY_LEVEL % 2 == 1) require(!_isContract(user), "!human");
        if (CONTRACT_CHECK_BUY_LEVEL >= 2) require(user == tx.origin, "!human");

        require(MARKET_OPEN_STAGE > 0, "!market");
        require(msg.value > 0, "!eth");
        require(minTokenAmt > 0, "!minToken");
        require(expireTimestamp == 0 || block.timestamp <= expireTimestamp, "!expire");
        require(MARKET_BUY_ETH_LIMIT == 0 || msg.value <= MARKET_BUY_ETH_LIMIT, "!ethLimit");

        // Calculate output using constant product formula
        uint256 newEthReserve = INITIAL_VIRTUAL_ETH + address(this).balance - treasuryAmtTotal;
        uint256 oldEthReserve = newEthReserve - msg.value;

        uint256 oldTokenReserve = balanceOf(TOKEN_FACTORY_ADDR);
        uint256 newTokenReserve = (oldEthReserve * oldTokenReserve + newEthReserve / 2) / newEthReserve;

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
     * @dev Sell tokens for ETH
     * @param tokenAmt Amount of tokens to sell
     * @param minEthAmt Minimum ETH to receive (slippage protection)
     * @param expireTimestamp Transaction deadline (0 for no deadline)
     */
    function sellToken(uint256 tokenAmt, uint256 minEthAmt, uint256 expireTimestamp) external nonReentrant {
        address payable user = payable(msg.sender);

        // Anti-bot checks
        if (CONTRACT_CHECK_SELL_LEVEL % 2 == 1) require(!_isContract(user), "!human");
        if (CONTRACT_CHECK_SELL_LEVEL >= 2) require(user == tx.origin, "!human");

        require(tokenAmt > 0, "!token");
        require(minEthAmt > 0, "!minEth");
        require(expireTimestamp == 0 || block.timestamp <= expireTimestamp, "!expire");

        // Apply sell burn (if any)
        uint256 burnAmt = (tokenAmt * SELL_BURN_BP) / 10000;
        _burnWithAutoBoost(user, burnAmt);
        uint256 tokenAmtAfterBurn = tokenAmt - burnAmt;

        // Calculate ETH output using constant product formula
        uint256 oldEthReserve = INITIAL_VIRTUAL_ETH + address(this).balance - treasuryAmtTotal;
        uint256 oldTokenReserve = balanceOf(TOKEN_FACTORY_ADDR);

        uint256 newTokenReserve = oldTokenReserve + tokenAmtAfterBurn;
        uint256 newEthReserve = (oldEthReserve * oldTokenReserve + newTokenReserve / 2) / newTokenReserve;

        uint256 outEthAmt = oldEthReserve - newEthReserve;
        require(outEthAmt > 0, "!outEth");

        // Transfer tokens from user to factory (no additional burn)
        _transferNoBurn(user, TOKEN_FACTORY_ADDR, tokenAmtAfterBurn);

        // Send ETH to user (minus treasury fee if any)
        if (SELL_TREASURY_BP > 0) {
            uint256 treasuryAmt = (outEthAmt * SELL_TREASURY_BP) / 10000;
            treasuryAmtTotal += treasuryAmt;
            uint256 userReceives = outEthAmt - treasuryAmt;
            require(userReceives >= minEthAmt, "INSUFFICIENT_OUTPUT_AMOUNT");
            user.transfer(userReceives);
        } else {
            require(outEthAmt >= minEthAmt, "INSUFFICIENT_OUTPUT_AMOUNT");
            user.transfer(outEthAmt);
        }

        emit SellToken(user, tokenAmt, outEthAmt);
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
        payable(treasuryAddr).transfer(amt);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Receive ETH (for adding liquidity or donations)
    ////////////////////////////////////////////////////////////////////////////////

    receive() external payable {}
}
