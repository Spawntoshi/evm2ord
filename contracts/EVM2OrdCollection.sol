// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @title EVM2Ord Collection — reference ERC-721 for the EVM2Ord Protocol.
/// @notice Liquid ERC-721 today; art migrates to recursive Bitcoin Ordinals over time,
///         funded by the ERC-2981 royalties this contract enforces.
contract EVM2OrdCollection is ERC721, ERC2981, Ownable, EIP712, ReentrancyGuard {
    using Strings for uint256;

    uint256 public immutable MAX_SUPPLY;
    address public minterSigner;   // server hot key that authorizes mints
    string  private _base;         // metadata base, e.g. https://you.xyz/meta/
    string  private _contractURI;  // marketplace-level collection metadata

    // On-chain declaration of where this collection's art is inscribed on Bitcoin.
    // Set at deploy; changeable ONLY by the creator (owner), and optionally lockable forever.
    // This is a public, creator-signed COMMITMENT / pointer — an EVM contract cannot custody BTC
    // or verify inscriptions, so enforcement (sending inscriptions to this address) happens at the
    // platform / indexer layer. It makes "where does this collection's art live?" answerable on-chain.
    string  public btcInscriptionAddress;
    bool    public btcInscriptionAddressLocked;

    mapping(uint256 => bool) public minted;

    struct MintVoucher { address to; uint256 tokenId; uint256 nonce; uint256 deadline; }
    bytes32 private constant VTYPE =
        keccak256("MintVoucher(address to,uint256 tokenId,uint256 nonce,uint256 deadline)");

    event Minted(address indexed to, uint256 indexed tokenId);
    event BtcInscriptionAddressUpdated(string addr);
    event BtcInscriptionAddressLocked();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address minterSigner_,
        string memory baseURI_,
        string memory contractURI_,
        address royaltyReceiver_,
        uint96 royaltyBps_,             // e.g. 500 = 5%
        string memory btcInscriptionAddress_
    ) ERC721(name_, symbol_) Ownable(msg.sender) EIP712("EVM2Ord", "1") {
        MAX_SUPPLY   = maxSupply_;
        minterSigner = minterSigner_;
        _base        = baseURI_;
        _contractURI = contractURI_;
        _setDefaultRoyalty(royaltyReceiver_, royaltyBps_);
        btcInscriptionAddress = btcInscriptionAddress_;
    }

    /// @notice Mint a token authorized by a server-signed EIP-712 voucher.
    function mint(MintVoucher calldata v, bytes calldata sig) external payable nonReentrant {
        require(block.timestamp <= v.deadline, "voucher expired");
        require(v.tokenId < MAX_SUPPLY && !minted[v.tokenId], "unavailable");
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(VTYPE, v.to, v.tokenId, v.nonce, v.deadline))
        );
        require(ECDSA.recover(digest, sig) == minterSigner, "bad voucher");
        minted[v.tokenId] = true;
        _safeMint(v.to, v.tokenId);
        emit Minted(v.to, v.tokenId);
    }

    /// @notice Owner mint (reserves / promos). Mint to a wallet — never to the contract.
    function ownerMint(address to, uint256 tokenId) external onlyOwner {
        require(tokenId < MAX_SUPPLY && !minted[tokenId], "unavailable");
        minted[tokenId] = true;
        _safeMint(to, tokenId);
        emit Minted(to, tokenId);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return string.concat(_base, id.toString(), ".json");
    }

    function contractURI() external view returns (string memory) { return _contractURI; }

    // --- admin ---
    function setSigner(address s) external onlyOwner { minterSigner = s; }
    function setBaseURI(string calldata b) external onlyOwner { _base = b; }
    function setContractURI(string calldata c) external onlyOwner { _contractURI = c; }
    function setRoyalty(address r, uint96 bps) external onlyOwner { _setDefaultRoyalty(r, bps); }

    /// @notice Change the declared Bitcoin inscription address. Owner-only; blocked once locked.
    function setBtcInscriptionAddress(string calldata a) external onlyOwner {
        require(!btcInscriptionAddressLocked, "btc address locked");
        btcInscriptionAddress = a;
        emit BtcInscriptionAddressUpdated(a);
    }
    /// @notice Freeze the Bitcoin inscription address forever (irreversible) for maximum provenance.
    function lockBtcInscriptionAddress() external onlyOwner {
        btcInscriptionAddressLocked = true;
        emit BtcInscriptionAddressLocked();
    }

    function withdraw(address payable to) external onlyOwner nonReentrant {
        (bool ok, ) = to.call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }

    function supportsInterface(bytes4 id)
        public view override(ERC721, ERC2981) returns (bool)
    { return super.supportsInterface(id); }
}
