// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HIME NFT collection — PREPARATION ONLY, NOT DEPLOYED
/// @notice ERC721 with 5 fixed tiers, free public mint (gas only) against a
///         public allocation, creator-only reserve mint, and 7% ERC-2981
///         royalty to the creator address.
/// @dev FINALIZED SPEC (2026-11-03, BSC):
///  - Artemis,  Rare,     1 star: 1800 total = creator 180 + public 1620, claim 2,500/NFT
///  - Aphrodite, Rare,     2 stars: 1200 total = creator 360 + public 840,  claim 3,300/NFT
///  - Medusa,    Epic,    3 stars:  300 total = creator 210 + public 90,   claim 15,000/NFT
///  - Hera,     Legendary,4 stars:   25 total = creator 25  + public 0,    claim 50,000/NFT
///  - Athena,   Limited,  5 stars:    8 total = creator 8   + public 0,    claim 150,000/NFT
///  - Grand total 3333; creator total 783; public total 2550.
///  - Medusa is the collection's star character (best-selling / most sought-after),
///    now the Epic tier after the user-confirmed 2026-11-03 swap with Aphrodite
///    (Medusa was Rare ★★, Aphrodite was Epic ★★★; slot counts, claims,
///    creator/public splits, and tokenId ranges are UNCHANGED — only the
///    character assigned to each slot swapped).
///  - Creator reserve is minted AUTOMATICALLY to the creator address:
///    the creator never goes through the public mint flow for them.
///    Reserve minting is gradual/batched (gas saving): mintReserve() for
///    one, mintReserveBatch() for many. Each reserve NFT's vesting starts
///    the day after ITS mint (H+1 per tokenId), so batches minted on
///    different days vest on different days.
///  - Every NFT has DIFFERENT off-chain artwork/metadata; this contract only serves
///    tokenURI = baseURI + tokenId. Artwork/metadata hosting is off-chain work.
///  - Launch scope ONLY: NFT + Token + Claim. Burn, stake, and the project's own
///    marketplace are COMING SOON and are deliberately NOT in this contract.
///  - Public mint is capped at EXACTLY 1 NFT per wallet (DECIDED
///    2026-11-03): mintPublic() tracks publicMintCount per address and
///    reverts if the caller already minted publicly. Creator reserve
///    mints are NOT counted toward this cap and are NOT capped by it.
///  - PoW/task gating is NOT implemented (difficulty undecided). See the `mintGate`
///    extension point below: when an owner-set gate contract exists, public mints
///    must pass it; while it is address(0) the public mint is open.
///  - NFT collection name/symbol are DECIDED (2026-11-03): name "Aura Spirits",
///    symbol "AURA" (symbol assumed from the name; it is a constructor arg, so
///    it is easily changeable at deploy time without a code change).
///    Passed as constructor args; final values are listed in DEPLOY_PREP.md.

interface IMintGate {
    /// @notice Future PoW/task-gating hook. Return true only if `minter` may mint `tier`.
    function isApproved(address minter, uint8 tier) external view returns (bool);
}

contract HimeNFT {
    // ------------------------------------------------------------------------
    // ERC721 storage
    // ------------------------------------------------------------------------
    string public name;
    string public symbol;
    string public baseURI;
    address public owner;
    address public creator;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /// @notice Mint timestamp per tokenId (block.timestamp at mint).
    /// Read by HimeClaim: each NFT's vesting starts 1 day after ITS mint
    /// (H+1 per tokenId), so every NFT has its own schedule.
    mapping(uint256 => uint256) public mintedAt;

    /// @notice How many NFTs an address has minted through the PUBLIC mint
    /// path (1-per-wallet cap). Reserve mints are NEVER counted here:
    /// they mint automatically to the creator and are not capped.
    mapping(address => uint256) public publicMintCount;

    // ------------------------------------------------------------------------
    // Tiers
    // ------------------------------------------------------------------------
    uint8 public constant TIER_ARTEMIS = 0;
    uint8 public constant TIER_APHRODITE = 1;
    uint8 public constant TIER_MEDUSA = 2;
    uint8 public constant TIER_HERA = 3;
    uint8 public constant TIER_ATHENA = 4;

    struct Tier {
        uint256 total; // total supply of this tier
        uint256 reserve; // creator reserve allocation
        uint256 publicAlloc; // public mint allocation
        uint256 claimAmount; // token claim entitlement per NFT (whole tokens, no decimals)
        uint256 startId; // first tokenId of this tier
        uint256 nextId; // next tokenId to mint in this tier
        uint256 reserveMinted;
        uint256 publicMinted;
    }

    Tier[5] public tiers;

    /// @notice EXTENSION POINT (PoW/task gating). Zero = open public mint.
    /// When set by the owner, mintPublic() requires gate approval. The gate
    /// contract is trusted (owner-set); it is only ever called read-only.
    address public mintGate;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event PublicMint(address indexed minter, uint8 indexed tier, uint256 indexed tokenId);
    event ReserveMint(address indexed to, uint8 indexed tier, uint256 indexed tokenId);
    event MintGateSet(address indexed gate);
    event BaseURISet(string baseURI);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    /// @param creator_ Deployer-equivalent: royalty recipient, reserve recipient,
    ///        and contract owner. MUST be 0xa9Fa6a30DD6b1a082cb6E19d98487B0424A26018
    ///        per the finalized spec (public address only; never a key).
    /// @param name_ Collection name. FINAL: "Aura Spirits".
    /// @param symbol_ Collection symbol. FINAL: "AURA" (assumed from the name;
    ///        easily changeable — it is only a constructor argument).
    /// @param baseURI_ Metadata base URI (tokenURI = baseURI + tokenId).
    constructor(address creator_, string memory name_, string memory symbol_, string memory baseURI_) {
        require(creator_ != address(0), "zero creator");
        creator = creator_;
        owner = creator_;
        name = name_;
        symbol = symbol_;
        baseURI = baseURI_;

        //            total  reserve  public  claim   startId
        tiers[0] = Tier(1800, 180, 1620, 2500, 1, 1, 0, 0); // Artemis
        tiers[1] = Tier(1200, 360, 840, 3300, 1801, 1801, 0, 0); // Aphrodite
        tiers[2] = Tier(300, 210, 90, 15000, 3001, 3001, 0, 0); // Medusa
        tiers[3] = Tier(25, 25, 0, 50000, 3301, 3301, 0, 0); // Hera
        tiers[4] = Tier(8, 8, 0, 150000, 3326, 3326, 0, 0); // Athena
    }

    // ------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ------------------------------------------------------------------------
    // ERC721 core
    // ------------------------------------------------------------------------
    function balanceOf(address account) external view returns (uint256) {
        require(account != address(0), "zero account");
        return _balances[account];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address account = _owners[tokenId];
        require(account != address(0), "nonexistent token");
        return account;
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function approve(address to, uint256 tokenId) external {
        address tokenOwner = ownerOf(tokenId);
        require(to != tokenOwner, "approve to owner");
        require(
            msg.sender == tokenOwner || _operatorApprovals[tokenOwner][msg.sender],
            "not authorized"
        );
        _tokenApprovals[tokenId] = to;
        emit Approval(tokenOwner, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        require(_exists(tokenId), "nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        require(operator != msg.sender, "approve self");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address account, address operator) external view returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address tokenOwner = _owners[tokenId];
        return (spender == tokenOwner ||
            _tokenApprovals[tokenId] == spender ||
            _operatorApprovals[tokenOwner][spender]);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "not authorized");
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "not authorized");
        _transfer(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, data), "unsafe recipient");
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        require(ownerOf(tokenId) == from, "wrong from");
        require(to != address(0), "zero to");
        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "zero to");
        require(!_exists(tokenId), "already minted");
        _balances[to] += 1;
        _owners[tokenId] = to;
        mintedAt[tokenId] = block.timestamp;
        emit Transfer(address(0), to, tokenId);
    }

    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private returns (bool) {
        if (to.code.length == 0) return true;
        (bool success, bytes memory ret) = to.call(
            abi.encodeWithSelector(
                bytes4(0x150b7a02), // onERC721Received(address,address,uint256,bytes)
                msg.sender,
                from,
                tokenId,
                data
            )
        );
        if (!success) return false;
        bytes4 retval = abi.decode(ret, (bytes4));
        return retval == bytes4(0x150b7a02);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_exists(tokenId), "nonexistent token");
        return string(abi.encodePacked(baseURI, _toString(tokenId)));
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return (interfaceId == 0x01ffc9a7 || // ERC165
            interfaceId == 0x80ac58cd || // ERC721
            interfaceId == 0x5b5e139f || // ERC721Metadata
            interfaceId == 0x2a55205a); // ERC2981
    }

    // ------------------------------------------------------------------------
    // ERC-2981 royalty: 7% to the creator on every secondary sale that
    // honors the standard. Plain wallet-to-wallet transfers are NOT taxed.
    // ------------------------------------------------------------------------
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (creator, (salePrice * 700) / 10000);
    }

    // ------------------------------------------------------------------------
    // Tiers / minting
    // ------------------------------------------------------------------------
    function maxSupply() external pure returns (uint256) {
        return 3333;
    }

    function tierOf(uint256 tokenId) public pure returns (uint8) {
        if (tokenId >= 1 && tokenId <= 1800) return TIER_ARTEMIS;
        if (tokenId >= 1801 && tokenId <= 3000) return TIER_APHRODITE;
        if (tokenId >= 3001 && tokenId <= 3300) return TIER_MEDUSA;
        if (tokenId >= 3301 && tokenId <= 3325) return TIER_HERA;
        if (tokenId >= 3326 && tokenId <= 3333) return TIER_ATHENA;
        revert("bad tokenId");
    }

    /// @notice Per-NFT token claim entitlement (whole tokens) for a tokenId.
    /// Read by HimeClaim; the entitlement follows the tier, and the vesting
    /// right follows the tokenId (see HimeClaim).
    function claimAmountFor(uint256 tokenId) external view returns (uint256) {
        return tiers[tierOf(tokenId)].claimAmount;
    }

    function tierInfo(uint8 tier)
        external
        view
        returns (
            uint256 total,
            uint256 reserve,
            uint256 publicAlloc,
            uint256 claimAmount,
            uint256 minted,
            uint256 reserveMinted,
            uint256 publicMinted
        )
    {
        require(tier < 5, "bad tier");
        Tier storage t = tiers[tier];
        return (t.total, t.reserve, t.publicAlloc, t.claimAmount, t.reserveMinted + t.publicMinted, t.reserveMinted, t.publicMinted);
    }

    /// @notice Free public mint (gas only; this function is nonpayable, so any
    /// sent value reverts). Mints exactly 1 NFT of `tier` to the caller.
    /// CAPPED at 1 NFT per wallet: a caller that already minted publicly
    /// reverts ("one per wallet"), regardless of tier. Creator reserve
    /// mints do NOT count toward this cap and are NOT capped by it.
    /// EXTENSION POINT: if `mintGate` is set, the gate must approve the minter.
    function mintPublic(uint8 tier) external {
        require(tier < 5, "bad tier");
        if (mintGate != address(0)) {
            require(IMintGate(mintGate).isApproved(msg.sender, tier), "gate rejected");
        }
        require(publicMintCount[msg.sender] == 0, "one per wallet");
        Tier storage t = tiers[tier];
        require(t.publicMinted < t.publicAlloc, "public sold out");
        uint256 tokenId = t.nextId;
        t.nextId += 1;
        t.publicMinted += 1;
        publicMintCount[msg.sender] += 1;
        _mint(msg.sender, tokenId);
        emit PublicMint(msg.sender, tier, tokenId);
    }

    /// @notice Creator-side reserve mint (gradual, gas saving). Reserve NFTs
    /// are minted AUTOMATICALLY to the creator address — the creator never
    /// goes through the public mint flow for them. Each reserve NFT's
    /// vesting starts the day after ITS mint (H+1 per tokenId).
    function mintReserve(uint8 tier) external onlyOwner {
        _mintReserve(tier, 1);
    }

    /// @notice Batch version of mintReserve: mints `count` reserve NFTs of
    /// `tier` directly to the creator address in one transaction. Batches
    /// minted on different days get different vesting starts (each batch's
    /// vesting follows its own batch mint date). Keep batches reasonably
    /// sized so the transaction stays within the block gas limit.
    function mintReserveBatch(uint8 tier, uint256 count) external onlyOwner {
        require(count > 0, "zero count");
        _mintReserve(tier, count);
    }

    function _mintReserve(uint8 tier, uint256 count) internal {
        require(tier < 5, "bad tier");
        Tier storage t = tiers[tier];
        require(t.reserveMinted + count <= t.reserve, "reserve exhausted");
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = t.nextId;
            t.nextId += 1;
            _mint(creator, tokenId);
            emit ReserveMint(creator, tier, tokenId);
        }
        t.reserveMinted += count;
    }

    // ------------------------------------------------------------------------
    // Owner admin
    // ------------------------------------------------------------------------
    function setMintGate(address gate) external onlyOwner {
        mintGate = gate;
        emit MintGateSet(gate);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
        emit BaseURISet(newBaseURI);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
