import 'hardhat-contract-sizer';
import 'hardhat-gas-reporter';
import 'hardhat-tracer';
import '@nomiclabs/hardhat-solhint';
import 'hardhat-docgen';
import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import { HardhatNetworkAccountUserConfig } from 'hardhat/types/config';
import { STAGING_ACCOUNTS_PKEYS } from './config/constants';
import { STAGING_NETWORKS } from './config/networks';

const PRIVATE_KEY = process.env.PRIVATE_KEY || STAGING_ACCOUNTS_PKEYS[0];

const devAccounts: HardhatNetworkAccountUserConfig[] =
  STAGING_ACCOUNTS_PKEYS.map(key => {
    return { privateKey: key, balance: '1000000000000000000000000' };
  });

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.24',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  docgen: {
    path: './docs',
    clear: true,
    runOnCompile: true,
  },
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
    only: [],
  },
  gasReporter: {
    enabled: !process.env.REPORT_GAS || process.env.REPORT_GAS === 'true',
  },
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {
      accounts: {
        accountsBalance: '100000000'.concat('0'.repeat(18)), // 100000000 ETH
      },
      blockGasLimit: 20995106510310,
      initialBaseFeePerGas: 7,
    },
    local: {
      chainId: 1337,
      url: 'http://127.0.0.1:8545',
      accounts: STAGING_ACCOUNTS_PKEYS,
    },
    ...STAGING_NETWORKS,
    mumbai: {
      chainId: 80001,
      url: 'https://rpc-mumbai.maticvigil.com',
      accounts: STAGING_ACCOUNTS_PKEYS,
    },
    polygon: {
      chainId: 137,
      url: 'https://polygon-rpc.com',
      accounts: [PRIVATE_KEY],
    },
  },
};

export default config;
