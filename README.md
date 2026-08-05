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
- **Digs remaining.** Shows items dug today against your rank's daily limit
  (100 at Amateur, +10 per rank, 200 at Expert — see
  [the wiki](https://horizonffxi.wiki/Chocobo_Digging)). Set your skill level by
  hand in `/hgather`; a skill-up message states the level it rose *to*, so the
  addon takes that number and corrects itself, announcing any rank-up. Both the
  limit and the addon's sessions reset at JP midnight, so the counter lines up
  with the game's.

  It is an estimate, and biased low: high ranks occasionally get a free dig,
  Blue Race Silks skip the counter about half the time, and Goblin Digger items
  are exempt — so you can usually dig a little past zero. It also only counts
  digs the addon saw; dig before loading it and the number reads high.
- **Session browser** (`/hgather sessions`) — all-time totals, a switchable bar
  chart across sessions (Net / Value / Digs / Items / Acc% / Chocobo gil), and
  per-session detail with a digs-by-hour histogram and a cumulative net-gil line.
- **Zone breakdown.** Every dig records the zone it happened in, so each session
  shows a per-zone table — digs, items, accuracy, net gil, and gil/hr — and a
  "Zones (all-time)" section compares every zone you have ever dug in, sorted by
  gil/hr. Only the gap between two consecutive digs *in the same zone* counts as
  time spent there, and gaps over 3 minutes are treated as breaks, so travel and
  AFK never inflate a zone's rate. Zones with under a minute of digging show
  `-` rather than a rate built on nothing.
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

## Notes for future edits

Behaviours that are easy to "fix" back into bugs:

- `default_settings.item_index` is deliberately **empty**. Ashita's settings
  loader merges defaults into the saved table per array index, so a non-empty
  default re-injects its own entries into any shorter saved list on every load,
  reload, and character switch — measured at 31 of 40 fetched prices reset to
  the `:123` placeholder. The seed list is applied once, on first run, by
  `seed_item_index()`. Upstream HGather has this bug.
- For the same reason, changing a default does nothing for existing installs.
  Upgrades need an explicit step in `migrate_settings()`, keyed off
  `settings_version` — whose default stays at `1` on purpose, since a default of
  `2` would make an unmigrated file look already-migrated.
- `ashita.memory.find` returns `0`, not `nil`, when a signature scan fails, and
  the world-clock pointer is `0` before the game world exists. Both are checked
  before every dereference in `get_vana_timestamp` / `get_weather`.
- The per-day graphs bake prices and the greens setting into their curves, so
  anything that changes either must clear `hgather.browser.details`.
- Zone time only accrues between consecutive digs in the same zone, capped at
  180s. Widening that to "first dig to last dig" would silently bill travel and
  AFK to whichever zone you happened to be standing in.
- Ashita ships no `encoding` library in `libs` (the ShiftJIS helper other addons
  use lives inside their own folders). Digging zone names are ASCII, so none is
  needed — don't add a `require` for one.

There is no Lua interpreter needed to check work: `pip install luaparser` gives
a syntax gate, and `pip install lupa` runs the pure logic (disk parsing, price
and zone aggregation, settings-merge behaviour) headlessly against fixtures.

## Credits

Original HGather by Hastega (SlowedHaste), building on atom0s' equipmon.
