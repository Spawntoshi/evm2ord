# EVM2Ord Protocol — Specification

The loop: **mint (EVM) → serve (renderer) → earn (royalties) → inscribe (BTC) → upgrade (metadata) → repeat.**

---

## 1. Design deterministic art (id → image)

Art must be reproducible from the token id alone: a pure `render(id) → SVG`, seeded by the id, with no external assets. This enables (a) serving any token on-demand without storing N files, and (b) inscribing a single *renderer* on Bitcoin that every token references (recursion).

```js
function meta(id, total) {
  const rng = mulberry32(hashId(id));
  return { id, type: TYPES[(id-1) % TYPES.length], rarity: rarityFor(id, total), variant: id % 5 };
}
function buildSVG(id, total) { return draw(meta(id, total)); }
module.exports = { meta, buildSVG };
```

> If `buildSVG(42, 10000)` differs across machines, it's not ready to inscribe. Keep it pure.

## 2. ERC-721 with royalties + voucher mint

OpenZeppelin v5 + ERC-2981 (royalties = fuel) + EIP-712 voucher mint (server-gated). See [`../contracts/EVM2OrdCollection.sol`](../contracts/EVM2OrdCollection.sol). The royalty recipient is the wallet that tops up your Bitcoin inscription wallet — that's the flywheel.

**On-chain Bitcoin inscription address.** The contract declares, on-chain, *where this collection's art is inscribed on Bitcoin* — a `string public btcInscriptionAddress`, set at deploy (constructor arg) and changeable **only by the creator (owner)** via `setBtcInscriptionAddress`, with an optional one-time `lockBtcInscriptionAddress()` to freeze it forever. This is a public, creator-signed **commitment / pointer**, not custody: an EVM contract cannot hold BTC or verify inscriptions, so enforcement (actually sending inscriptions to that address) happens at the platform/indexer layer. It makes "where does this art live?" answerable directly from the token contract, and every change is an auditable on-chain event.

Deploy to Robinhood Chain:

```js
// hardhat.config.js
networks: {
  robinhoodMainnet: { url: "https://rpc.mainnet.chain.robinhood.com", chainId: 4663, accounts: [process.env.DEPLOYER_KEY] },
  robinhoodTestnet: { url: "https://rpc.testnet.chain.robinhood.com", chainId: 46630, accounts: [process.env.DEPLOYER_KEY] },
}
```

```bash
npx hardhat compile
npx hardhat run scripts/deploy.js --network robinhoodMainnet
```

> No testnet ETH? Deploy straight to mainnet (gas is cents), or deploy from the owner's own wallet in the browser via `ContractFactory.deploy` so no private key touches your server.

## 3. Metadata + renderer server

`tokenURI` base points here. `image`/`animation_url` return the renderer now, the Bitcoin ordinal once inscribed.

```js
app.get('/nft/:id.svg', (req, res) => res.type('image/svg+xml').send(buildSVG(+req.params.id, TOTAL)));

app.get('/meta/:id.json', async (req, res) => {
  const id = +req.params.id;
  const insc = await inscriptionIdFor(id);                       // null until inscribed
  const image = insc ? `https://ordinals.com/content/${insc}`    // upgraded
                     : `https://you.xyz/nft/${id}.svg`;          // renderer
  res.json({ name: `#${id}`, image, animation_url: image, attributes: attrsFor(id) });
});
```

## 4. Mint flow (server voucher → on-chain mint)

Server signs an EIP-712 voucher; browser submits it with payment.

```js
// server
const domain = { name:'EVM2Ord', version:'1', chainId, verifyingContract: CONTRACT };
const types  = { MintVoucher:[{name:'to',type:'address'},{name:'tokenId',type:'uint256'},
                              {name:'nonce',type:'uint256'},{name:'deadline',type:'uint256'}] };
const voucher = { to, tokenId, nonce, deadline: now + 600 };
const sig = await minterWallet.signTypedData(domain, types, voucher);
```

```js
// client
const c = new ethers.Contract(CONTRACT, ABI, await provider.getSigner());
await (await c.mint(voucher, sig, { value: price })).wait();
```

On confirmation, insert the token into an `inscriptions` queue as `pending`. Buyer sees art instantly (renderer); Bitcoin inscription happens later, off the critical path.

## 5. Pay for inscriptions — custodial *or* non-custodial

Two models; pick per how much custody you want to hold.

**A. Self-hosted (custodial).** Generate a P2TR hot wallet (key server-side, never web-served). Royalties top it up; it pays for every inscription. **Lump sum vs chunks:** you can send one large amount (change handled, funds safe), but the mempool caps unconfirmed chains at **25** — a single coin stalls after ~25 inscriptions. Send a large amount split into **~5–10 UTXOs** (300k–500k sat each). Budget ~1,000 sat/token at 1 sat/vB.

**B. Non-custodial (creator's own wallet).** The platform holds **no keys and no funds**. For each batch, a **throwaway ephemeral key** is generated in the creator's browser (used once) to sign the reveal; the creator's **own Bitcoin wallet funds the commit**; inscriptions land at the contract-declared `btcInscriptionAddress` (any wallet may fund — the destination is independent of the payer). Works with **Unisat, Xverse, Leather, and OKX**; the creator sets the **fee rate (sats/vByte)** and can raise it if fees spike. The editable fee rate always governs the reveal fee (the commit amount is computed from it). This is the model the EVM2Ord Platform uses by default.

## 6. Inscribe the PARENT renderer (once)

```js
inscribeParent(rendererJs, wallet, { network:'mainnet', feeRate:1 });
// → parentInscriptionId (e.g. 3cc7677f…853ci0). Save it.
```

A ~30 KB renderer ≈ ~8,300 sat at 1 sat/vB, inscribed once; every child reuses it.

## 7. Inscribe each token as a recursive CHILD

```html
<script src="/content/PARENT_INSCRIPTION_ID"></script>
<script>document.body.append(E2O.buildSVG(ID, TOTAL, true))</script>
```

```js
async function tick() {
  const fee = await economyFeeRate();
  if (fee > FEE_TARGET) return;                    // too pricey → wait
  const budget = Math.floor((25 - await countUnconfirmed(addr)) / 2);  // stay under the chain limit
  for (const row of pending().slice(0, budget)) {
    await inscribeChild(row, wallet, { network:'mainnet', feeRate:FEE_TARGET, parentId: PARENT_INSCRIPTION_ID });
    markInscribed(row.tokenId, revealTxid, inscriptionId);
  }
}
```

> Never spend a UTXO ≤ ~1,000 sat as funding — those are the 546-sat postage outputs carrying inscriptions. Carry change locally between inscriptions to avoid waiting on API indexing.

## 7b. Optimize: batch inscribe to cut fees (optional)

Every inscription is **two transactions** (commit + reveal), and most of the fee is fixed *transaction overhead*, not content. **Batch inscribing** packs N children into **one commit + one reveal**, amortizing that overhead. Each child still lands on its **own 546-sat output** via the ordinals `pointer` tag, keeps **byte-identical** content, and is individually owned — indistinguishable to collectors.

```js
// micro-ordinals accepts an ARRAY of inscriptions; `pointer` places each on its own output.
const inscriptions = rows.map((row, i) => {
  const tags = { contentType: 'text/html;charset=utf-8' };
  if (i > 0) tags.pointer = 546n * BigInt(i);   // i=0 → sat 0; i>0 → output i
  return { tags, body: utf8.decode(childHtml(row.id, total, parentId)) };
});
const revealPayment = btc.p2tr(undefined,
  ordinals.p2tr_ord_reveal(pub, inscriptions), NET, false, [ordinals.OutOrdinalReveal]);
// commit funds N*546 + revealFee; reveal creates N dust outputs.
// ids: <revealTxid>i0, <revealTxid>i1, … <revealTxid>i(N-1)
```

**Measured (1 sat/vB):** single ≈ 385 sat/token fee; batch of 25 ≈ **156 sat/token (~59% off the fee)**. The 546-sat postage is fixed, so total per-token outlay drops ~25% — plus ~25× fewer transactions (no mempool 25-chain stall).

**Trade-off:** shared fate — a batch confirms in one reveal, so retry/verify per batch, not per token. Always round-trip the reveal with `parseWitness` to confirm every child decodes, and test a small batch before scaling. Cap batch size (~40) to stay relay-safe.

## 8. Auto-upgrade metadata → fully on Bitcoin

Once `inscription_id` exists, Step 3 returns the `ordinals.com/content/…` image. Do this for all N tokens and the server becomes optional. **Royalties funded the migration; low-demand projects never reach this line — the quality filter.**

## 9. (Reverse) Migrate Ordinals → EVM

Deploy the Step-2 contract but point `tokenURI` directly at each inscription's content — no new inscription needed. Existing Ordinal collections gain EVM liquidity/tooling while the art stays native to Bitcoin.

### Rule: LOCK, never BURN

When an asset migrates cross-chain, EVM2Ord **locks it in a vault** — it is **never** sent to a burn/sink address. Because the asset is only escrowed, it can always be redeemed, so **every migration is reversible in both directions**. A "sink/burn" mode is deliberately excluded — it strands assets.

- **Vault-bridge (default):** the migrating asset is locked; exactly one side is live at a time; fully reversible. A vault engine handles the lock-and-release.
- **Dual-market:** nothing is locked or burned — the holder keeps the asset and a parallel EVM market is added (the token is a license/pointer). Two markets by design.

**Reinclusion nuance:** if a round-trip must return the *exact original collection token* (contract + tokenId), use **lock-not-burn custody** — the original token is escrowed and released unchanged on return, rather than reissued as a new wrapper. Choose this at launch to guarantee reinclusion.

## 10. Go live & operate

- `contractURI` for marketplaces: name, logo, banner, `fee_recipient` + `seller_fee_basis_points`.
- Reconciler: scan `Transfer`-from-`0x0` events to keep the off-chain ledger in sync.
- Top up the BTC wallet as royalties arrive; the fee-gated worker drains the queue when fees ≤ target.
- Monitor: pending vs inscribed, wallet balance, mempool chain depth.
