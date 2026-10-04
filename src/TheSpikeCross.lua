--[[
  The Spike Cross - offline trainer for Cheat Engine (Lua)

  SCOPE
    In-match helpers for story mode, training and matches against the CPU:
      * stat lock for your player (multiplier or fixed values)
      * weaker CPU opponents (their stats scaled down)
      * holds: team stamina, perfect timing, skill gauge, match timer
      * score adjust and "jump to match point"
      * game speed (Cheat Engine speedhack)
      * presets for your stat / speed settings
    Every in-match value is put back when its feature turns off.

    Deliberately NOT included: gold / premium currency, recruiting, training
    or upgrade shortcuts, character / costume / skill unlocks, or anything
    written to the saved profile. Those touch paid items and carry over into
    online play.

  MODE GUARD
    Every feature is gated by a mode guard that you configure once (see
    docs/SETUP_GUIDE.md). If the guard is not configured, cannot be read, or
    reports a mode that is not in your offline list, all features switch off,
    values are restored, feature hooks are removed and game speed returns to
    1.0. It fails closed.

  HOW TO USE
    1. Fill in CONFIG below with the values you find (docs/SETUP_GUIDE.md).
    2. Open TheSpikeCross.CT in Cheat Engine (or paste this file into
       Table > Show Cheat Table Lua Script) and execute it.
    3. Start the game; the trainer attaches automatically.
]]

-- If an older copy of the trainer is still running (script re-executed),
-- shut it down first so its code hooks are restored and not stacked.
if _G.SpikeCrossTrainer and type(_G.SpikeCrossTrainer.shutdown) == "function" then
  pcall(_G.SpikeCrossTrainer.shutdown)
end

local Trainer = {}

--------------------------------------------------------------------------------
-- CONFIG -- everything you fill in lives here.
--
-- Sources describe where a single value lives:
--   { expr = "[[TheSpike-Cross.exe+1A2B3C0]+B8]+44" }
--       A Cheat Engine address expression (pointer chain).
--   { hook = "match", offset = 0x20 }
--       A field inside the object captured by a code hook. The hook must be
--       seeing exactly one object (e.g. the match object).
--   { group = "me", offset = 0x44 }
--       A field inside the single object of a group (see CONFIG.groups).
-- `nil` means "not configured yet"; the trainer shows it as such.
--------------------------------------------------------------------------------
local CONFIG = {
  -- Exact process name of the Steam build. nil = auto-detect by looking for
  -- a running process whose name contains `processMatch`.
  processName  = "TheSpike-Cross.exe",
  processMatch = "spike",

  -- How often (ms) values are re-applied and the guard re-checked.
  tickMs = 100,

  -- A captured object not seen for this long (ms) is treated as gone.
  -- Protects against writing into objects after the match ended.
  staleMs = 2000,

  -- Code hooks. Each one records every object pointer the hooked instruction
  -- works on (up to 16 at a time).
  --   module   : module to scan; the game is a native build, so this is the
  --              game's own exe
  --   aob      : unique byte pattern, wildcards as ??
  --   offset   : bytes from the start of the pattern to the hooked instruction
  --   length   : total bytes of the whole instructions being replaced (>= 5);
  --              they must not contain jumps, calls or RIP-relative operands
  --   register : register holding the object pointer (rcx, rbx, rsi, ...)
  --   filter   : optional { offset = 0x.., size = "dword"|"byte", equals = n }
  --              checked in the hook itself; usually `groups` is easier
  hooks = {
    players = { module = "TheSpike-Cross.exe", aob = nil, offset = 0, length = nil, register = nil, filter = nil },
    match   = { module = "TheSpike-Cross.exe", aob = nil, offset = 0, length = nil, register = nil, filter = nil },
  },

  -- Groups pick objects out of a hook by a field value, e.g. the
  -- human-controlled player, or the players of the opposing team.
  --   where : { offset = 0x.., type = "int32"|"byte", equals = n }
  groups = {
    me  = { hook = "players", where = nil },  -- exactly your player
    cpu = { hook = "players", where = nil },  -- the opposing team's players
  },

  -- Mode guard: a value that tells which game mode is running.
  --   allowed : values that mean story / training / vs CPU. Anything else
  --             (online, Nightmare Arena, Faction Battle, events with points
  --             or rankings, ...) blocks every feature.
  --   names   : optional labels shown in the UI, keyed by value.
  guard = {
    source  = nil,               -- e.g. { expr = "[[TheSpike-Cross.exe+1A2B3C0]+B8]+30" }
    type    = "int32",
    allowed = {},                -- e.g. { 1, 2 }
    names   = {},                -- e.g. { [1] = "Story", [2] = "Training" }
    -- sessionPid: set only when `source` is a plain address found this
    -- session; the guard then blocks after a game restart.
  },

  -- Player stats, as named on the in-game help screen. `offset` is the
  -- field inside a player object; it is used for your player (group "me")
  -- and for the CPU opponents (group "cpu").
  --   type      : "float", "double" or "int32"
  --   max       : optional cap for your target value
  --   source    : optional full source for your player instead of `offset`
  --   cpuOffset : optional, if CPU players keep the stat elsewhere
  stats = {
    { key = "attack",  label = "Attack",  offset = nil, type = "float" },
    { key = "defense", label = "Defense", offset = nil, type = "float" },
    { key = "speed",   label = "Speed",   offset = nil, type = "float" },
    { key = "jump",    label = "Jump",    offset = nil, type = "float" },
  },
  -- Multiplier for your stats when a stat's target box is left empty.
  statMultiplier = 1.5,

  -- Weaker CPU opponents: their stats are multiplied by this.
  cpu = { group = "cpu", multiplier = 0.6 },

  -- Holds keep values pinned while switched on. Each value has a mode:
  --   "max"      : hold at `max` (a source) or `maxValue` (a number)
  --   "fixed"    : hold at `value`
  --   "multiply" : hold at original * `factor`
  --   "freeze"   : hold at the value it had when the hold started
  -- restore = true puts the original values back when the hold turns off.
  holds = {
    { key = "stamina", label = "Team stamina at max", hotkey = "VK_F6", restore = false,
      values = {
        { label = "Team stamina", source = nil, type = "float", mode = "max", max = nil, maxValue = nil },
      } },
    { key = "timing", label = "Perfect timing", hotkey = "VK_NUMPAD1", restore = true,
      values = {
        { label = "Receive timing window", source = nil, type = "float", mode = "multiply", factor = 3 },
        { label = "Spike timing window",   source = nil, type = "float", mode = "multiply", factor = 3 },
      } },
    { key = "gauge", label = "Skill gauge full", hotkey = "VK_NUMPAD2", restore = false,
      values = {
        { label = "Skill gauge", source = nil, type = "float", mode = "max", max = nil, maxValue = nil },
      } },
    { key = "timer", label = "Freeze match timer", hotkey = "VK_NUMPAD4", restore = false,
      values = {
        { label = "Match timer", source = nil, type = "float", mode = "freeze" },
      } },
  },

  score = {
    mine   = nil,                -- source of your team's score
    theirs = nil,                -- source of the opponent's score
    type   = "int32",
    target = 25,                 -- points needed to win a set
    cap    = 50,                 -- deuce hard cap (from the in-game help)
  },

  speed = { min = 0.25, max = 5.0, step = 0.25, default = 2.0 },

  -- Presets file. nil = %APPDATA%\TheSpikeCrossTrainer_presets.lua
  presets = { file = nil },

  -- Hotkeys (Cheat Engine VK_ names; nil disables one). Holds carry their
  -- own `hotkey` above.
  hotkeys = {
    toggleStats    = "VK_F5",
    toggleSpeed    = "VK_F7",
    speedDown      = "VK_F8",
    speedUp        = "VK_F9",
    myScoreUp      = "VK_F10",
    theirScoreDown = "VK_F11",
    toggleCpu      = "VK_NUMPAD3",
    matchPoint     = "VK_NUMPAD5",
  },
}
Trainer.CONFIG = CONFIG

local VALID_REGISTERS = {
  rax = true, rbx = true, rcx = true, rdx = true, rsi = true, rdi = true, rbp = true,
  r8 = true, r9 = true, r10 = true, r11 = true, r12 = true, r13 = true, r14 = true, r15 = true,
}
-- Registers the hook code may borrow (saved and restored around use).
local SCRATCH = { "rax", "rdx", "r8", "r9", "r10", "r11" }
-- Pointer slots per hook.
local SLOTS = 16

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------
local lastLogged = {}
local function log(msg)
  print("[SpikeCross] " .. tostring(msg))
end
-- Logs a message only when it differs from the last one under `key`.
local function logOnce(key, msg)
  if lastLogged[key] ~= msg then
    lastLogged[key] = msg
    log(msg)
  end
end

local function now()
  return getTickCount()
end

--------------------------------------------------------------------------------
-- Runtime state
--------------------------------------------------------------------------------
local state = {
  pid            = nil,
  aliveCheck     = 0,
  guardOk        = false,
  guardReason    = "not attached",
  statsLocked    = false,
  cpuWeak        = false,
  speedOn        = false,
  holds          = {},           -- hold key -> true while on
  speed          = CONFIG.speed.default,
  appliedSpeed   = 1.0,
  statTargets    = {},           -- stat key -> number (nil = multiplier)
  statMultiplier = CONFIG.statMultiplier,
  cpuMultiplier  = CONFIG.cpu.multiplier,
  originals      = {},           -- stat key -> { addr, value } (your player)
  cpuOriginals   = {},           -- address -> original value (CPU players)
  holdOriginals  = {},           -- hold key -> { [i] = { addr, value } }
  status         = "",
}
Trainer._state = state

--------------------------------------------------------------------------------
-- Value IO
--------------------------------------------------------------------------------
local IO = {
  float  = { "readFloat",   "writeFloat"   },
  double = { "readDouble",  "writeDouble"  },
  int32  = { "readInteger", "writeInteger" },
}

local function readAt(addr, vtype)
  if vtype == "byte" then
    local t = readBytes(addr, 1, true)
    return t and t[1]
  end
  local io = IO[vtype]
  if not io then error("unknown value type " .. tostring(vtype)) end
  if vtype == "int32" then return _G[io[1]](addr, true) end
  return _G[io[1]](addr)
end

local function writeOnce(addr, vtype, v)
  if vtype == "byte" then return writeBytes(addr, { math.floor(v + 0.5) & 0xFF }) end
  local io = IO[vtype]
  if not io then error("unknown value type " .. tostring(vtype)) end
  if vtype == "int32" then v = math.floor(v + 0.5) end
  return _G[io[2]](addr, v)
end

-- Constants such as timing windows live in the exe's read-only data; if a
-- write is refused, make those few bytes writable and try once more.
local function writeAt(addr, vtype, v)
  local ok = writeOnce(addr, vtype, v)
  if ok == false and fullAccess then
    fullAccess(addr, 8)
    ok = writeOnce(addr, vtype, v)
  end
  return ok
end

--------------------------------------------------------------------------------
-- Code hooks
--------------------------------------------------------------------------------
local Hooks = {}
Hooks.live = {}                  -- name -> { inj, orig, mem, tbl, idx, enabled, seen }
Hooks.failed = {}                -- name -> error message (not retried until reset)

-- Absolute address for Auto Assembler, zero-padded so it always starts with
-- a digit and can never be read as a label name.
local function aaAddr(n)
  return string.format("%016X", n)
end

local function hexBytes(bytes)
  local parts = {}
  for i = 1, #bytes do parts[i] = string.format("%02X", bytes[i]) end
  return table.concat(parts, " ")
end

function Hooks.isConfigured(name)
  local h = CONFIG.hooks[name]
  return type(h) == "table" and type(h.aob) == "string" and h.aob ~= ""
    and type(h.length) == "number" and type(h.register) == "string"
end

-- Returns the single address of `aob` inside `module` (or anywhere executable
-- when module is nil). Fails if the pattern matches zero or several times.
function Hooks.findUnique(module, aob)
  local lo, hi
  if module then
    lo = getAddressSafe(module)
    if not lo or lo == 0 then return nil, "module " .. module .. " not loaded" end
    hi = lo + (getModuleSize(module) or 0)
  end
  local list = AOBScan(aob, "+X")
  if not list then return nil, "pattern not found" end
  local hits = {}
  for i = 0, list.Count - 1 do
    local a = tonumber(list[i], 16)
    if a and (not lo or (a >= lo and a < hi)) then hits[#hits + 1] = a end
  end
  list.destroy()
  if #hits == 0 then return nil, "pattern not found" .. (module and (" in " .. module) or "") end
  if #hits > 1 then return nil, "pattern matches " .. #hits .. " places; make it longer" end
  return hits[1]
end

-- Two scratch registers that differ from the captured register.
function Hooks.scratch(reg)
  local out = {}
  for _, r in ipairs(SCRATCH) do
    if r ~= reg then out[#out + 1] = r end
    if #out == 2 then break end
  end
  return out[1], out[2]
end

-- Builds the Auto Assembler script that installs hook `name`. The injected
-- code adds the object pointer to a table of SLOTS entries unless it is
-- already there, then runs the replaced instructions and jumps back.
function Hooks.buildEnableScript(name, h, inj, mem, tbl, idx, orig)
  local s1, s2 = Hooks.scratch(h.register)
  local loop, done = "spk_loop_" .. name, "spk_done_" .. name
  local L = {
    "label(" .. loop .. ")",
    "label(" .. done .. ")",
    aaAddr(mem) .. ":",
    "  pushfq",
    "  push " .. s1,
    "  push " .. s2,
  }
  if h.filter then
    L[#L + 1] = string.format("  cmp %s ptr [%s+%X],#%d", h.filter.size or "dword", h.register, h.filter.offset, h.filter.equals)
    L[#L + 1] = "  jne " .. done
  end
  local more = {
    string.format("  lea %s,[%s]", s1, aaAddr(tbl)),
    string.format("  xor %s,%s", s2, s2),
    loop .. ":",
    string.format("  cmp [%s+%s*8],%s", s1, s2, h.register),
    "  je " .. done,
    "  inc " .. s2,
    string.format("  cmp %s,#%d", s2, SLOTS),
    "  jb " .. loop,
    string.format("  mov %s,[%s]", s2, aaAddr(idx)),
    string.format("  mov [%s+%s*8],%s", s1, s2, h.register),
    "  inc " .. s2,
    string.format("  and %s,#%d", s2, SLOTS - 1),
    string.format("  mov [%s],%s", aaAddr(idx), s2),
    done .. ":",
    "  pop " .. s2,
    "  pop " .. s1,
    "  popfq",
    "  db " .. hexBytes(orig),
    "  jmp " .. aaAddr(inj + #orig),
    aaAddr(inj) .. ":",
    "  jmp " .. aaAddr(mem),
  }
  for _, line in ipairs(more) do L[#L + 1] = line end
  if #orig > 5 then
    local nops = {}
    for i = 1, #orig - 5 do nops[i] = "90" end
    L[#L + 1] = "  db " .. table.concat(nops, " ")
  end
  return table.concat(L, "\n")
end

-- Name of the hook the mode guard reads through, if any.
function Hooks.guardHook()
  local src = CONFIG.guard.source
  if type(src) ~= "table" then return nil end
  if src.hook then return src.hook end
  if src.group then
    local g = CONFIG.groups[src.group]
    return type(g) == "table" and g.hook or nil
  end
  return nil
end

-- Feature hooks only go into the game while an offline mode is confirmed.
-- The guard's own hook is the one exception: it is needed to find out.
function Hooks.mayEnable(name)
  return state.guardOk or name == Hooks.guardHook()
end

local function clearSlots(live)
  for i = 0, SLOTS - 1 do writePointer(live.tbl + i * 8, 0) end
  writePointer(live.idx, 0)
end

function Hooks.enable(name)
  local live = Hooks.live[name]
  if live and live.enabled then return true end
  if Hooks.failed[name] then return false, Hooks.failed[name] end
  if not Hooks.isConfigured(name) then return false, "hook '" .. name .. "' not configured" end
  if not Hooks.mayEnable(name) then return false, "waiting for an offline mode" end

  local function fail(why)
    Hooks.failed[name] = why
    log("hook '" .. name .. "' not installed: " .. why)
    return false, why
  end

  local h = CONFIG.hooks[name]
  if not VALID_REGISTERS[h.register] then return fail("register must be a 64-bit register like rcx") end
  if h.length < 5 or h.length > 32 then return fail("length must be between 5 and 32 bytes") end
  if h.filter and (type(h.filter.offset) ~= "number" or type(h.filter.equals) ~= "number") then
    return fail("filter needs numeric offset and equals")
  end

  local base, why = Hooks.findUnique(h.module, h.aob)
  if not base then return fail(why) end
  local inj = base + (h.offset or 0)

  local orig = readBytes(inj, h.length, true)
  if not orig or #orig ~= h.length then return fail("cannot read code bytes") end
  if orig[1] == 0xE9 then return fail("code is already hooked (another table or script?)") end

  if not live then
    -- Allocated once per attach and reused; freeing hook memory while a game
    -- thread may still be inside it would crash the game.
    local mem = allocateMemory(0x200, inj)
    if not mem or mem == 0 then return fail("cannot allocate memory near the hook") end
    if math.abs(mem - (inj + 5)) >= 0x7FFFFFFF then
      return fail("allocated memory too far away for a 5-byte jump")
    end
    live = { mem = mem, tbl = mem + 0x100, idx = mem + 0x100 + SLOTS * 8 }
    Hooks.live[name] = live
  end
  live.inj, live.orig, live.seen = inj, orig, {}
  clearSlots(live)

  local ok, err = autoAssemble(Hooks.buildEnableScript(name, h, inj, live.mem, live.tbl, live.idx, orig))
  if not ok then return fail("auto assembler error: " .. tostring(err)) end
  live.enabled = true
  log("hook '" .. name .. "' installed at " .. string.format("%X", inj))
  return true
end

function Hooks.disable(name)
  local live = Hooks.live[name]
  if not live or not live.enabled then return end
  local ok, err = autoAssemble(aaAddr(live.inj) .. ":\n  db " .. hexBytes(live.orig))
  if not ok then log("hook '" .. name .. "' restore failed: " .. tostring(err)) end
  live.enabled = false
  live.seen = {}
end

function Hooks.disableAll()
  for name in pairs(Hooks.live) do Hooks.disable(name) end
end

-- Removes every hook except the guard's, restoring the original game code.
function Hooks.disableFeatureHooks()
  local keep = Hooks.guardHook()
  for name in pairs(Hooks.live) do
    if name ~= keep then Hooks.disable(name) end
  end
end

-- Collects the pointers each enabled hook captured since the last poll and
-- clears its table, so an object only counts while the game keeps running
-- the hooked instruction on it.
function Hooks.poll()
  local t = now()
  for _, live in pairs(Hooks.live) do
    if live.enabled then
      for i = 0, SLOTS - 1 do
        local a = live.tbl + i * 8
        local p = readPointer(a)
        if p and p ~= 0 then
          live.seen[p] = t
          writePointer(a, 0)
        end
      end
      for p, seenAt in pairs(live.seen) do
        if t - seenAt > CONFIG.staleMs then live.seen[p] = nil end
      end
    end
  end
end

-- The objects hook `name` is currently seeing, sorted, or nil + reason.
function Hooks.objects(name)
  local ok, why = Hooks.enable(name)
  if not ok then return nil, why end
  local live, t, out = Hooks.live[name], now(), {}
  for p, seenAt in pairs(live.seen) do
    if t - seenAt <= CONFIG.staleMs then out[#out + 1] = p end
  end
  if #out == 0 then return nil, "waiting for hook '" .. name .. "' (enter a match)" end
  table.sort(out)
  return out
end

function Hooks.reset()
  Hooks.live = {}
  Hooks.failed = {}
end

Trainer.Hooks = Hooks

--------------------------------------------------------------------------------
-- Groups
--------------------------------------------------------------------------------
local Groups = {}

function Groups.isConfigured(name)
  local g = CONFIG.groups[name]
  return type(g) == "table" and Hooks.isConfigured(g.hook)
end

-- Objects of group `name`, or nil + reason.
function Groups.objects(name)
  if not Groups.isConfigured(name) then return nil, "group '" .. tostring(name) .. "' not configured" end
  local g = CONFIG.groups[name]
  local objs, why = Hooks.objects(g.hook)
  if not objs then return nil, why end
  if not g.where then return objs end
  local out = {}
  for _, p in ipairs(objs) do
    if readAt(p + g.where.offset, g.where.type or "int32") == g.where.equals then out[#out + 1] = p end
  end
  if #out == 0 then return nil, "no object in group '" .. name .. "' yet" end
  return out
end

Trainer.Groups = Groups

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------
local Values = {}
Values.readAt, Values.writeAt = readAt, writeAt

function Values.isConfigured(src)
  if type(src) ~= "table" then return false end
  if type(src.expr) == "string" and src.expr ~= "" then return true end
  if type(src.offset) ~= "number" then return false end
  if src.hook then return Hooks.isConfigured(src.hook) end
  if src.group then return Groups.isConfigured(src.group) end
  return false
end

-- The one object a hook/group source refers to. More than one is refused:
-- writing to the wrong object is worse than writing nothing.
local function singleObject(src)
  local objs, why, what
  if src.hook then
    objs, why = Hooks.objects(src.hook)
    what = "hook '" .. src.hook .. "'"
  else
    objs, why = Groups.objects(src.group)
    what = "group '" .. src.group .. "'"
  end
  if not objs then return nil, why end
  if #objs > 1 then return nil, #objs .. " objects in " .. what .. "; add a filter" end
  return objs[1]
end

function Values.address(src)
  if not Values.isConfigured(src) then return nil, "not configured" end
  if src.expr and src.expr ~= "" then
    local a = getAddressSafe(src.expr)
    if not a or a == 0 then return nil, "address expression did not resolve" end
    return a
  end
  local base, why = singleObject(src)
  if not base then return nil, why end
  return base + src.offset
end

function Values.read(src, vtype)
  local a, why = Values.address(src)
  if not a then return nil, why end
  local v = readAt(a, vtype)
  if v == nil then return nil, "address not readable" end
  return v, a
end

Trainer.Values = Values

--------------------------------------------------------------------------------
-- Mode guard (fails closed)
--------------------------------------------------------------------------------
local Guard = {}

function Guard.check()
  local g = CONFIG.guard
  if not Values.isConfigured(g.source) or type(g.allowed) ~= "table" or #g.allowed == 0 then
    return false, "Mode guard not configured (docs/SETUP_GUIDE.md, step 2)"
  end
  -- A guard pointing at a plain heap address (set while testing) is only
  -- valid in the game process it was found in; `sessionPid` ties it there.
  if g.sessionPid and g.sessionPid ~= state.pid then
    return false, "Mode guard expired: the game restarted (guide step 1c)"
  end
  local v, why = Values.read(g.source, g.type or "int32")
  if v == nil then return false, "Mode guard: " .. tostring(why) end
  for _, allowed in ipairs(g.allowed) do
    if v == allowed then
      return true, "Offline mode: " .. tostring((g.names or {})[v] or v)
    end
  end
  return false, "Blocked: mode " .. tostring((g.names or {})[v] or v) .. " is not in the offline list"
end

Trainer.Guard = Guard

--------------------------------------------------------------------------------
-- Features
--------------------------------------------------------------------------------
local Features = {}

local function holdByKey(key)
  for _, h in ipairs(CONFIG.holds) do
    if h.key == key then return h end
  end
  return nil
end

-- Where your value of `stat` lives.
function Features.statSource(stat)
  if stat.source then return stat.source end
  if type(stat.offset) == "number" then return { group = "me", offset = stat.offset } end
  return nil
end

-- Target value for one of your stats given its original value.
function Features.statTarget(stat, original)
  local t = state.statTargets[stat.key]
  if t == nil then t = original * state.statMultiplier end
  if stat.max and t > stat.max then t = stat.max end
  return t
end

function Features.applyStats()
  for _, stat in ipairs(CONFIG.stats) do
    local addr = Values.address(Features.statSource(stat))
    if addr then
      local rec = state.originals[stat.key]
      if not rec or rec.addr ~= addr then
        -- First time we see this object: remember the real value.
        local v = readAt(addr, stat.type)
        rec = v ~= nil and { addr = addr, value = v } or nil
        state.originals[stat.key] = rec
      end
      if rec then writeAt(addr, stat.type, Features.statTarget(stat, rec.value)) end
    end
  end
end

-- Puts original stat values back, but only into objects that are still the
-- live, freshly captured ones. Anything else may already be freed.
function Features.restoreStats()
  for _, stat in ipairs(CONFIG.stats) do
    local rec = state.originals[stat.key]
    if rec then
      local addr = Values.address(Features.statSource(stat))
      if addr and addr == rec.addr then writeAt(addr, stat.type, rec.value) end
    end
  end
  state.originals = {}
end

-- CPU objects to touch: the cpu group minus your own player, so a loose
-- group filter can never weaken you.
local function cpuObjects()
  local objs = Groups.objects(CONFIG.cpu.group)
  if not objs then return {} end
  local mine = {}
  for _, p in ipairs(Groups.objects("me") or {}) do mine[p] = true end
  local out = {}
  for _, p in ipairs(objs) do
    if not mine[p] then out[#out + 1] = p end
  end
  return out
end

local function cpuStatOffset(stat)
  local off = stat.cpuOffset or stat.offset
  return type(off) == "number" and off or nil
end

function Features.applyCpu()
  local keep = {}
  for _, p in ipairs(cpuObjects()) do
    for _, stat in ipairs(CONFIG.stats) do
      local off = cpuStatOffset(stat)
      if off then
        local a = p + off
        local orig = state.cpuOriginals[a]
        if orig == nil then
          orig = readAt(a, stat.type)
          state.cpuOriginals[a] = orig
        end
        if orig ~= nil then
          keep[a] = true
          writeAt(a, stat.type, orig * state.cpuMultiplier)
        end
      end
    end
  end
  -- Forget objects that are gone so the record cannot grow across matches.
  for a in pairs(state.cpuOriginals) do
    if not keep[a] then state.cpuOriginals[a] = nil end
  end
end

function Features.restoreCpu()
  for _, p in ipairs(cpuObjects()) do
    for _, stat in ipairs(CONFIG.stats) do
      local off = cpuStatOffset(stat)
      local orig = off and state.cpuOriginals[p + off]
      if orig ~= nil then writeAt(p + off, stat.type, orig) end
    end
  end
  state.cpuOriginals = {}
end

function Features.holdTarget(v, original)
  if v.mode == "fixed" then return v.value end
  if v.mode == "multiply" then return original * (v.factor or 1) end
  if v.mode == "freeze" then return original end
  if v.mode == "max" then
    if Values.isConfigured(v.max) then return (Values.read(v.max, v.type)) end
    return v.maxValue
  end
  return nil
end

function Features.applyHold(hold)
  local recs = state.holdOriginals[hold.key] or {}
  state.holdOriginals[hold.key] = recs
  for i, v in ipairs(hold.values) do
    local addr = Values.address(v.source)
    if addr then
      local rec = recs[i]
      if not rec or rec.addr ~= addr then
        local cur = readAt(addr, v.type)
        rec = cur ~= nil and { addr = addr, value = cur } or nil
        recs[i] = rec
      end
      if rec then
        local target = Features.holdTarget(v, rec.value)
        if type(target) == "number" then writeAt(addr, v.type, target) end
      end
    end
  end
end

function Features.releaseHold(hold)
  local recs = state.holdOriginals[hold.key]
  if recs and hold.restore then
    for i, v in ipairs(hold.values) do
      local rec = recs[i]
      if rec then
        local addr = Values.address(v.source)
        if addr and addr == rec.addr then writeAt(addr, v.type, rec.value) end
      end
    end
  end
  state.holdOriginals[hold.key] = nil
end

function Features.applySpeed(target)
  if target ~= state.appliedSpeed then
    speedhack_setSpeed(target)
    state.appliedSpeed = target
  end
end

-- Adds `delta` to a score, never going below zero. Returns the new score or
-- nil + reason.
function Features.adjustScore(which, delta)
  if not state.guardOk then return nil, state.guardReason end
  local v, addrOrWhy = Values.read(CONFIG.score[which], CONFIG.score.type)
  if v == nil then return nil, addrOrWhy end
  local nv = math.max(0, v + delta)
  writeAt(addrOrWhy, CONFIG.score.type, nv)
  return nv
end

-- Raises your score to one point short of winning the set, respecting the
-- win-by-two rule and the deuce cap. Never lowers your score.
function Features.matchPoint()
  if not state.guardOk then return nil, state.guardReason end
  local sc = CONFIG.score
  local mine, mineAddr = Values.read(sc.mine, sc.type)
  if mine == nil then return nil, mineAddr end
  local theirs, why = Values.read(sc.theirs, sc.type)
  if theirs == nil then return nil, why end
  local target = math.min(sc.cap - 1, math.max(sc.target - 1, theirs + 1))
  if mine >= target then return mine end
  writeAt(mineAddr, sc.type, target)
  return target
end

function Features.anyActive()
  if state.statsLocked or state.cpuWeak or state.speedOn then return true end
  return next(state.holds) ~= nil
end

function Features.disableAll(reason)
  if state.statsLocked then Features.restoreStats() end
  if state.cpuWeak then Features.restoreCpu() end
  for key in pairs(state.holds) do
    local hold = holdByKey(key)
    if hold then Features.releaseHold(hold) end
  end
  state.statsLocked, state.cpuWeak, state.speedOn, state.holds = false, false, false, {}
  Features.applySpeed(1.0)
  if reason then log("features off: " .. reason) end
end

-- Turns a feature on or off on request (UI or hotkey): "stats", "cpu",
-- "speed" or a hold key. Turning on is refused while the guard blocks.
function Features.set(name, on)
  if on and not state.guardOk then
    state.status = "Refused: " .. state.guardReason
    log(state.status)
    return false
  end
  if name == "stats" then
    if not on and state.statsLocked then Features.restoreStats() end
    state.statsLocked = on
  elseif name == "cpu" then
    if not on and state.cpuWeak then Features.restoreCpu() end
    state.cpuWeak = on
  elseif name == "speed" then
    state.speedOn = on
    if not on then Features.applySpeed(1.0) end
  else
    local hold = holdByKey(name)
    if not hold then error("unknown feature " .. tostring(name)) end
    if not on and state.holds[name] then Features.releaseHold(hold) end
    state.holds[name] = on or nil
  end
  state.status = name .. (on and " on" or " off")
  return true
end

function Features.isOn(name)
  if name == "stats" then return state.statsLocked end
  if name == "cpu" then return state.cpuWeak end
  if name == "speed" then return state.speedOn end
  return state.holds[name] == true
end

function Features.toggle(name)
  return Features.set(name, not Features.isOn(name))
end

function Features.setSpeed(v)
  local c = CONFIG.speed
  v = math.max(c.min, math.min(c.max, v))
  state.speed = v
  return v
end

Trainer.Features = Features

--------------------------------------------------------------------------------
-- Presets: your stat targets, multipliers and speed, saved to a file.
--------------------------------------------------------------------------------
local Presets = {}

function Presets.path()
  if CONFIG.presets.file then return CONFIG.presets.file end
  return (os.getenv("APPDATA") or ".") .. "\\TheSpikeCrossTrainer_presets.lua"
end

local function serialize(v, indent)
  indent = indent or ""
  if type(v) == "number" then
    return math.type(v) == "integer" and tostring(v) or string.format("%.17g", v)
  elseif type(v) == "string" then
    return string.format("%q", v)
  elseif type(v) == "boolean" then
    return tostring(v)
  elseif type(v) == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local inner, parts = indent .. "  ", {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = inner .. "[" .. serialize(k) .. "] = " .. serialize(v[k], inner) .. ","
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
  end
  error("cannot save a " .. type(v))
end

-- All saved presets (name -> preset). A missing or broken file reads as none.
function Presets.readAll()
  local f = io.open(Presets.path(), "r")
  if not f then return {} end
  local text = f:read("a")
  f:close()
  local chunk = load("return " .. text, "=presets", "t", {})
  local ok, data = pcall(chunk or error)
  if not ok or type(data) ~= "table" then
    log("presets file unreadable; ignoring it")
    return {}
  end
  return data
end

function Presets.writeAll(all)
  local f, err = io.open(Presets.path(), "w")
  if not f then return false, err end
  f:write(serialize(all), "\n")
  f:close()
  return true
end

function Presets.names()
  local names = {}
  for name in pairs(Presets.readAll()) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function Presets.save(name)
  if type(name) ~= "string" or name == "" then return false, "give the preset a name" end
  local all = Presets.readAll()
  local targets = {}
  for k, v in pairs(state.statTargets) do targets[k] = v end
  all[name] = {
    statTargets    = targets,
    statMultiplier = state.statMultiplier,
    cpuMultiplier  = state.cpuMultiplier,
    speed          = state.speed,
  }
  return Presets.writeAll(all)
end

function Presets.load(name)
  local p = Presets.readAll()[name]
  if type(p) ~= "table" then return false, "no preset named " .. tostring(name) end
  local known = {}
  for _, stat in ipairs(CONFIG.stats) do known[stat.key] = true end
  state.statTargets = {}
  if type(p.statTargets) == "table" then
    for k, v in pairs(p.statTargets) do
      if known[k] and type(v) == "number" then state.statTargets[k] = v end
    end
  end
  if type(p.statMultiplier) == "number" then state.statMultiplier = p.statMultiplier end
  if type(p.cpuMultiplier) == "number" then state.cpuMultiplier = p.cpuMultiplier end
  if type(p.speed) == "number" then Features.setSpeed(p.speed) end
  return true
end

function Presets.delete(name)
  local all = Presets.readAll()
  if all[name] == nil then return false, "no preset named " .. tostring(name) end
  all[name] = nil
  return Presets.writeAll(all)
end

Trainer.Presets = Presets

--------------------------------------------------------------------------------
-- Process attach
--------------------------------------------------------------------------------
local Proc = {}

local function processListHas(pid)
  local list = getProcesslist()
  return type(list) == "table" and list[pid] ~= nil
end

local function findGameProcess()
  local list = getProcesslist()
  if type(list) ~= "table" then return nil end
  for pid, pname in pairs(list) do
    local n = tostring(pname):lower()
    if CONFIG.processName then
      if n == CONFIG.processName:lower() then return pid, pname end
    elseif n:find(CONFIG.processMatch:lower(), 1, true) then
      return pid, pname
    end
  end
  return nil
end

function Proc.onDetach()
  if state.pid then log("game process gone; trainer detached") end
  state.pid = nil
  -- The game's memory (and our hooks with it) is gone; drop the records.
  Hooks.reset()
  state.originals, state.cpuOriginals, state.holdOriginals = {}, {}, {}
  state.statsLocked, state.cpuWeak, state.speedOn, state.holds = false, false, false, {}
  state.appliedSpeed = 1.0
  state.guardOk, state.guardReason = false, "not attached"
end

-- Returns true while attached to the game, attaching when it appears.
function Proc.ensureAttached()
  local t = now()
  if state.pid then
    if getOpenedProcessID() ~= state.pid then
      Proc.onDetach()
    elseif t - state.aliveCheck > 2000 then
      state.aliveCheck = t
      if not processListHas(state.pid) then Proc.onDetach() end
    end
    if state.pid then return true end
  end
  local pid, pname = findGameProcess()
  if not pid then
    state.guardReason = "Waiting for the game to start"
    return false
  end
  openProcess(pid)
  if getOpenedProcessID() ~= pid then
    state.guardReason = "Could not open the game process"
    return false
  end
  if reinitializeSymbolhandler then reinitializeSymbolhandler(true) end
  state.pid, state.aliveCheck = pid, t
  log("attached to " .. tostring(pname) .. " (pid " .. tostring(pid) .. ")")
  return true
end

Trainer.Proc = Proc

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------
local UI = {}

function Trainer.tick()
  if not Proc.ensureAttached() then
    UI.refresh()
    return
  end
  Hooks.poll()
  local ok, why = Guard.check()
  state.guardOk, state.guardReason = ok, why
  if not ok then
    if Features.anyActive() then Features.disableAll(why) end
    Features.applySpeed(1.0)
    Hooks.disableFeatureHooks()
    UI.refresh()
    return
  end
  if state.statsLocked then Features.applyStats() end
  if state.cpuWeak then Features.applyCpu() end
  for _, hold in ipairs(CONFIG.holds) do
    if state.holds[hold.key] then Features.applyHold(hold) end
  end
  Features.applySpeed(state.speedOn and state.speed or 1.0)
  UI.refresh()
end

local tickErrors = 0
local function safeTick()
  local ok, err = pcall(Trainer.tick)
  if ok then
    tickErrors = 0
    return
  end
  tickErrors = tickErrors + 1
  logOnce("tick", "error: " .. tostring(err))
  if tickErrors >= 10 then
    pcall(Features.disableAll, "repeated errors")
    tickErrors = 0
  end
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
UI.form = nil
UI.updating = false
UI.statRows = {}
UI.holdRows = {}

-- "VK_NUMPAD1" -> "Num1", "VK_F5" -> "F5"
local function keyLabel(name)
  if not name then return "" end
  local k = name:gsub("^VK_", ""):gsub("^NUMPAD", "Num")
  return "[" .. k .. "]"
end

local function fmt(v, vtype)
  if vtype == "int32" or vtype == "byte" then return tostring(v) end
  return string.format("%.2f", v)
end

local function describe(src, vtype)
  if not Values.isConfigured(src) then return "not configured" end
  local v, why = Values.read(src, vtype)
  if v == nil then return why end
  return fmt(v, vtype)
end

local function countText(group)
  if not Groups.isConfigured(group) then return "not configured" end
  local objs, why = Groups.objects(group)
  if not objs then return why end
  return #objs .. " seen"
end

function UI.refresh()
  local f = UI.form
  if not f then return end
  UI.updating = true
  UI.procLabel.Caption = state.pid and ("Attached: pid " .. state.pid) or "Not attached"
  UI.guardLabel.Caption = state.guardReason or ""
  -- Colours are 0xBBGGRR; bright enough for both light and dark themes.
  UI.guardLabel.Font.Color = state.guardOk and 0x30B030 or 0x4040FF
  UI.statsBox.Checked = state.statsLocked
  UI.cpuBox.Checked = state.cpuWeak
  UI.speedBox.Checked = state.speedOn
  UI.speedLabel.Caption = string.format("Speed: %.2fx", state.speed)
  for _, row in ipairs(UI.holdRows) do row.box.Checked = state.holds[row.hold.key] == true end
  if state.pid then
    for _, row in ipairs(UI.statRows) do
      row.value.Caption = describe(Features.statSource(row.stat), row.stat.type)
    end
    UI.cpuValue.Caption = countText(CONFIG.cpu.group)
    for _, row in ipairs(UI.holdRows) do
      local v = row.hold.values[1]
      row.value.Caption = v and describe(v.source, v.type) or ""
    end
    local mine = describe(CONFIG.score.mine, CONFIG.score.type)
    local theirs = describe(CONFIG.score.theirs, CONFIG.score.type)
    UI.scoreValue.Caption = (mine == theirs and not tonumber(mine)) and mine or (mine .. "  :  " .. theirs)
  end
  UI.statusLabel.Caption = state.status or ""
  UI.updating = false
end

local function addLabel(parent, text, x, y)
  local l = createLabel(parent)
  l.Caption, l.Left, l.Top = text, x, y
  return l
end

local function addCheck(parent, text, x, y, onChange)
  local c = createCheckBox(parent)
  c.Caption, c.Left, c.Top = text, x, y
  c.OnChange = function(sender)
    if UI.updating then return end
    onChange(sender.Checked)
    UI.refresh()
  end
  return c
end

local function addButton(parent, text, x, y, w, onClick)
  local b = createButton(parent)
  b.Caption, b.Left, b.Top, b.Width = text, x, y, w
  b.OnClick = function() onClick(); UI.refresh() end
  return b
end

-- "3x", " 1,5 " and "2.0" all read as numbers; anything else as nil.
local function parseNumber(text)
  local t = tostring(text or ""):gsub("%s", ""):gsub("[xX]$", ""):gsub(",", ".")
  return tonumber(t)
end
Trainer.parseNumber = parseNumber

local function addNumberEdit(parent, x, y, w, initial, onNumber)
  local e = createEdit(parent)
  e.Left, e.Top, e.Width = x, y, w
  e.Text = initial ~= nil and tostring(initial) or ""
  e.OnChange = function(sender)
    if UI.updating then return end
    onNumber(parseNumber(sender.Text))
  end
  return e
end

local function scoreAction(which, delta)
  local v, why = Features.adjustScore(which, delta)
  state.status = v and ("score set to " .. v) or ("score: " .. tostring(why))
end

local function matchPointAction()
  local v, why = Features.matchPoint()
  state.status = v and ("your score is now " .. v) or ("match point: " .. tostring(why))
end

-- Puts state values (after loading a preset) back into the edit boxes.
function UI.syncEdits()
  if not UI.form then return end
  UI.updating = true
  for _, row in ipairs(UI.statRows) do
    local t = state.statTargets[row.stat.key]
    row.edit.Text = t ~= nil and tostring(t) or ""
  end
  UI.multEdit.Text = tostring(state.statMultiplier)
  UI.cpuEdit.Text = tostring(state.cpuMultiplier)
  UI.updating = false
end

function UI.reloadPresetNames()
  local items = UI.presetBox.Items
  items.clear()
  for _, name in ipairs(Presets.names()) do items.add(name) end
end

function UI.build()
  local hk = CONFIG.hotkeys
  local f = createForm(false)
  UI.form = f
  f.Caption = "The Spike Cross - Offline Trainer"
  f.Width = 460
  f.Position = "poScreenCenter"
  f.BorderStyle = "bsSingle"

  local y = 8
  UI.procLabel = addLabel(f, "Not attached", 10, y); y = y + 20
  UI.guardLabel = addLabel(f, "", 10, y); y = y + 28

  -- Your stats
  UI.statsBox = addCheck(f, "Lock my stats " .. keyLabel(hk.toggleStats), 10, y, function(on) Features.set("stats", on) end)
  addLabel(f, "Empty box = original x", 220, y + 2)
  UI.multEdit = addNumberEdit(f, 350, y, 50, state.statMultiplier, function(v)
    if v then state.statMultiplier = v end
  end)
  y = y + 26
  for _, stat in ipairs(CONFIG.stats) do
    local row = { stat = stat }
    addLabel(f, stat.label, 24, y + 3)
    row.edit = addNumberEdit(f, 110, y, 70, nil, function(v) state.statTargets[stat.key] = v end)
    row.value = addLabel(f, "", 190, y + 3)
    UI.statRows[#UI.statRows + 1] = row
    y = y + 26
  end
  y = y + 6

  -- CPU opponents
  UI.cpuBox = addCheck(f, "Weaker CPU opponents " .. keyLabel(hk.toggleCpu), 10, y, function(on) Features.set("cpu", on) end)
  addLabel(f, "stats x", 220, y + 2)
  UI.cpuEdit = addNumberEdit(f, 270, y, 50, state.cpuMultiplier, function(v)
    if v then state.cpuMultiplier = v end
  end)
  UI.cpuValue = addLabel(f, "", 330, y + 2)
  y = y + 32

  -- Holds
  for _, hold in ipairs(CONFIG.holds) do
    local row = { hold = hold }
    row.box = addCheck(f, hold.label .. " " .. keyLabel(hold.hotkey), 10, y, function(on) Features.set(hold.key, on) end)
    row.value = addLabel(f, "", 260, y + 2)
    UI.holdRows[#UI.holdRows + 1] = row
    y = y + 26
  end
  y = y + 6

  -- Score
  addLabel(f, "Score (mine : theirs)", 10, y + 3)
  UI.scoreValue = addLabel(f, "", 150, y + 3)
  y = y + 24
  addButton(f, "Mine +1 " .. keyLabel(hk.myScoreUp), 10, y, 105, function() scoreAction("mine", 1) end)
  addButton(f, "Mine -1", 120, y, 70, function() scoreAction("mine", -1) end)
  addButton(f, "Theirs +1", 195, y, 80, function() scoreAction("theirs", 1) end)
  addButton(f, "Theirs -1 " .. keyLabel(hk.theirScoreDown), 280, y, 150, function() scoreAction("theirs", -1) end)
  y = y + 30
  addButton(f, "Match point " .. keyLabel(hk.matchPoint), 10, y, 180, matchPointAction)
  y = y + 36

  -- Speed
  UI.speedBox = addCheck(f, "Speedhack " .. keyLabel(hk.toggleSpeed), 10, y, function(on) Features.set("speed", on) end)
  UI.speedLabel = addLabel(f, "", 150, y + 2)
  addButton(f, "- " .. keyLabel(hk.speedDown), 260, y - 2, 80, function() Features.setSpeed(state.speed - CONFIG.speed.step) end)
  addButton(f, "+ " .. keyLabel(hk.speedUp), 350, y - 2, 80, function() Features.setSpeed(state.speed + CONFIG.speed.step) end)
  y = y + 36

  -- Presets
  addLabel(f, "Preset", 10, y + 3)
  UI.presetBox = createComboBox(f)
  UI.presetBox.Left, UI.presetBox.Top, UI.presetBox.Width = 60, y, 150
  addButton(f, "Save", 220, y - 1, 65, function()
    local ok, err = Presets.save(UI.presetBox.Text)
    state.status = ok and ("preset saved: " .. UI.presetBox.Text) or ("preset: " .. tostring(err))
    UI.reloadPresetNames()
  end)
  addButton(f, "Load", 290, y - 1, 65, function()
    local ok, err = Presets.load(UI.presetBox.Text)
    state.status = ok and ("preset loaded: " .. UI.presetBox.Text) or ("preset: " .. tostring(err))
    UI.syncEdits()
  end)
  addButton(f, "Delete", 360, y - 1, 70, function()
    local ok, err = Presets.delete(UI.presetBox.Text)
    state.status = ok and "preset deleted" or ("preset: " .. tostring(err))
    UI.reloadPresetNames()
  end)
  y = y + 36

  addButton(f, "Retry hooks", 10, y, 100, function()
    Hooks.failed = {}
    state.status = "hook errors cleared"
  end)
  addButton(f, "Close trainer", 115, y, 100, function() Trainer.shutdown() end)
  y = y + 32
  UI.statusLabel = addLabel(f, "", 10, y)

  f.Height = y + 30
  f.OnClose = function()
    Trainer.shutdown(true)
    return caFree
  end
  UI.reloadPresetNames()
  f.show()
end

--------------------------------------------------------------------------------
-- Hotkeys
--------------------------------------------------------------------------------
local hotkeyObjects = {}

local function bindHotkey(keyName, fn)
  if not keyName then return end
  local key = _G[keyName]
  if not key then
    log("unknown hotkey " .. tostring(keyName))
    return
  end
  hotkeyObjects[#hotkeyObjects + 1] = createHotkey(function()
    pcall(fn)
    UI.refresh()
  end, key)
end

local function bindHotkeys()
  local hk = CONFIG.hotkeys
  bindHotkey(hk.toggleStats,    function() Features.toggle("stats") end)
  bindHotkey(hk.toggleCpu,      function() Features.toggle("cpu") end)
  bindHotkey(hk.toggleSpeed,    function() Features.toggle("speed") end)
  bindHotkey(hk.speedDown,      function() Features.setSpeed(state.speed - CONFIG.speed.step) end)
  bindHotkey(hk.speedUp,        function() Features.setSpeed(state.speed + CONFIG.speed.step) end)
  bindHotkey(hk.myScoreUp,      function() scoreAction("mine", 1) end)
  bindHotkey(hk.theirScoreDown, function() scoreAction("theirs", -1) end)
  bindHotkey(hk.matchPoint,     matchPointAction)
  for _, hold in ipairs(CONFIG.holds) do
    bindHotkey(hold.hotkey, function() Features.toggle(hold.key) end)
  end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
local timer = nil
local shuttingDown = false

-- fromForm: called by the window's OnClose, which frees the form itself.
function Trainer.shutdown(fromForm)
  if shuttingDown then return end
  shuttingDown = true
  if timer then timer.destroy(); timer = nil end
  for _, h in ipairs(hotkeyObjects) do pcall(function() h.destroy() end) end
  hotkeyObjects = {}
  if state.pid then
    pcall(Features.disableAll, nil)
    pcall(Hooks.disableAll)
  end
  local f = UI.form
  UI.form = nil
  if f and not fromForm then pcall(function() f.close() end) end
  if _G.SpikeCrossTrainer == Trainer then _G.SpikeCrossTrainer = nil end
  log("trainer closed")
end

function Trainer.start()
  UI.build()
  bindHotkeys()
  timer = createTimer(nil, false)
  timer.Interval = CONFIG.tickMs
  timer.OnTimer = safeTick
  timer.Enabled = true
  log("trainer started; waiting for the game")
end

_G.SpikeCrossTrainer = Trainer

-- Tests load this file with SPIKE_CROSS_TEST set and drive it directly.
if not _G.SPIKE_CROSS_TEST then Trainer.start() end

return Trainer
