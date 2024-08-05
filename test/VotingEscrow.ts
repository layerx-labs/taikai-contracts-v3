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

  const NUMBER_OF_DECIMALS = 18;

  /**
   * @notice A function that receives a number's name, for example one, two, three, four, and return a string with 18 decimals
   * for example, one => 1000000000000000000
   * @param value The number's name
   * @returns A string with NUMBER_OF_DECIMALS decimals
   */
  function withDecimal(value: string) {
    return wordsToNumbers(value)?.toString().concat('0'.repeat(NUMBER_OF_DECIMALS)) ?? '0';
  }

  const formatCurrencyValue = (_value: BigInt, fractionDigits = 2) => {
    const valueToArray = _value.toString().split('');
    const extractDecimals = valueToArray.splice(-NUMBER_OF_DECIMALS);

    const value = Number(valueToArray.join(''));
    const decimals = extractDecimals
      ? Number(Number(`0.${extractDecimals.join('')}`).toFixed(fractionDigits))
      : 0;

    return {
      value,
      decimals,
      valueWithDecimals: Number(value + decimals),
    };
  };

  const errorFactor = 1000000000000n;

  async function deployContract() {
    // Contracts are deployed using the first signer/account by default
    const signers = await ethers.getSigners();
    const [owner, alice, bob, charlie] = signers;
    const TKAI = await ethers.getContractFactory('TKAI');
    const tkai = await TKAI.deploy('TAIKAI Token', 'TKAI', owner.address);

    for (const account of signers) {
      if (account.address !== owner.address) {
        // Transfer 1M to each account
        await tkai.transfer(account.address, withDecimal('million'));
      }
    }

    // Deploy VeTKAI Settings
    const veTKAISettings = await (await ethers.getContractFactory('VeTokenSettings')).deploy();

    // Deploy VeTKAI Contract
    const VotingEscrow = await ethers.getContractFactory('VeToken');
    const VeTKAI = await VotingEscrow.deploy(
      tkai.address,
      contractMetadata.name,
      contractMetadata.symbol,
      contractMetadata.version,
      veTKAISettings.address,
    );

    return { owner, alice, bob, charlie, tkai, VeTKAI, veTKAISettings };
  }

  function daysToSeconds(days: number) {
    return Math.floor(86400 * days);
  }

  describe('Deployment', function () {
    it('Checks Contract Metadata', async function () {
      const { VeTKAI, veTKAISettings, tkai } = await loadFixture(deployContract);

      expect(await tkai.decimals()).to.equal(18);
      expect(await VeTKAI.name()).to.equal(contractMetadata.name);
      expect(await VeTKAI.symbol()).to.equal(contractMetadata.symbol);
      expect(await VeTKAI.version()).to.equal(contractMetadata.version);
      expect(await VeTKAI.decimals()).to.equal(contractMetadata.decimals);
      expect(await VeTKAI.token()).to.equal(tkai.address);
      expect(await VeTKAI.totalLocked()).to.equal(0);
    });

    it('Reject deploy if invalid data', async function () {
      // Deploy VeTKAI Settings
      const veTKAISettings = await (await ethers.getContractFactory('VeTokenSettings')).deploy();

      // Deploy VeTKAI Contract
      const VotingEscrow = await ethers.getContractFactory('VeToken');

      await expect(
        VotingEscrow.deploy(
          '0x0000000000000000000000000000000000000000',
          contractMetadata.name,
          contractMetadata.symbol,
          contractMetadata.version,
          veTKAISettings.address,
        ),
      ).to.revertedWithCustomError(VotingEscrow, 'ZeroAddressNotAllowed');
    });

    it('Create a Deposit', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await expect(VeTKAI.connect(alice).deposit(amount))
        .to.emit(VeTKAI, 'Deposit')
        .to.emit(tkai, 'Transfer');

      const aliceTkaiBalance = await tkai.balanceOf(alice.address);
      const aliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);

      expect(aliceTkaiBalance.toBigInt()).to.equal(
        BigInt(withDecimal('million')) - BigInt(withDecimal('ten')),
      );
      expect(await VeTKAI.totalLocked()).to.equal(BigInt(withDecimal('ten')));
      expect(aliceVeTkaiBalance.toBigInt()).to.equal(0n);
      expect(await VeTKAI.lockedEnd(alice.address)).to.equal(
        (await time.latest()) + daysToSeconds(365),
      );
    });

    it('Tries to deposit 0, fails', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await expect(VeTKAI.connect(alice).deposit(0)).to.be.revertedWithCustomError(
        VeTKAI,
        'InvalidDepositAmount',
      );

      expect(await VeTKAI.totalLocked()).to.equal(0);
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
      await time.increase(daysToSeconds(365));
      const aliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);

      expect(formatCurrencyValue(aliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.equal(20);

      expect(aliceBalance).to.equal(BigInt(withDecimal('million')) - BigInt(withDecimal('twenty')));
      expect(await VeTKAI.totalLocked()).to.equal(BigInt(withDecimal('twenty')));
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
      await expect(VeTKAI.connect(alice).deposit(amount)).to.be.revertedWithCustomError(
        VeTKAI,
        'DepositToExpiredLockNotAllowed',
      );

      expect(await VeTKAI.totalLocked()).to.equal(BigInt(withDecimal('ten')));
    });

    it('Set lock Time', async function () {
      const { alice, owner, veTKAISettings } = await loadFixture(deployContract);
      await veTKAISettings.setLockTime(daysToSeconds(730));

      await expect(veTKAISettings.setLockTime(daysToSeconds(5))).to.be.revertedWithCustomError(
        veTKAISettings,
        'InvalidLockTime',
      );

      await expect(
        veTKAISettings.connect(alice).setLockTime(daysToSeconds(1095)),
      ).to.be.revertedWith('Ownable: caller is not the owner');

      expect(veTKAISettings.setLockTime(daysToSeconds(731))).to.be.fulfilled;
      expect(await veTKAISettings.locktime()).to.equal(daysToSeconds(731));
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
        .to.emit(tkai, 'Transfer');

      const newAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(BigInt(withDecimal('million')));
      expect(await VeTKAI.totalLocked()).to.equal(0);
      expect(formatCurrencyValue(oldAliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.be.equal(
        0,
      );
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
      await time.increase(daysToSeconds(365));
      const newAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(BigInt(withDecimal('million')) - BigInt(withDecimal('five')));
      expect(await VeTKAI.totalLocked()).to.equal(withDecimal('five'));
      expect(formatCurrencyValue(oldAliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.be.equal(
        0,
      );
      expect(formatCurrencyValue(newAliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.be.equal(
        5,
      );
    });

    it('Insufficient balance on Withdraw', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);

      expect(oldAliceVeTkaiBalance).to.be.equal(0);
      await expect(
        VeTKAI.connect(alice).withdraw(withDecimal('eleven')),
      ).to.be.revertedWithCustomError(VeTKAI, 'InsufficientBalance');
    });

    it('Check the initial, intermediate and final balance', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days
      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);

      await time.increase(daysToSeconds(91.25));
      const aliceBalanceAfterThreeMonths = await VeTKAI.balanceOf(alice.address); // After 3 months

      await time.increase(daysToSeconds(91.25));
      const aliceBalanceAfterSixMonths = await VeTKAI.balanceOf(alice.address); // After 6 months

      await time.increase(daysToSeconds(91.25));
      const aliceBalanceAfterNineMonths = await VeTKAI.balanceOf(alice.address); // After 9 months

      await time.increase(daysToSeconds(91.25));
      const aliceBalanceAfterOneYear = await VeTKAI.balanceOf(alice.address); // After 1 year (Max possible balance)

      expect(formatCurrencyValue(oldAliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.be.equal(
        0,
      );
      expect(
        formatCurrencyValue(aliceBalanceAfterThreeMonths.toBigInt()).valueWithDecimals,
      ).to.be.equal(2.5);
      expect(
        formatCurrencyValue(aliceBalanceAfterSixMonths.toBigInt()).valueWithDecimals,
      ).to.be.equal(5);
      expect(
        formatCurrencyValue(aliceBalanceAfterNineMonths.toBigInt()).valueWithDecimals,
      ).to.be.equal(7.5);
      expect(
        formatCurrencyValue(aliceBalanceAfterOneYear.toBigInt()).valueWithDecimals,
      ).to.be.equal(10);
    });

    it('Should present the totalSupply as the total voting power', async function () {
      const { tkai, VeTKAI, alice, bob, charlie } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      await tkai.connect(bob).approve(VeTKAI.address, amount);
      await VeTKAI.connect(bob).deposit(amount); // Lock for 365 days

      await tkai.connect(charlie).approve(VeTKAI.address, amount);
      await VeTKAI.connect(charlie).deposit(amount); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI.balanceOf(alice.address);
      const oldBobVeTkaiBalance = await VeTKAI.balanceOf(bob.address);
      const oldCharlieVeTkaiBalance = await VeTKAI.balanceOf(charlie.address);
      const oldTotalSupply = await VeTKAI.totalSupply();

      await time.increase(daysToSeconds(365));

      const aliceBalanceAfterOneYear = await VeTKAI.balanceOf(alice.address); // Max possible balance
      const bobBalanceAfterOneYear = await VeTKAI.balanceOf(bob.address); // Max possible balance
      const charlieBalanceAfterOneYear = await VeTKAI.balanceOf(charlie.address); // Max possible balance

      const newTotalSupply = await VeTKAI.totalSupply();

      expect(formatCurrencyValue(aliceBalanceAfterOneYear.toBigInt()).valueWithDecimals).equal(10);
      expect(formatCurrencyValue(bobBalanceAfterOneYear.toBigInt()).valueWithDecimals).equal(10);
      expect(formatCurrencyValue(charlieBalanceAfterOneYear.toBigInt()).valueWithDecimals).equal(
        10,
      );

      expect(formatCurrencyValue(oldTotalSupply.toBigInt()).valueWithDecimals).to.be.lt(1);
      expect(formatCurrencyValue(newTotalSupply.toBigInt()).valueWithDecimals).to.be.equal(30);

      expect(formatCurrencyValue(oldTotalSupply.toBigInt()).valueWithDecimals).to.be.equal(
        formatCurrencyValue(
          oldAliceVeTkaiBalance.toBigInt() +
            oldBobVeTkaiBalance.toBigInt() +
            oldCharlieVeTkaiBalance.toBigInt(),
        ).valueWithDecimals,
      );

      expect(formatCurrencyValue(newTotalSupply.toBigInt()).valueWithDecimals).to.be.equal(
        formatCurrencyValue(
          aliceBalanceAfterOneYear.toBigInt() +
            bobBalanceAfterOneYear.toBigInt() +
            charlieBalanceAfterOneYear.toBigInt(),
        ).valueWithDecimals,
      );
    });

    it('Stop increasing Voting Power after lock expired', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).deposit(amount); // Lock for 365 days

      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterOneYear = await VeTKAI.balanceOf(alice.address);
      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterTwoYear = await VeTKAI.balanceOf(alice.address);

      expect(
        formatCurrencyValue(aliceBalanceAfterOneYear.toBigInt()).valueWithDecimals,
      ).to.be.equal(10);

      expect(aliceBalanceAfterTwoYear.toBigInt()).to.be.equal(aliceBalanceAfterOneYear.toBigInt());
    });

    it('Revert on not allowed erc20 methods', async function () {
      const { VeTKAI, alice, owner } = await loadFixture(deployContract);

      await expect(VeTKAI.allowance(owner.address, alice.address)).to.be.reverted;
      await expect(VeTKAI.transfer(alice.address, withDecimal('ten'))).to.be.reverted;
      await expect(VeTKAI.approve(alice.address, withDecimal('ten'))).to.be.reverted;
      await expect(VeTKAI.transferFrom(owner.address, alice.address, withDecimal('ten'))).to.be
        .reverted;
    });
  });
});
