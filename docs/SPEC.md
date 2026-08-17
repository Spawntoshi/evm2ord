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

## 5. Fund a Bitcoin taproot wallet

Generate a P2TR hot wallet (key server-side, never web-served). Royalties top it up; it pays for every inscription.

**Lump sum vs chunks:** you can send one large amount (change handled, funds safe), but the mempool caps unconfirmed chains at **25** — a single coin stalls after ~25 inscriptions. Send a large amount split into **~5–10 UTXOs** (300k–500k sat each). Budget ~1,000 sat/token at 1 sat/vB.

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

## 8. Auto-upgrade metadata → fully on Bitcoin

Once `inscription_id` exists, Step 3 returns the `ordinals.com/content/…` image. Do this for all N tokens and the server becomes optional. **Royalties funded the migration; low-demand projects never reach this line — the quality filter.**

## 9. (Reverse) Migrate Ordinals → EVM

Deploy the Step-2 contract but point `tokenURI` directly at each inscription's content — no new inscription needed. Existing Ordinal collections gain EVM liquidity/tooling while the art stays native to Bitcoin.

## 10. Go live & operate

- `contractURI` for marketplaces: name, logo, banner, `fee_recipient` + `seller_fee_basis_points`.
- Reconciler: scan `Transfer`-from-`0x0` events to keep the off-chain ledger in sync.
- Top up the BTC wallet as royalties arrive; the fee-gated worker drains the queue when fees ≤ target.
- Monitor: pending vs inscribed, wallet balance, mempool chain depth.
