// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers } from "hardhat";

async function main() {
  // We get the contract to deploy
  const TKAI = await ethers.getContractFactory("TKAI");
  const accounts = await ethers.getSigners();
  const owner = accounts[0].address;
  const kai = await TKAI.deploy("TAIKAI Token", "TKAI", owner);
  await kai.deployed();
  console.log("TKAI Token deployed to:", kai.address);

  //
  for (const account of accounts) {
    if (account.address != owner) {
      // Transfer 1M to each account
      console.log("Transferring 1M to ", account.address);
      await kai.transfer(account.address, "1000000000000000000000000");
    }
  }
  // Deploy POP Contract
  const POP = await ethers.getContractFactory("POP");
  const pop = await POP.deploy("TAIKAI PoP", "POP", owner);
  await pop.deployed();
  console.log("POP Smart Contract deployed to:", pop.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
