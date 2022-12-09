pragma solidity >=0.8.9;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol";

/*
 * A BountyToken is a non-transferable NFT that tracks the record of participation of a certain address on a
 * @INetworkV2.Bounty
 */
contract TAIKAICertificate is ERC721URIStorage, Ownable {

    uint256 private _nextMintId = 0 ;

    constructor(string memory name_, string memory symbol_, address owner) 
        ERC721URIStorage() 
        ERC721(name_, symbol_)
        Ownable() 
    {
        transferOwnership(owner);        
    }
    
    /*
     * Alias to safeMint
     *
     * Assert rules,
     *  msg.sender must be dispatcher
     */
    function mintCertificate(address to, string memory uri ) external onlyOwner  {
        uint256 id = _nextMintId;
        _safeMint(to, id);
        _setTokenURI(id, uri);
        _nextMintId++;
    }

    function getNextId() external view returns (uint256) {
        return _nextMintId;
    }

    /** Certificate is not transferable */
    function transferFrom(address from, address to, uint256 tokenId) public override { revert(); }
    function safeTransferFrom(address from, address to, uint256 tokenId) public override { revert(); }
}
