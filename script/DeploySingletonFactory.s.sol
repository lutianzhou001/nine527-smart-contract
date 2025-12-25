// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/**
 * @title DeploySingletonFactory
 * @dev Script to deploy the EIP-2470 Singleton Factory on any chain
 * 
 * The Singleton Factory (EIP-2470) allows deterministic deployment of contracts
 * using CREATE2, ensuring the same contract address on every chain.
 * 
 * Reference: https://eips.ethereum.org/EIPS/eip-2470
 * 
 * Steps:
 * 1. Check if factory already exists at 0xce0042B868300000d44A59004Da54A005ffdcf9f
 * 2. If not, send 0.0247 BNB to single-use deployment account
 * 3. Broadcast the raw deployment transaction
 */
contract DeploySingletonFactoryScript is Script {
    // EIP-2470 Constants
    address constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    address constant DEPLOYER_ACCOUNT = 0xBb6e024b9cFFACB947A71991E386681B1Cd1477D;
    uint256 constant DEPLOYMENT_COST = 0.0247 ether;

    function run() external {
        // Check if factory already deployed
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(SINGLETON_FACTORY)
        }

        if (codeSize > 0) {
            console.log("Singleton Factory already deployed at:", SINGLETON_FACTORY);
            return;
        }

        console.log("Singleton Factory not found. Deploying...");
        console.log("Single-use deployer account:", DEPLOYER_ACCOUNT);
        console.log("Required funding:", DEPLOYMENT_COST);

        // Check deployer account balance
        uint256 deployerBalance = DEPLOYER_ACCOUNT.balance;
        console.log("Current deployer balance:", deployerBalance);

        vm.startBroadcast();

        if (deployerBalance < DEPLOYMENT_COST) {
            uint256 needed = DEPLOYMENT_COST - deployerBalance;
            console.log("Funding deployer account with:", needed);
            
            // Send BNB to the single-use deployment account
            (bool success,) = DEPLOYER_ACCOUNT.call{value: needed}("");
            require(success, "Failed to fund deployer account");
            
            console.log("Funded deployer account successfully");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("==============================================");
        console.log("IMPORTANT: Now broadcast the raw transaction!");
        console.log("==============================================");
        console.log("");
        console.log("Run the following command to deploy the factory:");
        console.log("");
        console.log("cast publish --rpc-url <RPC_URL> 0xf9016c8085174876e8008303c4d88080b90154608060405234801561001057600080fd5b50610134806100206000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80634af63f0214602d575b600080fd5b60cf60048036036040811015604157600080fd5b810190602081018135640100000000811115605b57600080fd5b820183602082011115606c57600080fd5b80359060200191846001830284011164010000000083111715608d57600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600092019190915250929550509135925060eb915050565b604080516001600160a01b039092168252519081900360200190f35b6000818351602085016000f5939250505056fea26469706673582212206b44f8a82cb6b156bfcc3dc6aadd6df4eefd204bc928a4397fd15dacf6d5320564736f6c634300060200331b83247000822470");
    }
}

