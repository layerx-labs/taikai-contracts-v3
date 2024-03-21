// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./IVeTokenSettings.sol";

/// @title VeTokenSettings
/// @notice This contract defines settings for a VeToken.
contract VeTokenSettings is Ownable, IVeTokenSettings {
    /// @notice Duration for which tokens are locked by default.
    /// @notice The locktime is in seconds. The default is 1 year.
    /// @notice For example, 365 days in seconds is 31536000.
    int128 public locktime = 365 days; // 1 year in seconds

    /// @notice Constructs the VeTokenSettings contract.
    /// @dev The contract is Ownable.
    constructor() Ownable() {}


    /// @notice Sets the lock time for tokens, locktime should be in seconds.
    /// @dev Only callable by the owner.
    /// @param _locktime The new lock time.
    function setLockTime(int128 _locktime) external onlyOwner {
        require(_locktime >= 7 days, "locktime should be at least 1 week");
        locktime = _locktime;
    }
}
