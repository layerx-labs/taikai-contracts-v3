// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { INonfungiblePositionManager } from "./INonfungiblePositionManager.sol";
import { ICLPool } from "./pool/ICLPool.sol";

interface ILiquidityGauge {
  event Deposit(address indexed user, uint256 indexed tokenId, uint128 indexed liquidityToStake);
  event Withdraw(address indexed user, uint256 indexed tokenId, uint128 indexed liquidityToStake);
  event ClaimRewards(address indexed from, uint256 amount);

  /// @notice NonfungiblePositionManager used to create nfts this gauge accepts
  function nft() external view returns (INonfungiblePositionManager);

  /// @notice Address of the CL pool linked to the gauge
  function pool() external view returns (ICLPool);

  /// @notice Cached address of token0, corresponding to token0 of the pool
  function token0() external view returns (address);

  /// @notice Cached address of token1, corresponding to token1 of the pool
  function token1() external view returns (address);

  /// @notice Cached tick spacing of the pool.
  function tickSpacing() external view returns (int24);

  /// @notice Address of the emissions token
  function rewardToken() external view returns (address);

  /// @notice Returns the rewardGrowthInside of the position at the last user action (deposit, withdraw, getReward)
  /// @param tokenId The tokenId of the position
  /// @return The rewardGrowthInside for the position
  function rewardGrowthInside(uint256 tokenId) external view returns (uint256);

  /// @notice Retrieve rewards for a tokenId
  /// @dev Throws if not called by the position owner
  /// @param tokenId The tokenId of the position
  function getReward(uint256 tokenId) external;

  /// @notice Used to deposit a CL position into the gauge
  /// @notice Allows the user to receive emissions instead of fees
  /// @param tokenId The tokenId of the position
  function deposit(uint256 tokenId) external;

  /// @notice Used to withdraw a CL position from the gauge
  /// @notice Allows the user to receive fees instead of emissions
  /// @notice Outstanding emissions will be collected on withdrawal
  /// @param tokenId The tokenId of the position
  function withdraw(uint256 tokenId) external;

  /// @notice Fetch all tokenIds staked by a given account
  /// @param depositor The address of the user
  /// @return The tokenIds of the staked positions
  function stakedValues(address depositor) external view returns (uint256[] memory);
}
