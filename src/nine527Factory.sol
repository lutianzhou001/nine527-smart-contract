// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./nine527.sol";

/**
 * @title nine527Factory
 * @dev Factory contract for deploying 9527 meme tokens with vanity addresses
 * 
 * Features:
 * - Token addresses end with "9527" (vanity addresses via CREATE2)
 * - Tracks all deployed tokens
 * - Query tokens by deployer
 * 
 * Note: Contract optimized for size to fit within 24KB limit
 */
contract nine527Factory {
    
    address[] public allTokens;
    mapping(address => address[]) public tokensByDeployer;
    mapping(address => bool) public isValidToken;
    mapping(bytes32 => bool) public usedSalts;
    
    address public feeRecipient;
    uint256 public creationFee;
    bool public enforceVanity = true;
    
    event TokenCreated(
        address indexed tokenAddress,
        address indexed deployer,
        string name,
        string symbol,
        uint256 treasuryFeeBP,
        bytes32 salt
    );
    
    constructor() {
        feeRecipient = msg.sender;
    }
    
    /**
     * @dev Create token with vanity address ending in 9527
     */
    function createToken(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        bytes32 salt_
    ) external payable returns (address tokenAddress) {
        require(msg.value >= creationFee, "!fee");
        require(!usedSalts[salt_], "!salt");
        
        bytes memory bytecode = _getBytecode(name_, symbol_, treasuryFeeBP_, msg.sender);
        address predicted = _computeAddr(bytecode, salt_);
        
        if (enforceVanity) {
            require(uint160(predicted) & 0xFFFF == 0x9527, "!9527");
        }
        
        usedSalts[salt_] = true;
        
        assembly {
            tokenAddress := create2(0, add(bytecode, 0x20), mload(bytecode), salt_)
        }
        require(tokenAddress != address(0) && tokenAddress == predicted, "!deploy");
        
        _track(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, salt_);
        return tokenAddress;
    }
    
    /**
     * @dev Create token without vanity requirement
     */
    function createTokenSimple(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_
    ) external payable returns (address tokenAddress) {
        require(msg.value >= creationFee, "!fee");
        
        nine527 newToken = new nine527(name_, symbol_, treasuryFeeBP_, msg.sender);
        tokenAddress = address(newToken);
        
        _track(tokenAddress, msg.sender, name_, symbol_, treasuryFeeBP_, bytes32(0));
        return tokenAddress;
    }
    
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
        
        if (msg.value > 0 && feeRecipient != address(0)) {
            payable(feeRecipient).transfer(msg.value);
        }
        
        emit TokenCreated(token, deployer, name_, symbol_, treasuryFeeBP_, salt_);
    }
    
    /**
     * @dev Predict address for salt
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
        valid = (uint160(predicted) & 0xFFFF == 0x9527) && !usedSalts[salt_];
    }
    
    /**
     * @dev Get init code hash for off-chain mining
     */
    function getInitCodeHash(
        string calldata name_,
        string calldata symbol_,
        uint256 treasuryFeeBP_,
        address deployer_
    ) external pure returns (bytes32) {
        return keccak256(_getBytecode(name_, symbol_, treasuryFeeBP_, deployer_));
    }
    
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
    
    function _computeAddr(bytes memory bytecode, bytes32 salt) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, keccak256(bytecode)
        )))));
    }
    
    // View functions
    function totalTokens() external view returns (uint256) {
        return allTokens.length;
    }
    
    function getTokensByDeployer(address deployer) external view returns (address[] memory) {
        return tokensByDeployer[deployer];
    }
    
    function getRecentTokens(uint256 count) external view returns (address[] memory) {
        uint256 total = allTokens.length;
        if (count > total) count = total;
        
        address[] memory recent = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            recent[i] = allTokens[total - 1 - i];
        }
        return recent;
    }
    
    function getTokenInfoBatch(address[] calldata tokens) external view returns (
        string[] memory names,
        string[] memory symbols,
        uint256[] memory prices
    ) {
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
    
    // Admin functions
    function setCreationFee(uint256 newFee) external {
        require(msg.sender == feeRecipient, "!auth");
        creationFee = newFee;
    }
    
    function setFeeRecipient(address newRecipient) external {
        require(msg.sender == feeRecipient && newRecipient != address(0), "!auth");
        feeRecipient = newRecipient;
    }
    
    function setEnforceVanity(bool enforce) external {
        require(msg.sender == feeRecipient, "!auth");
        enforceVanity = enforce;
    }
}
