// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

/// @title IVeToken
/// @notice Interface for VeToken functionality.
interface IVeToken {
    /// @notice Retrieves the last user slope.
    /// @param addr The address of the user.
    /// @return The last user slope.
    function getLastUserSlope(address addr) external view returns (int128);

    /// @notice Retrieves the timestamp of a user's point history at a specific index.
    /// @param addr The address of the user.
    /// @param idx The index of the point history.
    /// @return The timestamp of the user's point history at the specified index.
    function userPointHistoryTs(
        address addr,
        uint256 idx
    ) external view returns (uint256);

    /// @notice Retrieves the end timestamp of the lock for a user.
    /// @param addr The address of the user.
    /// @return The end timestamp of the lock for the user.
    function lockedEnd(address addr) external view returns (uint256);

    /// @notice Creates a checkpoint of the current state.
    function checkpoint() external;

    /// @notice Deposits tokens into the VeToken contract.
    /// @param _value The amount of tokens to deposit.
    function deposit(uint256 _value) external;

    /// @notice Withdraws tokens from the VeToken contract.
    function withdraw() external;

    /// @notice Retrieves the balance of tokens for a specific address.
    /// NOTE:The following ERC20/minime-compatible methods are not real balanceOf!!
    /// They measure the weights for the purpose of voting, so they don't represent real coins.
    /// @param addr The address of the account.
    /// @return The balance of tokens (VotingPower) for the specified address.
    function balanceOf(address addr) external view returns (uint256);

    /// @notice Retrieves the balance of tokens for a specific address at a specific block.
    /// NOTE:The following ERC20/minime-compatible methods are not real balanceOfAt!!
    /// They measure the weights for the purpose of voting, so they don't represent real coins.
    /// @param addr The address of the account.
    /// @param _block The block number.
    /// @return The balance of tokens (VotingPower) for the specified address at the specified block.
    function balanceOfAt(
        address addr,
        uint256 _block
    ) external view returns (uint256);

    /// @notice Retrieves the total amount of tokens locked.
    /// @return The total amount of tokens locked.
    function totalLocked() external view returns (uint256);
}
