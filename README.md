<div align="center">

# EVM2Ord Protocol

**Progressive-decentralization for NFT art.**
Mint liquid ERC-721s on an EVM chain → serve the art from a deterministic renderer → let **royalty revenue** inscribe every piece onto **Bitcoin** as a recursive Ordinal, one by one, until the collection needs no server at all.

`ERC-721 + ERC-2981` · `Robinhood Chain` · `Recursive Ordinals` · `Royalty-funded` · `EVM ⇄ BTC`

</div>

---

## Why

Most "on-chain" NFTs aren't — the JPEG lives on someone's S3 bucket. EVM2Ord fixes that **without** sacrificing day-one liquidity:

- **Mint fast & liquid.** ERC-721s trade on OpenSea from block one. The `tokenURI` image points at a renderer you control.
- **Migrate to Bitcoin, funded by royalties.** As secondary sales generate royalties, that revenue pays to inscribe each token onto Bitcoin as a recursive Ordinal. The metadata **auto-upgrades** to the immutable `ordinals.com/content/…` image.
- **A built-in quality filter.** Royalties fuel the migration, so only collections with real demand ever finish inscribing. Low-effort projects never reach the finish line.
- **Bi-directional.** EVM art backdoors onto BTC — *and* existing Ordinal collections can reverse-migrate into EVM for liquidity and tooling.

The loop:

```
mint (EVM) → serve (renderer) → earn (royalties) → inscribe (BTC) → upgrade (metadata) → repeat
```

When it completes, the collection lives on two chains at once: **art immutable on Bitcoin, liquidity on the EVM.** The server becomes optional.

---

## Reference implementation

**SPAWNHOOD Genesis** — 10,000 pieces, launched on Robinhood Chain (chainId 4663), art recursively inscribed on Bitcoin.
- Contract: `0xdb7cf5bb66efbf995545e5335cb107ed32866d29`
- Parent inscription: `3cc7677f050a9fb39033666fde86e347a3db83d12e9dd15c9f6d4274e8c3853ci0`
- Explorer: https://robinhoodchain.blockscout.com/address/0xdb7cf5bb66efbf995545e5335cb107ed32866d29

---

## Quickstart

1. **Design deterministic art** — a pure `render(id) → SVG` function seeded by the token id. No external assets. (This is what makes recursive inscription possible.)
2. **Deploy the ERC-721** ([`contracts/EVM2OrdCollection.sol`](contracts/EVM2OrdCollection.sol)) with ERC-2981 royalties + an EIP-712 voucher mint.
   ```bash
   npx hardhat run scripts/deploy.js --network robinhoodMainnet
   ```
3. **Run a metadata server** whose `image` points at your renderer now, and at `ordinals.com/content/<id>` once inscribed.
4. **Mint** via server-signed EIP-712 vouchers → `contract.mint(voucher, sig){value: price}`.
5. **Fund a Bitcoin taproot wallet** (royalties top it up).
6. **Inscribe the renderer once** as a recursive **parent**.
7. **Inscribe each token** as a tiny recursive **child** via a fee-gated worker (only when fees ≤ your target).
8. **Auto-upgrade** metadata → the art now serves from Bitcoin.

Full step-by-step with code: [`docs/SPEC.md`](docs/SPEC.md).

---

## Networks

| | chainId | hex | RPC |
|---|---|---|---|
| Robinhood Mainnet | 4663 | 0x1237 | https://rpc.mainnet.chain.robinhood.com |
| Robinhood Testnet | 46630 | 0xB626 | https://rpc.testnet.chain.robinhood.com |

Explorer: https://robinhoodchain.blockscout.com

---

## Funding the inscription wallet — lump sum vs chunks

You **can** send one large amount (change is handled automatically, funds are safe). But Bitcoin's mempool caps **unconfirmed transaction chains at 25** — with a single coin, every inscription chains off the previous change and stalls after ~25 until a block confirms. With several independent coins the worker funds inscriptions in parallel.

**Best practice:** send a large amount split into **~5–10 UTXOs** (a few separate sends of 300k–500k sat each). Budget **~1,000 sat per token** at 1 sat/vB. Never spend a UTXO ≤ ~1,000 sat — those are the 546-sat postage outputs carrying your inscriptions.

---

## License

MIT © 2026 — see [LICENSE](LICENSE).
