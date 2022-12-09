// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.9;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Capped token
 * @dev Mintable token with a token cap.
 */
contract TKAI is ERC20PresetFixedSupply, Ownable {
    
    // Maximum supply is 300M TKAI
    uint256 private constant _totalSupply = 300000000 *(10 ** 18);

    constructor(
        string memory _name,
        string memory _symbol,
        address owner
        ) ERC20PresetFixedSupply(_name, _symbol, _totalSupply, owner ) {
            transferOwnership(owner);
        }

}