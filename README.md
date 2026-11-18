# OPHIR — On-Chain Gold Mining Game on BNB Chain

**OPHIR** is a fully on-chain mining game built around the Binance **Agent ID**.
An Agent ID is the passport to the game: only wallets that hold an Agent ID can mint
**OPHIR Miners** NFTs, and every Miner digs **$OPHR** around the clock.

🌐 Play: https://ophr.pages.dev
🪙 Token: $OPHR (ERC-20) · ⛏️ NFTs: OPHIR Miners (ERC-721, 16,666 supply)

## How Agent ID is integrated

Agent ID is not a badge on the site — it is enforced by the smart contracts:

1. **Exclusive mint access.** `OphirMiners.mint()` reads the Agent ID registry
   (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`) on every mint. Wallets without an
   Agent ID cannot mint at all, so every Miner in existence was created by a
   verified Agent ID holder.
2. **Per-identity economics.** The mint price ladder is keyed to the holder's own
   mint count — the 1st Miner is free, Miners #2–10 cost 0.0003 BNB, #11–20 cost
   0.0006 BNB and #21–30 cost 0.0009 BNB, with a hard cap of 30 per wallet. One
   identity = one fair, Sybil-resistant progression curve.
3. **Gameplay identity.** Miners are sealed at mint and revealed by blockhash.
   Mining (start / claim), house & storage upgrades and the built-in escrow market
   all operate on NFTs that only Agent ID holders could create.

## Gameplay

- **5 tiers of Miners** — Digger (7,000), Scribe (4,700), Priest (2,900),
  Vizier (1,500) and Solomon (566) — each with its own mining rate
  (10 / 19 / 35 / 64 / 120 $OPHR per hour).
- **Mining & storage.** Miners accumulate $OPHR over time; storage fills up and can
  be expanded through 15 house levels (150 → 180,000 capacity).
- **Built-in market.** A native escrow market lets holders list, buy and delist
  Miners for BNB from day one — no external marketplace required.
- **Tokenomics (fixed 1B $OPHR).** 500M reserved for liquidity (held by
  `OphirVault`), 400M allocated to mining rewards, 100M partner allocation.
  Liquidity seeding is executed from the Vault through the LP locker, so the
  reserve cannot be spent on anything else by accident.

## Deployed contracts (BNB Chain, chain id 56)

All contracts are verified and open-source on BscScan and Sourcify (exact match).

| Contract | Address |
| --- | --- |
| OPHIR Miners (NFT) | `0x1FA5B0B218e15c7d97D1896fBc0aE7780F65e6D4` |
| $OPHR Token | `0x54f57E05f072749f03ffFf9b801D1B38e6993496` |
| Mining | `0xaC1537769e365Fd1A8C0CaaacB2CaA2DD8400cd5` |
| Buildings | `0x1DEFeDEc7815e62aF9E8B20ee62d825bA04cc32D` |
| Market | `0xe345Ab0C3fb34E8C58fC44da7FeB03cD32ec7Dd5` |
| Vault | `0x87e4fe1B5d7Dd0a6a11325837A9851939b669BD2` |
| LP Locker | `0x295061C561FD5930759D4579B204376658B22442` |

## Repository layout

```
OphirMiners.sol          ERC-721 miners, Agent ID gate, price ladder, reveal
OphirToken.sol           $OPHR ERC-20 (fixed supply, allocation split)
OphirMining.sol          Mining accrual, start/claim, storage accounting
OphirBuildings.sol       House levels & storage capacities
OphirMarket.sol          Escrow market (BNB), listing fees, royalty
OphirVault.sol           Liquidity reserve vault (approve / mint-and-lock)
PxioLpLocker.sol         LP locking for the seeded pool
OphirMinersDeployer.sol  CREATE2 helper used at deployment
OphirMiningDeployer.sol  CREATE2 helper used at deployment
OphirDeployer.sol        Deployment helper
IPancakeV3.sol           PancakeSwap V3 interface used by the locker
```

Contracts were deployed with CREATE2 for deterministic addresses and were
simulation-tested on a BSC fork before deployment (mint ladder, Agent ID gate,
mining accrual, market escrow and fee flows).

## Risk notice

OPHIR is a game. $OPHR is a game token with no promised returns; values can go to
zero. Always verify contract addresses from this README or the official site
before interacting.

## License

MIT
