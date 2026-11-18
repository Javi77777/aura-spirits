// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HimeAccessory — AURA Spirits accessory NFTs (ERC-721) + shop + equip
/// @notice Game design doc: ~/workspace/goals/aura-spirits-nft-project/files/aura-game-design.md
///  Locked decisions implemented here:
///  - 4 slots: Weapon (+Power), Shield (+Defense), Armor (+HP), Horse (+Speed).
///    One accessory per slot; accessories are SEPARATE NFTs (tradeable, can be
///    unequipped and moved/sold). Equipped accessories cannot be transferred
///    until unequipped (enforced in _transfer).
///  - Rarities: Rare / Epic / Legendary only (NO Common). Stat bonus by rarity:
///    Rare +8, Epic +14, Legendary +22. Level-cap bonus by rarity:
///    Rare +10, Epic +15, Legendary +20 (hard cap level 50, enforced in HimeGame).
///  - Shop prices (CAGENT or BNB, buyer chooses): Rare 15,000 CAGENT / 0.015 BNB,
///    Epic 40,000 / 0.04 BNB, Legendary 100,000 / 0.1 BNB. $70 = GROSS (decided
///    2026-11-07): prices UNCHANGED. Owner may retune prices later (setShopPrice).
///  - Stock 100 per item. Payments go to the owner (creator at deploy).
///  - Resale floor 80% of shop price (Rare 12,000 / Epic 32,000 / Legendary
///    80,000 CAGENT): exposed as floorPriceOf() — the authoritative floor
///    source. ENFORCEMENT lives in the market contract (HimeMarket needs an
///    accessory-listing mode reading floorPriceOf; follow-up, not built here).
///  - Hera: Shield accessories give +50% Defense on Hera. Athena: ALL accessory
///    stat bonuses +25% on Athena. Affinity (proposal in the doc, implemented):
///    a goddess wearing her OWN Signature item gets +50% on that bonus.
///    Multipliers apply sequentially with integer division (round down):
///    Legendary +22 on Athena = 22*125/100 = 27; on Hera shield = 22*150/100 = 33.
///  - Starter "Pedang Kayu Latihan" (Wooden Training Sword): FREE, 1 per wallet,
///    +2 Power, +3 level cap, SOULBOUND (not an NFT, cannot be traded/sold).
///    Claimable once per wallet via claimStarter(); equip/unequip like a weapon.
///  - Purchase bonuses (one-time per milestone, counted per wallet):
///    1 accessory -> +2,000 CAGENT + 1,000 XP; 3 -> +8,000 + 4,000;
///    5 -> +20,000 + 10,000; 10 -> +50,000 + 25,000. Paid by HimeGame out of
///    the game reward budget (see HimeGame.grantPurchaseBonus). The XP bonus is
///    credited to a card the buyer names at purchase (must own it); pass 0 to
///    skip the XP part (CAGENT part is still paid).
///  - Free milestone accessories (combined level 90/100/110/120, 1 Rare each,
///    max 4): claimed via HimeGame.claimFreeAccessory, which calls mintFree()
///    here. Free mints draw from a per-slot designated Rare item and do NOT
///    consume shop stock (shop stock is for sales only).
///  - The catalog (122 items in the doc) is owner-registered via addItem /
///    addItems (slot, rarity, name, optional Signature tier). Names live
///    on-chain so tokenURI can expose them; the full 122-name list is in the
///    design doc and is registered at deploy time (see GAME_DEPLOY.md).
///  - HimeGame address is set post-deploy via setGame() (owner only), same
///    pattern as HimeNFT.setMintGate. The shop works without a game set, but
///    purchase bonuses are skipped until the game is wired.

interface IHimeNFT {
    function tierOf(uint256 tokenId) external pure returns (uint8);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IHimeGame {
    function grantPurchaseBonus(address buyer, uint256 cardId, uint8 milestone) external;
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract HimeAccessory {
    // Slots
    uint8 public constant SLOT_WEAPON = 0;
    uint8 public constant SLOT_SHIELD = 1;
    uint8 public constant SLOT_ARMOR = 2;
    uint8 public constant SLOT_HORSE = 3;
    // Rarities (0 = Beginner, starter only, never sold)
    uint8 public constant RARITY_BEGINNER = 0;
    uint8 public constant RARITY_RARE = 1;
    uint8 public constant RARITY_EPIC = 2;
    uint8 public constant RARITY_LEGENDARY = 3;
    // Tiers (match HimeNFT)
    uint8 public constant TIER_ARTEMIS = 0;
    uint8 public constant TIER_APHRODITE = 1;
    uint8 public constant TIER_MEDUSA = 2;
    uint8 public constant TIER_HERA = 3;
    uint8 public constant TIER_ATHENA = 4;

    uint256 public constant STOCK_PER_ITEM = 100;
    uint256 public constant RESALE_FLOOR_BPS = 8000; // 80% of shop price

    address public immutable nft; // HimeNFT (Aura Spirits)
    address public immutable token; // HimeToken (CAGENT)
    address public immutable creator;
    address public owner;
    address public game; // HimeGame, set post-deploy (0 = not wired yet)

    string public name = "AURA Accessories";
    string public symbol = "AURAA";
    string public baseURI;

    struct Item {
        uint8 slot;
        uint8 rarity;
        string itemName;
        bool hasSignature;
        uint8 signatureTier; // tier this item is Signature for (if hasSignature)
        uint256 minted; // shop sales (capped at STOCK_PER_ITEM)
        uint256 freeMinted; // free milestone mints (no stock cap)
    }
    mapping(uint256 => Item) public items;
    uint256 public nextItemId = 1;
    mapping(uint8 => uint256) public freeItemId; // slot => Rare itemId for free milestones

    mapping(uint256 => uint256) public accessoryItem; // accessory tokenId => itemId
    uint256 public nextAccessoryId = 1;

    // Equip state: equipped[cardId][slot] = accessory tokenId (0 = none).
    mapping(uint256 => mapping(uint8 => uint256)) public equipped;
    // equippedOn[accessoryId] = cardId it is equipped to (0 = not equipped).
    mapping(uint256 => uint256) public equippedOn;

    // Starter sword (soulbound, not an NFT).
    mapping(address => bool) public hasStarter;
    mapping(uint256 => bool) public starterEquipped; // cardId => starter on it
    mapping(address => uint256) public starterCard; // wallet => cardId holding its starter

    // Shop prices by rarity (owner-changeable; defaults = design doc).
    mapping(uint8 => uint256) public cagentPrice;
    mapping(uint8 => uint256) public bnbPrice;

    // Purchase-bonus tracking per wallet.
    mapping(address => uint256) public boughtCount;
    mapping(address => mapping(uint8 => bool)) public milestoneClaimed; // wallet => milestone idx => claimed

    bool private _locked;

    event ItemAdded(uint256 indexed itemId, uint8 slot, uint8 rarity, string itemName);
    event FreeItemSet(uint8 indexed slot, uint256 indexed itemId);
    event AccessoryBought(uint256 indexed accessoryId, uint256 indexed itemId, address indexed buyer, bool paidWithBNB, uint256 price);
    event Equipped(uint256 indexed cardId, uint8 indexed slot, uint256 indexed accessoryId);
    event Unequipped(uint256 indexed cardId, uint8 indexed slot, uint256 indexed accessoryId);
    event StarterClaimed(address indexed wallet);
    event StarterEquipped(uint256 indexed cardId, address indexed wallet);
    event StarterUnequipped(uint256 indexed cardId, address indexed wallet);
    event FreeMinted(uint256 indexed accessoryId, uint256 indexed itemId, address indexed to, uint8 slot);
    event ShopPriceSet(uint8 indexed rarity, uint256 cagent, uint256 bnb);
    event GameSet(address indexed game);
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

    constructor(address nft_, address token_, address creator_, string memory baseURI_) {
        require(nft_ != address(0) && token_ != address(0) && creator_ != address(0), "zero address");
        nft = nft_;
        token = token_;
        creator = creator_;
        owner = creator_;
        baseURI = baseURI_;
        cagentPrice[RARITY_RARE] = 15000 ether;
        bnbPrice[RARITY_RARE] = 0.015 ether;
        cagentPrice[RARITY_EPIC] = 40000 ether;
        bnbPrice[RARITY_EPIC] = 0.04 ether;
        cagentPrice[RARITY_LEGENDARY] = 100000 ether;
        bnbPrice[RARITY_LEGENDARY] = 0.1 ether;
    }

    // ------------------------------------------------------------------------
    // Minimal ERC721 core (pattern copied from HimeNFT; no external imports)
    // ------------------------------------------------------------------------
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

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
        require(equippedOn[tokenId] == 0, "equipped, unequip first");
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
                bytes4(0x150b7a02),
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
        return (interfaceId == 0x01ffc9a7 || interfaceId == 0x80ac58cd || interfaceId == 0x5b5e139f);
    }

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

    function setBaseURI(string memory uri) external onlyOwner {
        baseURI = uri;
    }

    // ------------------------------------------------------------------------
    // Catalog (owner-registered; the 122-item list is in the design doc)
    // ------------------------------------------------------------------------
    function addItem(
        uint8 slot,
        uint8 rarity,
        string memory itemName,
        bool hasSignature,
        uint8 signatureTier
    ) public onlyOwner returns (uint256 itemId) {
        require(slot <= SLOT_HORSE, "bad slot");
        require(rarity >= RARITY_RARE && rarity <= RARITY_LEGENDARY, "bad rarity");
        require(signatureTier < 5, "bad signature tier");
        itemId = nextItemId++;
        items[itemId] = Item(slot, rarity, itemName, hasSignature, signatureTier, 0, 0);
        emit ItemAdded(itemId, slot, rarity, itemName);
    }

    function addItems(
        uint8[] calldata slots,
        uint8[] calldata rarities,
        string[] calldata names,
        bool[] calldata sigs,
        uint8[] calldata sigTiers
    ) external onlyOwner {
        require(
            slots.length == rarities.length &&
                rarities.length == names.length &&
                names.length == sigs.length &&
                sigs.length == sigTiers.length,
            "length mismatch"
        );
        for (uint256 i = 0; i < slots.length; i++) {
            addItem(slots[i], rarities[i], names[i], sigs[i], sigTiers[i]);
        }
    }

    /// @notice Designate the Rare item given away free at a combined-level
    /// milestone for a slot (called by HimeGame.claimFreeAccessory).
    function setFreeItem(uint8 slot, uint256 itemId) external onlyOwner {
        require(slot <= SLOT_HORSE, "bad slot");
        require(items[itemId].rarity == RARITY_RARE, "free item must be Rare");
        require(items[itemId].slot == slot, "slot mismatch");
        freeItemId[slot] = itemId;
        emit FreeItemSet(slot, itemId);
    }

    function setShopPrice(uint8 rarity, uint256 cagent, uint256 bnb) external onlyOwner {
        require(rarity >= RARITY_RARE && rarity <= RARITY_LEGENDARY, "bad rarity");
        cagentPrice[rarity] = cagent;
        bnbPrice[rarity] = bnb;
        emit ShopPriceSet(rarity, cagent, bnb);
    }

    function setGame(address game_) external onlyOwner {
        game = game_;
        emit GameSet(game_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ------------------------------------------------------------------------
    // Pricing views
    // ------------------------------------------------------------------------
    function shopPriceOf(uint8 rarity) external view returns (uint256 cagent, uint256 bnb) {
        return (cagentPrice[rarity], bnbPrice[rarity]);
    }

    /// @notice Resale floor for an accessory: 80% of its rarity's shop price
    /// (CAGENT). Authoritative source for the market contract's floor check.
    function floorPriceOf(uint256 accessoryId) external view returns (uint256) {
        uint256 itemId = accessoryItem[accessoryId];
        require(itemId != 0, "nonexistent accessory");
        return (cagentPrice[items[itemId].rarity] * RESALE_FLOOR_BPS) / 10000;
    }

    // ------------------------------------------------------------------------
    // Shop
    // ------------------------------------------------------------------------
    /// @notice Buy an accessory from the shop. payWithBNB = pay BNB, else CAGENT.
    /// cardIdForXp: card receiving the purchase-bonus XP (must own it); pass 0
    /// to skip the XP part (the CAGENT bonus is still paid).
    function buyAccessory(
        uint256 itemId,
        bool payWithBNB,
        uint256 cardIdForXp
    ) external payable nonReentrant returns (uint256 accessoryId) {
        Item storage item = items[itemId];
        require(item.rarity >= RARITY_RARE && item.rarity <= RARITY_LEGENDARY, "bad item");
        require(item.minted < STOCK_PER_ITEM, "sold out");
        if (cardIdForXp != 0) {
            require(IHimeNFT(nft).ownerOf(cardIdForXp) == msg.sender, "not card owner");
        }
        if (payWithBNB) {
            require(msg.value == bnbPrice[item.rarity], "wrong BNB amount");
            (bool ok, ) = payable(owner).call{ value: msg.value }("");
            require(ok, "bnb forward failed");
        } else {
            require(msg.value == 0, "no BNB for CAGENT pay");
            require(
                IERC20(token).transferFrom(msg.sender, owner, cagentPrice[item.rarity]),
                "cagent pay failed"
            );
        }
        item.minted += 1;
        accessoryId = nextAccessoryId++;
        accessoryItem[accessoryId] = itemId;
        _mint(msg.sender, accessoryId);
        emit AccessoryBought(accessoryId, itemId, msg.sender, payWithBNB, payWithBNB ? bnbPrice[item.rarity] : cagentPrice[item.rarity]);

        boughtCount[msg.sender] += 1;
        _maybePurchaseBonus(msg.sender, cardIdForXp);
    }

    function _maybePurchaseBonus(address buyer, uint256 cardIdForXp) internal {
        uint256 count = boughtCount[buyer];
        uint8 milestone;
        if (count == 1) milestone = 0;
        else if (count == 3) milestone = 1;
        else if (count == 5) milestone = 2;
        else if (count == 10) milestone = 3;
        else return;
        if (milestoneClaimed[buyer][milestone]) return;
        milestoneClaimed[buyer][milestone] = true;
        if (game != address(0)) {
            IHimeGame(game).grantPurchaseBonus(buyer, cardIdForXp, milestone);
        }
    }

    /// @notice Free milestone mint (HimeGame.claimFreeAccessory or owner).
    /// Draws from the per-slot designated Rare item; does NOT consume shop stock.
    function mintFree(address to, uint8 slot) external returns (uint256 accessoryId) {
        require(msg.sender == game || msg.sender == owner, "not game/owner");
        uint256 itemId = freeItemId[slot];
        require(itemId != 0, "no free item for slot");
        items[itemId].freeMinted += 1;
        accessoryId = nextAccessoryId++;
        accessoryItem[accessoryId] = itemId;
        _mint(to, accessoryId);
        emit FreeMinted(accessoryId, itemId, to, slot);
    }

    // ------------------------------------------------------------------------
    // Starter sword (soulbound, not an NFT)
    // ------------------------------------------------------------------------
    function claimStarter() external {
        require(!hasStarter[msg.sender], "starter already claimed");
        hasStarter[msg.sender] = true;
        emit StarterClaimed(msg.sender);
    }

    function equipStarter(uint256 cardId) external {
        require(hasStarter[msg.sender], "no starter");
        require(IHimeNFT(nft).ownerOf(cardId) == msg.sender, "not card owner");
        require(equipped[cardId][SLOT_WEAPON] == 0, "weapon occupied");
        if (starterCard[msg.sender] != 0 && starterCard[msg.sender] != cardId) {
            starterEquipped[starterCard[msg.sender]] = false;
            emit StarterUnequipped(starterCard[msg.sender], msg.sender);
        }
        starterEquipped[cardId] = true;
        starterCard[msg.sender] = cardId;
        emit StarterEquipped(cardId, msg.sender);
    }

    function unequipStarter(uint256 cardId) external {
        require(IHimeNFT(nft).ownerOf(cardId) == msg.sender, "not card owner");
        require(starterEquipped[cardId], "starter not equipped");
        require(starterCard[msg.sender] == cardId, "not your starter");
        starterEquipped[cardId] = false;
        starterCard[msg.sender] = 0;
        emit StarterUnequipped(cardId, msg.sender);
    }

    // ------------------------------------------------------------------------
    // Equip / unequip
    // ------------------------------------------------------------------------
    function equip(uint256 cardId, uint256 accessoryId) external {
        require(IHimeNFT(nft).ownerOf(cardId) == msg.sender, "not card owner");
        require(ownerOf(accessoryId) == msg.sender, "not accessory owner");
        uint8 slot = items[accessoryItem[accessoryId]].slot;
        if (slot == SLOT_WEAPON && starterEquipped[cardId]) {
            starterEquipped[cardId] = false;
            starterCard[msg.sender] = 0;
            emit StarterUnequipped(cardId, msg.sender);
        }
        uint256 old = equipped[cardId][slot];
        if (old != 0) equippedOn[old] = 0;
        equipped[cardId][slot] = accessoryId;
        equippedOn[accessoryId] = cardId;
        emit Equipped(cardId, slot, accessoryId);
    }

    function unequip(uint256 cardId, uint8 slot) external {
        require(IHimeNFT(nft).ownerOf(cardId) == msg.sender, "not card owner");
        require(slot <= SLOT_HORSE, "bad slot");
        uint256 accessoryId = equipped[cardId][slot];
        require(accessoryId != 0, "slot empty");
        equipped[cardId][slot] = 0;
        equippedOn[accessoryId] = 0;
        emit Unequipped(cardId, slot, accessoryId);
    }

    // ------------------------------------------------------------------------
    // Bonuses (read by HimeGame + the off-chain battle engine)
    // ------------------------------------------------------------------------
    function capBonusOf(uint256 rarity) public pure returns (uint256) {
        if (rarity == RARITY_RARE) return 10;
        if (rarity == RARITY_EPIC) return 15;
        if (rarity == RARITY_LEGENDARY) return 20;
        return 0;
    }

    function statBonusOf(uint256 rarity) public pure returns (uint256) {
        if (rarity == RARITY_RARE) return 8;
        if (rarity == RARITY_EPIC) return 14;
        if (rarity == RARITY_LEGENDARY) return 22;
        return 0;
    }

    /// @notice Total level-cap bonus from equipped accessories (+ starter).
    function capBonus(uint256 cardId) external view returns (uint256 bonus) {
        for (uint8 slot = 0; slot <= SLOT_HORSE; slot++) {
            uint256 accessoryId = equipped[cardId][slot];
            if (accessoryId != 0) {
                bonus += capBonusOf(items[accessoryItem[accessoryId]].rarity);
            }
        }
        if (starterEquipped[cardId]) bonus += 3;
    }

    /// @notice Effective stat bonus of the accessory in a slot on a card.
    /// Base by rarity, then affinity x1.5 (own Signature), Hera shield x1.5,
    /// Athena x1.25 — applied sequentially, integer division (round down).
    function statBonus(uint256 cardId, uint8 slot) external view returns (uint256 bonus) {
        uint8 tier = IHimeNFT(nft).tierOf(cardId);
        if (slot == SLOT_WEAPON && starterEquipped[cardId]) {
            bonus = 2; // Pedang Kayu Latihan: +2 Power
            if (tier == TIER_ATHENA) bonus = (bonus * 125) / 100;
            return bonus;
        }
        uint256 accessoryId = equipped[cardId][slot];
        if (accessoryId == 0) return 0;
        Item storage item = items[accessoryItem[accessoryId]];
        bonus = statBonusOf(item.rarity);
        if (item.hasSignature && item.signatureTier == tier) {
            bonus = (bonus * 150) / 100; // affinity
        }
        if (tier == TIER_HERA && slot == SLOT_SHIELD) {
            bonus = (bonus * 150) / 100; // Hera shield specialty
        }
        if (tier == TIER_ATHENA) {
            bonus = (bonus * 125) / 100; // Athena: all accessory bonuses +25%
        }
    }
}
