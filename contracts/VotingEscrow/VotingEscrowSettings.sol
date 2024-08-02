// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IVeTokenSettings.sol";

error InvalidLockTime(string message);

/// @title VeTokenSettings
/// @notice This contract defines settings for a VeToken.
contract VeTokenSettings is Ownable, IVeTokenSettings {
  /// @notice Duration for which tokens are locked by default.
  /// @notice The locktime is in seconds. The default is 1 year.
  /// @notice For example, 365 days in seconds is 31536000.
  int128 private _locktime = 365 days; // 1 year in seconds

  /// @notice Constructs the VeTokenSettings contract.
  /// @dev The contract is Ownable.
  constructor() Ownable() {}

  /// @notice Sets the lock time for tokens, locktime should be in seconds.
  /// @dev Only callable by the owner.
  /// @param locktime_ The new lock time.
  function setLockTime(int128 locktime_) external onlyOwner {
    if (locktime_ < 7 days) {
      revert InvalidLockTime("Lock time must be at least 7 days");
    }
    _locktime = locktime_;
  }

  /// @notice Retrieves the current lock time for tokens.
  /// @return The current lock time.
  function locktime() external view returns (int128) {
    return _locktime;
  }
}
