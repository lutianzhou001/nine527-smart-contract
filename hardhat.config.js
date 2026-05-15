require("@okxweb3/hardhat-explorer-verify");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.35",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1,
      },
      viaIR: true,
      evmVersion: "osaka",
    },
  },

  // Contracts live in src/ not the default contracts/
  paths: {
    sources: "./src",
  },

  networks: {
    xlayer: {
      url: "https://rpc.xlayer.tech",
      chainId: 196,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },

  // @okxweb3/hardhat-explorer-verify uses the etherscan config format
  etherscan: {
    apiKey: {
      xlayer: process.env.OKLINK_API_KEY || "nokeyneeded",
    },
    customChains: [
      {
        network: "xlayer",
        chainId: 196,
        urls: {
          apiURL: "https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER",
          browserURL: "https://www.oklink.com/xlayer",
        },
      },
    ],
  },
};
