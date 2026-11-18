# AURA Spirits

An on-chain hero-card game on BNB Chain where your **Binance Agent ID** is your
player identity. Mint a free hero NFT (gas only), battle, buy accessories, earn
XP, and claim CAGENT rewards — all tied to the Agent ID that minted the card.

**Live product:** https://aura-spirits.pages.dev/

## How Agent ID works here

AURA Spirits is built around Binance Agent ID end to end — it is not a
display name, it is the access key:

1. **Mint gate (on-chain).** `HimeGate` checks the Agent ID registry
   (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`) at mint time: the minter's
   wallet must hold an Agent ID (`balanceOf(minter) > 0` on the registry).
   No Agent ID, no free mint — even with a valid proof-of-work solution.
2. **One free mint per Agent ID.** Each Agent ID can claim exactly one free
   hero card. The card is bound to that identity's wallet.
3. **Proof-of-work.** Minting also requires solving a small Keccak
   proof-of-work challenge in the browser (per-tier difficulty in leading
   zero bits), which keeps the free mint bot-resistant while staying free
   apart from gas.
4. **Persistent identity.** Everything a player does — battles, accessory
   purchases, XP, and CAGENT vesting claims — is tied to cards owned by that
   Agent ID holder's wallet. The Agent ID becomes a playable, tradeable,
   reward-earning game identity.

## Contracts (BNB Chain)

| Contract | Address | BscScan |
|---|---|---|
| HimeNFT (AURA Spirits NFT) | `0x8de3eA5ff044061bFC3d90Da2aad28a61b256d0A` | [link](https://bscscan.com/address/0x8de3eA5ff044061bFC3d90Da2aad28a61b256d0A#code) |
| HimeToken (CAGENT) | `0x9044f1899f940e6A218A7D984F2cF99f6d7CF267` | [link](https://bscscan.com/address/0x9044f1899f940e6A218A7D984F2cF99f6d7CF267#code) |
| HimeMarket | `0x7F2F93675421851D8736b3475d7d3f0850370AFE` | [link](https://bscscan.com/address/0x7F2F93675421851D8736b3475d7d3f0850370AFE#code) |
| HimeDirectSale | `0x2B472d246804EE80C6Fc8b1982b808fc15E04eCd` | [link](https://bscscan.com/address/0x2B472d246804EE80C6Fc8b1982b808fc15E04eCd#code) |
| HimeGame | `0x4005e702801B8F09D10e565FC326a5Fc06eb3eB0` | [link](https://bscscan.com/address/0x4005e702801B8F09D10e565FC326a5Fc06eb3eB0#code) |
| HimeClaim | `0xF51ef24B15F8753042E2cAC5Afd94786Ed18f460` | [link](https://bscscan.com/address/0xF51ef24B15F8753042E2cAC5Afd94786Ed18f460#code) |
| HimeGate (Agent ID gate) | `0x382AB4c905AaDA0093EA8f85c597c8013deF66c3` | [link](https://bscscan.com/address/0x382AB4c905AaDA0093EA8f85c597c8013deF66c3#code) |
| HimeAccessory | `0x99F233edbddd531754439cfD7C005A97c428C0b8` | [link](https://bscscan.com/address/0x99F233edbddd531754439cfD7C005A97c428C0b8#code) |

Source code for `HimeNFT` and `HimeToken` is verified on BscScan (Exact Match,
Solidity 0.8.26, optimizer 200 runs, MIT — checked 2026-11-18). The sources in
this repo are the exact sources used for the BscScan verification packages
(byte-identical for all six contracts that have a verification package;
`HimeGame` and `HimeAccessory` have no verification package yet).

All contracts are MIT licensed (`pragma solidity ^0.8.20`, compiled with
solc 0.8.26, optimizer 200 runs, EVM Paris).

## Hero tiers

3,333 hero cards in 5 tiers. Each card carries a CAGENT claim, vested over
time (see `HimeClaim`).

| Tier | Rarity | Supply | CAGENT claim per card |
|---|---|---|---|
| Artemis | Rare ★ | 1,800 | 2,500 |
| Aphrodite | Rare ★★ | 1,200 | 3,300 |
| Medusa | Epic ★★★ | 300 | 15,000 |
| Hera | Legendary ★★★★ | 25 | 50,000 |
| Athena | Limited ★★★★★ | 8 | 150,000 |

Hera (25) and Athena (8) are fully minted. Token IDs:
Artemis 1–1800, Aphrodite 1801–3000, Medusa 3001–3300, Hera 3301–3325,
Athena 3326–3333.

## CAGENT economy

- **Direct sale:** `HimeDirectSale` sells CAGENT at 1,000,000 CAGENT per 1 BNB.
- **Vesting claims:** `HimeClaim` — vesting starts the day after the NFT is
  minted (H+1) per token ID; 3% unlocks at vesting start, the remaining 97%
  unlocks daily over 90 days. Self-claim, gas only.
- **Marketplace:** `HimeMarket` — list and buy hero cards; 7% royalty to the
  creator. Listings do not require a separate approval check — buyers should
  verify `isApprovedForAll(seller, market)` before buying.
- **Accessories:** `HimeAccessory` — buyable accessories (Rare / Epic /
  Legendary) that grant XP to the buyer's card plus a CAGENT bonus.
- **Game:** `HimeGame` — battles, XP, and accessory bonuses.

## Run the site locally

The site is a single static page (`site/index.html`, no build step). It loads
ethers.js from a CDN and reads chain data from public BSC RPC endpoints.

```bash
cd site
python3 -m http.server 8000
# open http://localhost:8000 in a browser with MetaMask (BNB Chain)
```

The live sales feed is fetched from `sales.json` next to the deployed site;
when it is absent locally the page falls back to reading sales directly from
the chain, so the site works standalone. Minting and buying need a Web3
wallet holding a Binance Agent ID.

## Repository structure

```
contracts/        Solidity sources (8 contracts, MIT)
site/             Static front-end (index.html) served at aura-spirits.pages.dev
README.md
LICENSE           MIT
```

## Security notes

- This repo contains **no private keys, mnemonics, API keys, or passwords** —
  only public contract sources and the public static site.
- The mint gate reads the Agent ID registry on-chain; there is no off-chain
  allowlist and no QR-login flow. Every transaction still requires the user's
  own wallet confirmation.
- `HimeNFT` has no owner/admin mint backdoor for the public allocation beyond
  the fixed creator reserve defined in the tier table above.
