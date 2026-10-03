-- Logic tests for the trainer against the mocked Cheat Engine API.
-- Run from the repository root:  lua5.3 tests/run_tests.lua

local out = print
package.path = "./tests/?.lua;" .. package.path
local ce = require("ce_mock")
local SRC = "src/TheSpikeCross.lua"

local PID = 4242
local MODE, SPIKE, SERVE = 0x5000, 0x6000, 0x6004
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
local function setup(opts)
  opts = opts or {}
  local T = ce.load(SRC)
  ce.processes[PID] = "TheSpikeCross.exe"
  if not opts.noGuard then
    ce.symbols["MODE"] = MODE
    ce.values[MODE] = opts.mode or OFFLINE
    T.CONFIG.guard.source = { expr = "MODE" }
    T.CONFIG.guard.allowed = { OFFLINE }
    T.CONFIG.guard.names = { [OFFLINE] = "Story" }
  end
  ce.symbols["SPIKE"], ce.symbols["SERVE"] = SPIKE, SERVE
  ce.values[SPIKE], ce.values[SERVE] = 50.0, 40.0
  T.CONFIG.stats = {
    { key = "spike", label = "Spike", source = { expr = "SPIKE" }, type = "float" },
    { key = "serve", label = "Serve", source = { expr = "SERVE" }, type = "float" },
  }
  return T
end

-- Configures a capture hook "player" over fake game code.
local INJ, MEM = 0x140001000, 0x140100000
local ORIG = { 0xF3, 0x0F, 0x10, 0x41, 0x44, 0x8B, 0xC8 }
local function setupHook(T, opts)
  opts = opts or {}
  ce.symbols["GameAssembly.dll"] = 0x140000000
  ce.moduleSizes["GameAssembly.dll"] = 0x1000000
  ce.aobHits["F3 0F 10 41 44 8B C8"] = opts.hits or { INJ }
  for i, b in ipairs(ORIG) do ce.code[INJ + i - 1] = b end
  ce.nextAlloc = opts.alloc or MEM
  T.CONFIG.hooks.player = {
    module = "GameAssembly.dll", aob = "F3 0F 10 41 44 8B C8", offset = 0,
    length = #ORIG, register = "rcx", filter = opts.filter,
  }
end
local function slot() return MEM + 0x80 end

test("guard not configured: features refuse, speed untouched", function()
  local T = setup({ noGuard = true })
  T.tick()
  eq(T._state.guardOk, false, "guardOk")
  truthy(T._state.guardReason:find("not configured"), "reason mentions configuration")
  eq(T.Features.set("stats", true), false, "stats enable")
  eq(T.Features.set("speed", true), false, "speed enable")
  T.tick()
  eq(ce.values[SPIKE], 50.0, "spike untouched")
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
  eq(T.Features.set("stamina", true), false, "stamina enable")
end)

test("guard unreadable fails closed", function()
  local T = setup()
  ce.symbols["MODE"] = nil
  T.tick()
  eq(T._state.guardOk, false, "guardOk")
end)

test("stat lock applies multiplier and restores originals on release", function()
  local T = setup()
  T.tick()
  eq(T._state.guardOk, true, "guardOk")
  truthy(T.Features.set("stats", true), "stats enable")
  T.tick()
  eq(ce.values[SPIKE], 75.0, "spike x1.5")
  eq(ce.values[SERVE], 60.0, "serve x1.5")
  T._state.statTargets.spike = 99
  T.tick()
  eq(ce.values[SPIKE], 99, "spike override")
  T.Features.set("stats", false)
  eq(ce.values[SPIKE], 50.0, "spike restored")
  eq(ce.values[SERVE], 40.0, "serve restored")
end)

test("stat max clamps the target", function()
  local T = setup()
  T.CONFIG.stats[1].max = 60
  T.tick()
  T.Features.set("stats", true)
  T.tick()
  eq(ce.values[SPIKE], 60, "spike clamped")
end)

test("int32 stats are rounded", function()
  local T = setup()
  ce.values[SPIKE] = 7
  T.CONFIG.stats[1].type = "int32"
  T.tick()
  T.Features.set("stats", true)
  T.tick()
  eq(ce.values[SPIKE], 11, "7 * 1.5 rounded")
end)

test("leaving offline mode switches everything off and restores", function()
  local T = setup()
  T.tick()
  T.Features.set("stats", true)
  T.Features.set("speed", true)
  T.tick()
  eq(ce.values[SPIKE], 75.0, "spike boosted")
  eq(ce.speed, 2.0, "speed applied")
  ce.values[MODE] = ONLINE
  T.tick()
  eq(T._state.statsLocked, false, "stats unlocked")
  eq(T._state.speedOn, false, "speed off")
  eq(ce.values[SPIKE], 50.0, "spike restored")
  eq(ce.speed, 1.0, "speed reset")
  -- Coming back to offline does not silently re-enable anything.
  ce.values[MODE] = OFFLINE
  T.tick()
  eq(T._state.statsLocked, false, "stays off")
  eq(ce.values[SPIKE], 50.0, "spike untouched")
end)

test("speed is clamped to the configured range", function()
  local T = setup()
  eq(T.Features.setSpeed(100), 5.0, "upper clamp")
  eq(T.Features.setSpeed(0), 0.25, "lower clamp")
end)

test("stamina lock holds current at max", function()
  local T = setup()
  ce.symbols["STA"], ce.symbols["STAMAX"] = 0x7000, 0x7004
  ce.values[0x7000], ce.values[0x7004] = 12.0, 100.0
  T.CONFIG.stamina.current = { expr = "STA" }
  T.CONFIG.stamina.max = { expr = "STAMAX" }
  T.tick()
  T.Features.set("stamina", true)
  T.tick()
  eq(ce.values[0x7000], 100.0, "stamina at max")
end)

test("score adjust clamps at zero and needs the guard", function()
  local T = setup()
  ce.symbols["MINE"], ce.symbols["THEIRS"] = 0x8000, 0x8004
  ce.values[0x8000], ce.values[0x8004] = 3, 0
  T.CONFIG.score.mine, T.CONFIG.score.theirs = { expr = "MINE" }, { expr = "THEIRS" }
  T.tick()
  eq(T.Features.adjustScore("mine", 1), 4, "mine +1")
  eq(T.Features.adjustScore("theirs", -1), 0, "theirs stays 0")
  ce.values[MODE] = ONLINE
  T.tick()
  eq(T.Features.adjustScore("mine", 1), nil, "refused when blocked")
  eq(ce.values[0x8000], 4, "score unchanged")
end)

test("capture hook: script shape, capture, stale pointer, restore", function()
  local T = setup()
  setupHook(T, { filter = { offset = 0x1C, size = "dword", equals = 1 } })
  T.CONFIG.stats[1].source = { hook = "player", offset = 0x44 }
  T.tick()
  T.Features.set("stats", true)
  T.tick()
  local script = ce.scripts[#ce.scripts]
  truthy(script, "hook script assembled")
  truthy(script:find("pushfq", 1, true), "flags saved")
  truthy(script:find("cmp dword ptr [rcx+1C],#1", 1, true), "filter compare")
  truthy(script:find(string.format("mov [%016X],rcx", slot()), 1, true), "pointer store")
  truthy(script:find("db F3 0F 10 41 44 8B C8", 1, true), "original bytes replayed")
  truthy(script:find(string.format("jmp %016X", INJ + #ORIG), 1, true), "jump back")
  truthy(script:find("db 90 90", 1, true), "nop padding")
  eq(ce.code[INJ], 0xE9, "jump written into game code")

  -- The game runs the hooked instruction for the player object.
  local obj = 0x20000000
  ce.values[slot()] = obj
  ce.values[obj + 0x44] = 10.0
  T.tick()
  eq(ce.values[obj + 0x44], 15.0, "hooked stat boosted")
  eq(ce.values[slot()], 0, "slot cleared after read")

  -- The match ends: the instruction stops running, the pointer goes stale.
  ce.time = ce.time + T.CONFIG.staleMs + 1
  ce.values[obj + 0x44] = 10.0
  T.tick()
  eq(ce.values[obj + 0x44], 10.0, "no write through a stale pointer")

  T.shutdown()
  for i, b in ipairs(ORIG) do eq(ce.code[INJ + i - 1], b, "code byte " .. i .. " restored") end
end)

test("feature hooks are not installed while the guard blocks", function()
  local T = setup({ mode = ONLINE })
  setupHook(T)
  T.CONFIG.stats[1].source = { hook = "player", offset = 0x44 }
  T.tick()
  T.Values.address(T.CONFIG.stats[1].source)
  eq(#ce.scripts, 0, "nothing assembled")
  eq(ce.code[INJ], ORIG[1], "game code untouched")
end)

test("feature hooks are removed when the guard starts blocking", function()
  local T = setup()
  setupHook(T)
  T.CONFIG.stats[1].source = { hook = "player", offset = 0x44 }
  T.tick()
  T.Features.set("stats", true)
  T.tick()
  eq(ce.code[INJ], 0xE9, "hook installed")
  ce.values[MODE] = ONLINE
  T.tick()
  eq(ce.code[INJ], ORIG[1], "hook removed")
end)

test("the guard's own hook may install before the guard passes", function()
  local T = setup({ noGuard = true })
  setupHook(T)
  T.CONFIG.guard.source = { hook = "player", offset = 0x30 }
  T.CONFIG.guard.allowed = { OFFLINE }
  T.tick()
  eq(ce.code[INJ], 0xE9, "guard hook installed")
  eq(T._state.guardOk, false, "still waiting for a capture")
  local obj = 0x30000000
  ce.values[slot()] = obj
  ce.values[obj + 0x30] = OFFLINE
  T.tick()
  eq(T._state.guardOk, true, "guard passes once captured")
end)

test("ambiguous pattern is refused and not retried until reset", function()
  local T = setup()
  setupHook(T, { hits = { INJ, INJ + 0x100 } })
  T.CONFIG.stats[1].source = { hook = "player", offset = 0x44 }
  T.tick()
  local ok, why = T.Hooks.enable("player")
  eq(ok, false, "enable")
  truthy(why:find("matches 2 places"), "reason")
  local logged = #ce.logs
  T.Hooks.enable("player")
  eq(#ce.logs, logged, "no repeated log")
  ce.aobHits["F3 0F 10 41 44 8B C8"] = { INJ }
  T.Hooks.failed = {}
  eq(T.Hooks.enable("player"), true, "enable after reset")
end)

test("pattern outside the module is ignored", function()
  local T = setup()
  setupHook(T, { hits = { 0x7FF000000000 } })
  T.tick()
  local ok, why = T.Hooks.enable("player")
  eq(ok, false, "enable")
  truthy(why:find("not found in GameAssembly.dll"), "reason")
end)

test("hook memory too far for a 5-byte jump is refused", function()
  local T = setup()
  setupHook(T, { alloc = INJ + 0x100000000 })
  T.tick()
  local ok, why = T.Hooks.enable("player")
  eq(ok, false, "enable")
  truthy(why:find("too far"), "reason")
  eq(ce.code[INJ], ORIG[1], "game code untouched")
end)

test("already-hooked code is refused", function()
  local T = setup()
  setupHook(T)
  ce.code[INJ] = 0xE9
  T.tick()
  local ok, why = T.Hooks.enable("player")
  eq(ok, false, "enable")
  truthy(why:find("already hooked"), "reason")
end)

test("bad hook settings are rejected", function()
  local T = setup()
  setupHook(T)
  T.CONFIG.hooks.player.register = "eax"
  T.tick()
  local ok, why = T.Hooks.enable("player")
  eq(ok, false, "enable")
  truthy(why:find("64%-bit register"), "register reason")
  T.Hooks.failed = {}
  T.CONFIG.hooks.player.register = "rcx"
  T.CONFIG.hooks.player.length = 4
  ok, why = T.Hooks.enable("player")
  eq(ok, false, "enable")
  truthy(why:find("length"), "length reason")
end)

test("process exit detaches and resets state", function()
  local T = setup()
  T.tick()
  T.Features.set("stats", true)
  eq(T._state.pid, PID, "attached")
  ce.processes[PID] = nil
  ce.time = ce.time + 2500
  T.tick()
  eq(T._state.pid, nil, "detached")
  eq(T._state.statsLocked, false, "features off")
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
  T.CONFIG.processName = "TheSpikeCross.exe"
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
