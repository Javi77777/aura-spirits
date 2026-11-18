// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HimeMarket — AURA Spirits NFT marketplace (CAGENT settlement)
/// @notice Launch scope decided 2026-11-05, floors decided 2026-11-07.
///  - Settlement is CAGENT ONLY. The buyer pays CAGENT; the seller receives
///    price minus 7% royalty; the creator receives the 7% royalty.
///  - Flat per-tier floors (CAGENT, 18 decimals), enforced on list AND on buy:
///      Artemis 300, Aphrodite 300, Medusa 1000, Hera 25000, Athena 75000.
///    (Decided 2026-11-07 ~16:07-16:12; replaces the old 0.5x-remaining-claim
///    rule. Floors are owner-changeable via setFloor/setFloors.)
///  - The seller KEEPS the NFT until sale (list-then-approve pattern, same as
///    the Star Agent / AnthroBit flows). The seller must approve this market
///    (approve / setApprovalForAll) before a buy can settle; buy() reverts
///    otherwise. No CAGENT ever sits in this contract: buy() pulls CAGENT
///    straight from buyer to seller and to the creator.
///  - SELF-BUY IS BLOCKED: a seller cannot buy their own listing. The user
///    explicitly rejected wash trading on 2026-11-07; the contract enforces it.
///  - No CAGENT sell-tax interference: HimeToken taxes ONLY transfers TO the
///    designated pair, and this contract never receives CAGENT (buyer pays
///    seller + creator directly), so market trades are never taxed.
///  - Honest display: all activity is emitted (Listed/Cancelled/Sold); the
///    site reads real on-chain data only — no fictitious listings/activity.

interface IHimeNFT {
    function tierOf(uint256 tokenId) external pure returns (uint8);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract HimeMarket {
    address public immutable nft; // HimeNFT (Aura Spirits)
    address public immutable token; // HimeToken (CAGENT)
    address public immutable creator; // royalty recipient (AURA creator)
    address public owner;

    uint256 public constant ROYALTY_BPS = 700; // 7%
    uint256[5] public floorPrice; // per tier, CAGENT (18 decimals)

    struct Listing {
        address seller;
        uint256 price;
    }
    mapping(uint256 => Listing) public listings;

    bool private _locked;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Cancelled(uint256 indexed tokenId, address indexed seller);
    event Sold(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 royalty
    );
    event FloorSet(uint8 indexed tier, uint256 price);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    /// @param nft_ Deployed HimeNFT address.
    /// @param token_ Deployed HimeToken (CAGENT) address.
    /// @param creator_ AURA creator address (royalty recipient).
    constructor(address nft_, address token_, address creator_) {
        require(nft_ != address(0) && token_ != address(0) && creator_ != address(0), "zero address");
        nft = nft_;
        token = token_;
        creator = creator_;
        owner = creator_;
        // Flat floors decided 2026-11-07 (CAGENT, 18 decimals).
        floorPrice[0] = 300 ether; // Artemis
        floorPrice[1] = 300 ether; // Aphrodite
        floorPrice[2] = 1000 ether; // Medusa
        floorPrice[3] = 25000 ether; // Hera
        floorPrice[4] = 75000 ether; // Athena
    }

    /// @notice List an NFT the caller owns. Price must be at or above the
    /// tier floor. The NFT stays with the seller until sold; the seller must
    /// approve this market separately before a buy can settle.
    function list(uint256 tokenId, uint256 price) external {
        require(IHimeNFT(nft).ownerOf(tokenId) == msg.sender, "not owner");
        require(listings[tokenId].seller == address(0), "already listed");
        uint8 tier = IHimeNFT(nft).tierOf(tokenId);
        require(price >= floorPrice[tier], "below floor");
        listings[tokenId] = Listing(msg.sender, price);
        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice Cancel the caller's own listing.
    function cancel(uint256 tokenId) external {
        Listing memory l = listings[tokenId];
        require(l.seller == msg.sender, "not seller");
        delete listings[tokenId];
        emit Cancelled(tokenId, msg.sender);
    }

    /// @notice Buy a listed NFT with CAGENT. Buyer must have approved this
    /// market to spend at least `price` CAGENT. Seller receives price minus
    /// 7% royalty; the creator receives the royalty. Floor is re-checked so
    /// a listing cannot sell below a floor raised after it was listed.
    /// Self-buy is blocked (anti wash-trading).
    function buy(uint256 tokenId) external nonReentrant {
        Listing memory l = listings[tokenId];
        require(l.seller != address(0), "not listed");
        require(msg.sender != l.seller, "self buy blocked");
        uint8 tier = IHimeNFT(nft).tierOf(tokenId);
        require(l.price >= floorPrice[tier], "below floor");
        address seller = l.seller;
        uint256 price = l.price;
        delete listings[tokenId];
        uint256 royalty = (price * ROYALTY_BPS) / 10000;
        require(
            IERC20(token).transferFrom(msg.sender, seller, price - royalty),
            "pay seller failed"
        );
        require(IERC20(token).transferFrom(msg.sender, creator, royalty), "pay royalty failed");
        IHimeNFT(nft).transferFrom(seller, msg.sender, tokenId);
        emit Sold(tokenId, seller, msg.sender, price, royalty);
    }

    /// @notice Change one tier floor (owner only). Takes effect for new
    /// listings immediately and for pending listings at buy time.
    function setFloor(uint8 tier, uint256 price) external onlyOwner {
        require(tier < 5, "bad tier");
        floorPrice[tier] = price;
        emit FloorSet(tier, price);
    }

    /// @notice Change all five tier floors at once (owner only).
    function setFloors(uint256[5] calldata prices) external onlyOwner {
        for (uint8 i = 0; i < 5; i++) {
            floorPrice[i] = prices[i];
            emit FloorSet(i, prices[i]);
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
