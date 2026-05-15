// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title nine527
 * @dev Meme token with a built-in single-sided AMM backed by virtual liquidity.
 *
 * ── Virtual Liquidity ──────────────────────────────────────────────────────────
 * The AMM starts with INITIAL_VIRTUAL_ETH (10 OKB) and INITIAL_TOKEN_RESERVE
 * (1 B tokens) already "in the pool" without any real ETH being deposited.
 * These virtual amounts are never stored — they are constants added into every
 * reserve calculation at runtime.  Real ETH flows in as users buy; the virtual
 * ETH ensures the price curve is well-behaved from the very first trade and
 * sets the launch price to 10 OKB / 1,000,000,000 tokens = 1e-8 OKB/token.
 *
 * ── Constant Product AMM (x · y = k) ──────────────────────────────────────────
 * Both buy and sell use the standard x·y = k formula, with integer rounding
 * applied via the "+reserve/2" trick (round to nearest instead of truncating).
 * This prevents the seller/buyer from being systematically shortchanged by 1 wei.
 *
 * ── Treasury Fee ──────────────────────────────────────────────────────────────
 * Sell fees accumulate inside the contract as real ETH (tracked by
 * `treasuryAmtTotal`) but are subtracted from the ETH reserve so they don't
 * inflate the apparent liquidity pool.  The treasury must call `withdrawTreasury`
 * to actually extract them.
 *
 * ── AutoBoost ─────────────────────────────────────────────────────────────────
 * When tokens are burned (e.g. from SELL_BURN_BP), the factory reserve is also
 * burned proportionally so the price floor rises monotonically.
 * Currently SELL_BURN_BP = 0, so AutoBoost is inactive but infrastructure is in place.
 */
contract nine527 is ERC20, ReentrancyGuard {
    address public immutable DEPLOYER;

    // ── Virtual Liquidity ─────────────────────────────────────────────────────
    // These constants are NEVER stored as real balances; they are added into
    // every reserve read so that getEthReserve() > 0 even before any buys.
    // Launch price = INITIAL_VIRTUAL_ETH / INITIAL_TOKEN_RESERVE = 2.1e-8 OKB/token.
    uint256 public constant INITIAL_VIRTUAL_ETH    = 21 * (10 ** 18);           // 21 virtual OKB
    uint256 public constant INITIAL_TOKEN_RESERVE  = 1000000000 * (10 ** 18);  // 1 B tokens (full supply)

    ////////////////////////////////////////////////////////////////////////////
    // Market Configuration
    ////////////////////////////////////////////////////////////////////////////

    // MARKET_OPEN_STAGE > 0 means trading is live; set to 0 to pause (would
    // require making this mutable — currently always open).
    uint256 public constant MARKET_OPEN_STAGE       = 1;
    uint256 public constant MARKET_BUY_ETH_LIMIT    = 0; // 0 = no per-tx cap

    // Whitelist: if MARKET_WHITELIST_TOKEN != address(0), buyers must hold
    // enough of that token to receive their requested output.
    // Both constants are 0/zero-address so the whitelist is completely disabled.
    address public constant MARKET_WHITELIST_TOKEN      = address(0);
    uint256 public constant MARKET_WHITELIST_TOKEN_BP   = 0;
    uint256 public constant MARKET_WHITELIST_BASE_AMT   = 10 * (10 ** 18); // floor if BP calc is tiny

    ////////////////////////////////////////////////////////////////////////////
    // Fee Configuration (basis points: 1 BP = 0.01%, 10000 BP = 100%)
    ////////////////////////////////////////////////////////////////////////////

    uint256 public constant TRANSFER_BURN_BP  = 0;   // burn on wallet-to-wallet transfers
    uint256 public constant SELL_BURN_BP      = 0;   // burn on sells (AutoBoost is inactive while 0)

    // Set once at construction; immutable so users can trust the fee won't change.
    uint256 public immutable SELL_TREASURY_BP;
    uint256 public constant  MAX_TREASURY_BP  = 300; // hard cap: 3%

    ////////////////////////////////////////////////////////////////////////////
    // Anti-bot Configuration
    ////////////////////////////////////////////////////////////////////////////

    // Bit-field: controls which checks apply to buyers and sellers.
    //   bit 0 (level & 1 == 1): extcodesize — rejects callers that are contracts
    //   level 0 = no checks (ERC-4337 / smart contract wallet compatible)
    uint256 public constant CONTRACT_CHECK_BUY_LEVEL  = 0;
    uint256 public constant CONTRACT_CHECK_SELL_LEVEL = 0;

    ////////////////////////////////////////////////////////////////////////////
    // State Variables
    ////////////////////////////////////////////////////////////////////////////

    // Placeholder address used as the "factory reserve" wallet.
    // Tokens minted here represent the unsold supply backing the virtual pool.
    // Must be non-zero and must not equal address(this) to avoid self-transfer loops.
    address internal constant TOKEN_FACTORY_ADDR = 0x1111111111111111111111111111111111111111;

    address public treasuryAddr;

    // Accumulated sell fees sitting inside the contract as real ETH.
    // Tracked separately so they don't distort the AMM reserve calculation.
    // Only withdrawable via withdrawTreasury().
    uint256 public treasuryAmtTotal;

    // Guards against double-burn: set to true inside _transferNoBurn so that
    // the _update override skips the TRANSFER_BURN_BP deduction for buy/sell ops
    // where burn is already handled (or intentionally absent).
    bool private _skipBurn;

    string private _tokenName;
    string private _tokenSymbol;

    ////////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////////

    event BuyToken(address indexed user, uint256 tokenAmt, uint256 ethAmt);
    event SellToken(address indexed user, uint256 tokenAmt, uint256 ethAmt);

    ////////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Deploy a new token.
     * @param tokenName_    Human-readable name (e.g. "Pepe Token")
     * @param tokenSymbol_  Ticker symbol (e.g. "PEPE")
     * @param treasuryBP_   Sell fee in basis points, 0–300 (0–3%).
     *                      Immutable after deployment — users can verify on-chain.
     * @param deployer_     Treasury / fee recipient.  Pass address(0) to use msg.sender.
     *                      The factory passes msg.sender explicitly so the token records
     *                      the end-user rather than the factory contract itself.
     *
     * All 1 B tokens are minted to TOKEN_FACTORY_ADDR (the virtual reserve).
     * No real ETH is required — the virtual liquidity constants provide the
     * initial price curve without a seed deposit.
     */
    constructor(
        string memory tokenName_,
        string memory tokenSymbol_,
        uint256 treasuryBP_,
        address deployer_
    ) ERC20(tokenName_, tokenSymbol_) {
        require(bytes(tokenName_).length > 0, "!name");
        require(bytes(tokenSymbol_).length > 0, "!symbol");
        require(treasuryBP_ <= MAX_TREASURY_BP, "!treasuryBP>3%");

        _tokenName   = tokenName_;
        _tokenSymbol = tokenSymbol_;

        // Resolve deployer: zero-address means "direct deploy, use msg.sender".
        // The factory always supplies the real user's address here.
        address actualDeployer = deployer_ == address(0) ? msg.sender : deployer_;

        DEPLOYER       = actualDeployer;
        treasuryAddr   = actualDeployer;
        SELL_TREASURY_BP = treasuryBP_;

        // Entire supply sits in the virtual reserve at launch; tokens leave this
        // address only when users buy and return when users sell.
        _mint(TOKEN_FACTORY_ADDR, INITIAL_TOKEN_RESERVE);
    }

    ////////////////////////////////////////////////////////////////////////////
    // View / Price Functions
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Effective ETH reserve used in all AMM calculations.
     *
     *   ethReserve = virtualETH + realETH_in_contract - accumulatedTreasuryFees
     *
     * We subtract treasuryAmtTotal because those ETH belong to the treasury, not
     * the liquidity pool.  Counting them would inflate buy prices and deflate sell
     * payouts for regular traders.
     */
    function getEthReserve() public view returns (uint256) {
        return INITIAL_VIRTUAL_ETH + address(this).balance - treasuryAmtTotal;
    }

    /**
     * @dev Token reserve = tokens still held by the virtual-pool address.
     * Decreases on buys, increases on sells.
     */
    function getTokenReserve() public view returns (uint256) {
        return balanceOf(TOKEN_FACTORY_ADDR);
    }

    /**
     * @dev Spot price in ETH per whole token (scaled by 1e18 for precision).
     * Derived directly from the AMM reserves: price = ethReserve / tokenReserve.
     */
    function getTokenPrice() public view returns (uint256) {
        uint256 ethReserve   = getEthReserve();
        uint256 tokenReserve = getTokenReserve();
        if (tokenReserve == 0) return 0;
        return (ethReserve * 1e18) / tokenReserve;
    }

    /**
     * @dev Preview tokens received for `ethAmount` ETH (no fee on buys).
     *
     * Applies constant-product: newTokenReserve = k / newEthReserve.
     * The "+ newEthReserve / 2" is integer rounding (round-half-up) so the
     * estimate matches what buyToken actually computes.
     */
    function estimateBuyReturn(uint256 ethAmount) public view returns (uint256) {
        if (ethAmount == 0) return 0;

        uint256 oldEthReserve   = getEthReserve();
        uint256 newEthReserve   = oldEthReserve + ethAmount;
        uint256 oldTokenReserve = getTokenReserve();

        // Round-half-up division: (a * b + c/2) / c  ≈  a * b / c  with rounding
        uint256 newTokenReserve = (oldEthReserve * oldTokenReserve + newEthReserve / 2) / newEthReserve;

        return oldTokenReserve - newTokenReserve;
    }

    /**
     * @dev Preview ETH received for selling `tokenAmount` tokens, after treasury fee.
     *
     * Steps:
     *   1. Apply SELL_BURN_BP to determine tokens that enter the pool.
     *   2. Compute new ETH reserve via constant-product.
     *   3. Deduct SELL_TREASURY_BP from gross ETH output.
     *
     * This matches the logic in sellToken() exactly so callers get accurate quotes.
     */
    function estimateSellReturn(uint256 tokenAmount) public view returns (uint256) {
        if (tokenAmount == 0) return 0;

        // Burned tokens don't enter the reserve — they're permanently removed.
        uint256 burnAmt          = (tokenAmount * SELL_BURN_BP) / 10000;
        uint256 tokenAmtAfterBurn = tokenAmount - burnAmt;

        uint256 oldEthReserve   = getEthReserve();
        uint256 oldTokenReserve = getTokenReserve();

        uint256 newTokenReserve = oldTokenReserve + tokenAmtAfterBurn;
        // Round-half-up to be consistent with buyToken rounding direction.
        uint256 newEthReserve   = (oldEthReserve * oldTokenReserve + newTokenReserve / 2) / newTokenReserve;

        uint256 grossEth = oldEthReserve - newEthReserve;

        // Treasury fee is taken from what the user receives, not from the pool math.
        if (SELL_TREASURY_BP > 0) {
            uint256 treasuryAmt = (grossEth * SELL_TREASURY_BP) / 10000;
            return grossEth - treasuryAmt;
        }
        return grossEth;
    }

    /**
     * @dev Aggregate token info for UIs / the factory's batch query.
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

    ////////////////////////////////////////////////////////////////////////////
    // Trading Functions
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Buy tokens with ETH.
     *
     * @param minTokenAmt      Slippage guard: revert if output < this value.
     * @param expireTimestamp  Deadline in Unix seconds; 0 means no deadline.
     *
     * Reserve snapshot:
     *   We read `address(this).balance` AFTER msg.value has landed (EVM adds it
     *   before the call body executes), so `newEthReserve` already includes the
     *   buyer's ETH.  We then back-calculate `oldEthReserve = newEthReserve - msg.value`
     *   to run the AMM formula forward correctly.
     *
     * No fee on buys: all sent ETH enters the liquidity pool, raising the price.
     */
    function buyToken(uint256 minTokenAmt, uint256 expireTimestamp) external payable nonReentrant {
        address user = msg.sender;

        if (CONTRACT_CHECK_BUY_LEVEL % 2 == 1) require(!_isContract(user), "!human");

        require(MARKET_OPEN_STAGE > 0, "!market");
        require(msg.value > 0,         "!eth");
        require(minTokenAmt > 0,       "!minToken");
        require(expireTimestamp == 0 || block.timestamp <= expireTimestamp, "!expire");
        require(MARKET_BUY_ETH_LIMIT == 0 || msg.value <= MARKET_BUY_ETH_LIMIT, "!ethLimit");

        // msg.value is already included in address(this).balance at this point.
        uint256 newEthReserve   = INITIAL_VIRTUAL_ETH + address(this).balance - treasuryAmtTotal;
        uint256 oldEthReserve   = newEthReserve - msg.value;

        uint256 oldTokenReserve = balanceOf(TOKEN_FACTORY_ADDR);
        // Constant-product with round-half-up: gives buyer the rounding benefit.
        uint256 newTokenReserve = (oldEthReserve * oldTokenReserve + newEthReserve / 2) / newEthReserve;

        uint256 outTokenAmt = oldTokenReserve - newTokenReserve;
        require(outTokenAmt > 0,              "!outToken");
        require(outTokenAmt >= minTokenAmt,   "INSUFFICIENT_OUTPUT_AMOUNT");

        // Whitelist: limits how many tokens a user can accumulate based on their
        // holding of an external "access" token.  Disabled when BP = 0.
        if (MARKET_WHITELIST_TOKEN_BP > 0 && MARKET_WHITELIST_TOKEN != address(0)) {
            uint256 amtWhitelistToken = IERC20(MARKET_WHITELIST_TOKEN).balanceOf(user);
            uint256 amtLimit = (amtWhitelistToken * MARKET_WHITELIST_TOKEN_BP) / 10000;
            // Enforce a minimum allowance even for tiny whitelist-token holders.
            if (amtLimit < MARKET_WHITELIST_BASE_AMT) {
                amtLimit = MARKET_WHITELIST_BASE_AMT;
            }
            require(balanceOf(user) + outTokenAmt <= amtLimit, "!need-more-whitelist-token");
        }

        // _transferNoBurn bypasses TRANSFER_BURN_BP so that buying doesn't trigger
        // the on-transfer burn — only explicit sell burns (SELL_BURN_BP) apply.
        _transferNoBurn(TOKEN_FACTORY_ADDR, user, outTokenAmt);

        emit BuyToken(user, outTokenAmt, msg.value);
    }

    /**
     * @dev Sell tokens for ETH.
     *
     * @param tokenAmt         Tokens to sell (gross, before burn).
     * @param minEthAmt        Slippage guard: revert if ETH received < this.
     * @param expireTimestamp  Deadline in Unix seconds; 0 means no deadline.
     *
     * Execution order matters:
     *   1. Burn `burnAmt` from the seller's wallet (and AutoBoost-burn from reserve).
     *   2. Transfer the remaining `tokenAmtAfterBurn` from seller → factory reserve.
     *   3. Send ETH to seller, keeping treasury fee in the contract.
     *
     * Doing the burn BEFORE updating the reserve means the constant-product
     * calculation uses the correct post-burn reserves.
     */
    function sellToken(uint256 tokenAmt, uint256 minEthAmt, uint256 expireTimestamp) external nonReentrant {
        address payable user = payable(msg.sender);

        if (CONTRACT_CHECK_SELL_LEVEL % 2 == 1) require(!_isContract(user), "!human");

        require(tokenAmt > 0,  "!token");
        require(minEthAmt > 0, "!minEth");
        require(expireTimestamp == 0 || block.timestamp <= expireTimestamp, "!expire");

        // Step 1: burn (currently a no-op because SELL_BURN_BP = 0).
        // AutoBoost inside _burnWithAutoBoost also burns from the factory reserve
        // proportionally, so the price floor can only rise, never fall from burns.
        uint256 burnAmt           = (tokenAmt * SELL_BURN_BP) / 10000;
        _burnWithAutoBoost(user, burnAmt);
        uint256 tokenAmtAfterBurn = tokenAmt - burnAmt;

        // Step 2: AMM calculation using the token reserve BEFORE the transfer so
        // we compute the ETH owed, then move tokens in step 3.
        uint256 oldEthReserve   = INITIAL_VIRTUAL_ETH + address(this).balance - treasuryAmtTotal;
        uint256 oldTokenReserve = balanceOf(TOKEN_FACTORY_ADDR);

        uint256 newTokenReserve = oldTokenReserve + tokenAmtAfterBurn;
        uint256 newEthReserve   = (oldEthReserve * oldTokenReserve + newTokenReserve / 2) / newTokenReserve;

        uint256 outEthAmt = oldEthReserve - newEthReserve;
        require(outEthAmt > 0, "!outEth");

        // Step 3: move tokens back to the reserve (no burn on this internal transfer).
        _transferNoBurn(user, TOKEN_FACTORY_ADDR, tokenAmtAfterBurn);

        // Step 4: pay seller and earmark treasury cut.
        // treasuryAmtTotal stays in the contract; the treasury withdraws separately.
        // This avoids an external call during the hot path and reduces reentrancy surface.
        if (SELL_TREASURY_BP > 0) {
            uint256 treasuryAmt  = (outEthAmt * SELL_TREASURY_BP) / 10000;
            treasuryAmtTotal    += treasuryAmt;
            uint256 userReceives = outEthAmt - treasuryAmt;
            require(userReceives >= minEthAmt, "INSUFFICIENT_OUTPUT_AMOUNT");
            user.transfer(userReceives);
        } else {
            require(outEthAmt >= minEthAmt, "INSUFFICIENT_OUTPUT_AMOUNT");
            user.transfer(outEthAmt);
        }

        emit SellToken(user, tokenAmt, outEthAmt);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Internal Transfer / Burn Helpers
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @dev ERC-20 balance-update hook — intercepts all mints, burns, and transfers.
     *
     * We piggyback TRANSFER_BURN_BP here so every wallet-to-wallet transfer
     * automatically burns a fraction of the transferred amount.
     *
     * Skipped for:
     *   - Mints (from == address(0)): would loop back into _mint.
     *   - Burns (to   == address(0)): already a burn, no double-burn.
     *   - _skipBurn == true: set by _transferNoBurn for AMM ops.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);

        if (from == address(0) || to == address(0) || _skipBurn) {
            return;
        }

        if (TRANSFER_BURN_BP > 0) {
            uint256 burnAmt = (value * TRANSFER_BURN_BP) / 10000;
            _burnWithAutoBoost(to, burnAmt);
        }
    }

    /**
     * @dev Transfer tokens while bypassing the transfer-burn logic.
     *
     * The _skipBurn flag is set for the duration of the internal _update call
     * so the hook in _update sees it and skips the TRANSFER_BURN_BP deduction.
     * This is safe within a single non-reentrant call; ReentrancyGuard on the
     * public functions ensures _skipBurn can't be left true across external calls.
     */
    function _transferNoBurn(address sender, address recipient, uint256 amount) internal {
        _skipBurn = true;
        _update(sender, recipient, amount);
        _skipBurn = false;
    }

    /**
     * @dev Burn `amount` from `account`, then proportionally burn from the factory
     * reserve to maintain the price floor (AutoBoost).
     *
     * AutoBoost math:
     *   extraBurn = reserveTokens × (burnAmt / circulatingSupply)
     *
     * Burning `burnAmt` from circulation shrinks supply; burning `extraBurn` from
     * the reserve in the same ratio keeps the ratio (reserve / circulating) constant,
     * which means the price floor (virtualETH / totalSupply) rises.
     *
     * No-ops when amount == 0 or when the account has no balance.
     */
    function _burnWithAutoBoost(address account, uint256 amount) internal {
        if (amount == 0) return;
        if (balanceOf(account) == 0) return;

        if (account != TOKEN_FACTORY_ADDR) {
            _burn(account, amount);

            uint256 tokenReserve      = balanceOf(TOKEN_FACTORY_ADDR);
            uint256 circulatingSupply = totalSupply() - tokenReserve;

            if (circulatingSupply > 0 && tokenReserve > 0) {
                // Integer math: may underestimate by 1; acceptable rounding loss.
                uint256 extraBurn = (tokenReserve * amount) / circulatingSupply;
                if (extraBurn > 0) {
                    _burn(TOKEN_FACTORY_ADDR, extraBurn);
                }
            }
        }
    }

    /**
     * @dev Returns true if `account` has deployed bytecode (i.e. is a contract).
     * Note: returns false during the target contract's own constructor.
     */
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    ////////////////////////////////////////////////////////////////////////////
    // Treasury Functions
    ////////////////////////////////////////////////////////////////////////////

    modifier onlyTreasury() {
        require(msg.sender == treasuryAddr, "!treasury");
        _;
    }

    /**
     * @dev Transfer treasury role to a new address.
     * The new address immediately becomes both the fee recipient and the only
     * account that can call treasury functions.
     */
    function setTreasuryAddr(address newTreasury) external onlyTreasury {
        require(newTreasury != address(0), "!zero");
        treasuryAddr = newTreasury;
    }

    /**
     * @dev Withdraw accumulated sell fees to the treasury address.
     * `amt` is capped by `treasuryAmtTotal`; the rest of the contract's ETH
     * balance is untouchable liquidity.
     */
    function withdrawTreasury(uint256 amt) external onlyTreasury {
        require(amt <= treasuryAmtTotal, "amt exceeds treasury");
        treasuryAmtTotal -= amt;
        payable(treasuryAddr).transfer(amt);
    }

    ////////////////////////////////////////////////////////////////////////////
    // ETH Receive Hook
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Accepts plain ETH transfers (e.g. donations or liquidity additions).
     *
     * Any ETH sent directly increases `address(this).balance` which raises
     * `getEthReserve()`, thereby boosting the token price permanently.
     * Unlike a buy, no tokens are minted or transferred — it's a pure price boost.
     */
    receive() external payable {}
}
