import { loadFixture, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';

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
    const signers = await ethers.getSigners();
    const [owner, alice] = signers;
    const TKAI = await ethers.getContractFactory('TKAI');
    const tkai = await TKAI.deploy('TAIKAI Token', 'TKAI', owner.address);

    for (const account of signers) {
      if (account.address !== owner.address) {
        // Transfer 1M to each account
        await tkai.transfer(account.address, million);
      }
    }

    // Deploy VeTKAI Settings
    const veTKAISettings = await (
      await ethers.getContractFactory('VeTokenSettings')
    ).deploy();

    // Deploy VeTKAI Contract
    const VotingEscrow = await ethers.getContractFactory('VeToken');
    const VeTKAI = await VotingEscrow.deploy(
      tkai.address,
      contractMetadata.name,
      contractMetadata.symbol,
      contractMetadata.version,
      veTKAISettings.address
    );

    return { owner, alice, tkai, VeTKAI, veTKAISettings };
  }

  function daysToSeconds(days: number) {
    return Math.floor(86400 * days);
  }

  function secondsToDays(seconds: number | bigint | string) {
    return Math.floor(Number((BigInt(seconds) / 86400n).toString()));
  }

  describe('Deployment', function () {
    it('Checks Contract Metadata', async function () {
      const { VeTKAI, veTKAISettings, tkai } = await loadFixture(
        deployContract
      );

      expect(await tkai.decimals()).to.equal(18);
      expect(await VeTKAI.name()).to.equal(contractMetadata.name);
      expect(await VeTKAI.symbol()).to.equal(contractMetadata.symbol);
      expect(await VeTKAI.version()).to.equal(contractMetadata.version);
      expect(await VeTKAI.decimals()).to.equal(contractMetadata.decimals);
      expect(await VeTKAI.token()).to.equal(tkai.address);
      expect(await VeTKAI.supply()).to.equal(0);
      expect(await veTKAISettings.advancePercentage()).to.equal(1000);
    });

    it('Create Lock', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = ten; // 10 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 14 days
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(BigInt(million) - BigInt(ten));
      expect(await VeTKAI.totalLocked()).to.equal(BigInt(ten));
      expect(await VeTKAI.balanceOf(alice.address)).to.greaterThan(0);
    });

    it('Increment Amount', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);
      const amount = ten; // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 14 days

      // Increment Amount
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // plus 10 TKAI
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(
        BigInt(million) - BigInt(ten) - BigInt(ten)
      );
      expect(await VeTKAI.totalLocked()).to.equal(BigInt(ten) + BigInt(ten));
      expect(await VeTKAI.balanceOf(alice.address)).to.greaterThan(0);
    });

    it('Set Advance Percentage', async function () {
      const { alice, veTKAISettings } = await loadFixture(deployContract);
      await veTKAISettings.setAdvancePercentage(5000);

      await expect(
        veTKAISettings.setAdvancePercentage(65000)
      ).to.be.revertedWith('_advancePercentage should be between 0 and 10000');
      await expect(
        veTKAISettings.connect(alice).setAdvancePercentage(10000)
      ).to.be.revertedWith('Ownable: caller is not the owner');

      expect(await veTKAISettings.advancePercentage()).to.equal(5000);
    });

    it('Withdraw', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = ten; // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 14 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      await VeTKAI.connect(alice).withdraw();
      const newAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(BigInt(million));
      expect(await VeTKAI.totalLocked()).to.equal(0);
      expect(oldAliceVeTkaiBalance).to.be.greaterThan(0);
      expect(newAliceVeTkaiBalance).to.be.equal(0);
    });

    it('Check the initial and final balance', async function () {
      const { tkai, VeTKAI, alice, veTKAISettings } = await loadFixture(
        deployContract
      );

      const amount = ten; // 10 TKAI

      await veTKAISettings.setAdvancePercentage(5000); // 50%

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterOneYear = await VeTKAI.balanceOf(alice.address); // Max possible balance

      const errorFactor = 1000000000000n;

      expect(aliceBalanceAfterOneYear)
        .to.be.greaterThanOrEqual(
          oldAliceVeTkaiBalance.toBigInt() * 2n - errorFactor
        )
        .and.lessThanOrEqual(oldAliceVeTkaiBalance.toBigInt() * 2n);
    });

    it('Stop increasing Voting Power after lock expired', async function () {
      const { tkai, VeTKAI, alice, veTKAISettings } = await loadFixture(
        deployContract
      );

      const amount = ten; // 10 TKAI

      await veTKAISettings.setAdvancePercentage(5000); // 50%

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterOneYear = await VeTKAI.balanceOf(alice.address);
      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterTwoYear = await VeTKAI.balanceOf(alice.address);

      const errorFactor = 1000000000000n;

      expect(aliceBalanceAfterTwoYear).to.be.equal(aliceBalanceAfterOneYear);

      expect(aliceBalanceAfterOneYear)
        .to.be.greaterThanOrEqual(
          oldAliceVeTkaiBalance.toBigInt() * 2n - errorFactor
        )
        .and.lessThanOrEqual(oldAliceVeTkaiBalance.toBigInt() * 2n);
    });
  });
});
