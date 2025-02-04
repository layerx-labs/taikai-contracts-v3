// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @title Immutable state
/// @notice Functions that return immutable state of the router
interface IPeripheryImmutableState {
  /// @return Returns the address of the CL factory
  function factory() external view returns (address);

  /// @return Returns the address of WETH9
  function WETH9() external view returns (address);
}
