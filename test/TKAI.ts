import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { STAGING_ACCOUNTS_ADDRESSES } from "../config/constants";

describe("TKAI", function () {
    
  const THREE_HUNDRED_M = 300_000_000_000_000;

  async function deployContract() {
    // Contracts are deployed using the first signer/account by default
    const [owner] = await ethers.getSigners();
    const TKAI = await ethers.getContractFactory("TKAI");
    const tkai = await TKAI.deploy("TAIKAI Token", "TKAI", owner.address);
    return { owner, tkai };
  }

  describe("Deployment", function () {
    it("Should have the full balance ", async function () {
      const { tkai, owner } = await loadFixture(deployContract);
      expect(await tkai.balanceOf(owner.address)).to.equal(THREE_HUNDRED_M);
    });

    it("Check Decimals", async function () {
      const { tkai } = await loadFixture(deployContract);
      expect(await tkai.decimals()).to.equal(6);
    });

    it("Transfer 1M to address", async function () {
      const { tkai } = await loadFixture(deployContract);
      await tkai.transfer(STAGING_ACCOUNTS_ADDRESSES[1], 1_000_000_000_000);
      expect(await tkai.balanceOf(STAGING_ACCOUNTS_ADDRESSES[1])).to.equal(
        1_000_000_000_000
      );
    });

    it("Alloance 1M to address", async function () {
      const { tkai } = await loadFixture(deployContract);
      await tkai.approve(STAGING_ACCOUNTS_ADDRESSES[1], 1_000_000_000_000);
      expect(
        await tkai.allowance(
          STAGING_ACCOUNTS_ADDRESSES[0],
          STAGING_ACCOUNTS_ADDRESSES[1]
        )
      ).to.equal(1_000_000_000_000);
    });

    it("Transfer Event", async function () {
      const { tkai } = await loadFixture(deployContract);
      await tkai.transfer(STAGING_ACCOUNTS_ADDRESSES[1], 1_000_000_000_000);
      await expect(
        tkai.transfer(STAGING_ACCOUNTS_ADDRESSES[1], 1_000_000_000_000)
      )
        .to.emit(tkai, "Transfer")
        .withArgs(
          STAGING_ACCOUNTS_ADDRESSES[0],
          STAGING_ACCOUNTS_ADDRESSES[1],
          1_000_000_000_000
        ); // We accept any value as `when` arg
    });
  });
});
