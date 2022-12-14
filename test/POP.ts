import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { STAGING_ACCOUNTS_ADDRESSES, ZERO_ADDRESS } from "../config/constants";
import { POP } from "../typechain-types";

describe("POP", function () {

  async function deployContract() {
    // Contracts are deployed using the first signer/account by default
    const [owner] = await ethers.getSigners();
    const POP = await ethers.getContractFactory("POP");
    const pop = await POP.deploy("Proof Of Participation", "POP", owner.address);
    return { owner, pop };
  }

  describe("Deployment", function () {
    let pop: POP, owner: SignerWithAddress

    beforeEach(async () => {
      ({ pop, owner } = await loadFixture(deployContract));
    })

    it("Mint Event", async () => {
      await expect(await pop.mint(STAGING_ACCOUNTS_ADDRESSES[0], '')).to.emit(
        pop,
        "Transfer"
      ).withArgs(
        ZERO_ADDRESS,
        STAGING_ACCOUNTS_ADDRESSES[0],
        0
      )
    });

    it("Pause Event", async () => {
      await expect(await pop.pause()).to.emit(
        pop,
        "Paused"
      ).withArgs(
        STAGING_ACCOUNTS_ADDRESSES[0],
      )
    });

    // Test soulbound token
    // TODO: Expect revert instead of balance check
    it("Soulbound transfer", async () => {
      await pop.mint(STAGING_ACCOUNTS_ADDRESSES[1], '');
      await pop.transferFrom(
        STAGING_ACCOUNTS_ADDRESSES[1], STAGING_ACCOUNTS_ADDRESSES[2], 0
      )

      expect(await pop.balanceOf(STAGING_ACCOUNTS_ADDRESSES[1])).to.equals(1)
    });

    it("Transfer contract ownership", async function () {
      expect(await pop.owner()).to.equal(owner.address);

      await pop.transferOwnership(STAGING_ACCOUNTS_ADDRESSES[1]);

      expect(await pop.owner()).to.equal(STAGING_ACCOUNTS_ADDRESSES[1]);
    });

    it("Mint while paused", async function () {
      await pop.pause();

      await expect(pop.mint(STAGING_ACCOUNTS_ADDRESSES[0], '')).to.be.reverted;
    });

    it("getNextId value", async function () {
      await pop.mint(STAGING_ACCOUNTS_ADDRESSES[0], '')
      expect(await pop.getNextId()).to.equals(1);

      await pop.mint(STAGING_ACCOUNTS_ADDRESSES[0], '')
      expect(await pop.getNextId()).to.equals(2);
    });
  });
});
