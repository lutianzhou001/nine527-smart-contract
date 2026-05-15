// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./nine527.sol";

/**
 * @title nine527Factory
 * @dev Deploys nine527 meme tokens with vanity addresses ending in "9527".
 *
 * ── Vanity Addresses via CREATE2 ──────────────────────────────────────────────
 * CREATE2 lets us deterministically predict a contract address before deploying:
 *   address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
 *
 * To get an address ending in 0x9527 we need:
 *   uint160(address) & 0xFFFF == 0x9527   (last 2 bytes = last 4 hex chars)
 *
 * Callers mine an appropriate salt off-chain using `getInitCodeHash()` and
 * `predictAddress()`, then submit the winning salt to `createToken()`.
 *
 * ── Salt Replay Prevention ────────────────────────────────────────────────────
 * `usedSalts` records every salt consumed so the same salt can't be reused even
 * after a token is destroyed.  This is important because a recycled salt with a
 * different deployer would produce the same address (CREATE2 is deterministic),
 * which could mislead users who cache token → deployer mappings.
 *
 * ── Size Constraint ───────────────────────────────────────────────────────────
 * The factory is kept lean (no inheritance, minimal storage) to stay well under
 * the 24 KB EIP-170 deployed bytecode limit.  The nine527 token itself carries
 * all the complex logic.
 */
contract nine527Factory {

    struct TokenSummary {
        address tokenAddress;
        string  name;
        string  symbol;
    }

    // ── Registry ──────────────────────────────────────────────────────────────
    address[] public allTokens;                         // ordered by creation time
    mapping(address => address[]) public tokensByDeployer;
    mapping(address => bool)      public isValidToken;  // guards getTokenInfoBatch
    mapping(bytes32 => bool)      public usedSalts;     // prevents salt reuse

    // ── Admin ─────────────────────────────────────────────────────────────────
    address public feeRecipient;  // receives creationFee; also the admin account
    uint256 public creationFee;   // ETH required per token deployment (default 0)
    bool    public enforceVanity = true; // set false to allow non-9527 addresses (e.g. testing)

    event TokenCreated(
        address indexed tokenAddress,
        address indexed deployer,
        string  name,
        string  symbol,
        uint256 treasuryFeeBP,
        bytes32 salt
    );

    constructor() {
        // Deployer of the factory becomes the initial fee recipient and admin.
        feeRecipient = msg.sender;
    }

    ////////////////////////////////////////////////////////////////////////////
    // Token Creation
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Deploy a nine527 token whose address ends in 0x9527.
     *
     * The caller must supply a `salt_` they mined off-chain:
     *   1. Call `getInitCodeHash(name, symbol, bp, yourAddress)` to get the hash.
     *   2. Iterate salts until `predictAddress(...)` returns a valid 9527 address.
     *   3. Call `createToken(...)` with that salt.
     *
     * @param name_         Token name
     * @param symbol_       Token symbol
     * @param treasuryFeeBP_ Sell fee 0–300 BP (0–3%)
     * @param salt_         Pre-mined CREATE2 salt producing a 9527 vanity address
     */
    function createToken(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        bytes32 salt_
    ) external payable returns (address tokenAddress) {
        require(msg.value >= creationFee, "!fee");
        require(!usedSalts[salt_], "!salt"); // each salt usable exactly once

        bytes memory bytecode = _getBytecode(name_, symbol_, treasuryFeeBP_, msg.sender);
        address predicted     = _computeAddr(bytecode, salt_);

        // Enforce that the predicted address has the vanity suffix 0x9527.
        // This check runs before deployment so no gas is wasted on a bad salt.
        if (enforceVanity) {
            require(uint160(predicted) & 0xFFFF == 0x9527, "!9527");
        }

        usedSalts[salt_] = true; // mark before deploy to prevent reentrancy-style reuse

        assembly {
            // CREATE2: value=0, offset into bytecode array, length, salt
            tokenAddress := create2(0, add(bytecode, 0x20), mload(bytecode), salt_)
        }
        // Double-check: if CREATE2 fails (e.g. address already occupied) it returns 0.
        // The equality check against `predicted` is a sanity guard for the same reason.
        require(tokenAddress != address(0) && tokenAddress == predicted, "!deploy");

        _track(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, salt_);
        return tokenAddress;
    }

    /**
     * @dev Deploy a nine527 token using a regular CREATE (no vanity address).
     *
     * Useful for testing or when the caller doesn't want to mine a salt.
     * The resulting address is unpredictable from the caller's perspective.
     */
    function createTokenSimple(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_
    ) external payable returns (address tokenAddress) {
        require(msg.value >= creationFee, "!fee");

        // Standard `new` uses CREATE opcode; address depends on factory nonce.
        nine527 newToken = new nine527(name_, symbol_, treasuryFeeBP_, msg.sender);
        tokenAddress = address(newToken);

        // salt_ = bytes32(0) signals "no vanity / simple deploy" in the event log.
        _track(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, bytes32(0));
        return tokenAddress;
    }

    ////////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Register a newly deployed token and forward any creation fee.
     *
     * Fee forwarding happens here (not in the individual create functions) so
     * both paths share the same accounting.  If feeRecipient is a contract that
     * reverts on receive, token creation will also revert — deployers should set
     * feeRecipient to a plain EOA or a contract with an accepting fallback.
     */
    function _track(
        address token,
        address deployer,
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        bytes32 salt_
    ) internal {
        allTokens.push(token);
        tokensByDeployer[deployer].push(token);
        isValidToken[token] = true;

        // Forward creation fee only when there is one; skip transfer when zero
        // to save gas and avoid reverting on edge cases (e.g. fee just became 0).
        if (msg.value > 0 && feeRecipient != address(0)) {
            payable(feeRecipient).transfer(msg.value);
        }

        emit TokenCreated(token, deployer, name_, symbol_, treasuryFeeBP_, salt_);
    }

    /**
     * @dev ABI-encode constructor args and prepend the creation bytecode.
     * The result is the full initcode used by CREATE2.
     */
    function _getBytecode(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        address deployer_
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(nine527).creationCode,
            abi.encode(name_, symbol_, treasuryFeeBP_, deployer_)
        );
    }

    /**
     * @dev Compute the CREATE2 address without deploying.
     * Standard formula per EIP-1014:
     *   address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
     */
    function _computeAddr(bytes memory bytecode, bytes32 salt) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(bytecode)
        )))));
    }

    ////////////////////////////////////////////////////////////////////////////
    // View / Query Functions
    ////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Predict the token address for a given salt without deploying.
     *
     * Returns `valid = true` only when:
     *   - The predicted address ends in 0x9527, AND
     *   - The salt has not been used yet.
     *
     * Off-chain miners should call this to confirm a candidate salt before
     * submitting `createToken()`.
     */
    function predictAddress(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        address deployer_,
        bytes32 salt_
    ) external view returns (address predicted, bool valid) {
        bytes memory bytecode = _getBytecode(name_, symbol_, treasuryFeeBP_, deployer_);
        predicted = _computeAddr(bytecode, salt_);
        valid     = (uint160(predicted) & 0xFFFF == 0x9527) && !usedSalts[salt_];
    }

    /**
     * @dev Return the keccak256 of the full initcode for off-chain salt mining.
     *
     * Miners use this hash in the CREATE2 formula locally to iterate salts
     * without making any on-chain calls, then verify with `predictAddress`.
     * The hash changes if any constructor parameter changes, so it must be
     * re-fetched whenever name, symbol, fee, or deployer address changes.
     */
    function getInitCodeHash(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        address deployer_
    ) external pure returns (bytes32) {
        return keccak256(_getBytecode(name_, symbol_, treasuryFeeBP_, deployer_));
    }

    /** @dev Total number of tokens deployed through this factory. */
    function totalTokens() external view returns (uint256) {
        return allTokens.length;
    }

    /** @dev Return every token deployed through this factory with name and symbol, in creation order. */
    function getAllTokens() external view returns (TokenSummary[] memory summaries) {
        uint256 total = allTokens.length;
        summaries = new TokenSummary[](total);
        for (uint256 i = 0; i < total; i++) {
            nine527 t = nine527(payable(allTokens[i]));
            summaries[i] = TokenSummary(allTokens[i], t.name(), t.symbol());
        }
    }

    /**
     * @dev Return a slice of the token list with name and symbol for pagination.
     *
     * @param offset  Zero-based index of the first token to return.
     * @param limit   Maximum number of tokens to return.
     *
     * Returns tokens[offset .. offset+limit], capped at the end of the array.
     * Reverts if `offset` is beyond the total count so callers detect the boundary.
     */
    function getTokensPaginated(uint256 offset, uint256 limit) external view returns (TokenSummary[] memory page, uint256 total) {
        total = allTokens.length;
        require(offset < total || total == 0, "offset out of range");

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;

        page = new TokenSummary[](size);
        for (uint256 i = 0; i < size; i++) {
            address addr = allTokens[offset + i];
            nine527 t = nine527(payable(addr));
            page[i] = TokenSummary(addr, t.name(), t.symbol());
        }
    }

    /** @dev All tokens deployed by a specific address, in creation order. */
    function getTokensByDeployer(address deployer) external view returns (address[] memory) {
        return tokensByDeployer[deployer];
    }

    /**
     * @dev Return the `count` most recently deployed tokens, newest first.
     * If `count` exceeds total tokens deployed, returns all of them.
     */
    function getRecentTokens(uint256 count) external view returns (address[] memory) {
        uint256 total = allTokens.length;
        if (count > total) count = total;

        address[] memory recent = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            recent[i] = allTokens[total - 1 - i]; // reverse order: newest first
        }
        return recent;
    }

    /**
     * @dev Batch-fetch name, symbol, and current price for multiple tokens.
     *
     * Skips addresses that weren't deployed by this factory (`isValidToken` guard)
     * so invalid addresses return empty strings and zero price rather than reverting.
     * Useful for building token list UIs in a single RPC call.
     */
    function getTokenInfoBatch(address[] calldata tokens) external view returns (
        string[] memory names,
        string[] memory symbols,
        uint256[] memory prices
    ) {
        uint256 len = tokens.length;
        names   = new string[](len);
        symbols = new string[](len);
        prices  = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            if (isValidToken[tokens[i]]) {
                nine527 t = nine527(payable(tokens[i]));
                // Destructure only the fields we need; unused return values are discarded.
                (names[i], symbols[i],,, prices[i],,) = t.getTokenInfo();
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // Admin Functions (only feeRecipient)
    ////////////////////////////////////////////////////////////////////////////

    /** @dev Update the ETH fee charged per token deployment. */
    function setCreationFee(uint256 newFee) external {
        require(msg.sender == feeRecipient, "!auth");
        creationFee = newFee;
    }

    /**
     * @dev Transfer admin/fee-recipient role to a new address.
     * Zero-address check prevents accidentally locking out the admin.
     */
    function setFeeRecipient(address newRecipient) external {
        require(msg.sender == feeRecipient && newRecipient != address(0), "!auth");
        feeRecipient = newRecipient;
    }

    /**
     * @dev Toggle vanity-address enforcement.
     * Disabling allows non-9527 addresses — useful for local testing where
     * mining a vanity salt would slow down the test suite.
     */
    function setEnforceVanity(bool enforce) external {
        require(msg.sender == feeRecipient, "!auth");
        enforceVanity = enforce;
    }
}
