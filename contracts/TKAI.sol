// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.9;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Token has a fixed supply , transfers could be pause and token could not be burned
 * @title TKAI token
 */
contract TKAI is ERC20PresetFixedSupply, ERC20Pausable,  Ownable {
    
    // Maximum supply is 300M TKAI
    uint256 private constant _totalSupply = 300000000 *(10 ** 6);

    constructor(
        string memory _name,
        string memory _symbol,
        address owner
        ) 
        ERC20PresetFixedSupply(_name, _symbol, _totalSupply, owner ) 
        ERC20Pausable()
        Ownable()
        {
            transferOwnership(owner);        
        }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Pausable) {
        ERC20Pausable._beforeTokenTransfer(from, to, amount);           
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    function pause() external virtual onlyOwner {    
        _pause();
    }

    function unpause() external virtual onlyOwner {
        _unpause();
    }
    
    function burn(uint256) public pure override { revert(); }
    function burnFrom(address, uint256) public pure override { revert();}

}