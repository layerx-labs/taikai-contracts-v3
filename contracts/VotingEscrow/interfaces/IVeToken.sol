// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IVeToken
/// @notice Interface for VeToken functionality.
interface IVeToken is IERC20 {
  /// @notice Retrieves the name of the token.
  /// @return The name of the token.
  function name() external view returns (string memory);

  /// @notice Retrieves the symbol of the token.
  /// @return The symbol of the token.
  function symbol() external view returns (string memory);

  /// @notice Retrieves the number of decimals for the token.
  /// @return The number of decimals for the token.
  function decimals() external view returns (uint8);

  /// @notice Retrieves the address of the VeTokenSettings contract.
  /// @return The address of the VeTokenSettings contract.
  function settings() external view returns (address);

  /// @notice Retrieves the version of the VeToken contract.
  /// @return The version of the VeToken contract.
  function version() external view returns (string memory);

  /// @notice Retrieves the address of the Token contract.
  /// @return The address of the Token contract.
  function token() external view returns (address);

  /// @notice Retrieves the total locked amount.
  /// @return The total locked amount.
  function totalLocked() external view returns (uint256);

  /// @notice Retrieves the end timestamp of the lock for a user.
  /// @param addr The address of the user.
  /// @return The end timestamp of the lock for the user.
  function lockedEnd(address addr) external view returns (uint256);

  /// @notice Retrieves the amount of the lock for a user.
  /// @param addr The address of the user.
  /// @return The user's locked balance.
  function lockedBalance(address addr) external view returns (int128);

  /// @notice Deposits tokens into the VeToken contract.
  /// @param _value The amount of tokens to deposit.
  /// @dev This emits the {Deposit} and {Supply} events.
  /// `_value` is (unsafely) downcasted from `uint256` to `int128`
  /// and `_unlockTime` is (unsafely) downcasted from `uint256` to `uint96`
  /// assuming that the values never reach the respective max values
  function deposit(uint256 _value) external;

  /// @notice Withdraws the `_amount` of tokens from the VeToken contract.
  /// @param _amount The amount of tokens to withdraw.
  /// @dev This emits the {Withdraw} and {Supply} events.
  function withdraw(uint256 _amount) external;

  /// @notice Retrieves the balance of tokens for a specific address.
  /// NOTE:The following ERC20/minime-compatible methods are not real balanceOf!!
  /// They measure the weights for the purpose of voting, so they don't represent real coins.
  /// @param addr The address of the account.
  /// @return The balance of tokens (VotingPower) for the specified address.
  function balanceOf(address addr) external view returns (uint256);

  /// @notice Calculate current total supply of voting power
  /// @return Current totalSupply
  function totalSupply() external view returns (uint256);
}
