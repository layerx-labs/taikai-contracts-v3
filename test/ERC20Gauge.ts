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

})