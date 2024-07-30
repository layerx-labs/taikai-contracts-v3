// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.24;

/// @title IVeTokenSettings
/// @notice Interface for managing settings related to VeToken.
interface IVeTokenSettings {
  /// @notice Sets the lock time for tokens.
  /// @param locktime_ The new lock time.
  function setLockTime(int128 locktime_) external;

  /// @notice Retrieves the current lock time for tokens.
  /// @return The current lock time.
  function locktime() external view returns (int128);
}
