import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { STAGING_ACCOUNTS_ADDRESSES } from '../config/constants';

describe('Voting Escrow (veTKAI)', function () {
  const contractMetadata = {
    name: 'TAIKAI Voting Escrow',
    symbol: 'veTKAI',
    version: '1.0.0',
    decimals: 18,
  };

  const ten = '10000000000000000000';
  const million = '1000000000000000000000000';
  async function deployContract() {
    // Contracts are deployed using the first signer/account by default
    const [owner, alice] = await ethers.getSigners();
    const TKAI = await ethers.getContractFactory('TKAI');
    const tkai = await TKAI.deploy('TAIKAI Token', 'TKAI', owner.address);

    for (const account of STAGING_ACCOUNTS_ADDRESSES) {
      if (account !== owner.address) {
        // Transfer 1M to each account
        await tkai.transfer(account, million);
      }
    }

    // Deploy VeTKAI Contract
    const VotingEscrow = await ethers.getContractFactory('VeToken');
    const VeTKAI = await VotingEscrow.deploy(
      tkai.address,
      contractMetadata.name,
      contractMetadata.symbol,
      contractMetadata.version
    );

    return { owner, alice, tkai, VeTKAI };
  }

  function makeUnlockTime(days: number) {
    return Math.floor(Date.now() / 1000 + 86400 * days);
  }

  describe('Deployment', function () {
    it('Check Contract Metadata', async function () {
      const { VeTKAI, tkai } = await loadFixture(deployContract);

      expect(await tkai.decimals()).to.equal(18);
      expect(await VeTKAI.name()).to.equal(contractMetadata.name);
      expect(await VeTKAI.symbol()).to.equal(contractMetadata.symbol);
      expect(await VeTKAI.version()).to.equal(contractMetadata.version);
      expect(await VeTKAI.decimals()).to.equal(contractMetadata.decimals);
      expect(await VeTKAI.token()).to.equal(tkai.address);
      expect(await VeTKAI.supply()).to.equal(0);
      expect(await VeTKAI.advance_percentage()).to.equal(1000);
    });

    it('Create Lock', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);
      const amount = ten; // 10 TKAI
      await tkai.approve(VeTKAI.address, amount, { from: alice.address });
      await VeTKAI.createLock(amount, makeUnlockTime(14), {
        from: alice.address,
      }); // Lock for 14 days

      expect(await tkai.balanceOf(alice.address)).to.equal(
        1_000_000_000_000 - 10
      );
      expect(await VeTKAI.totalLocked()).to.equal(10);
      expect(await VeTKAI.balanceOf(alice.address)).to.greaterThan(0);
    });

    it('Increment Amount', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);
      const amount = ten; // 10 TKAI
      await tkai.approve(VeTKAI.address, amount, { from: alice.address });
      await VeTKAI.increaseAmount(amount, { from: alice.address }); // plus 10 TKAI

      expect(await tkai.balanceOf(alice.address)).to.equal(
        1_000_000_000_000 - 20
      );
      expect(await VeTKAI.totalLocked()).to.equal(20);
      expect(await VeTKAI.balanceOf(alice.address)).to.greaterThan(0);
    });

    it('Increase Unlock Time', async function () {
      const { VeTKAI, alice } = await loadFixture(deployContract);

      const aliceInitialLockedInfo = await VeTKAI.locked(alice.address);

      await VeTKAI.increaseUnlockTime(makeUnlockTime(7), {
        from: alice.address,
      }); // plus 10 TKAI
      expect(await VeTKAI.lockedEnd(alice.address)).to.greaterThan(
        aliceInitialLockedInfo.end
      );
    });

    it('Set Advance Percentage', async function () {
      const { VeTKAI, alice } = await loadFixture(deployContract);
      await VeTKAI.setAdvancePercentage(5000);

      expect(await VeTKAI.setAdvancePercentage(100000)).to.throw(
        'advance_percentage should be between 0 and 10000'
      );
      expect(
        await VeTKAI.setAdvancePercentage(10000, { from: alice.address })
      ).to.throw('Ownable: caller is not the owner');

      expect(await VeTKAI.advance_percentage()).to.equal(5000);
    });

    it('Withdraw', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);
      await VeTKAI.withdraw({ from: alice.address });
      expect(await tkai.balanceOf(alice.address)).to.equal(1_000_000_000_000);
      expect(await VeTKAI.totalLocked()).to.equal(0);
      expect(await VeTKAI.balanceOf(alice.address)).to.equal(0);
    });
  });
});
