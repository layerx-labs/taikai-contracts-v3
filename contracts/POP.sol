// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.9;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/*
 * Proof of Participation
 */
contract POP is ERC721URIStorage, Ownable, Pausable {
  using Counters for Counters.Counter;
  Counters.Counter private _tokenIdTracker;

  /**
   */
  constructor(
    string memory name_,
    string memory symbol_,
    address owner
  ) ERC721URIStorage() ERC721(name_, symbol_) Ownable() Pausable() {
    transferOwnership(owner);
  }

  function mint(address to, string memory uri) external virtual onlyOwner whenNotPaused {
    uint256 id = _tokenIdTracker.current();
    _safeMint(to, id);
    _setTokenURI(id, uri);
    _tokenIdTracker.increment();
  }

  function getNextId() external view returns (uint256) {
    return _tokenIdTracker.current();
  }

  function pause() external virtual onlyOwner {
    _pause();
  }

  function unpause() external virtual onlyOwner {
    _unpause();
  }

  /** POP is not transferable */
  function transferFrom(address, address, uint256) public virtual override(ERC721, IERC721) {
    revert();
  }
  function safeTransferFrom(address, address, uint256) public virtual override(ERC721, IERC721) {
    revert();
  }
  function safeTransferFrom(
    address,
    address,
    uint256,
    bytes memory
  ) public virtual override(ERC721, IERC721) {
    revert();
  }
}
