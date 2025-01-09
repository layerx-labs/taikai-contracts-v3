// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { ILiquidityGauge } from "./interfaces/ILiquidityGauge.sol";

import { ICLPool } from "./interfaces/pool/ICLPool.sol";
import { TransferHelper } from "./libraries/TransferHelper.sol";
import { INonfungiblePositionManager } from "./interfaces/INonfungiblePositionManager.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { EnumerableSet } from "./libraries/EnumerableSet.sol";
import { SafeCast } from "./libraries/SafeCast.sol";
import { FullMath } from "./libraries/FullMath.sol";
import { FixedPoint128 } from "./libraries/FixedPoint128.sol";
import { ProtocolTimeLibrary } from "./libraries/ProtocolTimeLibrary.sol";
import { IReward } from "./interfaces/IReward.sol";

contract LiquidityGauge is ILiquidityGauge, ERC721Holder, ReentrancyGuard {
  using EnumerableSet for EnumerableSet.UintSet;
  using SafeCast for uint128;

  error LiquidityGauge__ParamsMismatch();
  error LiquidityGauge__NotApproved();
  error LiquidityGauge__AddressInvalid();

  /// @inheritdoc ILiquidityGauge
  INonfungiblePositionManager public override nft;
  /// @inheritdoc ILiquidityGauge
  ICLPool public override pool;

  /// @inheritdoc ILiquidityGauge
  address public override rewardToken;

  uint256 public rewardRate;

  /// @dev The set of all staked nfts for a given address
  mapping(address => EnumerableSet.UintSet) internal _stakes;
  /// @inheritdoc ILiquidityGauge
  mapping(uint256 => uint256) public override rewardGrowthInside;

  mapping(uint256 => uint256) public rewards;
  mapping(uint256 => uint256) public lastUpdateTime;

  address public override token0;
  address public override token1;
  int24 public override tickSpacing;

  constructor(
    address _pool,
    address _rewardToken,
    address _nft,
    address _token0,
    address _token1,
    int24 _tickSpacing
  ) {
    if (address(pool) != address(0)) revert LiquidityGauge__AddressInvalid();
    pool = ICLPool(_pool);
    rewardToken = _rewardToken;
    nft = INonfungiblePositionManager(_nft);
    token0 = _token0;
    token1 = _token1;
    tickSpacing = _tickSpacing;
  }

  // updates the claimable rewards and lastUpdateTime for tokenId
  function _updateRewards(uint256 tokenId, int24 tickLower, int24 tickUpper) internal {
    if (lastUpdateTime[tokenId] == block.timestamp) return;
    pool.updateRewardsGrowthGlobal();
    lastUpdateTime[tokenId] = block.timestamp;
    rewards[tokenId] += _earned(tokenId);
    rewardGrowthInside[tokenId] = pool.getRewardGrowthInside(tickLower, tickUpper, 0);
  }

  function _earned(uint256 tokenId) internal view returns (uint256) {
    uint256 lastUpdated = pool.lastUpdated();

    uint256 timeDelta = block.timestamp - lastUpdated;

    uint256 rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    uint256 rewardReserve = pool.rewardReserve();

    if (timeDelta != 0 && rewardReserve > 0 && pool.stakedLiquidity() > 0) {
      uint256 reward = rewardRate * timeDelta;
      if (reward > rewardReserve) reward = rewardReserve;

      rewardGrowthGlobalX128 += FullMath.mulDiv(reward, FixedPoint128.Q128, pool.stakedLiquidity());
    }

    (, , , , , int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = nft.positions(
      tokenId
    );

    uint256 rewardPerTokenInsideInitialX128 = rewardGrowthInside[tokenId];
    uint256 rewardPerTokenInsideX128 = pool.getRewardGrowthInside(
      tickLower,
      tickUpper,
      rewardGrowthGlobalX128
    );

    uint256 claimable = FullMath.mulDiv(
      rewardPerTokenInsideX128 - rewardPerTokenInsideInitialX128,
      liquidity,
      FixedPoint128.Q128
    );
    return claimable;
  }

  /// @inheritdoc ILiquidityGauge
  function getReward(uint256 tokenId) external override nonReentrant {
    if (!_stakes[msg.sender].contains(tokenId)) revert LiquidityGauge__NotApproved();

    (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nft.positions(tokenId);
    _getReward(tickLower, tickUpper, tokenId, msg.sender);
  }

  function _getReward(int24 tickLower, int24 tickUpper, uint256 tokenId, address owner) internal {
    _updateRewards(tokenId, tickLower, tickUpper);

    uint256 reward = rewards[tokenId];

    if (reward > 0) {
      delete rewards[tokenId];
      TransferHelper.safeTransfer(rewardToken, owner, reward);
      emit ClaimRewards(owner, reward);
    }
  }

  /// @inheritdoc ILiquidityGauge
  function deposit(uint256 tokenId) external override nonReentrant {
    if (nft.ownerOf(tokenId) != msg.sender) revert LiquidityGauge__NotApproved();
    (
      ,
      ,
      address _token0,
      address _token1,
      int24 _tickSpacing,
      int24 tickLower,
      int24 tickUpper,
      ,
      ,
      ,
      ,

    ) = nft.positions(tokenId);
    if (token0 != _token0 || token1 != _token1 || tickSpacing != _tickSpacing)
      revert LiquidityGauge__ParamsMismatch();

    // trigger update on staked position so NFT will be in sync with the pool
    nft.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId,
        recipient: msg.sender,
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );

    nft.safeTransferFrom(msg.sender, address(this), tokenId);
    _stakes[msg.sender].add(tokenId);

    (, , , , , , , uint128 liquidityToStake, , , , ) = nft.positions(tokenId);
    pool.stake(liquidityToStake.toInt128(), tickLower, tickUpper, true);

    uint256 rewardGrowth = pool.getRewardGrowthInside(tickLower, tickUpper, 0);
    rewardGrowthInside[tokenId] = rewardGrowth;
    lastUpdateTime[tokenId] = block.timestamp;

    emit Deposit(msg.sender, tokenId, liquidityToStake);
  }

  /// @inheritdoc ILiquidityGauge
  function withdraw(uint256 tokenId) external override nonReentrant {
    if (!_stakes[msg.sender].contains(tokenId)) revert LiquidityGauge__NotApproved();

    // trigger update on staked position so NFT will be in sync with the pool
    nft.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId,
        recipient: msg.sender,
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );

    (, , , , , int24 tickLower, int24 tickUpper, uint128 liquidityToStake, , , , ) = nft.positions(
      tokenId
    );
    _getReward(tickLower, tickUpper, tokenId, msg.sender);

    // update virtual liquidity in pool only if token has existing liquidity
    // i.e. not all removed already via decreaseStakedLiquidity
    if (liquidityToStake != 0) {
      pool.stake(-liquidityToStake.toInt128(), tickLower, tickUpper, true);
    }

    _stakes[msg.sender].remove(tokenId);
    nft.safeTransferFrom(address(this), msg.sender, tokenId);

    emit Withdraw(msg.sender, tokenId, liquidityToStake);
  }

  /// @inheritdoc ILiquidityGauge
  function stakedValues(
    address depositor
  ) external view override returns (uint256[] memory staked) {
    uint256 length = _stakes[depositor].length();
    staked = new uint256[](length);
    for (uint256 i = 0; i < length; i++) {
      staked[i] = _stakes[depositor].at(i);
    }
  }
}
