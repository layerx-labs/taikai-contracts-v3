import { loadFixture, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import wordsToNumbers from 'words-to-numbers';

describe('Voting Escrow (veTKAI)', function () {
  const contractMetadata = {
    name: 'TAIKAI Voting Escrow',
    symbol: 'veTKAI',
    version: '1.0.0',
    decimals: 18,
  };

  /**
   * @notice A function that receives a number's name, for example one, two, three, four, and return a string with 18 decimals
   * for example, one => 1000000000000000000
   * @param value The number's name
   * @returns A string with 18 decimals
   */
  function withDecimal(value: string) {
    return wordsToNumbers(value)?.toString().concat('0'.repeat(18)) ?? '0';
  }

  const errorFactor = 1000000000000n;

  async function deployContract() {
    // Contracts are deployed using the first signer/account by default
    const signers = await ethers.getSigners();
    const [owner, alice] = signers;
    const TKAI = await ethers.getContractFactory('TKAI');
    const tkai = await TKAI.deploy('TAIKAI Token', 'TKAI', owner.address);

    for (const account of signers) {
      if (account.address !== owner.address) {
        // Transfer 1M to each account
        await tkai.transfer(account.address, withDecimal('million'));
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
      expect(await VeTKAI.totalSupply()).to.equal(0);
      expect(await veTKAISettings.advancePercentage()).to.equal(1000);
    });

    it('Reject deploy if invalid data', async function () {
      // Deploy VeTKAI Settings
      const veTKAISettings = await (
        await ethers.getContractFactory('VeTokenSettings')
      ).deploy();

      // Deploy VeTKAI Contract
      const VotingEscrow = await ethers.getContractFactory('VeToken');

      await expect(
        VotingEscrow.deploy(
          '0x0000000000000000000000000000000000000000',
          contractMetadata.name,
          contractMetadata.symbol,
          contractMetadata.version,
          veTKAISettings.address
        )
      ).to.revertedWith('_token_addr cannot be zero address');
    });

    it('Get the last user slope', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI
      const expectedSlope = 317097919837;

      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // Lock 10 TKAI for 365 days
      expect(await VeTKAI.getLastUserSlope(alice.address)).to.equal(
        BigInt(expectedSlope)
      );

      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // plus 10 TKAI
      expect(await VeTKAI.getLastUserSlope(alice.address)).to.equal(
        BigInt(expectedSlope * 2 + 1)
      );
    });

    it('Create a Deposit', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await expect(VeTKAI.connect(alice).deposit(amount))
        .to.emit(VeTKAI, 'Deposit')
        .to.emit(VeTKAI, 'Supply')
        .to.emit(tkai, 'Transfer');

      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(
        BigInt(withDecimal('million')) - BigInt(withDecimal('ten'))
      );
      expect(await VeTKAI.totalSupply()).to.equal(BigInt(withDecimal('ten')));
      expect(await VeTKAI.balanceOf(alice.address)).to.greaterThan(0);
      expect(await VeTKAI.lockedEnd(alice.address)).to.equal(
        Math.floor(
          ((await time.latest()) + daysToSeconds(365)) / daysToSeconds(7)
        ) * daysToSeconds(7)
      );
    });

    it('Tries to deposit 0, fails', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await expect(VeTKAI.connect(alice).deposit(0)).to.be.revertedWith(
        'Value should be greater than 0'
      );
      expect(await VeTKAI.totalSupply()).to.equal(0);
      expect(await VeTKAI.balanceOf(alice.address)).to.equal(0);
    });

    it('Increment Amount', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);
      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      // Increment Amount
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // plus 10 TKAI
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(
        BigInt(withDecimal('million')) - BigInt(withDecimal('twenty'))
      );
      expect(await VeTKAI.totalSupply()).to.equal(
        BigInt(withDecimal('twenty'))
      );
      expect(await VeTKAI.balanceOf(alice.address)).to.greaterThan(0);
    });

    it('Fails incrementing the amount of an expired lock', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);
      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days
      await time.increase(daysToSeconds(366));

      // Increment Amount
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await expect(VeTKAI.connect(alice).deposit(amount)).to.be.revertedWith(
        'Cannot add to expired lock. Withdraw'
      );
      expect(await VeTKAI.totalSupply()).to.equal(BigInt(withDecimal('ten')));
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

    it('Set lock Time', async function () {
      const { alice, veTKAISettings } = await loadFixture(deployContract);
      await veTKAISettings.setLockTime(daysToSeconds(730));

      await expect(veTKAISettings.setLockTime(5)).to.be.revertedWith(
        'locktime should be at least 1 week'
      );
      await expect(
        veTKAISettings.connect(alice).setLockTime(daysToSeconds(1095))
      ).to.be.revertedWith('Ownable: caller is not the owner');

      expect(await veTKAISettings.locktime()).to.equal(daysToSeconds(730));
    });

    it('Total Withdraw', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      await expect(VeTKAI.connect(alice).withdraw(withDecimal('ten')))
        .to.emit(VeTKAI, 'Withdraw')
        .to.emit(VeTKAI, 'Supply')
        .to.emit(tkai, 'Transfer');
      const newAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(BigInt(withDecimal('million')));
      expect(await VeTKAI.totalSupply()).to.equal(0);
      expect(oldAliceVeTkaiBalance).to.be.greaterThan(0);
      expect(newAliceVeTkaiBalance).to.equal(0);
    });

    it('Partial Withdraw', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      await VeTKAI.connect(alice).withdraw(withDecimal('five')); // 5 TKAI
      const newAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(
        BigInt(withDecimal('million')) - BigInt(withDecimal('five'))
      );
      expect(await VeTKAI.totalSupply()).to.equal(withDecimal('five'));
      expect(oldAliceVeTkaiBalance).to.be.greaterThan(0);
      expect(newAliceVeTkaiBalance)
        .to.be.greaterThanOrEqual(
          oldAliceVeTkaiBalance.toBigInt() / 2n - errorFactor
        )
        .and.lessThanOrEqual(oldAliceVeTkaiBalance.toBigInt() / 2n);
    });

    it('Insufficient balance on Withdraw', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);

      expect(oldAliceVeTkaiBalance).to.be.greaterThan(0);
      await expect(
        VeTKAI.connect(alice).withdraw(withDecimal('eleven'))
      ).to.be.revertedWith('Insufficient balance');
    });

    it('Check the initial and final balance', async function () {
      const { tkai, VeTKAI, alice, veTKAISettings } = await loadFixture(
        deployContract
      );

      const amount = withDecimal('ten'); // 10 TKAI

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

      const amount = withDecimal('ten'); // 10 TKAI

      await veTKAISettings.setAdvancePercentage(5000); // 50%

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterOneYear = await VeTKAI.balanceOf(alice.address);
      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterTwoYear = await VeTKAI.balanceOf(alice.address);

      expect(aliceBalanceAfterTwoYear).to.be.equal(aliceBalanceAfterOneYear);

      expect(aliceBalanceAfterOneYear)
        .to.be.greaterThanOrEqual(
          oldAliceVeTkaiBalance.toBigInt() * 2n - errorFactor
        )
        .and.lessThanOrEqual(oldAliceVeTkaiBalance.toBigInt() * 2n);
    });
  });
});
