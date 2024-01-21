// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.9;

interface IVeToken {
    function getLastUserSlope(address addr) external view returns (int128);

    function setAdvancePercentage(uint16 _advance_percentage) external;

    function userPointHistoryTs(
        address addr,
        uint256 idx
    ) external view returns (uint256);

    function lockedEnd(address addr) external view returns (uint256);

    function checkpoint() external;

    function depositFor(address _addr, uint256 _value) external;

    function createLock(uint256 _value, uint256 _unlock_time) external;

    function increaseUnlockTime(uint256 _unlock_time) external;

    function increaseAmount(uint256 _value) external;

    function withdraw() external;

    function balanceOf(address addr) external view returns (uint256);

    function balanceOfAt(
        address addr,
        uint256 _block
    ) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function totalSupply(uint256 ts) external view returns (uint256);

    function totalLocked() external view returns (uint256);

    function totalSupplyAt(uint256 _block) external view returns (uint256);
}
