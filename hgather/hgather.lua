--[[
* hgather - Chocobo Digging tracker for Ashita v4 (HorizonXI)
*
* Rewrite of SlowedHaste/HGather (v1.4, itself based on atom0s' equipmon):
*   - Visual style shared with the local 'parse' addon (FFXI navy/steel-blue theme).
*   - Tracks chocobo rental gil, committed only once you actually dig (or try to)
*     after getting the bird. Rent-and-ride-away costs are not counted.
*   - Sessions are bound to the daily reset at Japanese midnight (00:00 JST).
*     Each session is persisted to disk, machine-readable:
*       addons/hgather/data/<Character>/<YYYY-MM-DD>.jsonl  (event stream, append-only)
*       addons/hgather/data/<Character>/<YYYY-MM-DD>.json   (session summary, rewritten)
*
* Commands:
*   /hgather              - Toggle the settings editor
*   /hgather report       - Print session report to chat
*   /hgather clear        - Clear the current session stats
*   /hgather show/hide    - Toggle the overlay window
*   /hgather export       - Force-write session files to disk now
*   /hgather rental <gil> - Manually record a chocobo rental fee
*   /hgather help         - Show help
--]]

addon.name      = 'hgather';
addon.author    = 'Hastega, rewritten by Claude';
addon.version   = '2.2';
addon.desc      = 'Chocobo digging tracker: yields, rental gil, JST-day sessions on disk.';
addon.link      = 'https://github.com/SlowedHaste/HGather';
addon.commands  = {'/hgather'};

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');
require('constants');

local JST_OFFSET = 9 * 3600;

------------------------------------------------------------
-- Settings
------------------------------------------------------------
local DEFAULT_PRICE_URL = 'https://raw.githubusercontent.com/nalienffxi/hgather/main/data/prices.json';

local default_settings = T{
    -- Bumped by migrate_settings() after it runs. The default stays at 1 on
    -- purpose: the settings loader fills in missing keys from the defaults, so
    -- a default of 2 would make an unmigrated file look already-migrated.
    settings_version = 1,

    visible         = T{ true },
    opacity         = T{ 0.80 },
    moon_display    = T{ true },
    skillup_display = T{ true },
    display_timeout = T{ 600 },   -- seconds after last dig before overlay auto-hides (0 = never)
    gysahl_cost     = T{ 62 },
    gysahl_subtract = T{ true },
    -- Deliberately empty: Ashita's settings loader merges defaults into the
    -- saved table per-index, so a non-empty default array would re-inject its
    -- own entries into any shorter saved list on every load, reload, and
    -- character switch -- resurrecting deleted lines and overwriting fetched
    -- prices with placeholders. The seed list is applied once, on first run.
    item_index      = T{ },
    -- Public price snapshot. This is a static file on a neutral host: it holds
    -- nothing but "item id -> gil" for dig yields, so the URL is safe to ship
    -- to anyone. No account, key, or private service is involved.
    price_url       = T{ DEFAULT_PRICE_URL },
    price_auto      = T{ true },   -- refresh the snapshot once per session

    -- Current JST-day session, kept in settings so it survives reloads and
    -- game restarts within the same Vana'diel day. Disk files are the export.
    session = T{
        date_jst   = '',
        started_at = 0,     -- unix, first dig attempt of the session
        last_at    = 0,     -- unix, last event of the session
        dig_tries  = 0,
        dig_items  = 0,
        skillups   = 0.0,
        rentals    = 0,
        gil_paid   = 0,     -- committed chocobo rental gil
        rewards    = T{ },  -- [item name] = count
    },
};

------------------------------------------------------------
-- State
------------------------------------------------------------
local hgather = T{
    settings = settings.load(default_settings),

    editor_open = T{ false },
    pricing     = T{ },
    gil_per_hour = 0,

    -- dig timing (digs per minute over the last 10 digs)
    dig_timing = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    dig_index  = 1,
    dig_per_minute = 0,

    last_attempt = 0,   -- ms clock of last outgoing dig packet

    -- chocobo rental detection
    prev_gil      = nil,
    last_gil_drop = nil,   -- { amount, time (os.clock) }
    prev_status   = nil,
    zero_seen     = false, -- a 0-gil reading needs confirming before it is trusted
    pending_rental = nil,  -- gil amount waiting for a dig attempt to be committed

    -- disk io
    priced_for = nil,      -- JST date the live prices were last fetched for
    dirty      = false,
    last_save  = 0,        -- os.clock of last disk write
    data_dir   = nil,      -- cached per-character data directory
    event_buf  = T{ },     -- events buffered until character name is known

    -- cached memory pointers (avoid re-scanning FFXiMain every call)
    ptr_vanatime = nil,
    ptr_weather  = nil,

    -- session browser
    browser = T{
        open     = T{ false },
        metric   = 1,
        sessions = nil,    -- cached list of past sessions from disk (nil = rescan)
        details  = T{ },   -- [date] = parsed jsonl timeline
        expanded = T{ },   -- [date] = true while its header is open
    },
};

local STATUS_CHOCOBO = 85;

------------------------------------------------------------
-- Small helpers
------------------------------------------------------------
local function split(inputstr, sep)
    if (sep == nil) then sep = '%s'; end
    local t = { };
    for str in string.gmatch(inputstr, '([^' .. sep .. ']+)') do
        table.insert(t, str);
    end
    return t;
end

------------------------------------------------------------
-- Item name normalization
--
-- The game log says "chunk of iron ore" (log name) while the item is
-- "iron ore" (canonical name). We build a lookup over the game's item
-- resources once, so every dug item resolves to its canonical name and
-- item id — which also lines up with AH pricing sources.
------------------------------------------------------------
local item_map = nil;   -- [lowercased name/log name] = { name, id }

local function build_item_map()
    item_map = { };
    local resmgr = AshitaCore:GetResourceManager();
    if (resmgr == nil) then item_map = nil; return; end
    -- Dig yields are all general items; equipment (10000+) never digs up.
    for id = 1, 9999 do
        local res = resmgr:GetItemById(id);
        if (res ~= nil) then
            local name = res.Name and res.Name[1];
            if (name ~= nil and #name > 0) then
                local entry = { name = name:lower(), id = id };
                item_map[entry.name] = entry;
                local logs = res.LogNameSingular and res.LogNameSingular[1];
                if (logs ~= nil and #logs > 0) then item_map[logs:lower()] = entry; end
                local logp = res.LogNamePlural and res.LogNamePlural[1];
                if (logp ~= nil and #logp > 0) then item_map[logp:lower()] = entry; end
            end
        end
    end
end

-- Returns canonical_name, item_id (falls back to the raw text, nil).
local function normalize_item(raw)
    if (raw == nil) then return nil, nil; end
    if (item_map == nil) then build_item_map(); end
    local s = raw:lower():gsub('^an? ', ''):gsub('^the ', '');
    if (item_map ~= nil) then
        local hit = item_map[s] or item_map[raw:lower()];
        if (hit ~= nil) then return hit.name, hit.id; end
    end
    return s, nil;
end

-- One-time upgrades of an already-saved settings file. The loader never
-- overwrites a value that is already present, so a changed default alone does
-- nothing for existing installs -- upgrades have to be done explicitly here.
local function migrate_settings()
    local version = tonumber(hgather.settings.settings_version) or 1;
    if (version >= 2) then return; end

    -- v1 pointed price_url at a live API host and built the request path in
    -- Lua. v2 reads a single static snapshot file, so an old host-only value
    -- would fetch a web page and fail as malformed.
    local url = tostring(hgather.settings.price_url[1] or '');
    if (not url:lower():match('%.json$')) then
        hgather.settings.price_url[1] = DEFAULT_PRICE_URL;
        print(chat.header(addon.name):append(chat.message(
            'Snapshot URL upgraded to the static price file.')));
    end

    hgather.settings.settings_version = 2;
    settings.save();
end

local function seed_item_index()
    if (#hgather.settings.item_index > 0) then return; end
    local seed = T{ };
    for _, v in ipairs(ItemIndex) do seed:append(v); end
    table.sort(seed);
    hgather.settings.item_index = seed;
end

local function update_pricing()
    hgather.pricing = T{ };
    hgather.browser.details = T{ };  -- cached graphs bake in prices
    for _, v in pairs(hgather.settings.item_index) do
        local parts = split(v, ':');
        if (#parts >= 2) then
            -- Normalize the key too, so "chunk of iron ore:50" and
            -- "iron ore:50" both price the same dug item.
            local name = normalize_item(parts[1]);
            hgather.pricing[name] = tonumber(parts[2]) or 0;
        end
    end
end

local function format_int(number)
    local s = tostring(math.floor(number));
    local neg = s:sub(1, 1) == '-';
    if (neg) then s = s:sub(2); end
    s = s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '');
    if (neg) then s = '-' .. s; end
    return s;
end

local function format_time(secs)
    if (secs <= 0) then return '0s'; end
    local h = math.floor(secs / 3600);
    local m = math.floor((secs % 3600) / 60);
    local s = math.floor(secs % 60);
    if (h > 0) then return string.format('%dh %02dm', h, m); end
    if (m > 0) then return string.format('%dm %02ds', m, s); end
    return string.format('%ds', s);
end

local function jst_date()
    return os.date('!%Y-%m-%d', os.time() + JST_OFFSET);
end

local function secs_to_jst_midnight()
    return 86400 - ((os.time() + JST_OFFSET) % 86400);
end

local function get_char_name()
    local player = GetPlayerEntity();
    if (player ~= nil and player.Name ~= nil and #player.Name > 0) then
        return player.Name;
    end
    return nil;
end

local function get_zone_id()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
end

local function get_gil()
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then return nil; end
    local item = inv:GetContainerItem(0, 0);
    if (item == nil) then return nil; end
    return item.Count;
end

------------------------------------------------------------
-- Vana'diel time / moon / weather (from luashitacast, pointers cached)
------------------------------------------------------------
-- ashita.memory.find returns 0 (not nil) when a signature scan fails, and the
-- world-clock pointer is still 0 before the game world exists. Dereferencing
-- either is an access violation, so both are checked every call.
local function get_vana_timestamp()
    if (hgather.ptr_vanatime == nil or hgather.ptr_vanatime == 0) then
        hgather.ptr_vanatime = ashita.memory.find('FFXiMain.dll', 0, 'B0015EC390518B4C24088D4424005068', 0, 0);
    end
    if (hgather.ptr_vanatime == nil or hgather.ptr_vanatime == 0) then return nil; end
    local pointer = ashita.memory.read_uint32(hgather.ptr_vanatime + 0x34);
    if (pointer == nil or pointer == 0) then return nil; end
    local rawTime = ashita.memory.read_uint32(pointer + 0x0C) + 92514960;
    local ts = { };
    ts.day    = math.floor(rawTime / 3456);
    ts.hour   = math.floor(rawTime / 144) % 24;
    ts.minute = math.floor((rawTime % 144) / 2.4);
    return ts;
end

local function get_weather()
    if (hgather.ptr_weather == nil or hgather.ptr_weather == 0) then
        hgather.ptr_weather = ashita.memory.find('FFXiMain.dll', 0, '66A1????????663D????72', 0, 0);
    end
    if (hgather.ptr_weather == nil or hgather.ptr_weather == 0) then return nil; end
    local pointer = ashita.memory.read_uint32(hgather.ptr_weather + 0x02);
    if (pointer == nil or pointer == 0) then return nil; end
    return ashita.memory.read_uint8(pointer + 0);
end

local function get_moon()
    local ts = get_vana_timestamp();
    if (ts == nil) then return { MoonPhase = '?', MoonPhasePercent = 0, VanaDay = -1 }; end
    local moon_index = ((ts.day + 26) % 84) + 1;
    return {
        MoonPhase        = MoonPhase[moon_index],
        MoonPhasePercent = MoonPhasePercent[moon_index],
        VanaDay          = ts.day % 8,
    };
end

------------------------------------------------------------
-- Disk storage (JSONL event stream + JSON summary per JST day)
------------------------------------------------------------
local function json_escape(s)
    return tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '');
end

local function json_encode_flat(tbl)
    -- Encodes a flat table of string/number/boolean/nil values.
    local parts = T{ };
    for k, v in pairs(tbl) do
        local val;
        if (type(v) == 'number') then
            if (v % 1 == 0) then val = string.format('%d', v); else val = string.format('%.2f', v); end
        elseif (type(v) == 'boolean') then
            val = tostring(v);
        else
            val = '"' .. json_escape(v) .. '"';
        end
        parts:append('"' .. json_escape(k) .. '":' .. val);
    end
    return '{' .. table.concat(parts, ',') .. '}';
end

local function get_data_dir()
    if (hgather.data_dir ~= nil) then return hgather.data_dir; end
    local name = get_char_name();
    if (name == nil) then return nil; end
    local base = addon.path .. '\\data';
    local dir  = base .. '\\' .. name;
    if (not ashita.fs.exists(base)) then ashita.fs.create_dir(base); end
    if (not ashita.fs.exists(dir))  then ashita.fs.create_dir(dir);  end
    hgather.data_dir = dir;
    return dir;
end

local function append_event(evt)
    evt.t = evt.t or os.time();
    hgather.event_buf:append(evt);
    local dir = get_data_dir();
    if (dir == nil) then return; end -- name unknown yet; flushed later
    local sess = hgather.settings.session;
    local f = io.open(dir .. '\\' .. sess.date_jst .. '.jsonl', 'a');
    if (f == nil) then return; end
    for _, e in ipairs(hgather.event_buf) do
        f:write(json_encode_flat(e) .. '\n');
    end
    f:close();
    hgather.event_buf = T{ };
end

local function session_totals()
    local sess = hgather.settings.session;
    local greens = sess.dig_tries * hgather.settings.gysahl_cost[1];
    local worth = 0;
    for k, v in pairs(sess.rewards) do
        if (hgather.pricing[k] ~= nil) then
            worth = worth + hgather.pricing[k] * v;
        end
    end
    local net = worth - sess.gil_paid;
    if (hgather.settings.gysahl_subtract[1]) then
        net = net - greens;
    end
    local accuracy = 0;
    if (sess.dig_tries > 0) then
        accuracy = sess.dig_items / sess.dig_tries * 100;
    end
    return greens, worth, net, accuracy;
end

local function write_summary(end_reason)
    local dir = get_data_dir();
    if (dir == nil) then return false; end
    local sess = hgather.settings.session;
    if (sess.date_jst == '') then return false; end

    local greens, worth, net, accuracy = session_totals();
    local items = T{ };
    for k, v in pairs(sess.rewards) do
        items:append('"' .. json_escape(k) .. '":' .. string.format('%d', v));
    end

    local f = io.open(dir .. '\\' .. sess.date_jst .. '.json', 'w');
    if (f == nil) then return false; end
    f:write('{\n');
    f:write('  "schema": 1,\n');
    f:write('  "character": "' .. json_escape(get_char_name() or 'Unknown') .. '",\n');
    f:write('  "date_jst": "' .. sess.date_jst .. '",\n');
    f:write('  "started_at": ' .. string.format('%d', sess.started_at) .. ',\n');
    f:write('  "last_event_at": ' .. string.format('%d', sess.last_at) .. ',\n');
    f:write('  "written_at": ' .. string.format('%d', os.time()) .. ',\n');
    f:write('  "end_reason": "' .. json_escape(end_reason or 'save') .. '",\n');
    f:write('  "dig_tries": ' .. string.format('%d', sess.dig_tries) .. ',\n');
    f:write('  "dig_items": ' .. string.format('%d', sess.dig_items) .. ',\n');
    f:write('  "accuracy_pct": ' .. string.format('%.2f', accuracy) .. ',\n');
    f:write('  "skillups": ' .. string.format('%.1f', sess.skillups) .. ',\n');
    f:write('  "rentals": ' .. string.format('%d', sess.rentals) .. ',\n');
    f:write('  "chocobo_gil_paid": ' .. string.format('%d', sess.gil_paid) .. ',\n');
    f:write('  "greens_cost_each": ' .. string.format('%d', hgather.settings.gysahl_cost[1]) .. ',\n');
    f:write('  "greens_cost_total": ' .. string.format('%d', greens) .. ',\n');
    f:write('  "item_value": ' .. string.format('%d', worth) .. ',\n');
    f:write('  "net_gil": ' .. string.format('%d', net) .. ',\n');
    f:write('  "items": {' .. table.concat(items, ', ') .. '}\n');
    f:write('}\n');
    f:close();
    return true;
end

local function save_to_disk(end_reason)
    write_summary(end_reason);
    settings.save();
    hgather.dirty = false;
    hgather.last_save = os.clock();
end

------------------------------------------------------------
-- Prices from the public snapshot
--
-- The addon reads one static file of the form
--   {"schema":1,"generated_at":<unix>,"items":{"<item id>":<gil>, ...}}
-- and nothing else. No API, no account, no key: the URL is safe to ship to
-- anyone, because knowing it grants exactly "dig item prices".
--
-- The snapshot is keyed by ITEM ID, not by name, and each id is resolved to a
-- name through the client's own item resources. That is deliberate -- it means
-- prices and dug items are named by the same authority and cannot drift apart.
------------------------------------------------------------
local function http_get(url)
    local body = nil;
    if (io.popen ~= nil) then
        local p = io.popen('curl -s -m 6 "' .. url .. '" 2>nul');
        if (p ~= nil) then
            body = p:read('*a');
            p:close();
        end
    else
        local tmp = addon.path .. '\\data\\_prices_tmp.json';
        os.execute('curl -s -m 6 "' .. url .. '" -o "' .. tmp .. '" 2>nul');
        local f = io.open(tmp, 'r');
        if (f ~= nil) then
            body = f:read('*a');
            f:close();
        end
    end
    if (body == nil or #body == 0) then return nil; end
    return body;
end

local function fetch_prices()
    local resmgr = AshitaCore:GetResourceManager();
    if (resmgr == nil) then
        print(chat.header(addon.name):append(chat.error('Item resources unavailable; cannot apply prices.')));
        return;
    end

    local body = http_get(hgather.settings.price_url[1]);
    if (body == nil) then
        print(chat.header(addon.name):append(chat.error('Price snapshot unreachable; keeping current prices.')));
        return;
    end

    -- Only the "items" object holds prices; ignore the surrounding metadata so
    -- generated_at/item_count can never be mistaken for an item id.
    local items_block = body:match('"items"%s*:%s*{(.*)}');
    if (items_block == nil) then
        print(chat.header(addon.name):append(chat.error(
            'Snapshot URL did not return a price file; keeping current prices.')));
        print(chat.header(addon.name):append(chat.message(
            'Expected a JSON snapshot. Check Snapshot URL in /hgather -- it should be:')));
        print(chat.header(addon.name):append(chat.color1(6, '  ' .. DEFAULT_PRICE_URL)));
        return;
    end

    local updated, unknown = 0, 0;
    for id_str, price_str in items_block:gmatch('"(%d+)"%s*:%s*(%d+)') do
        local id, price = tonumber(id_str), tonumber(price_str);
        local res = (id ~= nil) and resmgr:GetItemById(id) or nil;
        local name = res and res.Name and res.Name[1];
        if (name ~= nil and #name > 0 and price ~= nil and price > 0) then
            hgather.pricing[name:lower()] = price;
            updated = updated + 1;
        else
            unknown = unknown + 1;
        end
    end

    if (updated == 0) then
        print(chat.header(addon.name):append(chat.error('Price snapshot had no usable entries; keeping current prices.')));
        return;
    end

    -- Persist into the editable price list (canonical names, sorted).
    local lines = T{ };
    for name, price in pairs(hgather.pricing) do
        lines:append(name .. ':' .. tostring(math.floor(price)));
    end
    table.sort(lines);
    hgather.settings.item_index = lines;
    hgather.browser.details = T{ };  -- cached graphs were drawn with old prices
    settings.save();
    print(chat.header(addon.name):append(chat.message(
        'Updated ' .. updated .. ' prices from the snapshot' ..
        (unknown > 0 and (' (' .. unknown .. ' unrecognised ids skipped).') or '.'))));
end

------------------------------------------------------------
-- Session lifecycle (bound to JP midnight)
------------------------------------------------------------
local function reset_session(new_date)
    local sess = hgather.settings.session;
    sess.date_jst   = new_date;
    sess.started_at = 0;
    sess.last_at    = 0;
    sess.dig_tries  = 0;
    sess.dig_items  = 0;
    sess.skillups   = 0.0;
    sess.rentals    = 0;
    sess.gil_paid   = 0;
    sess.rewards    = T{ };
    hgather.browser.sessions = nil;  -- yesterday just became a disk session
    append_event({ e = 'session_start', date_jst = new_date });
    settings.save();
end

-- Finalizes the stored session if its JST date has passed, then opens today's.
local function ensure_session()
    local today = jst_date();
    local sess = hgather.settings.session;
    if (sess.date_jst == today) then return; end
    if (sess.date_jst ~= '') then
        -- Yesterday's (or older) session: write its summary under its own date.
        write_summary('jp_midnight_reset');
        print(chat.header(addon.name):append(chat.message(
            'JP midnight reset: session ' .. sess.date_jst .. ' archived, new session ' .. today .. ' started.')));
    end
    reset_session(today);
end

local function mark_event()
    local sess = hgather.settings.session;
    local now = os.time();
    if (sess.started_at == 0) then sess.started_at = now; end
    sess.last_at = now;
    hgather.dirty = true;
end

local function clear_session()
    append_event({ e = 'clear' });
    local today = hgather.settings.session.date_jst;
    reset_session(today ~= '' and today or jst_date());
    -- Rewrite the summary immediately; otherwise the file on disk keeps the
    -- pre-clear totals until the next dig, contradicting the addon itself.
    write_summary('clear');
    hgather.dig_timing = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    hgather.dig_index = 1;
    hgather.dig_per_minute = 0;
    hgather.pending_rental = nil;
    print(chat.header(addon.name):append(chat.message('Session cleared.')));
end

------------------------------------------------------------
-- Chocobo rental tracking
--
-- Renting deducts gil at the NPC, then the player mounts (server status 85).
-- We remember the most recent gil decrease; on the moment we go from
-- not-mounted to mounted, that decrease becomes a *pending* rental fee.
-- Only when a dig is actually attempted does the fee get committed to the
-- session. Dismounting without digging discards it.
------------------------------------------------------------
local RENTAL_MAX_GIL   = 10000;  -- sanity cap: bigger drops are not rental fees
local RENTAL_WINDOW_S  = 60;     -- gil drop must be at most this old at mount time

local function record_rental(amount)
    local sess = hgather.settings.session;
    ensure_session();
    sess.gil_paid = sess.gil_paid + amount;
    sess.rentals = sess.rentals + 1;
    mark_event();
    append_event({ e = 'rental', gil = amount, zone = get_zone_id() });
    save_to_disk('save');
    print(chat.header(addon.name):append(chat.message(
        'Chocobo rental recorded: ' .. format_int(amount) .. 'g (session total ' .. format_int(sess.gil_paid) .. 'g).')));
end

local function poll_rental_state()
    local player = GetPlayerEntity();
    if (player == nil) then
        hgather.prev_gil = nil;   -- zoning; gil readings are unreliable here
        hgather.prev_status = nil;
        return;
    end

    -- Watch the wallet. A reading of 0 is treated as suspect on first sight
    -- (inventory reads transiently empty around zoning) but honoured if it
    -- persists, so spending your last gil on a rental is still recorded.
    local gil = get_gil();
    if (gil ~= nil) then
        local trust = true;
        if (gil == 0 and hgather.prev_gil ~= nil and hgather.prev_gil > 0) then
            trust = hgather.zero_seen or false;
            hgather.zero_seen = true;
        elseif (gil > 0) then
            hgather.zero_seen = false;
        end

        if (trust) then
            if (hgather.prev_gil ~= nil and gil < hgather.prev_gil) then
                local drop = hgather.prev_gil - gil;
                if (drop <= RENTAL_MAX_GIL) then
                    hgather.last_gil_drop = { amount = drop, time = os.clock() };
                end
            end
            hgather.prev_gil = gil;
        end
    end

    -- Watch the mount.
    local status = player.StatusServer;
    if (hgather.prev_status ~= nil and status ~= hgather.prev_status) then
        if (status == STATUS_CHOCOBO) then
            local d = hgather.last_gil_drop;
            if (d ~= nil and (os.clock() - d.time) <= RENTAL_WINDOW_S) then
                hgather.pending_rental = d.amount;
                hgather.last_gil_drop = nil;
            end
        elseif (hgather.prev_status == STATUS_CHOCOBO) then
            -- Dismounted. An uncommitted fee means the bird was never dug from.
            hgather.pending_rental = nil;
        end
    end
    hgather.prev_status = status;
end

local function commit_pending_rental()
    if (hgather.pending_rental == nil) then return; end
    local amount = hgather.pending_rental;
    hgather.pending_rental = nil;
    record_rental(amount);
end

------------------------------------------------------------
-- Output / report
------------------------------------------------------------
local function print_report()
    local sess = hgather.settings.session;
    local greens, worth, net, accuracy = session_totals();
    local elapsed = (sess.started_at > 0) and (os.time() - sess.started_at) or 0;

    print(chat.header(addon.name):append(chat.message(
        '--- Session ' .. sess.date_jst .. ' (JST day, ' .. format_time(elapsed) .. ') ---')));
    print(chat.header(addon.name):append(chat.message(string.format(
        'Digs: %d (%.1f/min) | Items: %d | Acc: %.1f%%',
        sess.dig_tries, hgather.dig_per_minute, sess.dig_items, accuracy))));
    print(chat.header(addon.name):append(chat.message(
        'Greens: ' .. format_int(greens) .. 'g | Chocobo rentals: ' .. sess.rentals ..
        ' (' .. format_int(sess.gil_paid) .. 'g)')));
    for k, v in pairs(sess.rewards) do
        local price = hgather.pricing[k] or 0;
        print(chat.header(addon.name):append(chat.message(
            '  ' .. k .. ' x' .. format_int(v) .. ' (' .. format_int(price * v) .. 'g)')));
    end
    print(chat.header(addon.name):append(chat.message(
        'Item value: ' .. format_int(worth) .. 'g | Net: ' .. format_int(net) .. 'g (' ..
        format_int(hgather.gil_per_hour) .. ' gph)')));
end

local function print_help(isError)
    if (isError) then
        print(chat.header(addon.name):append(chat.error('Invalid command syntax for command: ')):append(chat.success('/' .. addon.name)));
    else
        print(chat.header(addon.name):append(chat.message('Available commands:')));
    end
    local cmds = T{
        { '/hgather',              'Toggles the settings editor.' },
        { '/hgather report',       'Prints the session report to chat.' },
        { '/hgather clear',        'Clears the current session stats.' },
        { '/hgather show',         'Shows the overlay window.' },
        { '/hgather hide',         'Hides the overlay window.' },
        { '/hgather export',       'Force-writes session files to disk.' },
        { '/hgather rental <gil>', 'Manually records a chocobo rental fee.' },
        { '/hgather sessions',     'Toggles the session browser (history + graphs).' },
        { '/hgather prices',       'Refreshes prices from the public snapshot.' },
        { '/hgather save',         'Saves settings to disk.' },
        { '/hgather reload',       'Reloads settings from disk.' },
    };
    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

------------------------------------------------------------
-- FFXI window theme (shared look with the 'parse' addon)
------------------------------------------------------------
local function rgba_u32(r, g, b, a)
    -- pack 0-255 channels into ImGui's 0xAABBGGRR U32
    return a * 0x1000000 + b * 0x10000 + g * 0x100 + r;
end

local function push_ffxi_theme()
    imgui.PushStyleColor(ImGuiCol_WindowBg,      { 0.00, 0.04, 0.13, 0.93 }); -- deep FFXI navy
    imgui.PushStyleColor(ImGuiCol_Border,        { 0.45, 0.62, 0.88, 0.85 }); -- steel-blue frame
    imgui.PushStyleColor(ImGuiCol_TitleBg,       { 0.00, 0.05, 0.16, 0.95 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.03, 0.12, 0.30, 0.97 });
    imgui.PushStyleColor(ImGuiCol_Separator,     { 0.35, 0.52, 0.80, 0.55 });
    imgui.PushStyleColor(ImGuiCol_Text,          { 0.92, 0.95, 1.00, 1.00 }); -- blue-white
    imgui.PushStyleColor(ImGuiCol_FrameBg,       { 0.00, 0.09, 0.24, 0.85 });
    imgui.PushStyleColor(ImGuiCol_PlotHistogram, { 0.28, 0.62, 1.00, 0.90 });
    imgui.PushStyleColor(ImGuiCol_Button,        { 0.05, 0.16, 0.38, 0.90 });
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.12, 0.30, 0.58, 0.95 });
    imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 0.18, 0.40, 0.72, 1.00 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding,   3.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding,    2.0);
    return 11, 3;  -- (colors, vars) pushed; must match the pops
end

local function pop_ffxi_theme(colors, vars)
    imgui.PopStyleColor(colors);
    imgui.PopStyleVar(vars);
end

-- Subtle vertical gradient behind the content for that FFXI "glass" depth.
local function draw_ffxi_backdrop()
    local wx, wy = imgui.GetWindowPos();
    local ww, wh = imgui.GetWindowSize();
    local _, cy  = imgui.GetCursorScreenPos();
    local dl  = imgui.GetWindowDrawList();
    local top = rgba_u32(18, 42, 92, 90);
    local bot = rgba_u32(0,  6, 22, 125);
    dl:AddRectFilledMultiColor(
        { wx + 2, cy - 4 },
        { wx + ww - 2, wy + wh - 2 },
        top, top, bot, bot
    );
end

local GOLD = { 1.0, 0.8, 0.2, 1.0 };
local CYAN = { 0.3, 1.0, 1.0, 1.0 };
local GREEN = { 0.3, 1.0, 0.3, 1.0 };
local RED   = { 1.0, 0.45, 0.4, 1.0 };
local GRAY  = { 0.6, 0.6, 0.6, 1.0 };

------------------------------------------------------------
-- Session browser: data loading
------------------------------------------------------------
local function parse_summary_file(path)
    local f = io.open(path, 'r');
    if (f == nil) then return nil; end
    local text = f:read('*a');
    f:close();

    local s = { };
    s.date     = text:match('"date_jst":%s*"(.-)"');
    if (s.date == nil) then return nil; end
    s.tries    = tonumber(text:match('"dig_tries":%s*(%-?%d+)')) or 0;
    s.items_n  = tonumber(text:match('"dig_items":%s*(%-?%d+)')) or 0;
    s.acc      = tonumber(text:match('"accuracy_pct":%s*(%-?[%d%.]+)')) or 0;
    s.skillups = tonumber(text:match('"skillups":%s*(%-?[%d%.]+)')) or 0;
    s.rentals  = tonumber(text:match('"rentals":%s*(%-?%d+)')) or 0;
    s.gil_paid = tonumber(text:match('"chocobo_gil_paid":%s*(%-?%d+)')) or 0;
    s.greens   = tonumber(text:match('"greens_cost_total":%s*(%-?%d+)')) or 0;
    s.worth    = tonumber(text:match('"item_value":%s*(%-?%d+)')) or 0;
    s.net      = tonumber(text:match('"net_gil":%s*(%-?%d+)')) or 0;
    s.items = T{ };
    local block = text:match('"items":%s*{(.-)}');
    if (block ~= nil) then
        for name, count in block:gmatch('"(.-)":%s*(%d+)') do
            s.items:append({ name = name, count = tonumber(count) });
        end
    end
    return s;
end

-- Past sessions from disk; the current JST day is always rendered live.
local function scan_past_sessions()
    local list = T{ };
    local dir = get_data_dir();
    if (dir == nil) then return list; end
    local today = hgather.settings.session.date_jst;
    local files = ashita.fs.get_dir(dir .. '\\', '.*.json', true);
    if (files == nil) then return list; end
    for _, fname in ipairs(files) do
        if (fname:match('%.json$')) then
            local s = parse_summary_file(dir .. '\\' .. fname);
            if (s ~= nil and s.date ~= today) then
                list:append(s);
            end
        end
    end
    table.sort(list, function (a, b) return a.date < b.date; end);
    return list;
end

local function live_summary()
    local sess = hgather.settings.session;
    if (sess.date_jst == '') then return nil; end
    local greens, worth, net, accuracy = session_totals();
    local items = T{ };
    for k, v in pairs(sess.rewards) do
        items:append({ name = k, count = v });
    end
    return {
        date = sess.date_jst, tries = sess.dig_tries, items_n = sess.dig_items,
        acc = accuracy, skillups = sess.skillups, rentals = sess.rentals,
        gil_paid = sess.gil_paid, greens = greens, worth = worth, net = net,
        items = items, live = true,
    };
end

-- Per-session timeline from the jsonl event stream (cached; today refreshes).
local function load_detail(date)
    local cached = hgather.browser.details[date];
    local is_today = (date == hgather.settings.session.date_jst);
    if (cached ~= nil and (not is_today or (os.clock() - cached.loaded_at) < 30)) then
        return cached;
    end

    local dir = get_data_dir();
    if (dir == nil) then return nil; end
    local f = io.open(dir .. '\\' .. date .. '.jsonl', 'r');
    if (f == nil) then return nil; end

    local d = { hours = { }, cum = T{ }, loaded_at = os.clock() };
    for i = 0, 23 do d.hours[i] = 0; end
    local run = 0;
    local green = hgather.settings.gysahl_subtract[1] and hgather.settings.gysahl_cost[1] or 0;

    for line in f:lines() do
        local ev = line:match('"e":%s*"(.-)"');
        local t = tonumber(line:match('"t":%s*(%d+)'));
        if (ev == 'clear') then
            for i = 0, 23 do d.hours[i] = 0; end
            d.cum = T{ };
            run = 0;
        elseif (ev == 'dig' and t ~= nil) then
            local hour = math.floor(((t + JST_OFFSET) % 86400) / 3600);
            d.hours[hour] = d.hours[hour] + 1;
            run = run - green;
            local item = line:match('"item":%s*"(.-)"');
            if (item ~= nil and hgather.pricing[item] ~= nil) then
                run = run + hgather.pricing[item];
            end
            d.cum:append(run);
        elseif (ev == 'rental') then
            run = run - (tonumber(line:match('"gil":%s*(%d+)')) or 0);
            d.cum:append(run);
        end
    end
    f:close();

    if (#d.cum > 200) then
        local ds = T{ };
        local stride = #d.cum / 200;
        for i = 1, 200 do ds:append(d.cum[math.floor(i * stride)]); end
        d.cum = ds;
    end

    hgather.browser.details[date] = d;
    return d;
end

------------------------------------------------------------
-- Session browser: chart drawing (window draw list; hoverable bars)
------------------------------------------------------------
local BAR_COL       = rgba_u32(72, 158, 255, 230);
local BAR_COL_HOT   = rgba_u32(150, 205, 255, 255);
local BAR_COL_NEG   = rgba_u32(255, 105, 95, 230);
local LINE_COL      = rgba_u32(77, 255, 255, 235);
local AXIS_COL      = rgba_u32(115, 133, 173, 140);

local function chart_width()
    local ww, _ = imgui.GetWindowSize();
    return math.max(120, ww - 28);
end

-- entries: array of { v = number, label = tooltip string }
local function draw_bars(entries, height)
    local n = #entries;
    if (n == 0) then
        imgui.TextColored(GRAY, '(no data)');
        return;
    end
    local w = chart_width();

    -- Keep bars readable: if too many entries, show the most recent ones.
    local max_bars = math.floor(w / 4);
    local first = 1;
    if (n > max_bars) then
        first = n - max_bars + 1;
        imgui.TextColored(GRAY, string.format('(last %d of %d)', max_bars, n));
    end
    local shown = n - first + 1;

    local vmax, vmin = 0, 0;
    for i = first, n do
        local v = entries[i].v;
        if (v > vmax) then vmax = v; end
        if (v < vmin) then vmin = v; end
    end
    local range = vmax - vmin;
    if (range <= 0) then
        -- All-zero data: keep the baseline at the bottom of the band
        -- instead of collapsing it onto the heading.
        vmax, vmin, range = 1, 0, 1;
    end

    local x0, y0 = imgui.GetCursorScreenPos();
    local dl = imgui.GetWindowDrawList();
    local hover_ok = imgui.IsWindowHovered();
    local mx, my = imgui.GetMousePos();
    local slot = w / shown;
    local bw = math.max(2, math.floor(slot) - 1);
    local zero_y = y0 + height * (vmax / range);

    dl:AddLine({ x0, zero_y }, { x0 + w, zero_y }, AXIS_COL, 1.0);

    for i = first, n do
        local e = entries[i];
        local x1 = x0 + (i - first) * slot;
        local y_top, y_bot;
        if (e.v >= 0) then
            y_top = y0 + height * ((vmax - e.v) / range);
            y_bot = zero_y;
            if (zero_y - y_top < 1 and e.v > 0) then y_top = zero_y - 1; end
        else
            y_top = zero_y;
            y_bot = y0 + height * ((vmax - e.v) / range);
        end
        local hot = hover_ok and (mx >= x1 and mx < x1 + bw and my >= y0 and my <= y0 + height);
        local col = (e.v < 0) and BAR_COL_NEG or (hot and BAR_COL_HOT or BAR_COL);
        dl:AddRectFilled({ x1, y_top }, { x1 + bw, y_bot }, col, 0.0, ImDrawCornerFlags_All);
        if (hot and e.label ~= nil) then
            imgui.SetTooltip(e.label);
        end
    end

    imgui.Dummy({ w, height });
    imgui.TextColored(GRAY, string.format('max %s%s', format_int(vmax),
        vmin < 0 and ('  min ' .. format_int(vmin)) or ''));
end

-- points: array of numbers, drawn as a connected line
local function draw_line_graph(points, height)
    local n = #points;
    if (n < 2) then
        imgui.TextColored(GRAY, '(not enough data)');
        return;
    end
    local w = chart_width();

    local vmax, vmin = points[1], points[1];
    for i = 2, n do
        if (points[i] > vmax) then vmax = points[i]; end
        if (points[i] < vmin) then vmin = points[i]; end
    end
    if (vmax < 0) then vmax = 0; end
    if (vmin > 0) then vmin = 0; end
    local range = vmax - vmin;
    if (range <= 0) then range = 1; end

    local x0, y0 = imgui.GetCursorScreenPos();
    local dl = imgui.GetWindowDrawList();
    local step = w / (n - 1);
    local zero_y = y0 + height * (vmax / range);
    dl:AddLine({ x0, zero_y }, { x0 + w, zero_y }, AXIS_COL, 1.0);

    local px, py = x0, y0 + height * ((vmax - points[1]) / range);
    for i = 2, n do
        local x = x0 + (i - 1) * step;
        local y = y0 + height * ((vmax - points[i]) / range);
        dl:AddLine({ px, py }, { x, y }, LINE_COL, 1.5);
        px, py = x, y;
    end

    imgui.Dummy({ w, height });
    imgui.TextColored(GRAY, string.format('peak %s   final %s', format_int(vmax), format_int(points[n])));
end

------------------------------------------------------------
-- Session browser: rendering
------------------------------------------------------------
local METRICS = {
    { label = 'Net',     get = function (s) return s.net; end,      fmt = function (v) return format_int(v) .. 'g'; end },
    { label = 'Value',   get = function (s) return s.worth; end,    fmt = function (v) return format_int(v) .. 'g'; end },
    { label = 'Digs',    get = function (s) return s.tries; end,    fmt = function (v) return format_int(v); end },
    { label = 'Items',   get = function (s) return s.items_n; end,  fmt = function (v) return format_int(v); end },
    { label = 'Acc%',    get = function (s) return s.acc; end,      fmt = function (v) return string.format('%.1f%%', v); end },
    { label = 'Choco g', get = function (s) return s.gil_paid; end, fmt = function (v) return format_int(v) .. 'g'; end },
};

local function render_session_detail(s)
    imgui.Columns(2, '##sess_detail_' .. s.date, false);
    imgui.Text('Digs / Items:'); imgui.NextColumn();
    imgui.Text(string.format('%d / %d', s.tries, s.items_n)); imgui.NextColumn();
    imgui.Text('Accuracy:'); imgui.NextColumn();
    imgui.TextColored(CYAN, string.format('%.1f%%', s.acc)); imgui.NextColumn();
    if (s.skillups > 0) then
        imgui.Text('Skillups:'); imgui.NextColumn();
        imgui.TextColored(GREEN, string.format('%.1f', s.skillups)); imgui.NextColumn();
    end
    imgui.Text('Chocobo gil:'); imgui.NextColumn();
    imgui.TextColored(RED, string.format('%sg (%d rental%s)', format_int(s.gil_paid), s.rentals, s.rentals == 1 and '' or 's')); imgui.NextColumn();
    imgui.Text('Greens cost:'); imgui.NextColumn();
    imgui.Text(format_int(s.greens) .. 'g'); imgui.NextColumn();
    imgui.Text('Item value:'); imgui.NextColumn();
    imgui.Text(format_int(s.worth) .. 'g'); imgui.NextColumn();
    imgui.Text('Net:'); imgui.NextColumn();
    imgui.TextColored(s.net >= 0 and GREEN or RED, format_int(s.net) .. 'g'); imgui.NextColumn();
    imgui.Columns(1);

    -- Items, most valuable first.
    if (#s.items > 0) then
        local sorted = T{ };
        for _, it in ipairs(s.items) do
            sorted:append({ name = it.name, count = it.count, value = (hgather.pricing[it.name] or 0) * it.count });
        end
        table.sort(sorted, function (a, b) return a.value > b.value; end);
        imgui.TextColored(GOLD, 'Items');
        imgui.Columns(3, '##sess_items_' .. s.date, true);
        imgui.SetColumnWidth(0, 170);
        imgui.SetColumnWidth(1, 50);
        for i = 1, math.min(#sorted, 12) do
            local it = sorted[i];
            imgui.Text(it.name);              imgui.NextColumn();
            imgui.Text(format_int(it.count)); imgui.NextColumn();
            imgui.Text(format_int(it.value)); imgui.NextColumn();
        end
        imgui.Columns(1);
        if (#sorted > 12) then
            imgui.TextColored(GRAY, string.format('  +%d more item types', #sorted - 12));
        end
    end

    -- Timeline graphs from the event stream.
    local d = load_detail(s.date);
    if (d ~= nil) then
        imgui.TextColored(GOLD, 'Digs by hour (JST)');
        local hours = T{ };
        for h = 0, 23 do
            hours:append({ v = d.hours[h], label = string.format('%02d:00 JST - %d digs', h, d.hours[h]) });
        end
        draw_bars(hours, 46);
        if (#d.cum >= 2) then
            imgui.TextColored(GOLD, 'Cumulative net gil');
            draw_line_graph(d.cum, 56);
        end
    else
        imgui.TextColored(GRAY, '(no event log on disk for this day)');
    end
end

local function render_sessions_browser()
    if (not hgather.browser.open[1]) then return; end

    imgui.SetNextWindowSize({ 430, 540 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowBgAlpha(hgather.settings.opacity[1]);
    local ffxi_c, ffxi_v = push_ffxi_theme();
    if (imgui.Begin('HGather Sessions', hgather.browser.open, ImGuiWindowFlags_NoFocusOnAppearing)) then
        draw_ffxi_backdrop();

        if (hgather.browser.sessions == nil) then
            hgather.browser.sessions = scan_past_sessions();
        end
        local all = T{ };
        for _, s in ipairs(hgather.browser.sessions) do all:append(s); end
        local live = live_summary();
        if (live ~= nil) then all:append(live); end

        if (imgui.SmallButton('Refresh')) then
            hgather.browser.sessions = nil;
            hgather.browser.details = T{ };
        end
        imgui.SameLine();
        imgui.TextColored(GRAY, string.format('%d archived + today', #hgather.browser.sessions));

        -- All-time totals.
        local tot = { tries = 0, items_n = 0, worth = 0, net = 0, gil_paid = 0, rentals = 0 };
        for _, s in ipairs(all) do
            tot.tries = tot.tries + s.tries;
            tot.items_n = tot.items_n + s.items_n;
            tot.worth = tot.worth + s.worth;
            tot.net = tot.net + s.net;
            tot.gil_paid = tot.gil_paid + s.gil_paid;
            tot.rentals = tot.rentals + s.rentals;
        end
        imgui.Separator();
        imgui.TextColored(GOLD, 'All-time');
        imgui.Columns(2, '##alltime', false);
        imgui.Text('Sessions:'); imgui.NextColumn();
        imgui.Text(string.format('%d', #all)); imgui.NextColumn();
        imgui.Text('Digs / Items:'); imgui.NextColumn();
        imgui.Text(string.format('%s / %s', format_int(tot.tries), format_int(tot.items_n))); imgui.NextColumn();
        imgui.Text('Item value:'); imgui.NextColumn();
        imgui.Text(format_int(tot.worth) .. 'g'); imgui.NextColumn();
        imgui.Text('Chocobo gil:'); imgui.NextColumn();
        imgui.TextColored(RED, string.format('%sg (%d rentals)', format_int(tot.gil_paid), tot.rentals)); imgui.NextColumn();
        imgui.Text('Net:'); imgui.NextColumn();
        imgui.TextColored(tot.net >= 0 and GREEN or RED, format_int(tot.net) .. 'g'); imgui.NextColumn();
        imgui.Columns(1);

        -- Metric chart over time.
        imgui.Separator();
        for i, m in ipairs(METRICS) do
            if (i > 1) then imgui.SameLine(); end
            local active = (hgather.browser.metric == i);
            if (active) then
                imgui.PushStyleColor(ImGuiCol_Button, { 0.18, 0.40, 0.72, 1.0 });
            end
            if (imgui.SmallButton(m.label)) then
                hgather.browser.metric = i;
            end
            if (active) then
                imgui.PopStyleColor(1);
            end
        end
        local metric = METRICS[hgather.browser.metric];
        local entries = T{ };
        for _, s in ipairs(all) do
            entries:append({
                v = metric.get(s),
                label = s.date .. (s.live and ' (today)' or '') .. ' - ' .. metric.fmt(metric.get(s)),
            });
        end
        draw_bars(entries, 80);

        -- Individual sessions, newest first.
        imgui.Separator();
        for i = #all, 1, -1 do
            local s = all[i];
            local title = string.format('%s   %d digs, net %sg%s###sess%s',
                s.date, s.tries, format_int(s.net), s.live and '  [today]' or '', s.date);
            if (imgui.CollapsingHeader(title)) then
                render_session_detail(s);
            end
        end
    end
    imgui.End();
    pop_ffxi_theme(ffxi_c, ffxi_v);
end

------------------------------------------------------------
-- Overlay window
------------------------------------------------------------
local function render_overlay()
    if (not hgather.settings.visible[1]) then return; end
    if (not AshitaCore:GetFontManager():GetVisible()) then return; end

    local sess = hgather.settings.session;
    local greens, worth, net, accuracy = session_totals();
    local elapsed = (sess.started_at > 0) and (os.time() - sess.started_at) or 0;

    -- gil/hr, refreshed at most once per 3 seconds
    if (elapsed > 0 and (os.time() % 3) == 0) then
        hgather.gil_per_hour = math.floor(net / elapsed * 3600);
    end

    imgui.SetNextWindowSize({ 330, 420 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowBgAlpha(hgather.settings.opacity[1]);

    local ffxi_c, ffxi_v = push_ffxi_theme();
    if (imgui.Begin('HGather - Chocobo Digging', hgather.settings.visible, ImGuiWindowFlags_NoFocusOnAppearing)) then
        draw_ffxi_backdrop();

        imgui.TextColored(GOLD, 'Session ' .. sess.date_jst .. ' (JST)');
        imgui.SameLine();
        imgui.TextColored(GRAY, ' reset in ' .. format_time(secs_to_jst_midnight()));

        imgui.Text('Time: ' .. (elapsed > 0 and format_time(elapsed) or 'Waiting...'));
        imgui.SameLine();
        if (imgui.SmallButton('Report')) then print_report(); end
        imgui.SameLine();
        if (imgui.SmallButton('Clear')) then clear_session(); end
        imgui.SameLine();
        if (imgui.SmallButton('Sessions')) then hgather.browser.open[1] = not hgather.browser.open[1]; end
        imgui.SameLine();
        if (imgui.SmallButton('Config')) then hgather.editor_open[1] = not hgather.editor_open[1]; end

        imgui.Separator();

        imgui.Columns(2, 'dig_stats', false);
        imgui.Text('Digs:'); imgui.NextColumn();
        imgui.Text(string.format('%d (%.1f/min)', sess.dig_tries, hgather.dig_per_minute)); imgui.NextColumn();
        imgui.Text('Items:'); imgui.NextColumn();
        imgui.Text(string.format('%d', sess.dig_items)); imgui.NextColumn();
        imgui.Text('Accuracy:'); imgui.NextColumn();
        imgui.TextColored(CYAN, string.format('%.1f%%', accuracy)); imgui.NextColumn();
        if (hgather.settings.skillup_display[1] and sess.skillups > 0) then
            imgui.Text('Skillups:'); imgui.NextColumn();
            imgui.TextColored(GREEN, string.format('%.1f', sess.skillups)); imgui.NextColumn();
        end
        if (hgather.settings.moon_display[1]) then
            local moon = get_moon();
            imgui.Text('Moon:'); imgui.NextColumn();
            imgui.Text(string.format('%s (%d%%)', moon.MoonPhase, moon.MoonPhasePercent)); imgui.NextColumn();
        end
        imgui.Columns(1);

        imgui.Separator();
        imgui.TextColored(GOLD, 'Costs');
        imgui.Columns(2, 'cost_stats', false);
        imgui.Text('Greens used:'); imgui.NextColumn();
        imgui.Text(string.format('%d (%sg)', sess.dig_tries, format_int(greens))); imgui.NextColumn();
        imgui.Text('Chocobo gil:'); imgui.NextColumn();
        imgui.TextColored(RED, string.format('%sg (%d rental%s)', format_int(sess.gil_paid), sess.rentals, sess.rentals == 1 and '' or 's')); imgui.NextColumn();
        imgui.Columns(1);
        if (hgather.pending_rental ~= nil) then
            imgui.TextColored(GRAY, string.format('  pending rental: %sg (counts on first dig)', format_int(hgather.pending_rental)));
        end

        imgui.Separator();
        imgui.TextColored(GOLD, 'Items');
        local sorted = T{ };
        for k, v in pairs(sess.rewards) do
            sorted:append({ name = k, count = v, value = (hgather.pricing[k] or 0) * v });
        end
        table.sort(sorted, function (a, b) return a.value > b.value; end);
        if (#sorted > 0) then
            imgui.Columns(3, 'item_cols', true);
            imgui.SetColumnWidth(0, 170);
            imgui.SetColumnWidth(1, 50);
            imgui.TextColored(GOLD, 'Name');  imgui.NextColumn();
            imgui.TextColored(GOLD, 'Qty');   imgui.NextColumn();
            imgui.TextColored(GOLD, 'Gil');   imgui.NextColumn();
            imgui.Separator();
            for _, it in ipairs(sorted) do
                imgui.Text(it.name);                    imgui.NextColumn();
                imgui.Text(format_int(it.count));       imgui.NextColumn();
                imgui.Text(format_int(it.value));       imgui.NextColumn();
            end
            imgui.Columns(1);
        else
            imgui.TextColored(GRAY, 'No items dug yet. Get digging!');
        end

        imgui.Separator();
        imgui.Columns(2, 'gil_stats', false);
        imgui.Text('Item value:'); imgui.NextColumn();
        imgui.Text(format_int(worth) .. 'g'); imgui.NextColumn();
        imgui.Text(hgather.settings.gysahl_subtract[1] and 'Net (all costs):' or 'Net (- rentals):'); imgui.NextColumn();
        imgui.TextColored(net >= 0 and GREEN or RED, format_int(net) .. 'g'); imgui.NextColumn();
        imgui.Text('Gil/hr:'); imgui.NextColumn();
        imgui.TextColored(CYAN, format_int(hgather.gil_per_hour)); imgui.NextColumn();
        imgui.Columns(1);
    end
    imgui.End();
    pop_ffxi_theme(ffxi_c, ffxi_v);
end

------------------------------------------------------------
-- Settings editor
------------------------------------------------------------
local function render_editor()
    if (not hgather.editor_open[1]) then return; end

    imgui.SetNextWindowSize({ 480, 560 }, ImGuiCond_FirstUseEver);
    local ffxi_c, ffxi_v = push_ffxi_theme();
    if (imgui.Begin('HGather Config', hgather.editor_open)) then
        draw_ffxi_backdrop();

        -- The tracker has its own close button, and it auto-hides on idle, so
        -- the config window needs a way back to it.
        if (imgui.Button(hgather.settings.visible[1] and 'Hide Tracker' or 'Show Tracker')) then
            hgather.settings.visible[1] = not hgather.settings.visible[1];
            hgather.last_attempt = ashita.time.clock()['ms'];  -- restart the idle timer
        end
        imgui.ShowHelp('Show or hide the tracker overlay. Same as /hgather show.');
        imgui.SameLine();
        if (imgui.Button('Sessions')) then
            hgather.browser.open[1] = not hgather.browser.open[1];
        end
        imgui.ShowHelp('Open the session browser with history and graphs.');

        imgui.Separator();

        if (imgui.Button('Save Settings')) then
            update_pricing();
            settings.save();
            print(chat.header(addon.name):append(chat.message('Settings saved.')));
        end
        imgui.SameLine();
        if (imgui.Button('Reload')) then
            settings.reload();
            update_pricing();
            print(chat.header(addon.name):append(chat.message('Settings reloaded.')));
        end
        imgui.SameLine();
        if (imgui.Button('Export Now')) then
            save_to_disk('manual_export');
            print(chat.header(addon.name):append(chat.message('Session exported to disk.')));
        end
        imgui.SameLine();
        if (imgui.Button('Clear Session')) then
            clear_session();
        end

        imgui.Separator();
        imgui.TextColored(GOLD, 'Display');
        imgui.SliderFloat('Opacity', hgather.settings.opacity, 0.125, 1.0, '%.3f');
        imgui.ShowHelp('The opacity of the HGather window.');
        imgui.InputInt('Hide Timeout', hgather.settings.display_timeout);
        imgui.ShowHelp('Seconds after the last dig before the overlay auto-hides. 0 = never hide.');
        imgui.Checkbox('Moon Display', hgather.settings.moon_display);
        imgui.ShowHelp('Toggles if moon phase / percent is shown.');
        imgui.Checkbox('Digging Skillups', hgather.settings.skillup_display);
        imgui.ShowHelp('Toggles if digging skillups are shown.');

        imgui.Separator();
        imgui.TextColored(GOLD, 'Gil');
        -- Both feed the cached per-day net-gil graphs, so changing either
        -- must drop the cache or archived sessions keep the old curve.
        if (imgui.InputInt('Gysahl Cost', hgather.settings.gysahl_cost)) then
            hgather.browser.details = T{ };
        end
        imgui.ShowHelp('Cost of a single gysahl green.');
        if (imgui.Checkbox('Subtract Greens From Net', hgather.settings.gysahl_subtract)) then
            hgather.browser.details = T{ };
        end
        imgui.ShowHelp('Chocobo rental gil is always subtracted; this additionally subtracts greens.');

        imgui.Separator();
        imgui.TextColored(GOLD, 'Price Snapshot');
        imgui.InputText('Snapshot URL', hgather.settings.price_url, 512);
        imgui.ShowHelp('Static JSON of item id -> gil. Public data; no account needed.');
        imgui.Checkbox('Auto-Refresh Each Session', hgather.settings.price_auto);
        imgui.ShowHelp('Refresh the snapshot on the first dig of each session.');
        if (imgui.Button('Fetch Prices Now')) then
            fetch_prices();
        end
        imgui.ShowHelp('Values are per unit: stackables at stack unit price, others at sales median.');

        imgui.Separator();
        imgui.TextColored(GOLD, 'Item Prices');
        local temp_strings = T{ };
        temp_strings[1] = table.concat(hgather.settings.item_index, '\n');
        if (imgui.InputTextMultiline('##item_prices', temp_strings, 16384, { -1, 240 })) then
            hgather.settings.item_index = split(temp_strings[1], '\n');
            table.sort(hgather.settings.item_index);
        end
        imgui.ShowHelp('One item per line, lowercase, name:price. No spaces around the colon.');
    end
    imgui.End();
    pop_ffxi_theme(ffxi_c, ffxi_v);
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
settings.register('settings', 'settings_update', function (s)
    if (s ~= nil) then
        hgather.settings = s;
    end
    hgather.data_dir = nil;  -- character may have changed
    hgather.browser.sessions = nil;
    hgather.browser.details = T{ };
    migrate_settings();
    seed_item_index();
    update_pricing();
    ensure_session();
    settings.save();
end);

ashita.events.register('load', 'load_cb', function ()
    migrate_settings();
    seed_item_index();
    update_pricing();
    ensure_session();
    print(chat.header(addon.name):append(chat.message('Loaded. Type /hgather help for commands.')));
end);

ashita.events.register('unload', 'unload_cb', function ()
    save_to_disk('unload');
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/hgather')) then
        return;
    end
    e.blocked = true;

    if (#args == 1 or (#args >= 2 and args[2]:any('edit'))) then
        hgather.editor_open[1] = not hgather.editor_open[1];
        return;
    end

    local cmd = args[2]:lower();

    if (cmd == 'save') then
        update_pricing();
        settings.save();
        print(chat.header(addon.name):append(chat.message('Settings saved.')));
    elseif (cmd == 'reload') then
        settings.reload();
        update_pricing();
        print(chat.header(addon.name):append(chat.message('Settings reloaded.')));
    elseif (cmd == 'report') then
        print_report();
    elseif (cmd == 'clear') then
        clear_session();
    elseif (cmd == 'show') then
        hgather.last_attempt = ashita.time.clock()['ms'];
        hgather.settings.visible[1] = true;
    elseif (cmd == 'hide') then
        hgather.settings.visible[1] = false;
    elseif (cmd == 'export') then
        save_to_disk('manual_export');
        print(chat.header(addon.name):append(chat.message('Session exported to disk.')));
    elseif (cmd == 'sessions') then
        hgather.browser.open[1] = not hgather.browser.open[1];
    elseif (cmd == 'prices') then
        fetch_prices();
    elseif (cmd == 'rental') then
        local amount = (#args >= 3) and tonumber(args[3]) or nil;
        if (amount ~= nil and amount > 0) then
            record_rental(math.floor(amount));
        else
            print(chat.header(addon.name):append(chat.error('Usage: /hgather rental <gil>')));
        end
    elseif (cmd == 'help') then
        print_help(false);
    else
        print_help(true);
    end
end);

-- Outgoing dig action: the truest "trying to dig" signal.
ashita.events.register('packet_out', 'packet_out_cb', function (e)
    if (e.id == 0x01A) then
        if (struct.unpack('H', e.data_modified, 0x0A) == 0x1104) then -- digging
            ensure_session();
            commit_pending_rental();

            -- Refresh the price snapshot once per session, on the first dig
            -- rather than at login: the HTTP call is synchronous and would
            -- otherwise stall the client while zoning in.
            if (hgather.settings.price_auto[1] and hgather.priced_for ~= hgather.settings.session.date_jst) then
                hgather.priced_for = hgather.settings.session.date_jst;
                pcall(fetch_prices);
            end

            local dig_diff = ashita.time.clock()['ms'] - hgather.last_attempt;
            hgather.last_attempt = ashita.time.clock()['ms'];
            if (dig_diff > 1000) then
                hgather.dig_timing[hgather.dig_index] = dig_diff;
                local timing_total = 0;
                for i = 1, #hgather.dig_timing do
                    timing_total = timing_total + hgather.dig_timing[i];
                end
                hgather.dig_per_minute = 60 / ((timing_total / 1000.0) / #hgather.dig_timing);
                if (hgather.dig_index >= #hgather.dig_timing) then
                    hgather.dig_index = 1;
                else
                    hgather.dig_index = hgather.dig_index + 1;
                end
            end
        end
    end
end);

-- Dig results come in as chat text.
ashita.events.register('text_in', 'text_in_cb', function (e)
    local last_attempt_secs = (ashita.time.clock()['ms'] - hgather.last_attempt) / 1000.0;
    local message = string.strip_colors(e.message):lower();

    local success  = message:match('obtained: (.-)%.');
    local unable   = message:contains('you dig and you dig');
    local skill_up = message:match('skill increases by (%d+%.?%d*) raising');

    -- Same 60s gate as dig results: without it, every combat and crafting
    -- skill-up would start a session and inflate its elapsed time.
    if (skill_up ~= nil and last_attempt_secs < 60) then
        ensure_session();
        local sess = hgather.settings.session;
        sess.skillups = sess.skillups + tonumber(skill_up);
        mark_event();
        append_event({ e = 'skillup', amount = tonumber(skill_up) });
    end

    -- Only trust results arriving within 60s of an actual dig packet;
    -- "obtained:" otherwise also fires for treasure pool lots etc.
    if ((success or unable) and last_attempt_secs < 60) then
        ensure_session();
        local sess = hgather.settings.session;
        sess.dig_tries = sess.dig_tries + 1;
        local moon = get_moon();
        local evt = {
            e = 'dig',
            zone = get_zone_id(),
            moon = moon.MoonPhasePercent,
            phase = moon.MoonPhase,
            vana_day = moon.VanaDay,
            weather = get_weather(),
        };
        if (success) then
            sess.dig_items = sess.dig_items + 1;
            local canon, item_id = normalize_item(success);
            if (sess.rewards[canon] == nil) then
                sess.rewards[canon] = 1;
            else
                sess.rewards[canon] = sess.rewards[canon] + 1;
            end
            evt.item = canon;
            evt.item_id = item_id;
        end
        mark_event();
        append_event(evt);

        if (not hgather.settings.visible[1]) then
            hgather.settings.visible[1] = true;
        end
    end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    poll_rental_state();

    -- JST rollover check + throttled dirty save (every ~15s).
    local now = os.clock();
    if (now - hgather.last_save > 15) then
        ensure_session();
        if (hgather.dirty) then
            save_to_disk('save');
        else
            hgather.last_save = now;
        end
    end

    -- Auto-hide after inactivity.
    if (hgather.settings.display_timeout[1] > 0 and hgather.last_attempt > 0) then
        local last_attempt_secs = (ashita.time.clock()['ms'] - hgather.last_attempt) / 1000.0;
        if (last_attempt_secs > hgather.settings.display_timeout[1] and hgather.settings.visible[1]) then
            hgather.settings.visible[1] = false;
        end
    end

    render_editor();
    render_overlay();
    render_sessions_browser();
end);
