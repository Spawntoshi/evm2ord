// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Enforced-royalty variant — real ERC-721C (LimitBreak Creator Token Standard).
// On deploy, the base auto-registers the canonical transfer validator
// (0x721C002B0059009a671D00aD1700c9748146cd1B, live on Robinhood Chain mainnet), and the
// contract exposes ICreatorToken + ERC-2981. That trio is what marketplaces (OpenSea) read as
// "royalties enforced" — a token can only be SOLD through royalty-honoring operators the validator
// permits, while direct wallet-to-wallet transfers by the holder stay free. Feature-identical to the
// standard SpawnhoodGenesis (voucher mint, tiered price, on-chain metadata, BTC address) — only the
// royalty-enforcement mechanism differs. Built on OpenZeppelin v4.9.6 (required by creator-token-standards@4.0.0).
import {ERC721C} from "@limitbreak/creator-token-standards/src/erc721c/ERC721C.sol";
import {ERC721OpenZeppelin} from "@limitbreak/creator-token-standards/src/token/erc721/ERC721OpenZeppelin.sol";
import {BasicRoyalties, ERC2981} from "@limitbreak/creator-token-standards/src/programmable-royalties/BasicRoyalties.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract SpawnhoodGenesisEnforced is ERC721C, BasicRoyalties, Ownable, EIP712, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 10000;
    uint256 public totalMinted;
    uint256[5] public tierPrice;             // tiered price by mint number (wei), owner-settable
    address public minterSigner;             // backend voucher signer
    string  private _base;                   // token metadata base, e.g. https://.../meta/
    string  private _contractURI;            // OpenSea collection metadata

    string  public btcInscriptionAddress;    // creator-declared on-chain pointer to the BTC inscription addr
    bool    public btcInscriptionAddressLocked;

    mapping(uint256 => string) private _insc; // per-token inscription id (for server-free on-chain metadata)
    bool    public onchainMetadata;
    string  public ordinalsGateway = "https://ordinals.com/content/";
    event InscriptionSet(uint256 indexed tokenId, string inscriptionId);

    mapping(uint256 => bool) public usedNonce;

    struct MintVoucher { address to; uint256 tokenId; uint256 nonce; uint256 deadline; }
    bytes32 private constant VOUCHER_TYPEHASH =
        keccak256("MintVoucher(address to,uint256 tokenId,uint256 nonce,uint256 deadline)");

    event Minted(address indexed to, uint256 indexed tokenId, uint256 price);
    event PriceUpdated(uint256 price);
    event SignerUpdated(address signer);
    event BtcInscriptionAddressUpdated(string addr);
    event BtcInscriptionAddressLocked();

    constructor(
        address initialOwner,
        address _minterSigner,
        uint256[5] memory _tierPrice,
        string memory base_,
        string memory contractURI_,
        address royaltyReceiver,
        uint96 royaltyBps,
        string memory _btcInscriptionAddress,
        string memory name_,
        string memory symbol_
    ) ERC721OpenZeppelin(name_, symbol_) BasicRoyalties(royaltyReceiver, royaltyBps) EIP712("SPAWNHOOD", "1") {
        _transferOwnership(initialOwner);   // OZ v4 Ownable() sets deployer; move to the chosen owner
        minterSigner = _minterSigner;
        tierPrice = _tierPrice;
        _base = base_;
        _contractURI = contractURI_;
        btcInscriptionAddress = _btcInscriptionAddress;
    }

    function currentPrice() public view returns (uint256) {
        uint256 n = totalMinted;
        if (n < 100) return tierPrice[0];
        if (n < 200) return tierPrice[1];
        if (n < 300) return tierPrice[2];
        if (n < 400) return tierPrice[3];
        return tierPrice[4];
    }

    // ---------- voucher mint ----------
    function mint(MintVoucher calldata v, bytes calldata sig) external payable nonReentrant {
        require(block.timestamp <= v.deadline, "voucher expired");
        require(v.to == msg.sender, "not your voucher");
        require(!usedNonce[v.nonce], "voucher used");
        require(v.tokenId >= 1 && v.tokenId <= MAX_SUPPLY, "bad tokenId");
        require(!_exists(v.tokenId), "already minted");
        uint256 price = currentPrice();
        require(msg.value >= price, "insufficient payment");
        require(_recover(v, sig) == minterSigner, "bad signature");

        usedNonce[v.nonce] = true;
        totalMinted += 1;
        _safeMint(v.to, v.tokenId);
        emit Minted(v.to, v.tokenId, price);

        if (msg.value > price) {
            (bool ok, ) = payable(msg.sender).call{value: msg.value - price}("");
            require(ok, "refund failed");
        }
    }

    function _recover(MintVoucher calldata v, bytes calldata sig) internal view returns (address) {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(VOUCHER_TYPEHASH, v.to, v.tokenId, v.nonce, v.deadline))
        );
        return ECDSA.recover(digest, sig);
    }

    // ---------- metadata ----------
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "nonexistent");
        string memory insc = _insc[tokenId];
        if (onchainMetadata && bytes(insc).length > 0) {
            string memory img = string(abi.encodePacked(ordinalsGateway, insc));
            string memory json = string(abi.encodePacked(
                '{"name":"', name(), ' #', tokenId.toString(),
                '","image":"', img, '","animation_url":"', img,
                '","attributes":[{"trait_type":"Inscribed","value":"Bitcoin"}]}'
            ));
            return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
        }
        return string(abi.encodePacked(_base, tokenId.toString(), ".json"));
    }

    function contractURI() external view returns (string memory) { return _contractURI; }

    // ---------- admin ----------
    function setTierPrices(uint256[5] calldata p) external onlyOwner { tierPrice = p; emit PriceUpdated(p[4]); }
    function setTierPrice(uint8 i, uint256 wei_) external onlyOwner { require(i < 5, "bad tier"); tierPrice[i] = wei_; emit PriceUpdated(wei_); }
    function setMinterSigner(address s) external onlyOwner { minterSigner = s; emit SignerUpdated(s); }
    function setBaseURI(string calldata b) external onlyOwner { _base = b; }
    function setContractURI(string calldata c) external onlyOwner { _contractURI = c; }
    function setRoyalty(address r, uint96 bps) external onlyOwner { _setDefaultRoyalty(r, bps); }

    // ---------- server-free on-chain metadata (image lives on Bitcoin) ----------
    function setInscription(uint256 tokenId, string calldata inscriptionId) external onlyOwner { _insc[tokenId] = inscriptionId; emit InscriptionSet(tokenId, inscriptionId); }
    function setInscriptions(uint256[] calldata ids, string[] calldata insc) external onlyOwner { require(ids.length == insc.length, "length"); for (uint256 i; i < ids.length; i++) { _insc[ids[i]] = insc[i]; emit InscriptionSet(ids[i], insc[i]); } }
    function inscriptionOf(uint256 tokenId) external view returns (string memory) { return _insc[tokenId]; }
    function setOnchainMetadata(bool on) external onlyOwner { onchainMetadata = on; }
    function setOrdinalsGateway(string calldata g) external onlyOwner { ordinalsGateway = g; }

    // ---------- BTC inscription address (creator-only) ----------
    function setBtcInscriptionAddress(string calldata a) external onlyOwner {
        require(!btcInscriptionAddressLocked, "btc address locked");
        btcInscriptionAddress = a;
        emit BtcInscriptionAddressUpdated(a);
    }
    function lockBtcInscriptionAddress() external onlyOwner {
        btcInscriptionAddressLocked = true;
        emit BtcInscriptionAddressLocked();
    }

    // owner reserve / creator mint — bounded by MAX_SUPPLY
    function ownerMint(address to, uint256 tokenId) external onlyOwner {
        require(tokenId >= 1 && tokenId <= MAX_SUPPLY, "bad tokenId");
        require(!_exists(tokenId), "already minted");
        totalMinted += 1;
        _safeMint(to, tokenId);
        emit Minted(to, tokenId, 0);
    }

    function withdraw(address payable to) external onlyOwner nonReentrant {
        (bool ok, ) = to.call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }

    // ---------- ERC-721C mandatory overrides ----------
    // Wire the LimitBreak owner check to OZ Ownable, and resolve the ERC721C + ERC2981 diamond.
    function _requireCallerIsContractOwner() internal view virtual override { _checkOwner(); }
    function supportsInterface(bytes4 id) public view virtual override(ERC721C, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }
}
