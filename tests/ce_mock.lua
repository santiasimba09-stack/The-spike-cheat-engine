-- Minimal stand-in for the parts of the Cheat Engine Lua API the trainer uses.
-- Memory is simulated with plain tables so the trainer's logic can be run
-- under a stock Lua 5.3 interpreter. This checks logic only; it says nothing
-- about how the real game or Cheat Engine behave.

local M = {}

function M.reset()
  M.time = 100000
  M.processes = {}       -- pid -> exe name
  M.opened = nil
  M.symbols = {}         -- expression/module -> address
  M.moduleSizes = {}     -- module -> size
  M.aobHits = {}         -- aob -> { addresses }
  M.code = {}            -- address -> byte (game code)
  M.values = {}          -- address -> number (data, any type)
  M.nextAlloc = nil      -- address allocateMemory returns
  M.scripts = {}         -- every script passed to autoAssemble
  M.aaFail = false
  M.speed = 1.0
  M.speedCalls = 0
  M.logs = {}
  M.readonly = {}        -- address -> true (writes fail until fullAccess)
end

local function install()
  function getTickCount() return M.time end

  function getProcesslist()
    local t = {}
    for pid, name in pairs(M.processes) do t[pid] = name end
    return t
  end
  function openProcess(pid) if M.processes[pid] then M.opened = pid end end
  function getOpenedProcessID() return M.opened or 0 end

  function getAddressSafe(expr) return M.symbols[expr] end
  function getModuleSize(module) return M.moduleSizes[module] end

  function AOBScan(aob)
    local hits = M.aobHits[aob]
    if not hits or #hits == 0 then return nil end
    local list = { Count = #hits }
    for i, a in ipairs(hits) do list[i - 1] = string.format("%X", a) end
    list.destroy = function() end
    return list
  end

  function readBytes(addr, n)
    local t = {}
    for i = 0, n - 1 do
      local b = M.code[addr + i]
      if b == nil then b = M.values[addr + i] end
      if b == nil then return nil end
      t[#t + 1] = b
    end
    return t
  end
  function writeBytes(addr, bytes)
    for i, b in ipairs(bytes) do M.values[addr + i - 1] = b end
    return true
  end

  function allocateMemory() return M.nextAlloc end

  -- Understands just enough Auto Assembler to track writes into game code:
  -- "ADDR:" lines, "db" byte lists and a "jmp" (recorded as an E9 opcode).
  function autoAssemble(script)
    M.scripts[#M.scripts + 1] = script
    if M.aaFail then return false, "mock failure" end
    local pos
    for line in script:gmatch("[^\n]+") do
      local addr = line:match("^(%x+):$")
      if addr then
        pos = tonumber(addr, 16)
      elseif pos and M.code[pos] ~= nil then
        local db = line:match("^%s*db%s+(.+)$")
        if db then
          for byte in db:gmatch("%x%x") do
            M.code[pos] = tonumber(byte, 16)
            pos = pos + 1
          end
        elseif line:match("^%s*jmp") then
          M.code[pos] = 0xE9
          pos = pos + 5
        end
      end
    end
    return true
  end

  local function rd(addr) return M.values[addr] end
  local function wr(addr, v)
    if M.readonly[addr] then return false end
    M.values[addr] = v
    return true
  end
  function fullAccess(addr) M.readonly[addr] = nil end
  readPointer, writePointer = rd, wr
  readFloat, writeFloat = rd, wr
  readDouble, writeDouble = rd, wr
  readInteger, writeInteger = rd, wr

  function speedhack_setSpeed(v) M.speed = v; M.speedCalls = M.speedCalls + 1 end

  print = function(msg) M.logs[#M.logs + 1] = tostring(msg) end
end

function M.load(path)
  M.reset()
  install()
  _G.SpikeCrossTrainer = nil
  _G.SPIKE_CROSS_TEST = true
  return dofile(path)
end

function M.loggedContaining(text)
  for _, l in ipairs(M.logs) do
    if l:find(text, 1, true) then return true end
  end
  return false
end

return M
