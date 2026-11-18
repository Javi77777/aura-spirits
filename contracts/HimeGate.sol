// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HimeGate — Keccak PoW + Binance Agent ID mint gate for HimeNFT
/// @notice Chip404-style PoW gate implementing the HimeNFT mintGate slot,
///         PLUS a Binance Agent ID eligibility check (DECIDED 2026-11-03):
///         `isApproved(minter, tier)` returns true only if BOTH hold:
///         (a) `minter` has submitted a valid PoW solution for `tier`, AND
///         (b) `minter` holds a Binance Agent ID at mint time (ERC721
///         balanceOf > 0 on the Agent ID registry). Generic Web3 wallets
///         without an Agent ID CANNOT freemint, even with a valid PoW
///         solution. The PoW requirement STAYS — the Agent check is
///         ADDITIONAL, not a replacement.
/// @dev PUZZLE (must match the off-chain solver byte-for-byte):
///      hash = keccak256(abi.encodePacked(minter, tier, nonce))
///           = keccak256( 20-byte minter address
///                      ‖ 1-byte tier (uint8)
///                      ‖ 32-byte nonce, big-endian (uint256) )
///      A solution is valid iff hash <= tierTarget[tier], where
///      tierTarget[tier] = type(uint256).max >> difficultyBits[tier]
///      (i.e. the hash must have at least difficultyBits leading zero bits).
///      The minter address and tier are INSIDE the hashed input, so a
///      solution found by one minter cannot be replayed by another minter,
///      and a solution for one tier cannot be replayed for another tier.
///      In addition, each exact (minter, tier, nonce) triple may be
///      submitted only once (usedNonce guard).
/// @dev TWO-STEP FLOW (HimeNFT is NOT changed):
///      1. Minter solves off-chain (browser solver) and calls
///         submitSolution(tier, nonce). This is a separate transaction that
///         only marks approval; it mints nothing.
///      2. Minter calls HimeNFT.mintPublic(tier), which reads
///         isApproved(minter, tier) from this gate. If the gate is set on
///         the NFT and approval is missing, mintPublic reverts.
///      Approval is NOT consumed by minting (the NFT never calls back into
///      this gate). That is safe because HimeNFT caps public mints at
///      exactly 1 NFT per wallet: an approved minter can mint at most once
///      anyway, regardless of tier.
/// @dev DIFFICULTY IS OWNER-CONFIGURABLE: setDifficultyBits() /
///      setTarget() change targets without redeploying this gate (and
///      without touching HimeNFT). Final difficulty numbers are a
///      launch-time tuning decision — see DEPLOY_PREP.md §6.
/// @dev AGENT ID ELIGIBILITY (DECIDED 2026-11-03; verified on-chain, see below):
///      The freemint is open ONLY to wallets holding a Binance Agent ID
///      (Agent ID like month.ai, registry.ai identity system). The check is
///      the canonical, ecosystem-standard one: ERC721 `balanceOf(minter) > 0`
///      on the .ai Agent ID registry
///      `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` (8,756 bytes of code
///      on BSC mainnet; `balanceOf(month-wallet) = 1`, `balanceOf(fresh) = 0`,
///      `handleOf(month-wallet) = "month"` — all verified live 2026-11-03).
///      WHY balanceOf AND NOT identityOf-on-registry: `identityOf(address)`
///      was PROBED live and REVERTS on the canonical registry itself (for
///      every wallet) — it exists only on a small wrapper contract
///      `0x135E3F94813198F345f09Eaa79AAe2C936aadED1` (1,559 bytes), where it
///      returns 0x73d98e0b…612e for the month wallet and bytes32(0) for a
///      fresh wallet. A gate calling identityOf on the registry would
///      therefore revert EVERY mint (including legit Agent holders) and
///      brick the freemint. The balanceOf check is also the pattern other
///      projects in this ecosystem document for ".ai Agent ID" gating.
///      The wrapper is deliberately NOT used: its provenance is a single
///      small helper contract, while the registry is the canonical,
///      widely-referenced ERC721 registry.
/// @dev REGISTRY IS OWNER-CONFIGURABLE (no redeploy to repoint):
///      `agentRegistry` defaults to the verified canonical registry in the
///      constructor and can be changed later by the owner via
///      `setAgentRegistry()` (zero address reverts). Rationale: if the
///      registry is ever replaced, the gate must not need a redeploy to
///      follow it — but the default is always the verified address, so a
///      deploy that passes no registry argument is safe by construction.
/// @dev NOTE ON TIERS: Hera (3) and Athena (4) have ZERO public allocation
///      in HimeNFT, so their gate targets never actually gate a public mint
///      (public mint of those tiers reverts "public sold out" regardless).
///      Targets are still stored for all 5 tiers for uniformity.
/// @notice Minimal interface of the .ai Agent ID registry (ERC721):
///         holding an Agent ID means balanceOf > 0.
interface IAgentRegistry {
    function balanceOf(address account) external view returns (uint256);
}

contract HimeGate {
    address public owner;

    /// @notice Canonical Binance Agent ID registry (.ai Agent ID, BSC).
    ///         Verified on-chain 2026-11-03 (see header docs).
    address public constant DEFAULT_AGENT_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    /// @notice Registry consulted by the Agent ID check. Defaults to
    ///         DEFAULT_AGENT_REGISTRY; the owner may repoint it via
    ///         setAgentRegistry() without redeploying this gate.
    address public agentRegistry;

    /// @notice Per-tier PoW target: a solution hash must be <= tierTarget[tier].
    mapping(uint8 => uint256) public tierTarget;

    /// @notice Per-tier difficulty in leading-zero bits (informational;
    /// kept in sync with target by the setters).
    mapping(uint8 => uint8) public difficultyBits;

    /// @notice Approval flags read by HimeNFT via isApproved().
    mapping(address => mapping(uint8 => bool)) public approved;

    /// @notice Replay guard: exact (minter, tier, nonce) triples already used.
    mapping(address => mapping(uint8 => mapping(uint256 => bool))) public usedNonce;

    event SolutionAccepted(address indexed minter, uint8 indexed tier, uint256 nonce, bytes32 hash);
    event TargetSet(uint8 indexed tier, uint256 target, uint8 bits);
    event AgentRegistrySet(address indexed registry);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @param owner_ Gate admin (the creator address). Should be the same
    ///        creator that owns HimeNFT.
    /// @param targets_ Initial per-tier targets, index = tier 0..4.
    ///        Pass the proposed values from DEPLOY_PREP.md §6, or zeros
    ///        and set them later via setDifficultyBits()/setTarget().
    constructor(address owner_, uint256[5] memory targets_) {
        require(owner_ != address(0), "zero owner");
        owner = owner_;
        // The Agent check defaults to the verified canonical registry; the
        // owner may repoint it later via setAgentRegistry() (no redeploy).
        agentRegistry = DEFAULT_AGENT_REGISTRY;
        for (uint8 t = 0; t < 5; t++) {
            tierTarget[t] = targets_[t];
            difficultyBits[t] = _leadingZeroBits(targets_[t]);
        }
    }

    /// @notice The exact puzzle hash. Pure so anyone can verify off-chain
    ///        that their solver builds the same input as this contract.
    function puzzleHash(address minter, uint8 tier, uint256 nonce) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(minter, tier, nonce));
    }

    /// @notice HimeNFT IMintGate interface. Returns true iff BOTH hold:
    ///         (a) `minter` has submitted a valid PoW solution for `tier`,
    ///         AND (b) `minter` holds a Binance Agent ID at mint time
    ///         (ERC721 balanceOf > 0 on agentRegistry).
    ///         PoW approval alone is NEVER sufficient: a wallet without an
    ///         Agent ID returns false here even after a valid solution.
    function isApproved(address minter, uint8 tier) external view returns (bool) {
        return approved[minter][tier] && _hasAgent(minter);
    }

    /// @notice Submit a PoW solution for `tier`. Verifies on-chain and, if
    ///         valid, marks the caller approved for that tier. Mints nothing.
    function submitSolution(uint8 tier, uint256 nonce) external {
        require(tier < 5, "bad tier");
        require(!usedNonce[msg.sender][tier][nonce], "solution reused");
        bytes32 hash = puzzleHash(msg.sender, tier, nonce);
        require(hash <= bytes32(tierTarget[tier]), "bad solution");
        usedNonce[msg.sender][tier][nonce] = true;
        approved[msg.sender][tier] = true;
        emit SolutionAccepted(msg.sender, tier, nonce, hash);
    }

    /// @notice Set a tier's difficulty by leading-zero bits. The most
    ///         convenient tuning knob: target = max >> bits.
    /// @param bits 0..255. 0 = everything passes; higher = harder.
    function setDifficultyBits(uint8 tier, uint8 bits) external onlyOwner {
        require(tier < 5, "bad tier");
        uint256 t = type(uint256).max >> bits;
        tierTarget[tier] = t;
        difficultyBits[tier] = bits;
        emit TargetSet(tier, t, bits);
    }

    /// @notice Set a tier's target directly (full control, e.g. for
    ///         non-power-of-two targets). difficultyBits is updated to the
    ///         target's leading-zero-bit count (capped at 255).
    function setTarget(uint8 tier, uint256 target_) external onlyOwner {
        require(tier < 5, "bad tier");
        tierTarget[tier] = target_;
        difficultyBits[tier] = _leadingZeroBits(target_);
        emit TargetSet(tier, target_, difficultyBits[tier]);
    }

    /// @notice Repoint the Agent ID registry (owner only). No gate redeploy
    ///         needed if the registry ever changes. Zero address reverts:
    ///         the registry must always be a real contract; to restore the
    ///         canonical registry, pass DEFAULT_AGENT_REGISTRY explicitly.
    function setAgentRegistry(address registry_) external onlyOwner {
        require(registry_ != address(0), "zero registry");
        agentRegistry = registry_;
        emit AgentRegistrySet(registry_);
    }

    /// @notice True iff `minter` holds at least one Binance Agent ID token
    ///         (ERC721 balanceOf > 0 on agentRegistry). Fail CLOSED via a
    ///         low-level staticcall with an explicit returndata-length
    ///         check (NOT try/catch): a high-level call to a misconfigured
    ///         registry with no code returns SUCCESS with empty returndata,
    ///         and the ABI decoding of that empty returndata reverts OUTSIDE
    ///         the try/catch on solc 0.8.26 (observed in local tests), which
    ///         would make isApproved revert opaquely instead of returning
    ///         false. The length check below closes that hole: any failure,
    ///         empty return, or short return yields false, so the mint is
    ///         rejected with "gate rejected" instead of an opaque revert.
    ///         Agent status is evaluated at MINT time
    ///         (inside isApproved), not at solution-submission time, so a
    ///         minter who acquires an Agent ID after solving can still mint,
    ///         and a minter who loses it before minting cannot.
    function _hasAgent(address minter) internal view returns (bool) {
        (bool ok, bytes memory ret) = agentRegistry.staticcall(
            abi.encodeWithSelector(IAgentRegistry.balanceOf.selector, minter)
        );
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) > 0;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    /// @notice Count of leading zero bits of x. Returns 255 (not 256) for
    ///         x == 0 because the return type is uint8.
    function _leadingZeroBits(uint256 x) internal pure returns (uint8) {
        if (x == 0) return 255;
        uint8 bits = 0;
        // Binary-search the highest set bit: check 128, 64, 32, 16, 8, 4, 2, 1.
        if (x < (1 << 128)) { bits += 128; x <<= 128; }
        if (x < (1 << 192)) { bits += 64; x <<= 64; }
        if (x < (1 << 224)) { bits += 32; x <<= 32; }
        if (x < (1 << 240)) { bits += 16; x <<= 16; }
        if (x < (1 << 248)) { bits += 8; x <<= 8; }
        if (x < (1 << 252)) { bits += 4; x <<= 4; }
        if (x < (1 << 254)) { bits += 2; x <<= 2; }
        if (x < (1 << 255)) { bits += 1; }
        return bits;
    }
}
