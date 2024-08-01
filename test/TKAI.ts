import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import wordsToNumbers from 'words-to-numbers';

describe('TKAI', function () {
  /**
   * @notice A function that receives a number's name, for example one, two, three, four, and return a string with 18 decimals
   * for example, one => 1000000000000000000
   * @param value The number's name
   * @returns A string with 18 decimals
   */
  function withDecimal(value: string) {
    return wordsToNumbers(value)?.toString().concat('0'.repeat(18)) ?? '0';
  }

  async function deployContract() {
    // Contracts are deployed using the first signer/account by default
    const signers = await ethers.getSigners();
    const [owner, alice, bob] = signers;
    const TKAI = await ethers.getContractFactory('TKAI');
    const tkai = await TKAI.deploy('TAIKAI Token', 'TKAI', owner.address);
    return { owner, alice, bob, tkai };
  }

  describe('Deployment', function () {
    it('Should have the full balance ', async function () {
      const { tkai, owner } = await loadFixture(deployContract);
      expect(await tkai.balanceOf(owner.address)).to.equal(withDecimal('three hundred million'));
    });

    it('Check Decimals', async function () {
      const { tkai } = await loadFixture(deployContract);
      expect(await tkai.decimals()).to.equal(18);
    });

    it('Transfer 1M to address', async function () {
      const { tkai, alice } = await loadFixture(deployContract);
      await tkai.transfer(alice.address, withDecimal('one million'));
      expect(await tkai.balanceOf(alice.address)).to.equal(withDecimal('one million'));
    });

    it('Alloance 1M to address', async function () {
      const { tkai, owner, alice } = await loadFixture(deployContract);
      await tkai.approve(alice.address, withDecimal('one million'));
      expect(await tkai.allowance(owner.address, alice.address)).to.equal(
        withDecimal('one million'),
      );
    });

    it('Transfer Event', async function () {
      const { tkai, owner, alice } = await loadFixture(deployContract);

      await expect(tkai.transfer(alice.address, withDecimal('one million')))
        .to.emit(tkai, 'Transfer')
        .withArgs(owner.address, alice.address, withDecimal('one million'));
    });
  });
});
