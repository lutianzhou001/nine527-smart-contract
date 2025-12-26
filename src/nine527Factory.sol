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
    
    address[] public allTokens;
    mapping(address => address[]) public tokensByDeployer;
    mapping(address => bool) public isValidToken;
    mapping(bytes32 => bool) public usedSalts;
    
    address public feeRecipient;
    uint256 public creationFee;
    uint256 public accumulatedFees;
    bool public enforceVanity = true;
    
    event TokenCreated(address indexed tokenAddress, address indexed deployer, string name, string symbol, uint256 treasuryFeeBP, bytes32 salt, uint256 virtualNative);
    event TokenCreatedAndBought(address indexed tokenAddress, address indexed deployer, uint256 buyAmount, uint256 tokensReceived);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event NativePriceUpdated(uint256 indexed chainId, uint256 priceUSDCents);
    
    constructor() {
        feeRecipient = msg.sender;
        creationFee = 0.1 ether;
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
    
    function createTokenSimple(string calldata name_, string calldata symbol_, uint256 treasuryFeeBP_) external payable returns (address tokenAddress) {
        require(msg.value >= creationFee, "!fee");
        uint256 virtualNative = getVirtualNativeForChain();
        nine527 newToken = new nine527(name_, symbol_, treasuryFeeBP_, msg.sender, virtualNative);
        tokenAddress = address(newToken);
        _trackAndCollectFee(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, bytes32(0), virtualNative);
        return tokenAddress;
    }
    
    function createTokenSimpleAndBuy(string calldata name_, string calldata symbol_, uint256 treasuryFeeBP_, uint256 minTokenAmt_) external payable returns (address tokenAddress, uint256 tokensReceived) {
        require(msg.value > creationFee, "!fee+buy");
        uint256 virtualNative = getVirtualNativeForChain();
        nine527 newToken = new nine527(name_, symbol_, treasuryFeeBP_, msg.sender, virtualNative);
        tokenAddress = address(newToken);
        _trackAndCollectFee(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, bytes32(0), virtualNative);
        uint256 buyAmount = msg.value - creationFee;
        tokensReceived = newToken.estimateBuyReturn(buyAmount);
        newToken.buyTokenFor{value: buyAmount}(msg.sender, minTokenAmt_, 0, true);
        emit TokenCreatedAndBought(tokenAddress, msg.sender, buyAmount, tokensReceived);
        return (tokenAddress, tokensReceived);
    }
    
    function _trackAndCollectFee(address token, address deployer, string calldata name_, string calldata symbol_, uint256 treasuryFeeBP_, bytes32 salt_, uint256 virtualNative_) internal {
        allTokens.push(token);
        tokensByDeployer[deployer].push(token);
        isValidToken[token] = true;
        if (creationFee > 0) accumulatedFees += creationFee;
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
    
    function setCreationFee(uint256 newFee) external { require(msg.sender == feeRecipient, "!auth"); creationFee = newFee; }
    function setFeeRecipient(address newRecipient) external { require(msg.sender == feeRecipient && newRecipient != address(0), "!auth"); feeRecipient = newRecipient; }
    function setEnforceVanity(bool enforce) external { require(msg.sender == feeRecipient, "!auth"); enforceVanity = enforce; }
    
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
