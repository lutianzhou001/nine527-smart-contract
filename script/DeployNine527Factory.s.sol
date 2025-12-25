// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/nine527Factory.sol";

/**
 * @title Deploynine527Factory
 * @dev Deploy nine527Factory using EIP-2470 Singleton Factory for deterministic addresses
 *
 * This ensures the nine527Factory has the same address on every chain!
 * 
 * Usage:
 * forge script script/Deploynine527Factory.s.sol:Deploynine527FactoryScript \
 *   --rpc-url <RPC_URL> \
 *   --private-key <PRIVATE_KEY> \
 *   --broadcast
 */
contract Deploynine527FactoryScript is Script {
    // EIP-2470 Singleton Factory address (same on all chains)
    address constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    
    // Salt for deterministic deployment - using "9527" as salt
    bytes32 constant SALT = keccak256("nine527.factory.v1");

    function run() external {
        // Check if Singleton Factory exists
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(SINGLETON_FACTORY)
        }
        
        require(codeSize > 0, "Singleton Factory not deployed! Deploy it first using deploy-singleton-bnb.sh");

        // Calculate deterministic address
        bytes memory initCode = type(nine527Factory).creationCode;
        bytes32 initCodeHash = keccak256(initCode);
        
        address predictedAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            SINGLETON_FACTORY,
            SALT,
            initCodeHash
        )))));

        console.log("==============================================");
        console.log("nine527Factory Deterministic Deployment");
        console.log("==============================================");
        console.log("");
        console.log("Singleton Factory:", SINGLETON_FACTORY);
        console.log("Salt:", vm.toString(SALT));
        console.log("Predicted Address:", predictedAddress);
        console.log("");

        // Check if already deployed
        assembly {
            codeSize := extcodesize(predictedAddress)
        }
        
        if (codeSize > 0) {
            console.log("nine527Factory already deployed at:", predictedAddress);
            return;
        }

        console.log("Deploying nine527Factory...");
        
        vm.startBroadcast();

        // Call Singleton Factory to deploy with CREATE2
        (bool success, bytes memory result) = SINGLETON_FACTORY.call(
            abi.encodeWithSignature("deploy(bytes,bytes32)", initCode, SALT)
        );
        
        require(success, "Deployment failed");
        
        address deployedAddress = abi.decode(result, (address));
        
        vm.stopBroadcast();

        console.log("");
        console.log("==============================================");
        console.log("SUCCESS!");
        console.log("==============================================");
        console.log("nine527Factory deployed at:", deployedAddress);
        console.log("");
        
        require(deployedAddress == predictedAddress, "Address mismatch!");
    }

    function getPredictedAddress() external pure returns (address) {
        bytes memory initCode = type(nine527Factory).creationCode;
        bytes32 initCodeHash = keccak256(initCode);
        
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            SINGLETON_FACTORY,
            SALT,
            initCodeHash
        )))));
    }
}

/**
 * @title Deploynine527FactoryDirect
 * @dev Direct deployment without Singleton Factory (for testing or single-chain deployments)
 */
contract Deploynine527FactoryDirectScript is Script {
    function run() external returns (address) {
        vm.startBroadcast();
        
        nine527Factory factory = new nine527Factory();
        
        vm.stopBroadcast();

        console.log("nine527Factory deployed at:", address(factory));
        
        return address(factory);
    }
}

