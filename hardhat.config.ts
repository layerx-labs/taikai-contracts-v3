import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import {HardhatNetworkAccountUserConfig} from "hardhat/types/config";
import { STAGING_ACCOUNTS_PKEYS} from "./config/constants";
import { STAGING_NETWORKS} from "./config/networks";

const PRIVATE_KEY = process.env.PRIVATE_KEY || STAGING_ACCOUNTS_PKEYS[0];

const devAccounts: HardhatNetworkAccountUserConfig[] =  STAGING_ACCOUNTS_PKEYS.map(
    key=>  { return {privateKey: key, balance: "1000000000000000000000000"}}); 

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 1337,
      accounts: devAccounts
    },
    ...STAGING_NETWORKS,
    mumbai: {
      chainId: 80001,
      url: "https://rpc-mumbai.maticvigil.com",
      accounts: STAGING_ACCOUNTS_PKEYS
    },
    polygon: {
      chainId: 137,
      url: "https://polygon-rpc.com",
      accounts: [PRIVATE_KEY]
    }
  },
};

export default config;
