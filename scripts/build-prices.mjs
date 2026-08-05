#!/usr/bin/env node
/**
 * Builds data/prices.json — the public price snapshot the hgather addon reads.
 *
 * Runs in CI only. The upstream price API lives in the PRICE_API env var
 * (a repository secret), so the URL never appears in a committed file and is
 * never shipped to addon users. Only the resulting id -> gil table is public.
 *
 * Usage: PRICE_API="<batch price endpoint>" node scripts/build-prices.mjs
 *
 * PRICE_API must accept ?itemIds=<comma separated> and return
 * { prices: { "<id>": { singlePrice, stackUnitPrice, medianSingle,
 *                       medianStack, npcSellPrice, stackSize } } }
 */

import { readFile, writeFile } from 'node:fs/promises';

const API = process.env.PRICE_API;
if (!API) {
  console.error('PRICE_API is not set. Refusing to build an empty snapshot.');
  process.exit(1);
}

const DIG_ITEMS = JSON.parse(await readFile('data/dig-items.json', 'utf8')).items;
const ids = DIG_ITEMS.map((i) => i.id);

/**
 * Per-unit value. Stackables are valued at the stack unit price because that
 * is how dig loot actually sells; everything else falls back through the
 * recent-sales median, the current listing, then the NPC sell floor.
 */
function pickPrice(f) {
  const stackSize = f.stackSize ?? 1;
  if (stackSize > 1) {
    if (f.stackUnitPrice) return f.stackUnitPrice;
    if (f.medianStack) return Math.ceil(f.medianStack / stackSize);
  }
  return f.medianSingle ?? f.singlePrice ?? f.stackUnitPrice ?? f.npcSellPrice ?? null;
}

// Never let the upstream URL reach stdout/stderr: on a public repository the
// Actions log is world-readable, and a raw fetch stack trace would carry the
// host. Errors are reported by class only.
let payload;
try {
  const res = await fetch(`${API}?itemIds=${ids.join(',')}`, {
    headers: { 'user-agent': 'hgather-price-publisher' },
  });
  if (!res.ok) {
    console.error(`Upstream returned ${res.status}. Leaving the existing snapshot in place.`);
    process.exit(1);
  }
  payload = await res.json();
} catch (err) {
  console.error(`Upstream request failed (${err?.name ?? 'Error'}). Leaving the existing snapshot in place.`);
  process.exit(1);
}

const { prices } = payload;
if (!prices || typeof prices !== 'object') {
  console.error('Upstream response had no prices object. Aborting.');
  process.exit(1);
}

const items = {};
let priced = 0;
for (const item of DIG_ITEMS) {
  const p = pickPrice(prices[item.id] ?? {});
  if (p && p > 0) {
    items[item.id] = Math.floor(p);
    priced += 1;
  }
}

// A collapse to near-zero coverage means the upstream is broken, not that every
// item became worthless. Keep the last good snapshot rather than publish junk.
const MIN_COVERAGE = 0.5;
if (priced < DIG_ITEMS.length * MIN_COVERAGE) {
  console.error(`Only ${priced}/${DIG_ITEMS.length} items priced (<${MIN_COVERAGE * 100}%). Aborting.`);
  process.exit(1);
}

const snapshot = {
  schema: 1,
  generated_at: Math.floor(Date.now() / 1000),
  item_count: priced,
  note: 'Per-unit gil values for chocobo dig yields, keyed by FFXI item id.',
  items,
};

await writeFile('data/prices.json', JSON.stringify(snapshot, null, 1) + '\n', 'utf8');
console.log(`Wrote data/prices.json — ${priced}/${DIG_ITEMS.length} items priced.`);
