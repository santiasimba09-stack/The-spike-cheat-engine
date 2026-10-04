-- Logic tests for the trainer against the mocked Cheat Engine API.
-- Run from the repository root:  lua5.3 tests/run_tests.lua

local out = print
package.path = "./tests/?.lua;" .. package.path
local ce = require("ce_mock")
local SRC = "src/TheSpikeCross.lua"

local PID = 4242
local MODE, ATK, DEF = 0x5000, 0x6000, 0x6004
local OFFLINE, ONLINE = 1, 7

local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(actual, expected, what)
  if actual ~= expected then
    error((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end
local function truthy(v, what) if not v then error((what or "condition") .. " was false", 2) end end

-- Loads a fresh trainer with the game running and an expression-based guard.
-- Stats point straight at fixed addresses.
local function setup(opts)
  opts = opts or {}
  local T = ce.load(SRC)
  ce.processes[PID] = "TheSpike-Cross.exe"
  if not opts.noGuard then
    ce.symbols["MODE"] = MODE
    ce.values[MODE] = opts.mode or OFFLINE
    T.CONFIG.guard.source = { expr = "MODE" }
    T.CONFIG.guard.allowed = { OFFLINE }
    T.CONFIG.guard.names = { [OFFLINE] = "Story" }
  end
  ce.symbols["ATK"], ce.symbols["DEF"] = ATK, DEF
  ce.values[ATK], ce.values[DEF] = 50.0, 40.0
  T.CONFIG.stats = {
    { key = "attack",  label = "Attack",  source = { expr = "ATK" }, type = "float" },
    { key = "defense", label = "Defense", source = { expr = "DEF" }, type = "float" },
  }
  return T
end

-- A capture hook "players" over fake game code in TheSpike-Cross.exe.
local INJ, MEM = 0x140001000, 0x140100000
local TBL = MEM + 0x100
local ORIG = { 0xF3, 0x0F, 0x10, 0x41, 0x44, 0x8B, 0xC8 }
local AOB = "F3 0F 10 41 44 8B C8"
local function setupHook(T, opts)
  opts = opts or {}
  ce.symbols["TheSpike-Cross.exe"] = 0x140000000
  ce.moduleSizes["TheSpike-Cross.exe"] = 0x1000000
  ce.aobHits[AOB] = opts.hits or { INJ }
  for i, b in ipairs(ORIG) do ce.code[INJ + i - 1] = b end
  ce.nextAlloc = opts.alloc or MEM
  T.CONFIG.hooks.players = {
    module = "TheSpike-Cross.exe", aob = AOB, offset = 0,
    length = #ORIG, register = opts.register or "rcx", filter = opts.filter,
  }
end

-- The game runs the hooked instruction on these objects this frame.
local function capture(...)
  for i, p in ipairs({ ... }) do ce.values[TBL + (i - 1) * 8] = p end
end

-- Six players: team field at +0x20 (1 = mine, 2 = opponents), the human
-- player has +0x1C == 1. Attack at +0x44, defense at +0x48.
local ME, MATE1, MATE2, OPP1, OPP2, OPP3 = 0x20000000, 0x20001000, 0x20002000, 0x21000000, 0x21001000, 0x21002000
local function setupPlayers(T)
  setupHook(T)
  local function player(p, team, human, atk)
    ce.values[p + 0x20], ce.values[p + 0x1C] = team, human and 1 or 0
    ce.values[p + 0x44], ce.values[p + 0x48] = atk, 30.0
  end
  player(ME, 1, true, 50.0)
  player(MATE1, 1, false, 45.0)
  player(MATE2, 1, false, 45.0)
  player(OPP1, 2, false, 60.0)
  player(OPP2, 2, false, 60.0)
  player(OPP3, 2, false, 60.0)
  T.CONFIG.groups.me = { hook = "players", where = { offset = 0x1C, type = "int32", equals = 1 } }
  T.CONFIG.groups.cpu = { hook = "players", where = { offset = 0x20, type = "int32", equals = 2 } }
  T.CONFIG.stats = {
    { key = "attack",  label = "Attack",  offset = 0x44, type = "float" },
    { key = "defense", label = "Defense", offset = 0x48, type = "float" },
  }
end

-- One game frame in a match: all six players run the hooked instruction.
local function frame(T)
  capture(ME, MATE1, MATE2, OPP1, OPP2, OPP3)
  T.tick()
end

-- Turns a feature on and plays until the hook has installed and captured.
local function enableInMatch(T, name)
  T.tick()
  T.Features.set(name, true)
  T.tick()   -- installs the hook (which starts with an empty table)
  frame(T)   -- the game reports its players, the feature applies
end

local function hold(T, key) for _, h in ipairs(T.CONFIG.holds) do if h.key == key then return h end end end

--------------------------------------------------------------------------------
-- Mode guard
--------------------------------------------------------------------------------
test("guard not configured: features refuse, speed untouched", function()
  local T = setup({ noGuard = true })
  T.tick()
  eq(T._state.guardOk, false, "guardOk")
  truthy(T._state.guardReason:find("not configured"), "reason mentions configuration")
  eq(T.Features.set("stats", true), false, "stats enable")
  eq(T.Features.set("speed", true), false, "speed enable")
  eq(T.Features.set("timing", true), false, "hold enable")
  T.tick()
  eq(ce.values[ATK], 50.0, "attack untouched")
  eq(ce.speedCalls, 0, "speedhack never called")
end)

test("guard with empty allowed list counts as not configured", function()
  local T = setup()
  T.CONFIG.guard.allowed = {}
  T.tick()
  eq(T._state.guardOk, false, "guardOk")
end)

test("guard blocks a mode outside the offline list", function()
  local T = setup({ mode = ONLINE })
  T.tick()
  eq(T._state.guardOk, false, "guardOk")
  truthy(T._state.guardReason:find("Blocked"), "blocked reason")
  eq(T.Features.set("cpu", true), false, "cpu enable")
end)

test("a session-only guard expires when the game restarts", function()
  local T = setup()
  T.tick()
  T.CONFIG.guard.sessionPid = PID
  T.tick()
  eq(T._state.guardOk, true, "valid in its own session")
  -- The game restarts under a new pid; the old heap address means nothing.
  ce.processes[PID] = nil
  ce.processes[PID + 1] = "TheSpike-Cross.exe"
  ce.time = ce.time + 2500
  T.tick()
  T.tick()
  eq(T._state.pid, PID + 1, "re-attached")
  eq(T._state.guardOk, false, "guard expired")
  truthy(T._state.guardReason:find("expired"), "reason")
end)

test("number boxes accept 3x, commas and spaces", function()
  local T = setup()
  eq(T.parseNumber("3x"), 3, "3x")
  eq(T.parseNumber(" 1,5 "), 1.5, "1,5")
  eq(T.parseNumber("2.25X"), 2.25, "2.25X")
  eq(T.parseNumber(""), nil, "empty")
  eq(T.parseNumber("lots"), nil, "words")
end)

test("guard unreadable fails closed", function()
  local T = setup()
  ce.symbols["MODE"] = nil
  T.tick()
  eq(T._state.guardOk, false, "guardOk")
end)

test("leaving offline mode switches everything off and restores", function()
  local T = setup()
  ce.symbols["T1"] = 0x7100
  ce.values[0x7100] = 1.0
  hold(T, "timing").values = { { source = { expr = "T1" }, type = "float", mode = "multiply", factor = 3 } }
  T.tick()
  T.Features.set("stats", true)
  T.Features.set("speed", true)
  T.Features.set("timing", true)
  T.tick()
  eq(ce.values[ATK], 75.0, "attack boosted")
  eq(ce.values[0x7100], 3.0, "timing widened")
  eq(ce.speed, 2.0, "speed applied")
  ce.values[MODE] = ONLINE
  T.tick()
  eq(T._state.statsLocked, false, "stats unlocked")
  eq(T._state.speedOn, false, "speed off")
  eq(T._state.holds.timing, nil, "hold off")
  eq(ce.values[ATK], 50.0, "attack restored")
  eq(ce.values[0x7100], 1.0, "timing restored")
  eq(ce.speed, 1.0, "speed reset")
  -- Coming back to offline does not silently re-enable anything.
  ce.values[MODE] = OFFLINE
  T.tick()
  eq(T._state.statsLocked, false, "stays off")
  eq(ce.values[ATK], 50.0, "attack untouched")
end)

--------------------------------------------------------------------------------
-- Your stats
--------------------------------------------------------------------------------
test("stat lock applies multiplier and restores originals on release", function()
  local T = setup()
  T.tick()
  eq(T._state.guardOk, true, "guardOk")
  truthy(T.Features.set("stats", true), "stats enable")
  T.tick()
  eq(ce.values[ATK], 75.0, "attack x1.5")
  eq(ce.values[DEF], 60.0, "defense x1.5")
  T._state.statTargets.attack = 99
  T.tick()
  eq(ce.values[ATK], 99, "attack override")
  T.Features.set("stats", false)
  eq(ce.values[ATK], 50.0, "attack restored")
  eq(ce.values[DEF], 40.0, "defense restored")
end)

test("stat max clamps the target", function()
  local T = setup()
  T.CONFIG.stats[1].max = 60
  T.tick()
  T.Features.set("stats", true)
  T.tick()
  eq(ce.values[ATK], 60, "attack clamped")
end)

test("int32 stats are rounded", function()
  local T = setup()
  ce.values[ATK] = 7
  T.CONFIG.stats[1].type = "int32"
  T.tick()
  T.Features.set("stats", true)
  T.tick()
  eq(ce.values[ATK], 11, "7 * 1.5 rounded")
end)

test("group 'me' picks only your player out of the hook", function()
  local T = setup()
  setupPlayers(T)
  enableInMatch(T, "stats")
  eq(ce.values[ME + 0x44], 75.0, "my attack boosted")
  eq(ce.values[MATE1 + 0x44], 45.0, "teammate untouched")
  eq(ce.values[OPP1 + 0x44], 60.0, "opponent untouched")
  T.Features.set("stats", false)
  eq(ce.values[ME + 0x44], 50.0, "my attack restored")
end)

test("an ambiguous group is refused instead of guessed", function()
  local T = setup()
  setupPlayers(T)
  T.CONFIG.groups.me.where = nil
  enableInMatch(T, "stats")
  eq(ce.values[ME + 0x44], 50.0, "nothing written")
  local _, why = T.Values.address(T.Features.statSource(T.CONFIG.stats[1]))
  truthy(why:find("6 objects"), "reason names the count")
end)

--------------------------------------------------------------------------------
-- CPU opponents
--------------------------------------------------------------------------------
test("weaker CPU scales only the opposing team and restores", function()
  local T = setup()
  setupPlayers(T)
  enableInMatch(T, "cpu")
  for _, p in ipairs({ OPP1, OPP2, OPP3 }) do
    eq(ce.values[p + 0x44], 36.0, "opponent attack x0.6")
    eq(ce.values[p + 0x48], 18.0, "opponent defense x0.6")
  end
  eq(ce.values[ME + 0x44], 50.0, "me untouched")
  eq(ce.values[MATE1 + 0x44], 45.0, "teammate untouched")
  -- Re-applying does not compound.
  frame(T)
  eq(ce.values[OPP1 + 0x44], 36.0, "still x0.6 of the original")
  T.Features.set("cpu", false)
  eq(ce.values[OPP1 + 0x44], 60.0, "opponent restored")
end)

test("a loose CPU group never weakens your own player", function()
  local T = setup()
  setupPlayers(T)
  T.CONFIG.groups.cpu.where = nil
  enableInMatch(T, "cpu")
  eq(ce.values[ME + 0x44], 50.0, "me untouched")
  eq(ce.values[OPP1 + 0x44], 36.0, "opponent weakened")
end)

test("CPU records are dropped when the players go away", function()
  local T = setup()
  setupPlayers(T)
  enableInMatch(T, "cpu")
  truthy(next(T._state.cpuOriginals), "records exist")
  ce.time = ce.time + T.CONFIG.staleMs + 1
  T.tick()
  eq(next(T._state.cpuOriginals), nil, "records pruned")
end)

--------------------------------------------------------------------------------
-- Holds
--------------------------------------------------------------------------------
test("stamina hold keeps the team bar at max", function()
  local T = setup()
  ce.symbols["STA"], ce.symbols["STAMAX"] = 0x7000, 0x7004
  ce.values[0x7000], ce.values[0x7004] = 12.0, 100.0
  hold(T, "stamina").values = { { source = { expr = "STA" }, type = "float", mode = "max", max = { expr = "STAMAX" } } }
  T.tick()
  T.Features.toggle("stamina")
  T.tick()
  eq(ce.values[0x7000], 100.0, "stamina at max")
  ce.values[0x7000] = 40.0
  T.tick()
  eq(ce.values[0x7000], 100.0, "refilled")
  T.Features.toggle("stamina")
  eq(ce.values[0x7000], 100.0, "restore = false leaves it")
end)

test("hold modes: maxValue, freeze and fixed", function()
  local T = setup()
  ce.symbols["G"], ce.symbols["TM"] = 0x7200, 0x7300
  ce.values[0x7200], ce.values[0x7300] = 3.0, 42.5
  hold(T, "gauge").values = { { source = { expr = "G" }, type = "float", mode = "max", maxValue = 10.0 } }
  hold(T, "timer").values = { { source = { expr = "TM" }, type = "float", mode = "freeze" } }
  T.tick()
  T.Features.set("gauge", true)
  T.Features.set("timer", true)
  T.tick()
  eq(ce.values[0x7200], 10.0, "gauge at maxValue")
  ce.values[0x7300] = 30.0 -- the game counts the clock down
  T.tick()
  eq(ce.values[0x7300], 42.5, "timer frozen at its start value")
  hold(T, "gauge").values[1].mode, hold(T, "gauge").values[1].value = "fixed", 7.0
  T.tick()
  eq(ce.values[0x7200], 7.0, "fixed value")
end)

test("read-only constants are made writable once", function()
  local T = setup()
  ce.symbols["WIN"] = 0x7400
  ce.values[0x7400] = 0.1
  ce.readonly[0x7400] = true
  hold(T, "timing").values = { { source = { expr = "WIN" }, type = "float", mode = "multiply", factor = 3 } }
  T.tick()
  T.Features.set("timing", true)
  T.tick()
  eq(ce.values[0x7400], 0.1 * 3, "window widened")
  T.Features.set("timing", false)
  eq(ce.values[0x7400], 0.1, "window restored")
end)

test("hold with an unconfigured value does nothing", function()
  local T = setup()
  T.tick()
  truthy(T.Features.set("timing", true), "enable")
  T.tick()
  eq(T._state.holds.timing, true, "on")
end)

--------------------------------------------------------------------------------
-- Score
--------------------------------------------------------------------------------
local function setupScore(T, mine, theirs)
  ce.symbols["MINE"], ce.symbols["THEIRS"] = 0x8000, 0x8004
  ce.values[0x8000], ce.values[0x8004] = mine, theirs
  T.CONFIG.score.mine, T.CONFIG.score.theirs = { expr = "MINE" }, { expr = "THEIRS" }
  T.CONFIG.score.enabled = true
end

test("score editing is off by default (the game closes itself)", function()
  local T = setup()
  setupScore(T, 3, 5)
  T.CONFIG.score.enabled = false
  T.tick()
  local v, why = T.Features.adjustScore("mine", 1)
  eq(v, nil, "adjust refused")
  truthy(why:find("score editing is off"), "reason")
  eq(T.Features.matchPoint(), nil, "match point refused")
  eq(ce.values[0x8000], 3, "score untouched")
  eq(T.CONFIG.score.enabled, false, "still off")
end)

test("the shipped config keeps score editing off", function()
  local T = ce.load(SRC)
  eq(T.CONFIG.score.enabled, false, "enabled flag")
end)

test("score adjust clamps at zero and needs the guard", function()
  local T = setup()
  setupScore(T, 3, 0)
  T.tick()
  eq(T.Features.adjustScore("mine", 1), 4, "mine +1")
  eq(T.Features.adjustScore("theirs", -1), 0, "theirs stays 0")
  ce.values[MODE] = ONLINE
  T.tick()
  eq(T.Features.adjustScore("mine", 1), nil, "refused when blocked")
  eq(ce.values[0x8000], 4, "score unchanged")
end)

test("match point respects win-by-two and the deuce cap", function()
  local T = setup()
  setupScore(T, 3, 10)
  T.tick()
  eq(T.Features.matchPoint(), 24, "normal set")
  setupScore(T, 20, 24)
  eq(T.Features.matchPoint(), 25, "they are at 24: one ahead of them")
  setupScore(T, 40, 49)
  eq(T.Features.matchPoint(), 49, "capped below 50")
  setupScore(T, 24, 5)
  eq(T.Features.matchPoint(), 24, "already at match point")
  setupScore(T, 26, 5)
  eq(T.Features.matchPoint(), 26, "never lowers your score")
  eq(ce.values[0x8000], 26, "unchanged")
  ce.values[MODE] = ONLINE
  T.tick()
  eq(T.Features.matchPoint(), nil, "refused when blocked")
end)

--------------------------------------------------------------------------------
-- Speed
--------------------------------------------------------------------------------
test("speed is clamped to the configured range", function()
  local T = setup()
  eq(T.Features.setSpeed(100), 5.0, "upper clamp")
  eq(T.Features.setSpeed(0), 0.25, "lower clamp")
end)

--------------------------------------------------------------------------------
-- Presets
--------------------------------------------------------------------------------
local PRESET_FILE = os.tmpname()

test("presets save, load and delete", function()
  local T = setup()
  os.remove(PRESET_FILE)
  T.CONFIG.presets.file = PRESET_FILE
  T._state.statTargets = { attack = 99, defense = 80.5 }
  T._state.statMultiplier, T._state.cpuMultiplier = 2.0, 0.5
  T.Features.setSpeed(3.0)
  truthy(T.Presets.save("grind"), "save")
  T._state.statTargets, T._state.statMultiplier, T._state.cpuMultiplier = {}, 1.5, 0.6
  T.Features.setSpeed(1.0)
  truthy(T.Presets.load("grind"), "load")
  eq(T._state.statTargets.attack, 99, "attack target")
  eq(T._state.statTargets.defense, 80.5, "defense target")
  eq(T._state.statMultiplier, 2.0, "stat multiplier")
  eq(T._state.cpuMultiplier, 0.5, "cpu multiplier")
  eq(T._state.speed, 3.0, "speed")
  eq(T.Presets.names()[1], "grind", "listed")
  truthy(T.Presets.delete("grind"), "delete")
  eq(#T.Presets.names(), 0, "gone")
  eq(T.Presets.load("grind"), false, "load missing")
  eq(T.Presets.save(""), false, "empty name refused")
end)

test("presets ignore junk and unknown stats", function()
  local T = setup()
  T.CONFIG.presets.file = PRESET_FILE
  local f = io.open(PRESET_FILE, "w")
  f:write('{ ["p"] = { statTargets = { attack = "lots", bogus = 5, defense = 70 }, speed = 99 } }')
  f:close()
  truthy(T.Presets.load("p"), "load")
  eq(T._state.statTargets.attack, nil, "non-number dropped")
  eq(T._state.statTargets.bogus, nil, "unknown stat dropped")
  eq(T._state.statTargets.defense, 70, "valid kept")
  eq(T._state.speed, 5.0, "speed clamped")
  f = io.open(PRESET_FILE, "w")
  f:write("this is not lua")
  f:close()
  eq(#T.Presets.names(), 0, "broken file reads as empty")
  os.remove(PRESET_FILE)
end)

--------------------------------------------------------------------------------
-- Code hooks
--------------------------------------------------------------------------------
test("capture hook: script shape, capture, stale objects, restore", function()
  local T = setup()
  setupPlayers(T)
  enableInMatch(T, "stats")
  local script = ce.scripts[#ce.scripts]
  truthy(script, "hook script assembled")
  truthy(script:find("pushfq", 1, true), "flags saved")
  truthy(script:find("push rax", 1, true) and script:find("push rdx", 1, true), "scratch saved")
  truthy(script:find(string.format("lea rax,[%016X]", TBL), 1, true), "table address")
  truthy(script:find("cmp [rax+rdx*8],rcx", 1, true), "duplicate check")
  truthy(script:find("cmp rdx,#16", 1, true), "slot count")
  truthy(script:find("and rdx,#15", 1, true), "index wraps")
  truthy(script:find("db F3 0F 10 41 44 8B C8", 1, true), "original bytes replayed")
  truthy(script:find(string.format("jmp %016X", INJ + #ORIG), 1, true), "jump back")
  truthy(script:find("db 90 90", 1, true), "nop padding")
  eq(ce.code[INJ], 0xE9, "jump written into game code")
  eq(ce.values[ME + 0x44], 75.0, "captured player boosted")
  eq(ce.values[TBL], 0, "slots cleared after read")

  -- The match ends: the instruction stops running, the objects go stale.
  ce.time = ce.time + T.CONFIG.staleMs + 1
  ce.values[ME + 0x44] = 50.0
  T.tick()
  eq(ce.values[ME + 0x44], 50.0, "no write through a stale pointer")

  T.shutdown()
  for i, b in ipairs(ORIG) do eq(ce.code[INJ + i - 1], b, "code byte " .. i .. " restored") end
end)

test("scratch registers never clash with the captured register", function()
  local T = setup()
  setupHook(T, { register = "rax", filter = { offset = 0x1C, size = "byte", equals = 1 } })
  T.CONFIG.guard.source = { hook = "players", offset = 0x30 }
  T.tick()
  local script = ce.scripts[#ce.scripts]
  truthy(not script:find("push rax", 1, true), "rax not borrowed")
  truthy(script:find("push rdx", 1, true) and script:find("push r8", 1, true), "rdx and r8 borrowed")
  truthy(script:find("cmp byte ptr [rax+1C],#1", 1, true), "in-hook filter")
end)

test("byte-sized group filters work", function()
  local T = setup()
  setupPlayers(T)
  T.CONFIG.groups.me.where = { offset = 0x1C, type = "byte", equals = 1 }
  enableInMatch(T, "stats")
  eq(ce.values[ME + 0x44], 75.0, "my attack boosted")
end)

test("feature hooks are not installed while the guard blocks", function()
  local T = setup({ mode = ONLINE })
  setupPlayers(T)
  T.tick()
  T.Values.address(T.Features.statSource(T.CONFIG.stats[1]))
  eq(#ce.scripts, 0, "nothing assembled")
  eq(ce.code[INJ], ORIG[1], "game code untouched")
end)

test("feature hooks are removed when the guard starts blocking", function()
  local T = setup()
  setupPlayers(T)
  enableInMatch(T, "stats")
  eq(ce.code[INJ], 0xE9, "hook installed")
  ce.values[MODE] = ONLINE
  T.tick()
  eq(ce.code[INJ], ORIG[1], "hook removed")
end)

test("the guard's own hook may install before the guard passes", function()
  local T = setup({ noGuard = true })
  setupHook(T)
  T.CONFIG.guard.source = { hook = "players", offset = 0x30 }
  T.CONFIG.guard.allowed = { OFFLINE }
  T.tick()
  eq(ce.code[INJ], 0xE9, "guard hook installed")
  eq(T._state.guardOk, false, "still waiting for a capture")
  local obj = 0x30000000
  capture(obj)
  ce.values[obj + 0x30] = OFFLINE
  T.tick()
  eq(T._state.guardOk, true, "guard passes once captured")
end)

test("ambiguous pattern is refused and not retried until reset", function()
  local T = setup()
  setupHook(T, { hits = { INJ, INJ + 0x100 } })
  T.tick()
  local ok, why = T.Hooks.enable("players")
  eq(ok, false, "enable")
  truthy(why:find("matches 2 places"), "reason")
  local logged = #ce.logs
  T.Hooks.enable("players")
  eq(#ce.logs, logged, "no repeated log")
  ce.aobHits[AOB] = { INJ }
  T.Hooks.failed = {}
  eq(T.Hooks.enable("players"), true, "enable after reset")
end)

test("pattern outside the module is ignored", function()
  local T = setup()
  setupHook(T, { hits = { 0x7FF000000000 } })
  T.tick()
  local ok, why = T.Hooks.enable("players")
  eq(ok, false, "enable")
  truthy(why:find("not found in TheSpike%-Cross.exe"), "reason")
end)

test("hook memory too far for a 5-byte jump is refused", function()
  local T = setup()
  setupHook(T, { alloc = INJ + 0x100000000 })
  T.tick()
  local ok, why = T.Hooks.enable("players")
  eq(ok, false, "enable")
  truthy(why:find("too far"), "reason")
  eq(ce.code[INJ], ORIG[1], "game code untouched")
end)

test("already-hooked code is refused", function()
  local T = setup()
  setupHook(T)
  ce.code[INJ] = 0xE9
  T.tick()
  local ok, why = T.Hooks.enable("players")
  eq(ok, false, "enable")
  truthy(why:find("already hooked"), "reason")
end)

test("bad hook settings are rejected", function()
  local T = setup()
  setupHook(T)
  T.CONFIG.hooks.players.register = "eax"
  T.tick()
  local ok, why = T.Hooks.enable("players")
  eq(ok, false, "enable")
  truthy(why:find("64%-bit register"), "register reason")
  T.Hooks.failed = {}
  T.CONFIG.hooks.players.register = "rcx"
  T.CONFIG.hooks.players.length = 4
  ok, why = T.Hooks.enable("players")
  eq(ok, false, "enable")
  truthy(why:find("length"), "length reason")
end)

--------------------------------------------------------------------------------
-- Process
--------------------------------------------------------------------------------
test("process exit detaches and resets state", function()
  local T = setup()
  T.tick()
  T.Features.set("stats", true)
  T.Features.set("gauge", true)
  eq(T._state.pid, PID, "attached")
  ce.processes[PID] = nil
  ce.time = ce.time + 2500
  T.tick()
  eq(T._state.pid, nil, "detached")
  eq(T._state.statsLocked, false, "features off")
  eq(next(T._state.holds), nil, "holds off")
  eq(T._state.guardOk, false, "guard reset")
end)

test("waits when the game is not running", function()
  local T = ce.load(SRC)
  T.tick()
  eq(T._state.pid, nil, "not attached")
  truthy(T._state.guardReason:find("Waiting"), "waiting reason")
end)

test("exact processName wins over the substring match", function()
  local T = setup()
  ce.processes[1] = "SpikeLauncher.exe"
  T.tick()
  eq(T._state.pid, PID, "attached to the exact name")
end)

for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then
    out("PASS  " .. t.name)
  else
    failures = failures + 1
    out("FAIL  " .. t.name .. "\n      " .. tostring(err))
  end
end
out(string.format("\n%d tests, %d failed", #tests, failures))
os.exit(failures == 0 and 0 or 1)
