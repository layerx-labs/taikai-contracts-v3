// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

/// @title IVeTokenSettings
/// @notice Interface for managing settings related to VeToken.
interface IVeTokenSettings {
    /// @notice Sets the advance percentage allowed for token unlocking.
    /// @param _advancePercentage The new advance percentage.
    function setAdvancePercentage(uint16 _advancePercentage) external;

    /// @notice Sets the lock time for tokens.
    /// @param _locktime The new lock time.
    function setLockTime(int128 _locktime) external;

    /// @notice Retrieves the current lock time for tokens.
    /// @return The current lock time.
    function locktime() external view returns (int128);

    /// @notice Retrieves the current advance percentage allowed for token unlocking.
    /// @return The current advance percentage.
    function advancePercentage() external view returns (uint16);
}
