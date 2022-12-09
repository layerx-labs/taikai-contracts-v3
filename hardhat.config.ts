import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import {HardhatNetworkAccountUserConfig} from "hardhat/types/config";
import { STAGING_ACCOUNTS_PKEYS} from "./config/constants";

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
  networks: {
    hardhat: {
      chainId: 1337,
      accounts: devAccounts
    },
    vp: {
      url: "https://vp-eth.taikai.network:8080",
      accounts: STAGING_ACCOUNTS_PKEYS
    },
    eden: {
      url: "https://eden-eth.taikai.network:8080",
      accounts: STAGING_ACCOUNTS_PKEYS
    },
    gaia: {
      url: "https://gaia-eth.taikai.network:8080",
      accounts: STAGING_ACCOUNTS_PKEYS
    },
    eva: {
      url: "https://eva-eth.taikai.network:8080",
      accounts: STAGING_ACCOUNTS_PKEYS
    },
    atena: {
      url: "https://atena-eth.taikai.network:8080",
      accounts: STAGING_ACCOUNTS_PKEYS 
    },
  },
};

export default config;
