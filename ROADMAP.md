# EVM2Ord — Roadmap

## Shipped (v1)
- Recursive-ordinal art on Bitcoin; royalty-funded, **batched** inscription (~59% cheaper fees)
- ERC-721 issuance on Robinhood Chain (ERC-2981 royalties + EIP-712 voucher mint)
- **MIGRATE** platform — Ordinals ⇄ EVM via Emblem Vault, **lock-not-burn** (always reversible)
- **CREATE** platform — deploy an EVM2Ord ERC-721 from your own wallet
- Live fee estimator; platform fee layer; security hardening

## Phase 2 — Multi-chain CREATE
Let creators launch on more networks than Robinhood Chain.

- **More EVM chains — low effort (config-level).** Ethereum, Base, Arbitrum, Optimism, Polygon. The same ERC-721 deploys unchanged; each chain just needs `chainId` / RPC / explorer added to the network selector. Gas differs (Ethereum pricey; L2s cheap).
- **Solana — larger effort (separate path).** The EVM2Ord model extends: the art stays inscribed on Bitcoin, and the token becomes a **Metaplex NFT** whose metadata points at `ordinals.com/content/<inscription_id>`. Requires Solana tooling (Metaplex / candy-machine deploy + a Solana wallet like Phantom) — not the ERC-721 flow.
- **Other non-EVM (TON, Aptos, Sui, …)** — same pattern as Solana: chain-specific token, Bitcoin-native art.

## Phase 2 — MIGRATE depth
- Per-project curated collections (onboard *any* collection, not only existing Emblem-curated ones)
- **Lock-not-burn custody** layer for exact-tokenId reinclusion (return the original token, not a new wrapper)
- Real Emblem API key hardening + per-migration fee-revenue accounting
- End-to-end mint proof on a funded run
