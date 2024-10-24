import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { latest, latestBlock } from '@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time';
import { expect } from 'chai';
import { ethers } from 'hardhat';


describe.only('ERC20Gauge', function () {

    async function deployContract() {
        const [owner, alice, bob] = await ethers.getSigners();
        const TKAI = await ethers.getContractFactory('TKAI');
        const tkai = await TKAI.deploy('TAIKAI Token', 'TKAI', owner.address);
        const ERC20Gauge = await ethers.getContractFactory('ERC20Gauge');

        const supplyAlocated = 20000000n * 10n**18n;
        const duration = 3600n * 24n * 30n*48n;
        const rewardRatePerSecond = supplyAlocated / duration;

        const erc20Gauge = await ERC20Gauge.deploy(
            "TKAI Staking NFT",
            "sTKAI",
            owner.address,
            tkai.address,
            tkai.address,
            rewardRatePerSecond,
            // 48 months
            3600 * 24 * 30*48,

        );;

        await tkai.transfer(erc20Gauge.address, supplyAlocated);
        return { owner, alice, bob, erc20Gauge, rewardRatePerSecond , duration, tkai, supplyAlocated};
    };

    it('Initialialization', async function () {
        const start = Math.floor((new Date().getTime()-2000) /1000);
        const { erc20Gauge, tkai, rewardRatePerSecond, duration, owner} = await loadFixture(deployContract);
        expect(await erc20Gauge.getRewardRate()).to.equal(rewardRatePerSecond);
        expect(await erc20Gauge.getStakingToken()).to.equal(tkai.address);
        expect(await erc20Gauge.getRewardToken()).to.equal(tkai.address);
        expect(await erc20Gauge.getRewardStartTimestamp()).to.greaterThanOrEqual(start);
        expect(await erc20Gauge.getRewardEndTimestamp()).to.greaterThanOrEqual(BigInt(start) + BigInt(duration));
        expect(await erc20Gauge.owner()).to.equal(owner.address);
        expect(await erc20Gauge.totalSupply()).to.equal(0);
        expect(await erc20Gauge.getTotalLocked()).to.equal(0);
        expect(await erc20Gauge.getTotalLocks()).to.equal(0);
        expect(await erc20Gauge.getLocksForAddress(owner.address)).to.deep.equal([]);
    });


    it("Deposit 100TKAI No Lock", async function () {

    });

    it("Deposit 100TKAI 1.1x Boost", async function () {

    });

    it("Deposit 100TKAI 1.1x Boost- unlock fail before 1 month", async function () {

    });

    it("Deposit 100TKAI 1.2x Boost", async function () {

    });

    it("Deposit 100TKAI 1.2x Boost unlock fail before 3 months", async function () {

    });

    it("Deposit 100TKAI 1.3x Boost", async function () {

    });

    it("Deposit 100TKAI 1.3x Boost nlock fail before 6 months", async function () {

    });

    it("Deposit 100TKAI 1.4x Boost", async function () {

    });

    it("Deposit 100TKAI 1.4x Boost lock fail before 12 months", async function () {

    });

    it("Deposit 100TKAI 1.5x Boost", async function () {

    });

    it("Deposit 100TKAI 1.5x Boost lock fail before 24 months", async function () {

    });

    it("Deposit 100TKAI 1.6x Boost", async function () {

    });

    it("Deposit 100TKAI 1.6x Boost lock fail before 48 months", async function () {

    });


    it("Deposit and Withdraw", async function () {

    });


    it("Claim Rewards at 12Months ", async function () {

    });

    it("Claim Rewards at 48Months ", async function () {

    });


    it("Claim Multiple Rewards", async function () {

    });


    it("Multiple Deposits - Single Address", async function () {

    });

    it("Multiple Deposits - Multiple Addressese", async function () {

    });

    it("Test Boost Factors", async function () {

    });

    it("Test TokenURI", async function () {

    });

    it("Test Rewadrd left after 12Months", async function () {

    });

    it("Test Rewadrd left after 48Months", async function () {

    });

    it("test getBoostingFactor", async function () {
        const { erc20Gauge} = await loadFixture(deployContract);
        const oneMonth = 3600*24*30;
        expect(await erc20Gauge.getBoostingFactor(0)).to.deep.equal([0, 100]);
        expect(await erc20Gauge.getBoostingFactor(1* oneMonth)).to.deep.equal([1* oneMonth, 110]);
        expect(await erc20Gauge.getBoostingFactor(3* oneMonth)).to.deep.equal([3* oneMonth, 120]);
        expect(await erc20Gauge.getBoostingFactor(6* oneMonth)).to.deep.equal([6* oneMonth, 130]);
        expect(await erc20Gauge.getBoostingFactor(12* oneMonth)).to.deep.equal([12* oneMonth, 140]);
        expect(await erc20Gauge.getBoostingFactor(24* oneMonth)).to.deep.equal([24* oneMonth, 150]);
        expect(await erc20Gauge.getBoostingFactor(48* oneMonth)).to.deep.equal([48* oneMonth, 160]);

    });

})