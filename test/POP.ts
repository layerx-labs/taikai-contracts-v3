import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { ZERO_ADDRESS } from '../config/constants';
import { POP } from '../typechain-types';

describe('POP', function () {
  async function deployContract() {
    // Contracts are deployed using the first signer/account by default
    const signers = await ethers.getSigners();
    const [owner, alice, bob] = signers;
    const POP = await ethers.getContractFactory('POP');
    const pop = await POP.deploy(
      'Proof Of Participation',
      'POP',
      owner.address
    );
    return { owner, alice, bob, pop };
  }

  describe('Deployment', function () {
    let pop: POP,
      owner: SignerWithAddress,
      alice: SignerWithAddress,
      bob: SignerWithAddress;

    beforeEach(async () => {
      ({ pop, owner, alice, bob } = await loadFixture(deployContract));
    });

    it('Mint Event', async () => {
      await expect(await pop.mint(owner.address, ''))
        .to.emit(pop, 'Transfer')
        .withArgs(ZERO_ADDRESS, owner.address, 0);
    });

    it('Pause Event', async () => {
      await expect(await pop.pause())
        .to.emit(pop, 'Paused')
        .withArgs(owner.address);
    });

    // Test soulbound token
    it('Soulbound transfer', async () => {
      await pop.mint(alice.address, '');

      await expect(pop.transferFrom(alice.address, bob.address, 0)).to.be
        .reverted;
    });

    it('Transfer contract ownership', async function () {
      expect(await pop.owner()).to.equal(owner.address);

      await pop.transferOwnership(alice.address);

      expect(await pop.owner()).to.equal(alice.address);
    });

    it('Mint while paused', async function () {
      await pop.pause();

      await expect(pop.mint(owner.address, '')).to.be.revertedWith(
        'Pausable: paused'
      );
    });

    it('getNextId value', async function () {
      await pop.mint(owner.address, '');
      expect(await pop.getNextId()).to.equals(1);

      await pop.mint(owner.address, '');
      expect(await pop.getNextId()).to.equals(2);
    });
  });
});
