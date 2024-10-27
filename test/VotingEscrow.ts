import { loadFixture, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import wordsToNumbers from 'words-to-numbers';

describe('Voting Escrow (veTKAI)', function () {
  const NUMBER_OF_DECIMALS = 18;
  const ERROR_FACTOR = 5;
  const contractMetadata = {
    name: 'TAIKAI Voting Escrow',
    symbol: 'veTKAI',
    version: '1.0.0',
    decimals: NUMBER_OF_DECIMALS,
  };

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

    // Deploy VeTKAI Contract
    const VotingEscrow = await ethers.getContractFactory('VeToken');
    const VeTKAI = await VotingEscrow.deploy(
      tkai.address,
      contractMetadata.name,
      contractMetadata.symbol,
      contractMetadata.version,
    );

    return { owner, alice, bob, charlie, tkai, VeTKAI };
  }

  function daysToSeconds(days: number) {
    return Math.floor(86400 * days);
  }

  function secondsToDays(seconds: number) {
    return (seconds - Date.now() / 1000) / 60 / 60 / 24;
  }

  function makeUnlockTime(days: number) {
    return daysToSeconds(days) + Math.floor(Date.now() / 1000);
  }

  describe('Deployment', function () {
    it('Checks Contract Metadata', async function () {
      const { VeTKAI, tkai } = await loadFixture(deployContract);

      expect(await tkai.decimals()).to.equal(NUMBER_OF_DECIMALS);
      expect(await VeTKAI.name()).to.equal(contractMetadata.name);
      expect(await VeTKAI.symbol()).to.equal(contractMetadata.symbol);
      expect(await VeTKAI.version()).to.equal(contractMetadata.version);
      expect(await VeTKAI.decimals()).to.equal(contractMetadata.decimals);
      expect(await VeTKAI.token()).to.equal(tkai.address);
      expect(await VeTKAI.totalLocked()).to.equal(0);
    });

    it('Reject deploy if invalid data', async function () {
      // Deploy VeTKAI Contract
      const VotingEscrow = await ethers.getContractFactory('VeToken');

      await expect(
        VotingEscrow.deploy(
          '0x0000000000000000000000000000000000000000',
          contractMetadata.name,
          contractMetadata.symbol,
          contractMetadata.version,
        ),
      ).to.revertedWithCustomError(VotingEscrow, 'ZeroAddressNotAllowed');
    });

    it('Creates a Lock', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('one hundred and twenty'); // 120 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await expect(VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)))
        .to.emit(VeTKAI, 'UserCheckpoint')
        .to.emit(VeTKAI, 'Supply')
        .to.emit(tkai, 'Transfer');

      const aliceTkaiBalance = await tkai.balanceOf(alice.address);
      const aliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);
      const aliceVeTkaiBalanceFormatted = formatCurrencyValue(
        aliceVeTkaiBalance.toBigInt(),
        2,
      ).valueWithDecimals;

      const totalSupply = (await VeTKAI['totalSupply()']()).toBigInt();

      console.log({ totalSupply });

      expect(aliceTkaiBalance.toBigInt()).to.equal(BigInt(withDecimal('million')) - BigInt(amount));
      expect(await VeTKAI.totalLocked()).to.equal(BigInt(amount));
      expect(aliceVeTkaiBalanceFormatted).to.closeTo(120, ERROR_FACTOR);
      expect((await VeTKAI.lockedEnd(alice.address)).toBigInt()).to.be.most(
        (await time.latest()) + daysToSeconds(365),
      );
      expect(totalSupply).to.be.equal(aliceVeTkaiBalance.toBigInt());
    });

    it('Fails on deposit 0', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await expect(
        VeTKAI.connect(alice).createLock(0, makeUnlockTime(365)),
      ).to.be.revertedWithCustomError(VeTKAI, 'InvalidDepositAmount');

      expect(await VeTKAI.totalLocked()).to.equal(0);
      expect(await VeTKAI['balanceOf(address)'](alice.address)).to.equal(0n);
    });

    it('Cretes Global Checkpoint', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      await expect(VeTKAI.connect(alice).checkpoint()).to.emit(VeTKAI, 'GlobalCheckpoint');
    });

    it('Fails creating more than one lock', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365));
      const aliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);
      const aliceVeTkaiBalanceFormatted = formatCurrencyValue(
        aliceVeTkaiBalance.toBigInt(),
        2,
      ).valueWithDecimals;

      await expect(
        VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)),
      ).to.be.revertedWithCustomError(VeTKAI, 'WithdrawOldTokensFirst');

      expect(await VeTKAI.totalLocked()).to.equal(BigInt(amount));
      expect(aliceVeTkaiBalanceFormatted).to.closeTo(10, ERROR_FACTOR);
    });

    it('Fails validating the locktime', async function () {
      const { VeTKAI, tkai, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);

      await expect(
        VeTKAI.connect(alice).createLock(amount, makeUnlockTime(6)),
      ).to.be.revertedWithCustomError(VeTKAI, 'LockingPeriodTooShort');

      await expect(
        VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365 * 4 + 7)),
      ).to.be.revertedWithCustomError(VeTKAI, 'LockingPeriodTooLong');
    });

    it('Deposits for someone else', async function () {
      const { VeTKAI, tkai, alice, bob } = await loadFixture(deployContract);

      const amount = withDecimal('one hundred and twenty'); // 120 TKAI
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await tkai.connect(bob).approve(VeTKAI.address, amount);

      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365));
      const previousAliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);
      await VeTKAI.connect(bob).depositFor(alice.address, amount);
      const afterAliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);
      const bobVeTkaiBalance = await VeTKAI['balanceOf(address)'](bob.address);

      const totalSupply = (await VeTKAI['totalSupply()']()).toBigInt();
      const aliceVeTkaiBalanceFormatted = formatCurrencyValue(
        afterAliceVeTkaiBalance.toBigInt(),
      ).valueWithDecimals;

      expect(previousAliceVeTkaiBalance.toBigInt()).to.lessThan(afterAliceVeTkaiBalance.toBigInt());
      expect(bobVeTkaiBalance.toBigInt()).to.equal(0n);
      expect(await VeTKAI.totalLocked()).to.equal(BigInt(amount) * 2n);
      expect(aliceVeTkaiBalanceFormatted).to.closeTo(240, ERROR_FACTOR);

      expect((await VeTKAI.lockedEnd(alice.address)).toBigInt()).to.be.most(
        (await time.latest()) + daysToSeconds(365),
      );
      expect(formatCurrencyValue(totalSupply).valueWithDecimals).to.be.closeTo(240, ERROR_FACTOR);
    });

    it('Increment Amount', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);
      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)); // Lock for 365 days

      // Increment Amount
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).increaseAmount(amount); // plus 10 TKAI

      const aliceBalance = await tkai.balanceOf(alice.address);
      const aliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);

      expect(formatCurrencyValue(aliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.closeTo(
        20,
        ERROR_FACTOR,
      );
      expect(aliceBalance).to.equal(BigInt(withDecimal('million')) - BigInt(withDecimal('twenty')));
      expect(await VeTKAI.lockedBalance(alice.address)).to.equal(BigInt(withDecimal('twenty')));
    });

    it('Increment LockTime', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);
      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)); // Lock for 365 days

      // Increment Locktime

      const previousLockedEnd = await VeTKAI.lockedEnd(alice.address);
      await VeTKAI.connect(alice).increaseUnlockTime(makeUnlockTime(730)); // increment locktime to 730 days
      const afterLockedEnd = await VeTKAI.lockedEnd(alice.address);
      const aliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);

      expect(afterLockedEnd.toBigInt()).to.be.greaterThan(previousLockedEnd.toBigInt());

      expect(formatCurrencyValue(aliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.closeTo(
        20,
        ERROR_FACTOR,
      );
      expect(await VeTKAI.lockedBalance(alice.address)).to.equal(BigInt(withDecimal('ten')));
    });

    it('Fails incrementing the amount of an expired lock', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);
      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)); // Lock for 365 days
      await time.increase(daysToSeconds(366));

      // Increment Amount
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await expect(VeTKAI.connect(alice).increaseAmount(amount)).to.be.revertedWithCustomError(
        VeTKAI,
        'LockExpired',
      );

      expect(await VeTKAI.totalLocked()).to.equal(BigInt(withDecimal('ten')));
    });

    it('Estimates Deposit', async function () {
      const { VeTKAI } = await loadFixture(deployContract);
      const amount = withDecimal('ten'); // 10 TKAI
      const locktime = makeUnlockTime(365);

      const { initialVeTokenBalance, actualUnlockTime, providedUnlockTime, bias } =
        await VeTKAI.estimateDeposit(amount, locktime);

      expect(formatCurrencyValue(initialVeTokenBalance.toBigInt()).valueWithDecimals).to.closeTo(
        10,
        ERROR_FACTOR,
      );
      expect(formatCurrencyValue(bias.toBigInt()).valueWithDecimals).to.closeTo(10, ERROR_FACTOR);
      expect(providedUnlockTime).to.equal(locktime);
      expect(secondsToDays(Number(actualUnlockTime))).to.be.closeTo(secondsToDays(locktime), 5);
    });

    it('Withdraw', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(730)); // Lock for 730 days
      const oldAliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);

      await time.increase(daysToSeconds(730));

      await expect(VeTKAI.connect(alice).withdraw())
        .to.emit(VeTKAI, 'Withdraw')
        .to.emit(VeTKAI, 'Supply')
        .to.emit(tkai, 'Transfer');

      const newAliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);
      const aliceBalance = await tkai.balanceOf(alice.address);

      expect(aliceBalance).to.equal(BigInt(withDecimal('million')));
      expect(await VeTKAI.totalLocked()).to.equal(0);
      expect(formatCurrencyValue(oldAliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.be.closeTo(
        20,
        1,
      );
      expect(newAliceVeTkaiBalance).to.equal(0);
    });

    it('Fails on trying to withdraw of a not expired lock', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);

      expect(formatCurrencyValue(oldAliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.be.closeTo(
        10,
        0.125,
      );
      await expect(VeTKAI.connect(alice).withdraw()).to.be.revertedWithCustomError(
        VeTKAI,
        'LockNotExpired',
      );
    });

    it('Fails on trying to withdraw from a nonexisting lock', async function () {
      const { VeTKAI, alice } = await loadFixture(deployContract);
      const oldAliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);

      expect(oldAliceVeTkaiBalance).to.be.equal(0);
      await expect(VeTKAI.connect(alice).withdraw()).to.be.revertedWithCustomError(
        VeTKAI,
        'NonExistingLock',
      );
    });

    it('Check the initial, intermediate and final balance', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)); // Lock for 365 days
      const oldAliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);

      await time.increase(daysToSeconds(91.25));
      const aliceBalanceAfterThreeMonths = await VeTKAI['balanceOf(address)'](alice.address); // After 3 months

      await time.increase(daysToSeconds(91.25));
      const aliceBalanceAfterSixMonths = await VeTKAI['balanceOf(address)'](alice.address); // After 6 months

      await time.increase(daysToSeconds(91.25));
      const aliceBalanceAfterNineMonths = await VeTKAI['balanceOf(address)'](alice.address); // After 9 months

      await time.increase(daysToSeconds(91.25));
      const aliceBalanceAfterOneYear = await VeTKAI['balanceOf(address)'](alice.address); // After 1 year (Max possible balance)

      expect(formatCurrencyValue(oldAliceVeTkaiBalance.toBigInt()).valueWithDecimals).to.be.closeTo(
        10,
        0.125,
      );
      expect(
        formatCurrencyValue(aliceBalanceAfterThreeMonths.toBigInt()).valueWithDecimals,
      ).to.be.closeTo(7.5, 0.125);
      expect(
        formatCurrencyValue(aliceBalanceAfterSixMonths.toBigInt()).valueWithDecimals,
      ).to.be.closeTo(5, 0.125);
      expect(
        formatCurrencyValue(aliceBalanceAfterNineMonths.toBigInt()).valueWithDecimals,
      ).to.be.closeTo(2.5, 0.125);
      expect(
        formatCurrencyValue(aliceBalanceAfterOneYear.toBigInt()).valueWithDecimals,
      ).to.be.equal(0);
    });

    it('Should present the totalSupply as the total voting power', async function () {
      const { tkai, VeTKAI, alice, bob, charlie } = await loadFixture(deployContract);

      const amount = withDecimal('ten'); // 10 TKAI

      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)); // Lock for 365 days

      await tkai.connect(bob).approve(VeTKAI.address, amount);
      await VeTKAI.connect(bob).createLock(amount, makeUnlockTime(365)); // Lock for 365 days

      await tkai.connect(charlie).approve(VeTKAI.address, amount);
      await VeTKAI.connect(charlie).createLock(amount, makeUnlockTime(365)); // Lock for 365 days

      const oldAliceVeTkaiBalance = await VeTKAI['balanceOf(address)'](alice.address);
      const oldBobVeTkaiBalance = await VeTKAI['balanceOf(address)'](bob.address);
      const oldCharlieVeTkaiBalance = await VeTKAI['balanceOf(address)'](charlie.address);
      const oldTotalSupply = await VeTKAI['totalSupply()']();

      await time.increase(daysToSeconds(365));

      const aliceBalanceAfterOneYear = await VeTKAI['balanceOf(address)'](alice.address); // Max possible balance
      const bobBalanceAfterOneYear = await VeTKAI['balanceOf(address)'](bob.address); // Max possible balance
      const charlieBalanceAfterOneYear = await VeTKAI['balanceOf(address)'](charlie.address); // Max possible balance

      const newTotalSupply = await VeTKAI['totalSupply()']();

      expect(formatCurrencyValue(aliceBalanceAfterOneYear.toBigInt()).valueWithDecimals).equal(0);
      expect(formatCurrencyValue(bobBalanceAfterOneYear.toBigInt()).valueWithDecimals).equal(0);
      expect(formatCurrencyValue(charlieBalanceAfterOneYear.toBigInt()).valueWithDecimals).equal(0);
      expect(formatCurrencyValue(newTotalSupply.toBigInt()).valueWithDecimals).to.be.equal(0);

      expect(formatCurrencyValue(oldTotalSupply.toBigInt()).valueWithDecimals).to.be.closeTo(
        30,
        0.5,
      );
      expect(formatCurrencyValue(oldTotalSupply.toBigInt()).valueWithDecimals).to.be.equal(
        formatCurrencyValue(
          oldAliceVeTkaiBalance.toBigInt() +
            oldBobVeTkaiBalance.toBigInt() +
            oldCharlieVeTkaiBalance.toBigInt(),
        ).valueWithDecimals,
      );
    });

    it('Stop decreasing Voting Power after lock expired', async function () {
      const { tkai, VeTKAI, alice } = await loadFixture(deployContract);

      const amount = withDecimal('one thousand'); // 1000 TKAI

      // Create Lock
      await tkai.connect(alice).approve(VeTKAI.address, amount);
      await VeTKAI.connect(alice).createLock(amount, makeUnlockTime(365)); // Lock for 365 days

      const aliceStartBalance = await VeTKAI['balanceOf(address)'](alice.address);
      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterOneYear = await VeTKAI['balanceOf(address)'](alice.address);
      await time.increase(daysToSeconds(365));
      const aliceBalanceAfterTwoYear = await VeTKAI['balanceOf(address)'](alice.address);

      expect(formatCurrencyValue(aliceStartBalance.toBigInt()).valueWithDecimals).to.be.closeTo(
        988,
        ERROR_FACTOR,
      );
      expect(
        formatCurrencyValue(aliceBalanceAfterOneYear.toBigInt()).valueWithDecimals,
      ).to.be.equal(0n);

      expect(aliceBalanceAfterTwoYear.toBigInt()).to.be.equal(aliceBalanceAfterOneYear.toBigInt());
    });
  });
});
