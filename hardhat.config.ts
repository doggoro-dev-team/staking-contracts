import "dotenv/config";
import "hardhat-abi-exporter";
import { HardhatUserConfig } from "hardhat/config";
import "@nomiclabs/hardhat-waffle";
import "@nomiclabs/hardhat-ethers";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";

import "hardhat-deploy";

const config: HardhatUserConfig = {
  namedAccounts: {
    deployer: {
      default: 0,
    }
  },
  networks: {
    localhost: {
      url: "http://localhost:8545",
    },
    chapel: {
      gasPrice: 1000000000,
      url: process.env.CHAPEL_URL || "",
      accounts: [process.env.PRIVATE_KEY || ""],
    },
    bsc: {
      url: process.env.BSC_URL || "",
      accounts: [process.env.PRIVATE_KEY || ""],
    },
    hardhat: {
      allowUnlimitedContractSize: true,
    },
  },
  solidity: {
    version: "0.8.4",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  mocha: {
    timeout: 40000,
  },
  gasReporter: {
    currency: "USD",
    gasPrice: 100,
    // enabled: process.env.REPORT_GAS ? true : false,
  },
  abiExporter: {
    except: ["@openzeppelin"],
  },
};

export default config;
