import { NetworkConfig } from "hardhat/types";
import { STAGING_ACCOUNTS_PKEYS} from "./constants";
export const STAGING_NETWORKS = {
     vp: {
        chainId: 1600,
        url: "https://eth-vp.taikai.network:18080",
        accounts: STAGING_ACCOUNTS_PKEYS
      },
      eden: {
        chainId: 1601,
        url: "https://eth-eden.taikai.network:18080",
        accounts: STAGING_ACCOUNTS_PKEYS
      },
      gaia: {
        chainId: 1602,
        url: "https://eth-gaia.taikai.network:18080",
        accounts: STAGING_ACCOUNTS_PKEYS
      },
      eva: {
        chainId: 1603,
        url: "https://eth-eva.taikai.network:18080",
        accounts: STAGING_ACCOUNTS_PKEYS
      },
      atena: {
        chainId: 1604,
        url: "https://eth-atena.taikai.network:18080",
        accounts: STAGING_ACCOUNTS_PKEYS 
      },
      heras: {
        chainId: 1605,
        url: "https://eth-heras.taikai.network:18080",
        accounts: STAGING_ACCOUNTS_PKEYS 
      },
}