// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HimeDirectSale — buy CAGENT with BNB (no DEX pool yet)
/// @notice Build order #2, decided 2026-11-05; no-minimum decided 2026-11-07.
///  - Rate: 1,000,000 CAGENT per 1 BNB (owner-changeable via setRate).
///  - NO minimum purchase (decided 2026-11-07 ~16:07): any msg.value > 0 buys.
///    A super-small buy can cost more gas than the CAGENT is worth — that is
///    the buyer's choice; the contract does not stop it.
///  - Owner + revenue recipient: wallet 1 (0x63b1C848d331a4a0C7022052ed591617b684439e).
///    BNB paid by buyers is forwarded to the owner on every purchase.
///  - The contract holds CAGENT inventory, funded by the owner (plain CAGENT
///    transfer into the contract). Buy reverts if stock is insufficient.
///  - No CAGENT sell-tax interference: HimeToken taxes ONLY transfers TO the
///    designated pair, and this contract sends CAGENT to buyers (never to the
///    pair), so sales are never taxed.
///  - Plain BNB transfers to this contract revert (no receive/fallback) so
///    BNB cannot get stuck; buys go through buy() only.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract HimeDirectSale {
    address public immutable token; // HimeToken (CAGENT)
    address public owner; // wallet 1: rate setter + revenue recipient

    /// @notice CAGENT (18 decimals) paid per 1 BNB. Default 1,000,000 CAGENT.
    uint256 public rate;

    bool private _locked;

    event Bought(address indexed buyer, uint256 bnbPaid, uint256 cagentOut, uint256 rate);
    event RateSet(uint256 oldRate, uint256 newRate);
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

    /// @param token_ Deployed HimeToken (CAGENT) address.
    /// @param owner_ Wallet 1 (ops treasury): receives all BNB revenue.
    constructor(address token_, address owner_) {
        require(token_ != address(0) && owner_ != address(0), "zero address");
        token = token_;
        owner = owner_;
        rate = 1000000 ether; // 1,000,000 CAGENT per 1 BNB
    }

    /// @notice CAGENT stock held by this contract (available to sell).
    function stock() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Quote: how much CAGENT `bnbAmount` wei buys at the current rate.
    function quote(uint256 bnbAmount) external view returns (uint256) {
        return (bnbAmount * rate) / 1 ether;
    }

    /// @notice Buy CAGENT with BNB. No minimum: any msg.value > 0 buys.
    /// BNB is forwarded to the owner immediately.
    function buy() external payable nonReentrant {
        require(msg.value > 0, "zero BNB");
        uint256 amount = (msg.value * rate) / 1 ether;
        require(amount > 0, "amount zero");
        require(IERC20(token).balanceOf(address(this)) >= amount, "insufficient stock");
        require(IERC20(token).transfer(msg.sender, amount), "cagent transfer failed");
        (bool ok, ) = payable(owner).call{ value: msg.value }("");
        require(ok, "bnb forward failed");
        emit Bought(msg.sender, msg.value, amount, rate);
    }

    /// @notice Change the rate (owner only). New rate applies immediately.
    function setRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "rate zero");
        emit RateSet(rate, newRate);
        rate = newRate;
    }

    /// @notice Safety valve: owner can pull unsold CAGENT inventory.
    function withdrawCAGENT(uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(owner, amount), "withdraw failed");
    }

    /// @notice Safety valve: owner can pull any BNB stuck in the contract
    /// (normally zero — buy() forwards BNB immediately).
    function withdrawBNB(uint256 amount) external onlyOwner {
        (bool ok, ) = payable(owner).call{ value: amount }("");
        require(ok, "withdraw failed");
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
