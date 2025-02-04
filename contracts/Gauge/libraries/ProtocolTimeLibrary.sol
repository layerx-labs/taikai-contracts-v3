// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

library ProtocolTimeLibrary {
  uint256 internal constant WEEK = 7 days;

  /// @dev Returns start of epoch based on current timestamp
  function epochStart(uint256 timestamp) internal pure returns (uint256) {
    return timestamp - (timestamp % WEEK);
  }

  /// @dev Returns start of next epoch / end of current epoch
  function epochNext(uint256 timestamp) internal pure returns (uint256) {
    return timestamp - (timestamp % WEEK) + WEEK;
  }

  /// @dev Returns start of voting window
  function epochVoteStart(uint256 timestamp) internal pure returns (uint256) {
    return timestamp - (timestamp % WEEK) + 1 hours;
  }

  /// @dev Returns end of voting window / beginning of unrestricted voting window
  function epochVoteEnd(uint256 timestamp) internal pure returns (uint256) {
    return timestamp - (timestamp % WEEK) + WEEK - 1 hours;
  }
}
