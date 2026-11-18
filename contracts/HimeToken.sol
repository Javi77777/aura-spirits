// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HIME token (CAGENT) — PREPARATION ONLY, NOT DEPLOYED
/// @notice ERC20, fixed supply 150,000,000, minted once to the creator at deploy.
///         Buy tax 0%, sell tax 7% to the creator, claim contract tax-free.
/// @dev FINALIZED SPEC (2026-11-03, BSC):
///  - Token name "CAGENT", symbol "CAGENT". The NAME was confirmed by the user
///    (carried over from the earlier AURA token name). The SYMBOL is set equal
///    to the name as a clearly-marked constant and may be corrected later —
///    see MUST-CONFIRM note in DEPLOY_PREP.md. It is a constant here, so a
///    symbol change needs a code edit + redeploy (no proxy is used).
///  - Total supply 150,000,000 (18 decimals), NO further mint function.
///  - NO liquidity pool at launch (0 liquidity). The sell-tax mechanism keys
///    off an owner-set `pair` address which starts UNSET (address(0)); while
///    it is unset, no transfer is taxed anywhere. When a pool exists, the
///    owner sets `pair` to the pool address and sells (transfers TO the pair)
///    are taxed 7% to the creator.
///  - Buy tax 0%: transfers FROM the pair are never taxed.
///  - Plain wallet-to-wallet transfers are NOT taxed. DESIGN DECISION (flagged
///    in DEPLOY_PREP.md): the spec taxes "sells"; this contract defines a sell
///    strictly as a transfer TO the designated pair. If the user wants plain
///    transfers taxed too, that is a code change before deploy.
///  - The claim contract MUST be added to `taxExempt` post-deploy (see
///    DEPLOY_PREP.md). The creator and this contract are exempt by default.
///  - Burn/stake are COMING SOON and are deliberately NOT in this contract.

contract HimeToken {
    // ------------------------------------------------------------------------
    // Identity — token name/symbol (see header notes)
    // ------------------------------------------------------------------------
    /// @notice Confirmed token name (user, 2026-11-03; carried over from AURA).
    string public constant name = "CAGENT";
    /// @notice Symbol set equal to the name. FINAL naming decision (user,
    /// 2026-11-03): token is CAGENT/CAGENT, all decisions settled. Changing
    /// the symbol would still need a code edit + redeploy (no proxy is used).
    string public constant symbol = "CAGENT";
    uint8 public constant decimals = 18;

    uint256 public constant TOTAL_SUPPLY = 150_000_000 * 10 ** 18;
    uint256 public constant SELL_TAX_BPS = 700; // 7%

    uint256 public totalSupply;
    address public owner;
    address public creator;

    /// @notice Designated liquidity-pair address for sell detection.
    /// Starts UNSET (address(0)) because there is 0 liquidity at launch.
    address public pair;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) public taxExempt;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event PairSet(address indexed pair);
    event TaxExemptSet(address indexed account, bool exempt);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @param creator_ Treasury holder: receives the full 150,000,000 supply
    ///        and all sell tax. MUST be 0xa9Fa6a30DD6b1a082cb6E19d98487B0424A26018
    ///        per the finalized spec (public address only; never a key).
    constructor(address creator_) {
        require(creator_ != address(0), "zero creator");
        creator = creator_;
        owner = creator_;
        totalSupply = TOTAL_SUPPLY;
        _balances[creator_] = TOTAL_SUPPLY;
        taxExempt[creator_] = true;
        taxExempt[address(this)] = true;
        emit Transfer(address(0), creator_, TOTAL_SUPPLY);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ------------------------------------------------------------------------
    // ERC20 core
    // ------------------------------------------------------------------------
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address account, address spender) external view returns (uint256) {
        return _allowances[account][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "zero from");
        require(to != address(0), "zero to");
        require(_balances[from] >= amount, "balance");

        uint256 tax = 0;
        // A "sell" is strictly a transfer TO the designated pair, from a
        // non-exempt sender, while a pair is set. Everything else is 0%:
        // buys (pair -> user), plain transfers, and exempt senders.
        if (!taxExempt[from] && pair != address(0) && to == pair) {
            tax = (amount * SELL_TAX_BPS) / 10000;
        }

        _balances[from] -= amount;
        _balances[to] += (amount - tax);
        emit Transfer(from, to, amount - tax);
        if (tax > 0) {
            _balances[creator] += tax;
            emit Transfer(from, creator, tax);
        }
    }

    // ------------------------------------------------------------------------
    // Owner admin
    // ------------------------------------------------------------------------
    /// @notice Set the liquidity-pair address once a pool exists. Until then
    /// it MUST stay address(0) (0 liquidity at launch = no tax anywhere).
    function setPair(address pair_) external onlyOwner {
        pair = pair_;
        emit PairSet(pair_);
    }

    /// @notice REQUIRED post-deploy step: setTaxExempt(claimContract, true)
    /// so vesting claims are tax-free. Also usable for future integrations.
    function setTaxExempt(address account, bool exempt) external onlyOwner {
        taxExempt[account] = exempt;
        emit TaxExemptSet(account, exempt);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }
}
