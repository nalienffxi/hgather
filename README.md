# hgather — Chocobo Digging tracker for Ashita v4 (HorizonXI)

Tracks chocobo digging: yields, accuracy, skillups, **chocobo rental gil**, and
gil earned — organised into sessions that run on the FFXI daily reset (Japanese
midnight) and written to disk in a machine-readable form.

Rewrite of [SlowedHaste/HGather](https://github.com/SlowedHaste/HGather) v1.4.

## Install

Copy the `hgather` folder into your Ashita `addons` directory, then:

```
/addon load hgather
```

To load it automatically, add `/addon load hgather` to
`Game\scripts\default.txt` under the custom-addons section.

## What it does

- **Rental gil, counted honestly.** Watches your wallet and mount status. A gil
  drop shortly before mounting becomes a *pending* rental fee, committed only
  once you actually dig (or try to) from that bird. Rent a chocobo and ride off
  without digging and it costs your session nothing. Manual fallback:
  `/hgather rental <gil>`.
- **Sessions on the JP daily reset.** A session runs to 00:00 JST, survives
  reloads and game restarts, then archives itself and starts fresh.
- **Session browser** (`/hgather sessions`) — all-time totals, a switchable bar
  chart across sessions (Net / Value / Digs / Items / Acc% / Chocobo gil), and
  per-session detail with a digs-by-hour histogram and a cumulative net-gil line.
- **Data on disk**, under `addons/hgather/data/<Character>/`:
  - `YYYY-MM-DD.jsonl` — append-only event stream; one JSON object per line,
    each dig carrying zone, moon phase and percent, Vana'diel weekday, weather,
    and the resolved item id.
  - `YYYY-MM-DD.json` — session summary: totals, accuracy, rentals, greens cost,
    item value, net gil, item counts.

## Prices

The addon reads `data/prices.json` from this repository — a static file of
`item id -> gil` for chocobo dig yields, refreshed hourly by a GitHub Action.

It is plain public market data. There is **no API, account, key, or login**
involved, and the addon sends no credentials of any kind. It makes exactly one
request: a `GET` for that file.

Values are per unit — stackables at stack unit price (how dig loot actually
sells), everything else at the recent sales median. Items missing from the
snapshot keep whatever price you already had rather than dropping to zero.

You are free to point the addon somewhere else: set the snapshot URL in
`/hgather` → Price Snapshot, or turn auto-refresh off and price items by hand in
the same editor (`name:price`, one per line, lowercase).

## Commands

| Command | Effect |
|---|---|
| `/hgather` | Toggle the settings editor |
| `/hgather sessions` | Toggle the session browser |
| `/hgather report` | Print the session report to chat |
| `/hgather prices` | Refresh prices from the snapshot |
| `/hgather clear` | Clear the current session |
| `/hgather show` / `hide` | Toggle the overlay |
| `/hgather export` | Force-write session files to disk |
| `/hgather rental <gil>` | Manually record a rental fee |

## Repository layout

| Path | Purpose |
|---|---|
| `hgather/` | The addon itself — copy this into `addons/` |
| `data/prices.json` | Published price snapshot (generated; do not edit by hand) |
| `data/dig-items.json` | The dig-item id list the snapshot is built from |
| `scripts/build-prices.mjs` | Snapshot generator (CI only) |

The generator reads its upstream from a `PRICE_API` repository secret, so no
service URL is committed here or shipped to users.

## Enabling the price publisher

The workflow at `.github/workflows/publish-prices.yml` is already in the
repository. It needs one secret before it can run:

1. Add a repository secret named `PRICE_API` (Settings → Secrets and variables →
   Actions), set to the price endpoint including its path but **no** query
   string — the script appends `?itemIds=...` itself.
2. Run it once from the Actions tab ("Run workflow") to confirm it commits a
   refreshed `data/prices.json`.

Until the secret exists the workflow fails fast and changes nothing, so the
committed snapshot stays as-is — the addon keeps working, the numbers just stop
moving.

## Credits

Original HGather by Hastega (SlowedHaste), building on atom0s' equipmon.
