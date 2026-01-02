// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./nine527.sol";

contract nine527Factory {
    uint256 public constant TARGET_USD_CENTS = 260000;
    
    // Mainnet chain IDs only
    uint256 public constant CHAIN_ETHEREUM = 1;
    uint256 public constant CHAIN_BNB = 56;
    uint256 public constant CHAIN_POLYGON = 137;
    uint256 public constant CHAIN_ARBITRUM = 42161;
    uint256 public constant CHAIN_OPTIMISM = 10;
    uint256 public constant CHAIN_BASE = 8453;
    uint256 public constant CHAIN_ZKSYNC = 324;
    uint256 public constant CHAIN_LINEA = 59144;
    uint256 public constant CHAIN_SCROLL = 534352;
    uint256 public constant CHAIN_XLAYER = 196;
    
    mapping(uint256 => uint256) public nativePriceUSDCents;
    mapping(uint256 => uint256) public creationFee; // Chain-specific creation fees
    
    address[] public allTokens;
    mapping(address => address[]) public tokensByDeployer;
    mapping(address => bool) public isValidToken;
    mapping(bytes32 => bool) public usedSalts;
    
    address public feeRecipient;
    uint256 public accumulatedFees;
    
    event TokenCreated(address indexed tokenAddress, address indexed deployer, string name, string symbol, uint256 treasuryFeeBP, bytes32 salt, uint256 virtualNative);
    event TokenCreatedAndBought(address indexed tokenAddress, address indexed deployer, uint256 buyAmount, uint256 tokensReceived);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event NativePriceUpdated(uint256 indexed chainId, uint256 priceUSDCents);
    
    constructor(address admin_) {
        require(admin_ != address(0), "!admin");
        feeRecipient = admin_;
        
        // ETH-based chains: 0.01 ETH creation fee
        creationFee[CHAIN_ETHEREUM] = 0.01 ether;
        creationFee[CHAIN_ARBITRUM] = 0.01 ether;
        creationFee[CHAIN_OPTIMISM] = 0.01 ether;
        creationFee[CHAIN_BASE] = 0.01 ether;
        creationFee[CHAIN_ZKSYNC] = 0.01 ether;
        creationFee[CHAIN_LINEA] = 0.01 ether;
        creationFee[CHAIN_SCROLL] = 0.01 ether;
        // BNB Chain: 0.05 BNB creation fee
        creationFee[CHAIN_BNB] = 0.05 ether;
        // Polygon: 10 POL creation fee
        creationFee[CHAIN_POLYGON] = 10 ether;
        // X Layer: 0.2 OKB creation fee
        creationFee[CHAIN_XLAYER] = 0.2 ether;
        
        // ETH-based chains ($3,000)
        nativePriceUSDCents[CHAIN_ETHEREUM] = 300000;
        nativePriceUSDCents[CHAIN_ARBITRUM] = 300000;
        nativePriceUSDCents[CHAIN_OPTIMISM] = 300000;
        nativePriceUSDCents[CHAIN_BASE] = 300000;
        nativePriceUSDCents[CHAIN_ZKSYNC] = 300000;
        nativePriceUSDCents[CHAIN_LINEA] = 300000;
        nativePriceUSDCents[CHAIN_SCROLL] = 300000;
        // BNB ($850)
        nativePriceUSDCents[CHAIN_BNB] = 85000;
        // POL ($0.10)
        nativePriceUSDCents[CHAIN_POLYGON] = 10;
        // OKB ($108)
        nativePriceUSDCents[CHAIN_XLAYER] = 10800;
    }
    
    function getVirtualNativeForChain() public view returns (uint256) {
        uint256 priceUSDCents = nativePriceUSDCents[block.chainid];
        if (priceUSDCents == 0) priceUSDCents = 300000;
        return (TARGET_USD_CENTS * 1e18) / priceUSDCents;
    }
    
    function getCreationFee() public view returns (uint256) {
        uint256 fee = creationFee[block.chainid];
        if (fee == 0) fee = 0.01 ether; // Default to 0.01 for unknown chains
        return fee;
    }
    
    // ============ CREATE2 Vanity Address Functions ============
    
    /// @notice Get the init code hash for mining vanity addresses
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param treasuryFeeBP_ Treasury fee in basis points (0-300)
    /// @param deployer_ The deployer address (will be token's deployer/treasury)
    /// @return The keccak256 hash of the init code
    function getInitCodeHash(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        address deployer_
    ) public view returns (bytes32) {
        uint256 virtualNative = getVirtualNativeForChain();
        bytes memory initCode = abi.encodePacked(
            type(nine527).creationCode,
            abi.encode(name_, symbol_, treasuryFeeBP_, deployer_, virtualNative)
        );
        return keccak256(initCode);
    }
    
    /// @notice Predict the address that will be deployed with CREATE2
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param treasuryFeeBP_ Treasury fee in basis points
    /// @param deployer_ The deployer address
    /// @param salt_ The salt for CREATE2
    /// @return predicted The predicted address
    /// @return isVanity Whether the address ends with 9527
    function predictAddress(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        address deployer_,
        bytes32 salt_
    ) public view returns (address predicted, bool isVanity) {
        bytes32 initCodeHash = getInitCodeHash(name_, symbol_, treasuryFeeBP_, deployer_);
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt_,
            initCodeHash
        )))));
        isVanity = _endsWithNine527(predicted);
        return (predicted, isVanity);
    }
    
    /// @notice Check if an address ends with 9527 (hex)
    function _endsWithNine527(address addr) internal pure returns (bool) {
        // 9527 in hex = 0x9527, check last 2 bytes
        return (uint160(addr) & 0xFFFF) == 0x9527;
    }
    
    /// @notice Create token with CREATE2 for vanity address
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param treasuryFeeBP_ Treasury fee in basis points (0-300)
    /// @param salt_ Salt for CREATE2 (mined by frontend)
    /// @return tokenAddress The deployed token address
    function createToken(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        bytes32 salt_
    ) external payable returns (address tokenAddress) {
        uint256 fee = getCreationFee();
        require(msg.value >= fee, "!fee");
        require(!usedSalts[salt_], "!salt");
        
        uint256 virtualNative = getVirtualNativeForChain();
        
        // Deploy with CREATE2
        nine527 newToken = new nine527{salt: salt_}(
            name_,
            symbol_,
            treasuryFeeBP_,
            msg.sender,
            virtualNative
        );
        tokenAddress = address(newToken);
        
        usedSalts[salt_] = true;
        _trackAndCollectFee(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, salt_, virtualNative, fee);
        return tokenAddress;
    }
    
    /// @notice Create token with CREATE2 and buy tokens in one transaction
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param treasuryFeeBP_ Treasury fee in basis points (0-300)
    /// @param salt_ Salt for CREATE2 (mined by frontend)
    /// @param minTokenAmt_ Minimum tokens to receive (slippage protection)
    /// @return tokenAddress The deployed token address
    /// @return tokensReceived Amount of tokens received
    function createTokenAndBuy(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        bytes32 salt_,
        uint256 minTokenAmt_
    ) external payable returns (address tokenAddress, uint256 tokensReceived) {
        uint256 fee = getCreationFee();
        require(msg.value > fee, "!fee+buy");
        require(!usedSalts[salt_], "!salt");
        
        uint256 virtualNative = getVirtualNativeForChain();
        
        // Deploy with CREATE2
        nine527 newToken = new nine527{salt: salt_}(
            name_,
            symbol_,
            treasuryFeeBP_,
            msg.sender,
            virtualNative
        );
        tokenAddress = address(newToken);
        
        usedSalts[salt_] = true;
        _trackAndCollectFee(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, salt_, virtualNative, fee);
        
        // Buy tokens
        uint256 buyAmount = msg.value - fee;
        tokensReceived = newToken.estimateBuyReturn(buyAmount);
        newToken.buyTokenFor{value: buyAmount}(msg.sender, minTokenAmt_, 0, true);
        
        emit TokenCreatedAndBought(tokenAddress, msg.sender, buyAmount, tokensReceived);
        return (tokenAddress, tokensReceived);
    }
    
    // ============ Simple (non-vanity) Functions ============
    
    function createTokenSimple(string calldata name_, string calldata symbol_, uint256 treasuryFeeBP_) external payable returns (address tokenAddress) {
        uint256 fee = getCreationFee();
        require(msg.value >= fee, "!fee");
        
        uint256 virtualNative = getVirtualNativeForChain();
        nine527 newToken = new nine527(name_, symbol_, treasuryFeeBP_, msg.sender, virtualNative);
        tokenAddress = address(newToken);
        _trackAndCollectFee(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, bytes32(0), virtualNative, fee);
        return tokenAddress;
    }
    
    function createTokenSimpleAndBuy(string calldata name_, string calldata symbol_, uint256 treasuryFeeBP_, uint256 minTokenAmt_) external payable returns (address tokenAddress, uint256 tokensReceived) {
        uint256 fee = getCreationFee();
        require(msg.value > fee, "!fee+buy");
        
        uint256 virtualNative = getVirtualNativeForChain();
        nine527 newToken = new nine527(name_, symbol_, treasuryFeeBP_, msg.sender, virtualNative);
        tokenAddress = address(newToken);
        _trackAndCollectFee(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, bytes32(0), virtualNative, fee);
        uint256 buyAmount = msg.value - fee;
        tokensReceived = newToken.estimateBuyReturn(buyAmount);
        newToken.buyTokenFor{value: buyAmount}(msg.sender, minTokenAmt_, 0, true);
        emit TokenCreatedAndBought(tokenAddress, msg.sender, buyAmount, tokensReceived);
        return (tokenAddress, tokensReceived);
    }
    
    // ============ Internal & View Functions ============
    
    function _trackAndCollectFee(address token, address deployer, string calldata name_, string calldata symbol_, uint256 treasuryFeeBP_, bytes32 salt_, uint256 virtualNative_, uint256 fee_) internal {
        allTokens.push(token);
        tokensByDeployer[deployer].push(token);
        isValidToken[token] = true;
        if (fee_ > 0) accumulatedFees += fee_;
        emit TokenCreated(token, deployer, name_, symbol_, treasuryFeeBP_, salt_, virtualNative_);
    }
    
    function totalTokens() external view returns (uint256) { return allTokens.length; }
    function getTokensByDeployer(address deployer) external view returns (address[] memory) { return tokensByDeployer[deployer]; }
    
    function getRecentTokens(uint256 count) external view returns (address[] memory) {
        uint256 total = allTokens.length;
        if (count > total) count = total;
        address[] memory recent = new address[](count);
        for (uint256 i = 0; i < count; i++) recent[i] = allTokens[total - 1 - i];
        return recent;
    }
    
    function getTokenInfoBatch(address[] calldata tokens) external view returns (string[] memory names, string[] memory symbols, uint256[] memory prices) {
        uint256 len = tokens.length;
        names = new string[](len);
        symbols = new string[](len);
        prices = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            if (isValidToken[tokens[i]]) {
                nine527 t = nine527(payable(tokens[i]));
                (names[i], symbols[i],,, prices[i],,) = t.getTokenInfo();
            }
        }
    }
    
    // ============ Admin Functions ============
    
    function setCreationFee(uint256 chainId_, uint256 newFee) external { require(msg.sender == feeRecipient, "!auth"); creationFee[chainId_] = newFee; }
    function setFeeRecipient(address newRecipient) external { require(msg.sender == feeRecipient && newRecipient != address(0), "!auth"); feeRecipient = newRecipient; }
    
    function setNativePrice(uint256 chainId_, uint256 priceUSDCents_) external {
        require(msg.sender == feeRecipient, "!auth");
        require(priceUSDCents_ > 0, "!price");
        nativePriceUSDCents[chainId_] = priceUSDCents_;
        emit NativePriceUpdated(chainId_, priceUSDCents_);
    }
    
    function setNativePricesBatch(uint256[] calldata chainIds_, uint256[] calldata pricesUSDCents_) external {
        require(msg.sender == feeRecipient, "!auth");
        require(chainIds_.length == pricesUSDCents_.length, "!length");
        for (uint256 i = 0; i < chainIds_.length; i++) {
            require(pricesUSDCents_[i] > 0, "!price");
            nativePriceUSDCents[chainIds_[i]] = pricesUSDCents_[i];
            emit NativePriceUpdated(chainIds_[i], pricesUSDCents_[i]);
        }
    }
    
    function withdrawFees() external {
        require(msg.sender == feeRecipient, "!auth");
        uint256 amount = accumulatedFees;
        require(amount > 0, "!fees");
        accumulatedFees = 0;
        (bool success, ) = payable(feeRecipient).call{value: amount}("");
        require(success, "!transfer");
        emit FeesWithdrawn(feeRecipient, amount);
    }
    
    function withdrawTokenFees(address tokenAddress) external {
        require(msg.sender == feeRecipient, "!auth");
        require(isValidToken[tokenAddress], "!token");
        nine527(payable(tokenAddress)).withdrawFactoryFees();
    }
    
    receive() external payable { accumulatedFees += msg.value; }
}
