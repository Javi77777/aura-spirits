// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HimeGame — AURA Spirits game core: XP, levels, duels, seasons, rewards
/// @notice Game design doc: ~/workspace/goals/aura-spirits-nft-project/files/aura-game-design.md
///  Locked decisions implemented here (2026-11-06 design + 2026-11-07 decisions):
///  - Duel XP (L = card's level BEFORE the duel):
///      Ladder win 50 + L*10, loss 10 + L*2; Live win 75 + L*15, loss 15 + L*3.
///      Upset (beat an opponent 5+ levels above) +50 XP; beat a higher-rank
///      opponent +25 XP. Active play +1 XP per minute (capped at 60/duel).
///  - Level curve: XP to go L -> L+1 = 100*L; cumulative to reach L = 50*L*(L-1).
///    Level-up bonus 30*L per level gained (total L1->L50 = 38,220 XP).
///  - Level cap per card: base 3 + accessory cap bonuses (Rare +10 / Epic +15 /
///    Legendary +20, starter +3), hard cap 50. Read from HimeAccessory.
///  - XP -> CAGENT rate 2 XP = 1 CAGENT. NO minimum claim. Self-claim, gas paid
///    by the claimer. XP NEVER expires; unconverted XP carries to next season.
///  - Season = 30 days from deploy. Outflow per season 1,000,000 CAGENT
///    (decided 2026-11-07, replaces the old 100-300k cap; 7M budget = 7 seasons),
///    split: conversion 50% / season pool 20% / holder bonus 20% / kingdom 10%.
///    Owner may retune the TOTAL via setSeasonOutflow (split stays 50/20/20/10).
///  - Season pool split by final rank: Diamond 30% / Platinum 25% / Gold 20% /
///    Silver 15% / Bronze 10% (of the 200,000 pool). Pool rewards need 20+
///    ladder duels in that season (checked on-chain).
///  - Ladder: max 6 duels/card/day. Live challenges: max 10/card/day (UTC day).
///  - Rating starts at 1000; ladder win +16 / loss -16, live win +8 / loss -8
///    (floor 0). Ranks: Bronze <1200, Silver 1200-1399, Gold 1400-1599,
///    Platinum 1600-1799, Diamond 1800+.
///  - Kingdoms = tiers (0 Bulan/Artemis, 1 Cinta/Aphrodite, 2 Batu/Medusa,
///    3 Mahkota/Hera, 4 Hikmah/Athena). Kingdom XP + wins tracked per season.
///  - Free milestone accessories at combined level 90/100/110/120 (1 Rare each,
///    max 4): claimFreeAccessory mints via HimeAccessory (caller passes their
///    cardIds; combined level = sum of effective levels).
///  - Purchase bonuses (from HimeAccessory buys): 1 -> +2,000 CAGENT + 1,000 XP;
///    3 -> +8,000 + 4,000; 5 -> +20,000 + 10,000; 10 -> +50,000 + 25,000.
///    The CAGENT part counts against the season conversion allocation; if the
///    allocation is dry, it is DEFERRED as pendingBonus (claimable later via
///    claimPendingBonus) so accessory purchases never revert on a dry pool.
///
///  DESIGN DECISIONS MADE HERE (not in the doc — see GAME_DEPLOY.md):
///  - Duels are resolved OFF-CHAIN by the battle engine (like Agent Cards'
///    server-run ladder): an authorized battleServer submits results via
///    recordDuel. The contract verifies caps, computes XP/rating/levels, and
///    credits both cards. On-chain commit-reveal for every round would be
///    gas-prohibitive; the server is owner-authorized and auditable via events.
///  - Level-up bonus XP and purchase-bonus XP count toward CAGENT conversion
///    but NOT toward the level curve. (Forced by the doc's own numbers: total to
///    L50 = 122,500 duel XP + 38,220 bonus XP = 160,720 XP = 80,360 CAGENT.
///    If bonus XP drove levels, L50 would be reached at 122,500 TOTAL XP and
///    the 80,360 figure would be wrong.) Duration XP DOES drive levels (earned
///    in battle, like duel XP).
///  - Season-end rewards (pool / holder / kingdom) are recorded by an
///    owner-authorized distributor (who computes ranks/holders/winners off-chain)
///    and claimed by recipients themselves. The contract enforces: season ended,
///    per-kind season caps, per-rank pool-group caps, the 20-ladder-duel rule,
///    and one record per beneficiary. Rank itself is distributor-attested
///    (ratings keep moving into the next season, so the contract cannot
///    re-derive the season-end rank on-chain).
///  - Funding is manual: the owner transfers CAGENT into this contract (e.g.
///    1M per season from the 7M budget). Claims revert on insufficient stock;
///    caps (not stock) are the economic guardrail.
///  - conversionRemaining() saturates at 0 (added 2026-11-07): retuning
///    seasonOutflow below the season's already-paid amount must NOT panic;
///    the remainder is simply 0 and new conversion/bonus CAGENT defers.
///  - Units (fixed 2026-11-07, caught by test): XP->CAGENT conversion is in
///    WEI (CAGENT has 18 decimals). claimXp/claimAllXp/claimableCagent used
///    to compute whole CAGENT (XP/2) and compare/transfer it against wei
///    caps and balances, so the season cap never bound and claims paid dust
///    (e.g. 2088 XP claimed 2088 wei instead of 2088 CAGENT).

interface IHimeNFT {
    function tierOf(uint256 tokenId) external pure returns (uint8);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IHimeAccessory {
    function capBonus(uint256 cardId) external view returns (uint256);
    function statBonus(uint256 cardId, uint8 slot) external view returns (uint256);
    function mintFree(address to, uint8 slot) external returns (uint256);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract HimeGame {
    address public immutable nft; // HimeNFT (Aura Spirits)
    address public immutable token; // HimeToken (CAGENT)
    address public immutable creator;
    address public owner;
    address public accessory; // HimeAccessory (set post-deploy if needed)
    address public battleServer; // authorized duel-result submitter
    address public distributor; // authorized season-reward recorder

    uint256 public immutable seasonStart;
    uint256 public constant SEASON_LENGTH = 30 days;
    uint256 public constant XP_PER_CAGENT = 2;
    uint256 public constant LADDER_DAILY_MAX = 6;
    uint256 public constant LIVE_DAILY_MAX = 10;
    uint256 public constant BASE_CAP = 3;
    uint256 public constant MAX_LEVEL = 50;
    uint256 public constant MIN_LADDER_DUELS_FOR_POOL = 20;
    uint256 public constant DURATION_XP_CAP = 60; // max duration XP per duel

    uint256 public seasonOutflow = 1000000 ether; // 1M CAGENT / season

    // Reward kinds for season-end distribution.
    uint8 public constant REWARD_POOL = 0;
    uint8 public constant REWARD_HOLDER = 1;
    uint8 public constant REWARD_KINGDOM = 2;

    // Per-card state.
    mapping(uint256 => uint256) public duelXp; // drives levels (duel + duration)
    mapping(uint256 => uint256) public bonusXp; // convertible only (level-up + purchase)
    mapping(uint256 => uint256) public convertedXp;
    mapping(uint256 => uint8) public levelClaimed; // last level bonus was paid for (0 = unset, treat as 1)
    mapping(uint256 => uint256) public rating;
    mapping(uint256 => bool) public ratingInit;
    mapping(uint256 => mapping(uint256 => uint256)) public dailyLadder; // card => UTC day => count
    mapping(uint256 => mapping(uint256 => uint256)) public dailyLive;
    mapping(uint256 => mapping(uint256 => uint256)) public ladderDuels; // season => card => count
    mapping(uint256 => mapping(uint256 => uint256)) public liveDuels;
    mapping(uint256 => mapping(uint256 => uint256)) public kingdomXp; // season => kingdom => XP
    mapping(uint256 => mapping(uint256 => uint256)) public kingdomWins;

    // Per-season economy.
    mapping(uint256 => uint256) public conversionUsed; // season => CAGENT paid (conversion + bonuses)
    mapping(uint256 => mapping(uint8 => uint256)) public rewardRecorded; // season => kind => total
    mapping(uint256 => mapping(uint8 => uint256)) public poolRecordedByRank; // season => rank => total (kind 0 only)
    mapping(uint256 => mapping(uint8 => mapping(uint256 => uint256))) public rewardClaimable; // season => kind => beneficiary => amount

    mapping(address => uint256) public pendingBonus; // deferred purchase-bonus CAGENT
    mapping(address => mapping(uint8 => bool)) public freeClaimed; // wallet => milestone idx => claimed
    uint256[4] public freeMilestones = [90, 100, 110, 120];

    bool private _locked;

    event DuelRecorded(uint256 indexed cardId, uint256 indexed oppCardId, bool won, bool isLive, uint256 xpA, uint256 xpB);
    event LevelUp(uint256 indexed cardId, uint8 indexed newLevel, uint256 bonusXp);
    event XpClaimed(uint256 indexed cardId, address indexed claimer, uint256 xpUsed, uint256 cagentOut);
    event PurchaseBonusGranted(address indexed buyer, uint256 indexed cardId, uint8 milestone, uint256 cagent, uint256 xp);
    event PurchaseBonusDeferred(address indexed buyer, uint256 cagent);
    event PendingBonusClaimed(address indexed buyer, uint256 cagent);
    event SeasonRewardRecorded(uint256 indexed season, uint8 indexed kind, uint256 indexed beneficiary, uint256 amount, uint8 rank);
    event SeasonRewardClaimed(uint256 indexed season, uint8 indexed kind, uint256 indexed beneficiary, address claimer, uint256 amount);
    event FreeAccessoryClaimed(address indexed wallet, uint8 indexed milestone, uint256 indexed accessoryId, uint8 slot);
    event SeasonOutflowSet(uint256 oldTotal, uint256 newTotal);
    event BattleServerSet(address indexed server);
    event DistributorSet(address indexed distributor);
    event AccessorySet(address indexed accessory);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyBattleServer() {
        require(msg.sender == battleServer || msg.sender == owner, "not battle server");
        _;
    }

    modifier onlyDistributor() {
        require(msg.sender == distributor || msg.sender == owner, "not distributor");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address nft_, address token_, address creator_, address accessory_) {
        require(nft_ != address(0) && token_ != address(0) && creator_ != address(0), "zero address");
        nft = nft_;
        token = token_;
        creator = creator_;
        owner = creator_;
        accessory = accessory_;
        seasonStart = block.timestamp;
    }

    // ------------------------------------------------------------------------
    // Seasons, ranks, levels (views)
    // ------------------------------------------------------------------------
    function currentSeason() public view returns (uint256) {
        return (block.timestamp - seasonStart) / SEASON_LENGTH;
    }

    function conversionCap() public view returns (uint256) {
        return seasonOutflow / 2; // 50%
    }

    /// @notice Conversion allocation left in a season. Saturates at 0: if the
    /// owner retunes seasonOutflow below what was already paid out this
    /// season, the remainder is 0 (never an underflow panic). Added 2026-11-07
    /// after a test caught `conversionCap() - conversionUsed` panicking on a
    /// retune-down; the deferred-bonus path depends on it.
    function conversionRemaining(uint256 season) public view returns (uint256) {
        uint256 cap = conversionCap();
        uint256 used = conversionUsed[season];
        return cap > used ? cap - used : 0;
    }

    function seasonPoolCap() public view returns (uint256) {
        return (seasonOutflow * 20) / 100; // 20%
    }

    function holderCap() public view returns (uint256) {
        return (seasonOutflow * 20) / 100; // 20%
    }

    function kingdomCap() public view returns (uint256) {
        return seasonOutflow / 10; // 10%
    }

    function rankOf(uint256 rating_) public pure returns (uint8) {
        if (rating_ >= 1800) return 4; // Diamond
        if (rating_ >= 1600) return 3; // Platinum
        if (rating_ >= 1400) return 2; // Gold
        if (rating_ >= 1200) return 1; // Silver
        return 0; // Bronze
    }

    /// @notice Season-pool share for a rank (of the 200,000 pool at default outflow).
    function rankPoolShare(uint8 rank) public view returns (uint256) {
        uint256 pool = seasonPoolCap();
        if (rank == 4) return (pool * 30) / 100; // Diamond 30%
        if (rank == 3) return (pool * 25) / 100; // Platinum 25%
        if (rank == 2) return (pool * 20) / 100; // Gold 20%
        if (rank == 1) return (pool * 15) / 100; // Silver 15%
        return pool / 10; // Bronze 10%
    }

    function ratingOf(uint256 cardId) public view returns (uint256) {
        return ratingInit[cardId] ? rating[cardId] : 1000;
    }

    /// @notice Largest L with 50*L*(L-1) <= xp. L=1 at 0 XP, L=50 at 122,500 XP.
    function levelFromXp(uint256 xp) public pure returns (uint8) {
        uint8 level = 1;
        for (uint8 l = 2; l <= 50; l++) {
            if (xp >= 50 * uint256(l) * uint256(l - 1)) level = l;
            else break;
        }
        return level;
    }

    function levelCap(uint256 cardId) public view returns (uint256) {
        if (accessory == address(0)) return BASE_CAP;
        uint256 cap = BASE_CAP + IHimeAccessory(accessory).capBonus(cardId);
        return cap > MAX_LEVEL ? MAX_LEVEL : cap;
    }

    function effectiveLevel(uint256 cardId) public view returns (uint8) {
        uint8 fromXp = levelFromXp(duelXp[cardId]);
        uint256 cap = levelCap(cardId);
        if (uint256(fromXp) > cap) return uint8(cap);
        return fromXp;
    }

    function baseStats(uint8 tier) public pure returns (uint256 power, uint256 defense, uint256 speed, uint256 luck, uint256 hp) {
        if (tier == 0) return (50, 45, 70, 55, 145); // Artemis
        if (tier == 1) return (48, 48, 58, 72, 148); // Aphrodite
        if (tier == 2) return (75, 50, 60, 55, 150); // Medusa
        if (tier == 3) return (60, 75, 50, 60, 175); // Hera
        return (65, 65, 65, 65, 165); // Athena
    }

    /// @notice Full battle stats for a card: base + equipped accessory bonuses.
    /// HP = 100 + total Defense + armor bonus.
    function cardStats(uint256 cardId)
        external
        view
        returns (uint256 power, uint256 defense, uint256 speed, uint256 luck, uint256 hp)
    {
        uint8 tier = IHimeNFT(nft).tierOf(cardId);
        (power, defense, speed, luck, hp) = baseStats(tier);
        if (accessory != address(0)) {
            power += IHimeAccessory(accessory).statBonus(cardId, 0); // weapon
            defense += IHimeAccessory(accessory).statBonus(cardId, 1); // shield
            uint256 armorBonus = IHimeAccessory(accessory).statBonus(cardId, 2); // armor
            speed += IHimeAccessory(accessory).statBonus(cardId, 3); // horse
            hp = 100 + defense + armorBonus;
        }
    }

    function unclaimedXp(uint256 cardId) public view returns (uint256) {
        return duelXp[cardId] + bonusXp[cardId] - convertedXp[cardId];
    }

    function claimableCagent(uint256 cardId) public view returns (uint256) {
        // CAGENT has 18 decimals: XP/2 whole CAGENT must be scaled to wei.
        uint256 fromXp = (unclaimedXp(cardId) / XP_PER_CAGENT) * 1 ether;
        uint256 remaining = conversionRemaining(currentSeason());
        uint256 stock = IERC20(token).balanceOf(address(this));
        if (fromXp > remaining) fromXp = remaining;
        if (fromXp > stock) fromXp = stock;
        return fromXp;
    }

    function combinedLevel(address wallet, uint256[] calldata cardIds) public view returns (uint256 total) {
        for (uint256 i = 0; i < cardIds.length; i++) {
            require(IHimeNFT(nft).ownerOf(cardIds[i]) == wallet, "not card owner");
            total += effectiveLevel(cardIds[i]);
        }
    }

    function leadingKingdom(uint256 season) external view returns (uint8 kingdom) {
        uint256 best;
        for (uint8 k = 0; k < 5; k++) {
            if (kingdomXp[season][k] > best) {
                best = kingdomXp[season][k];
                kingdom = k;
            }
        }
    }

    function cardInfo(uint256 cardId)
        external
        view
        returns (
            uint8 level,
            uint256 cap,
            uint256 duelXp_,
            uint256 bonusXp_,
            uint256 convertedXp_,
            uint256 unclaimedXp_,
            uint256 rating_,
            uint8 rank
        )
    {
        level = effectiveLevel(cardId);
        cap = levelCap(cardId);
        duelXp_ = duelXp[cardId];
        bonusXp_ = bonusXp[cardId];
        convertedXp_ = convertedXp[cardId];
        unclaimedXp_ = unclaimedXp(cardId);
        rating_ = ratingOf(cardId);
        rank = rankOf(rating_);
    }

    // ------------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------------
    function setBattleServer(address server) external onlyOwner {
        battleServer = server;
        emit BattleServerSet(server);
    }

    function setDistributor(address distributor_) external onlyOwner {
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    function setAccessory(address accessory_) external onlyOwner {
        accessory = accessory_;
        emit AccessorySet(accessory_);
    }

    /// @notice Retune the per-season outflow total (split stays 50/20/20/10).
    function setSeasonOutflow(uint256 newTotal) external onlyOwner {
        require(newTotal > 0, "outflow zero");
        emit SeasonOutflowSet(seasonOutflow, newTotal);
        seasonOutflow = newTotal;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Safety valve: pull unallocated CAGENT stock back to the owner.
    function withdrawCAGENT(uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(owner, amount), "withdraw failed");
    }

    // ------------------------------------------------------------------------
    // Duels (results submitted by the authorized battle server)
    // ------------------------------------------------------------------------
    function recordDuel(
        uint256 cardId,
        uint256 oppCardId,
        bool won,
        bool isLive,
        uint256 durationMinutes
    ) external onlyBattleServer {
        require(cardId != oppCardId, "self duel");
        // ownerOf reverts for nonexistent cards.
        IHimeNFT(nft).ownerOf(cardId);
        IHimeNFT(nft).ownerOf(oppCardId);
        uint256 day = block.timestamp / 1 days;
        uint256 season = currentSeason();
        if (isLive) {
            require(dailyLive[cardId][day] < LIVE_DAILY_MAX, "live cap card");
            require(dailyLive[oppCardId][day] < LIVE_DAILY_MAX, "live cap opp");
        } else {
            require(dailyLadder[cardId][day] < LADDER_DAILY_MAX, "ladder cap card");
            require(dailyLadder[oppCardId][day] < LADDER_DAILY_MAX, "ladder cap opp");
        }
        _initRating(cardId);
        _initRating(oppCardId);
        uint256 xpA = _duelXp(cardId, oppCardId, won, isLive, durationMinutes);
        uint256 xpB = _duelXp(oppCardId, cardId, !won, isLive, durationMinutes);
        _creditDuelXp(cardId, xpA);
        _creditDuelXp(oppCardId, xpB);
        _applyRating(cardId, won, isLive);
        _applyRating(oppCardId, !won, isLive);
        _finalizeDuel(cardId, oppCardId, won, isLive, xpA, xpB, day, season);
    }

    function _finalizeDuel(
        uint256 cardId,
        uint256 oppCardId,
        bool won,
        bool isLive,
        uint256 xpA,
        uint256 xpB,
        uint256 day,
        uint256 season
    ) internal {
        if (isLive) {
            dailyLive[cardId][day] += 1;
            dailyLive[oppCardId][day] += 1;
            liveDuels[season][cardId] += 1;
            liveDuels[season][oppCardId] += 1;
        } else {
            dailyLadder[cardId][day] += 1;
            dailyLadder[oppCardId][day] += 1;
            ladderDuels[season][cardId] += 1;
            ladderDuels[season][oppCardId] += 1;
        }
        uint8 kA = IHimeNFT(nft).tierOf(cardId);
        uint8 kB = IHimeNFT(nft).tierOf(oppCardId);
        kingdomXp[season][kA] += xpA;
        kingdomXp[season][kB] += xpB;
        if (won) kingdomWins[season][kA] += 1;
        else kingdomWins[season][kB] += 1;
        emit DuelRecorded(cardId, oppCardId, won, isLive, xpA, xpB);
    }

    function _initRating(uint256 cardId) internal {
        if (!ratingInit[cardId]) {
            ratingInit[cardId] = true;
            rating[cardId] = 1000;
        }
    }

    function _duelXp(
        uint256 cardId,
        uint256 oppCardId,
        bool won,
        bool isLive,
        uint256 durationMinutes
    ) internal view returns (uint256 xp) {
        uint256 level = effectiveLevel(cardId);
        if (isLive) xp = won ? 75 + level * 15 : 15 + level * 3;
        else xp = won ? 50 + level * 10 : 10 + level * 2;
        if (won) {
            if (effectiveLevel(oppCardId) >= level + 5) xp += 50; // upset
            if (rankOf(ratingOf(oppCardId)) > rankOf(ratingOf(cardId))) xp += 25; // higher rank
        }
        uint256 dur = durationMinutes > DURATION_XP_CAP ? DURATION_XP_CAP : durationMinutes;
        xp += dur;
    }

    function _creditDuelXp(uint256 cardId, uint256 xp) internal {
        duelXp[cardId] += xp;
        uint8 newLevel = effectiveLevel(cardId);
        uint8 old = levelClaimed[cardId] == 0 ? 1 : levelClaimed[cardId];
        if (newLevel > old) {
            uint256 bonus;
            for (uint8 l = old + 1; l <= newLevel; l++) bonus += 30 * uint256(l);
            bonusXp[cardId] += bonus;
            levelClaimed[cardId] = newLevel;
            emit LevelUp(cardId, newLevel, bonus);
        } else if (levelClaimed[cardId] == 0) {
            levelClaimed[cardId] = newLevel;
        }
    }

    function _applyRating(uint256 cardId, bool won, bool isLive) internal {
        uint256 delta = isLive ? 8 : 16;
        if (won) rating[cardId] += delta;
        else rating[cardId] = rating[cardId] >= delta ? rating[cardId] - delta : 0;
    }

    // ------------------------------------------------------------------------
    // XP -> CAGENT conversion (self-claim, no minimum)
    // ------------------------------------------------------------------------
    function claimXp(uint256 cardId, uint256 xpAmount) external nonReentrant {
        require(IHimeNFT(nft).ownerOf(cardId) == msg.sender, "not card owner");
        require(xpAmount > 0 && xpAmount <= unclaimedXp(cardId), "bad xp amount");
        uint256 xpUsed = (xpAmount / XP_PER_CAGENT) * XP_PER_CAGENT; // round down to even
        uint256 cagent = (xpAmount / XP_PER_CAGENT) * 1 ether; // 2 XP = 1 CAGENT (18 decimals)
        require(cagent > 0, "nothing to convert");
        uint256 season = currentSeason();
        require(conversionUsed[season] + cagent <= conversionCap(), "conversion cap");
        require(IERC20(token).balanceOf(address(this)) >= cagent, "insufficient stock");
        convertedXp[cardId] += xpUsed;
        conversionUsed[season] += cagent;
        require(IERC20(token).transfer(msg.sender, cagent), "cagent transfer failed");
        emit XpClaimed(cardId, msg.sender, xpUsed, cagent);
    }

    /// @notice Claim as much as possible (up to unclaimed XP, season allocation, stock).
    function claimAllXp(uint256 cardId) external nonReentrant {
        require(IHimeNFT(nft).ownerOf(cardId) == msg.sender, "not card owner");
        uint256 cagent = claimableCagent(cardId);
        require(cagent > 0, "nothing to claim");
        uint256 xpUsed = (cagent / 1 ether) * XP_PER_CAGENT;
        convertedXp[cardId] += xpUsed;
        conversionUsed[currentSeason()] += cagent;
        require(IERC20(token).transfer(msg.sender, cagent), "cagent transfer failed");
        emit XpClaimed(cardId, msg.sender, xpUsed, cagent);
    }

    // ------------------------------------------------------------------------
    // Purchase bonuses (called by HimeAccessory on shop buys)
    // ------------------------------------------------------------------------
    function grantPurchaseBonus(address buyer, uint256 cardId, uint8 milestone) external {
        require(msg.sender == accessory, "not accessory");
        uint256 cagent;
        uint256 xp;
        if (milestone == 0) (cagent, xp) = (2000 ether, 1000);
        else if (milestone == 1) (cagent, xp) = (8000 ether, 4000);
        else if (milestone == 2) (cagent, xp) = (20000 ether, 10000);
        else if (milestone == 3) (cagent, xp) = (50000 ether, 25000);
        else revert("bad milestone");
        if (cardId != 0) {
            require(IHimeNFT(nft).ownerOf(cardId) == buyer, "not card owner");
            bonusXp[cardId] += xp;
        }
        uint256 season = currentSeason();
        uint256 remaining = conversionRemaining(season);
        if (remaining >= cagent && IERC20(token).balanceOf(address(this)) >= cagent) {
            conversionUsed[season] += cagent;
            require(IERC20(token).transfer(buyer, cagent), "bonus transfer failed");
            emit PurchaseBonusGranted(buyer, cardId, milestone, cagent, xp);
        } else {
            pendingBonus[buyer] += cagent;
            emit PurchaseBonusDeferred(buyer, cagent);
            emit PurchaseBonusGranted(buyer, cardId, milestone, 0, xp);
        }
    }

    /// @notice Claim deferred purchase-bonus CAGENT (subject to the current
    /// season's remaining conversion allocation and stock).
    function claimPendingBonus() external nonReentrant {
        uint256 amount = pendingBonus[msg.sender];
        require(amount > 0, "no pending bonus");
        uint256 season = currentSeason();
        uint256 remaining = conversionRemaining(season);
        uint256 stock = IERC20(token).balanceOf(address(this));
        uint256 pay = amount;
        if (pay > remaining) pay = remaining;
        if (pay > stock) pay = stock;
        require(pay > 0, "nothing claimable yet");
        pendingBonus[msg.sender] = amount - pay;
        conversionUsed[season] += pay;
        require(IERC20(token).transfer(msg.sender, pay), "bonus transfer failed");
        emit PendingBonusClaimed(msg.sender, pay);
    }

    // ------------------------------------------------------------------------
    // Free milestone accessories (combined level 90/100/110/120)
    // ------------------------------------------------------------------------
    function claimFreeAccessory(uint8 slot, uint256[] calldata cardIds) external nonReentrant returns (uint256 accessoryId) {
        require(accessory != address(0), "no accessory contract");
        uint256 combined = combinedLevel(msg.sender, cardIds);
        for (uint8 i = 0; i < 4; i++) {
            if (!freeClaimed[msg.sender][i] && combined >= freeMilestones[i]) {
                freeClaimed[msg.sender][i] = true;
                accessoryId = IHimeAccessory(accessory).mintFree(msg.sender, slot);
                emit FreeAccessoryClaimed(msg.sender, i, accessoryId, slot);
                return accessoryId;
            }
        }
        revert("milestone not reached");
    }

    // ------------------------------------------------------------------------
    // Season-end rewards (recorded by distributor, claimed by recipients)
    // ------------------------------------------------------------------------
    function recordReward(
        uint256 season,
        uint8 kind,
        uint256 beneficiary,
        uint256 amount,
        uint8 rank
    ) external onlyDistributor {
        require(season < currentSeason(), "season not ended");
        require(kind <= REWARD_KINGDOM, "bad kind");
        require(amount > 0, "zero amount");
        require(rewardClaimable[season][kind][beneficiary] == 0, "already recorded");
        if (kind == REWARD_POOL) {
            require(rank < 5, "bad rank");
            require(ladderDuels[season][beneficiary] >= MIN_LADDER_DUELS_FOR_POOL, "min 20 ladder duels");
            require(
                poolRecordedByRank[season][rank] + amount <= rankPoolShare(rank),
                "rank group cap"
            );
            poolRecordedByRank[season][rank] += amount;
            require(rewardRecorded[season][kind] + amount <= seasonPoolCap(), "pool cap");
        } else if (kind == REWARD_HOLDER) {
            require(rewardRecorded[season][kind] + amount <= holderCap(), "holder cap");
        } else {
            require(rewardRecorded[season][kind] + amount <= kingdomCap(), "kingdom cap");
        }
        rewardRecorded[season][kind] += amount;
        rewardClaimable[season][kind][beneficiary] = amount;
        emit SeasonRewardRecorded(season, kind, beneficiary, amount, rank);
    }

    function claimReward(uint256 season, uint8 kind, uint256 beneficiary) external nonReentrant {
        uint256 amount = rewardClaimable[season][kind][beneficiary];
        require(amount > 0, "nothing to claim");
        if (kind == REWARD_POOL) {
            require(IHimeNFT(nft).ownerOf(beneficiary) == msg.sender, "not card owner");
        } else {
            require(address(uint160(beneficiary)) == msg.sender, "not beneficiary");
        }
        delete rewardClaimable[season][kind][beneficiary];
        require(IERC20(token).balanceOf(address(this)) >= amount, "insufficient stock");
        require(IERC20(token).transfer(msg.sender, amount), "reward transfer failed");
        emit SeasonRewardClaimed(season, kind, beneficiary, msg.sender, amount);
    }
}
