// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { ERC721Enumerable } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

import { ILiquidityGauge } from "./interfaces/ILiquidityGauge.sol";

import { ICLPool } from "./interfaces/pool/ICLPool.sol";
import { TransferHelper } from "./libraries/TransferHelper.sol";
import { INonfungiblePositionManager } from "./interfaces/INonfungiblePositionManager.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import { EnumerableSet } from "./libraries/EnumerableSet.sol";
import { SafeCast } from "./libraries/SafeCast.sol";
import { FullMath } from "./libraries/FullMath.sol";
import { FixedPoint128 } from "./libraries/FixedPoint128.sol";
import { ProtocolTimeLibrary } from "./libraries/ProtocolTimeLibrary.sol";
import { IReward } from "./interfaces/IReward.sol";

contract LiquidityGauge is
  ILiquidityGauge,
  ERC721Holder,
  ERC721Enumerable,
  Ownable,
  ReentrancyGuard
{
  using EnumerableSet for EnumerableSet.UintSet;
  using SafeCast for uint128;

  error LiquidityGauge__ParamsMismatch();
  error LiquidityGauge__NotApproved();
  error LiquidityGauge__AddressInvalid();
  error LiquidityGauge__InvalidDuration();
  /// @inheritdoc ILiquidityGauge
  INonfungiblePositionManager public override nft;
  /// @inheritdoc ILiquidityGauge
  ICLPool public override pool;

  /// @inheritdoc ILiquidityGauge
  address public override rewardToken;

  uint256 public rewardRate;
  /**
   * @notice Constants for the boosting factor and the lock duration
   */
  uint256 constant ONE_HUNDRED_PERCENT = 100;
  uint256 constant ONE_TEN_PERCENT = 110;
  uint256 constant ONE_TWENTY_PERCENT = 120;
  uint256 constant ONE_THIRTY_PERCENT = 130;
  uint256 constant ONE_FOURTY_PERCENT = 140;
  uint256 constant ONE_FIFTY_PERCENT = 150;
  uint256 constant ONE_SIXTY_PERCENT = 160;

  uint256 constant ONE_MONTH = 30 days;
  uint256 constant THREE_MONTHS = 3 * ONE_MONTH;
  uint256 constant SIX_MONTHS = 6 * ONE_MONTH;
  uint256 constant TWELVE_MONTHS = 12 * ONE_MONTH;
  uint256 constant TWENTY_FOUR_MONTHS = 24 * ONE_MONTH;
  uint256 constant FOURTY_EIGHT_MONTHS = 48 * ONE_MONTH;

  uint256 internal constant PRECISION = 10 ** 18;
  uint256 internal constant BOOST_PRECISION = 100;

  /// @dev The set of all staked nfts for a given address
  mapping(address => EnumerableSet.UintSet) internal _stakes;
  /// @inheritdoc ILiquidityGauge
  mapping(uint256 => uint256) public override rewardGrowthInside;
  address[] private _providers; // Stores the providers to track length

  mapping(uint256 => uint256) public rewards;
  mapping(uint256 => uint256) public lastUpdateTime;

  /// @notice Counter for NFT IDs
  uint256 private _nftIdCounter = 1;
  uint256 private _totalStaked = 0;
  uint256 private _totalShares = 0;

  address public override token0;
  address public override token1;
  int24 public override tickSpacing;

  /**
   * @notice Struct to store the lock NFT Details
   */
  struct Lock {
    uint256 amount;
    uint256 shares;
    uint256 boostingFactor;
    uint256 unlockTime;
  }
  /// @notice Mapping of NFT ID to lock details
  mapping(uint256 => Lock) public _locksPerNft;

  constructor(
    string memory name,
    string memory symbol,
    address owner,
    address _pool,
    address _rewardToken,
    address _nft,
    address _token0,
    address _token1,
    int24 _tickSpacing
  ) ERC721(name, symbol) Ownable() {
    _transferOwnership(owner);
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

  /**
   * @notice Internal function to mint a new NFT
   * @param to The address to mint the NFT to
   * @param amount The amount of tokens to mint
   * @param time The duration of the lock
   * @return The ID of the minted NFT
   */
  function _mintNFT(address to, uint128 amount, uint256 time) internal returns (uint256) {
    uint256 tokenId = _nftIdCounter; // Get the current token ID
    _mint(to, tokenId); // Mint the NFT

    (uint256 fixedDuration, uint256 boostingFactorCalculated) = boostingFactor(time);

    uint256 shares = (amount * boostingFactorCalculated) / BOOST_PRECISION;

    Lock storage lockForNft = _locksPerNft[tokenId];
    lockForNft.amount = amount;
    lockForNft.shares = shares;
    lockForNft.boostingFactor = boostingFactorCalculated;
    lockForNft.unlockTime = block.timestamp + fixedDuration;
    _totalShares += shares;

    // Set the UR
    _nftIdCounter++; // Increment the token ID counter
    return tokenId; // Return the token ID
  }

  function _isInRange(int24 tickLower, int24 tickUpper) internal view returns (bool) {
    (, int24 currentTick, , , , ) = pool.slot0();
    return (currentTick >= tickLower && currentTick <= tickUpper);
  }

  /// @inheritdoc ILiquidityGauge
  function deposit(
    address receiver,
    uint256 tokenId,
    uint256 time
  ) external override nonReentrant returns (uint256 nftId) {
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
    if (!_isInRange(tickLower, tickUpper)) revert LiquidityGauge__ParamsMismatch();
    if (token0 != _token0 || token1 != _token1 || tickSpacing != _tickSpacing)
      revert LiquidityGauge__ParamsMismatch();

    // Transfer the NFT to the gauge
    nft.safeTransferFrom(msg.sender, address(this), tokenId);
    _stakes[msg.sender].add(tokenId);

    (, , , , , , , uint128 liquidityToStake, , , , ) = nft.positions(tokenId);

    // Mint the amount of tokens to the sender
    nftId = _mintNFT(receiver, liquidityToStake, time);
    _totalStaked += liquidityToStake;

    emit Deposit(msg.sender, receiver, liquidityToStake, nftId, time);
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

  /**
   * @notice Returns the boosting factor for a given lock duration
   * @param lockDuration The duration of the lock
   * @return The boosting factor
   */
  function boostingFactor(uint256 lockDuration) public pure returns (uint256, uint256) {
    // 0x 1.0x Boost
    if (lockDuration == 0) return (0, ONE_HUNDRED_PERCENT);
    // 0 - 1 month 1.1x Boost
    if (lockDuration >= 0 && lockDuration <= ONE_MONTH) return (ONE_MONTH, ONE_TEN_PERCENT);
    // 1 - 3 months 1.2x Boost
    if (lockDuration > ONE_MONTH && lockDuration <= THREE_MONTHS)
      return (THREE_MONTHS, ONE_TWENTY_PERCENT);
    // 3 - 6 months 1.3x Boost
    if (lockDuration > THREE_MONTHS && lockDuration <= SIX_MONTHS)
      return (SIX_MONTHS, ONE_THIRTY_PERCENT);
    // 6 - 12 months 1.4x Boost
    if (lockDuration > THREE_MONTHS && lockDuration <= TWELVE_MONTHS)
      return (TWELVE_MONTHS, ONE_FOURTY_PERCENT);
    // 12 - 24 months 1.5x Boost
    if (lockDuration > TWELVE_MONTHS && lockDuration <= TWENTY_FOUR_MONTHS)
      return (TWENTY_FOUR_MONTHS, ONE_FIFTY_PERCENT);
    // 24 - 48 months 1.6x Boost
    if (lockDuration > TWENTY_FOUR_MONTHS && lockDuration <= FOURTY_EIGHT_MONTHS)
      return (FOURTY_EIGHT_MONTHS, ONE_SIXTY_PERCENT);
    // Invalid duration
    revert LiquidityGauge__InvalidDuration();
  }
}
