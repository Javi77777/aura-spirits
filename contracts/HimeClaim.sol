// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HIME vesting claim — PREPARATION ONLY, NOT DEPLOYED
/// @notice Self-claim only (no auto-send). Vesting right attaches to the
///         tokenId: when an NFT is sold, the UNCLAIMED remainder moves to the
///         buyer; already-claimed amounts stay with the seller. Claiming costs
///         gas only, no fee/tax.
/// @dev FINALIZED SPEC (2026-11-03, BSC):
///  - Vesting starts the day AFTER the NFT is minted (H+1), PER TOKENID.
///    Each NFT has its own mint date and therefore its own schedule. The
///    schedule is read from the NFT contract's mintedAt(tokenId):
///    vestingStart(tokenId) = mintedAt(tokenId) + 1 day.
///  - Schedule per NFT: 3% unlocked AT vesting start, remaining 97% unlocked
///    DAILY over 90 days. Fully vested 90 days after vesting start, i.e.
///    91 days after mint. Daily steps use a cumulative formula so the day-90
///    total is EXACT (no rounding drift); intermediate days truncate down.
///    Verified per-NFT totals (initial / average-daily / total):
///      Artemis   2,500:   75 /  26.94 /  2,500
///      Aphrodite 3,300:   99 /  35.57 /  3,300
///      Medusa    15,000:  450 / 161.67 / 15,000
///      Hera     50,000: 1,500 / 538.89 / 50,000
///      Athena  150,000: 4,500 / 1,616.67 / 150,000
///    (Medusa ↔ Aphrodite tiers swapped 2026-11-03, user-confirmed:
///    Medusa is now Epic, Aphrodite is now Rare ★★; amounts per SLOT
///    are unchanged, only the character assigned to each slot swapped.)
///    (Daily rates shown are averages; on-chain math is cumulative integer
///    math, so each day's newly-unlocked amount is floor(total*97*day/9000)
///    minus what was already unlocked.)
///  - The earlier "global start timestamp / mint-vs-TGE" question is SETTLED
///    by this H+1-per-tokenId rule: there is NO global start and NO owner
///    start-setting function. Nothing to decide at deploy time for vesting.
///  - The claim contract must HOLD the tokens it pays out. Post-deploy the
///    creator funds it with the full holder-claim allocation: 15,410,000
///    CAGENT (see DEPLOY_PREP.md). Claims beyond its balance revert.
///  - The claim contract must ALSO be added to the token's taxExempt list
///    post-deploy (belt and suspenders: claims are transfers from the claim
///    contract, not sells, so they are already untaxed by the token's rules).
///  - Claim eligibility is checked live via ownerOf(tokenId) at claim time,
///    which is exactly what makes the unclaimed remainder follow the NFT.

interface IHimeNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function claimAmountFor(uint256 tokenId) external view returns (uint256);
    function mintedAt(uint256 tokenId) external view returns (uint256);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract HimeClaim {
    IHimeNFT public immutable nft;
    IERC20 public immutable token;
    address public owner;

    /// @notice Amount already claimed per tokenId. Because this is keyed by
    /// tokenId (not wallet), selling the NFT transfers the unclaimed
    /// remainder to the buyer automatically.
    mapping(uint256 => uint256) public claimed;

    event Claimed(uint256 indexed tokenId, address indexed claimer, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @param nft_ HimeNFT address.
    /// @param token_ HimeToken (CAGENT) address.
    /// @param owner_ Contract owner (the creator address).
    constructor(address nft_, address token_, address owner_) {
        require(nft_ != address(0) && token_ != address(0) && owner_ != address(0), "zero addr");
        nft = IHimeNFT(nft_);
        token = IERC20(token_);
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Vesting start for a tokenId: its mint time + 1 day (H+1).
    /// Returns 0 for unminted tokenIds (mintedAt == 0).
    function vestingStartOf(uint256 tokenId) public view returns (uint256) {
        uint256 m = nft.mintedAt(tokenId);
        if (m == 0) return 0;
        return m + 1 days;
    }

    /// @notice Total unlocked amount for a tokenId at the current time,
    /// in token BASE UNITS (wei). The NFT reports entitlements in WHOLE
    /// tokens (e.g. 2500); CAGENT has 18 decimals, so the entitlement is
    /// scaled by 1e18 here. All claimed/unlocked accounting is in base
    /// units, which is why the funding amount is 15,410,000 * 1e18.
    /// 0 before its vesting start. Reverts (via claimAmountFor) for tokenIds
    /// outside the valid 1..3333 range.
    function unlockedAmount(uint256 tokenId) public view returns (uint256) {
        uint256 start = vestingStartOf(tokenId);
        if (start == 0 || block.timestamp < start) return 0;
        uint256 total = nft.claimAmountFor(tokenId) * 1e18;
        uint256 daysElapsed = (block.timestamp - start) / 1 days;
        if (daysElapsed > 90) daysElapsed = 90;
        uint256 initial_ = (total * 3) / 100;
        uint256 vested = (total * 97 * daysElapsed) / (100 * 90);
        return initial_ + vested;
    }

    /// @notice Currently claimable amount for a tokenId (0 if nothing
    /// unlocked yet). Note: this view does NOT check the caller; the
    /// claim() function enforces ownership.
    function claimableAmount(uint256 tokenId) external view returns (uint256) {
        uint256 unlocked = unlockedAmount(tokenId);
        uint256 already = claimed[tokenId];
        return unlocked > already ? unlocked - already : 0;
    }

    /// @notice Claim all currently claimable tokens for `tokenId`.
    /// Caller must be the NFT's current owner. Claimed state is updated
    /// BEFORE the token transfer (checks-effects-interactions).
    function claim(uint256 tokenId) external {
        address nftOwner = nft.ownerOf(tokenId); // reverts for unminted tokenIds
        require(nftOwner == msg.sender, "not NFT owner");
        uint256 unlocked = unlockedAmount(tokenId);
        uint256 already = claimed[tokenId];
        require(unlocked > already, "nothing claimable");
        uint256 amount = unlocked - already;
        claimed[tokenId] = unlocked;
        require(token.transfer(msg.sender, amount), "token transfer failed");
        emit Claimed(tokenId, msg.sender, amount);
    }

    /// @notice Remaining token balance held by this contract for payouts.
    function fundingBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }
}
