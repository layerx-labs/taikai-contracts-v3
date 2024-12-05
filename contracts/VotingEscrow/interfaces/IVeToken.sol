// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.24;
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IVeToken
/// @notice Interface for VeToken functionality.
interface IVeToken {
  /// @notice Retrieves the name of the token.
  function name() external view returns (string memory);

  /// @notice Retrieves the symbol of the token.
  function symbol() external view returns (string memory);

  /// @notice Retrieves the number of decimals for the token.
  function decimals() external view returns (uint8);

  /// @notice Retrieves the version of the VeToken contract.
  function version() external view returns (string memory);

  /// @notice Retrieves the address of the Token contract.
  function token() external view returns (IERC20);

  /// @notice Retrieves the actual epoch.
  function getEpoch() external view returns (uint256);

  /// @notice Retrieves the total of token Locked.
  function totalLocked() external view returns (uint256);

  /// @notice Retrieves the total of token Locked for a given address.
  function lockedBalance(address addr_) external view returns (uint256);

  /// @notice Get timestamp when `addr`'s lock finishes
  /// @param addr_ User wallet address
  /// @return Timestamp when lock finishes
  function lockedEnd(address addr_) external view returns (uint256);

  /// @notice Get the most recently recorded rate of voting power decrease for `addr`
  /// @param addr_ The address to get the rate for
  /// @return value of the slope
  function getLastUserSlope(address addr_) external view returns (int128);

  /// @notice Get the timestamp for checkpoint `idx` for `addr`
  /// @param addr_ User wallet address
  /// @param idx User epoch number
  /// @return Epoch time of the checkpoint
  function getUserPointHistoryTS(address addr_, uint256 idx) external view returns (uint256);

  /// @notice Get the current voting power for a user
  /// @param addr_ User wallet address
  /// @return Voting power of user at current timestamp
  function balanceOf(address addr_) external view returns (uint256);

  /// @notice Get the voting power of `addr` at block `blockNumber`
  /// @param addr_ User wallet address
  /// @param blockNumber_ Block number to get voting power at
  /// @return Voting power of user at block number
  function balanceOfAt(address addr_, uint256 blockNumber_) external view returns (uint256);

  /// @notice Calculate total voting power at current timestamp
  /// @return Total voting power at current timestamp
  function totalSupply() external view returns (uint256);

  /// @notice Calculate total voting power at a given block number in past
  /// @param blockNumber_ Block number to calculate total voting power at
  /// @return Total voting power at block number
  function totalSupplyAt(uint256 blockNumber_) external view returns (uint256);

  /// @notice Record global data to checkpoint
  function checkpoint() external;

  /// @notice Deposit and lock tokens for a user
  /// @dev Anyone (even a smart contract) can deposit tokens for someone else, but
  ///      cannot extend their locktime and deposit for a user that is not locked
  /// @param addr_ Address of the user
  /// @param value_ Amount of tokens to deposit
  function depositFor(address addr_, uint128 value_) external;

  /// @notice Deposit `value` for `msg.sender` and lock untill `unlockTime`
  /// @param value_ Amount of tokens to deposit
  /// @param unlockTime_ Time when the tokens will be unlocked
  /// @dev unlockTime is rownded down to whole weeks
  function createLock(uint128 value_, uint256 unlockTime_) external;

  /// @notice Deposit `value` additional tokens for `msg.sender` without
  ///         modifying the locktime
  /// @param value_ Amount of tokens to deposit
  function increaseAmount(uint128 value_) external;

  /// @notice Extend the locktime of `msg.sender`'s tokens to `unlockTime`
  /// @param unlockTime_ New locktime
  function increaseUnlockTime(uint256 unlockTime_) external;

  /// @notice Withdraw tokens for `msg.sender`
  /// @dev Only possible if the locktime has expired
  function withdraw() external;
}
