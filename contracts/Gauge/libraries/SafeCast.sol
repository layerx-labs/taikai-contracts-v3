// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
library SafeCast {
  /// @notice Cast a uint128 to an int128, revert on overflow
  /// @param y The uint128 to be cast
  /// @return z The cast integer, now type int128
  function toInt128(uint128 y) internal pure returns (int128 z) {
    require(y < 2 ** 127);
    z = int128(y);
  }
}
