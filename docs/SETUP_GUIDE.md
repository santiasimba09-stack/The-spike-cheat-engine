# Setup guide: finding the values

The trainer ships with every address empty because they can only be found on
your machine with your game version. This guide walks through finding each one
with Cheat Engine and putting it into `CONFIG` at the top of
`src/TheSpikeCross.lua`.

Do all of this in **story mode or practice / vs CPU**. You never need to enter
an online match: the mode guard only needs to know which values mean
"offline", and everything else is blocked automatically.

Contents:

0. [Preparation](#0-preparation)
1. [Your player's stats (the capture hook)](#1-your-players-stats-the-capture-hook)
2. [The mode guard](#2-the-mode-guard)
3. [Stamina](#3-stamina)
4. [Score](#4-score)
5. [Test it](#5-test-it)
6. [Troubleshooting](#6-troubleshooting)

---

## 0. Preparation

1. **Find out how the game was built.** Open the game folder (Steam → right-click
   the game → Manage → Browse local files):
   - `GameAssembly.dll` and a `..._Data/il2cpp_data` folder → **Unity IL2CPP**.
     Keep `module = "GameAssembly.dll"` in the hooks.
   - `..._Data/Managed/Assembly-CSharp.dll` → **Unity Mono**. Set
     `module = nil` in the hooks (Mono code is generated at runtime, outside any
     module). Cheat Engine's **Mono → Dissect mono** menu can then show you
     class and field names directly, which makes steps 1–4 much easier.
   - Neither → tell me what you see, and we'll adapt.
2. **Process name.** With the game running, open Cheat Engine's process list
   and note the exact `.exe` name. Put it in `CONFIG.processName`
   (for example `"TheSpikeCross.exe"`). Auto-detect works too, but the exact
   name avoids attaching to a launcher.
3. In Cheat Engine: **Edit → Settings → Scan settings** → tick
   *MEM_PRIVATE*, *MEM_IMAGE* and *MEM_MAPPED*. Unity keeps a lot of data in
   mapped memory.

## 1. Your player's stats (the capture hook)

There are usually **two copies** of each stat: the saved profile value (shown
on the stats or training screen) and the in-match copy the gameplay code
reads every frame. You want the **in-match copy**. The trainer only edits that
copy and puts the original back afterwards, so nothing reaches your saved
profile.

### 1a. Find a stat address

1. Look up one stat on the stats screen, for example Spike = **63**.
2. Start a practice match.
3. Cheat Engine: *Value type* **Float**, *Scan type* **Exact value**, value `63`,
   **First Scan**. If nothing useful turns up, repeat with **4 Bytes**. Some
   games store stats ×10 or ×100, so also try `630`. If the stat is shown as a
   bar, use **Unknown initial value** and refine with *Unchanged* scans.
4. Usually several results remain. For each candidate, right-click →
   **Find out what accesses this address**:
   - the **in-match copy** gets a list of instructions whose counts climb
     constantly while the match runs;
   - the profile copy is barely touched.

### 1b. Pick the instruction to hook

From the access list of the in-match copy, choose an instruction that:

- has a count that keeps rising every frame;
- reads the stat through a register plus an offset, e.g.
  `movss xmm0,[rcx+44]`. That gives you **register = `rcx`** and the
  stat's **offset = `0x44`**.

Click **Show disassembler** on it, then generate a pattern with
**Tools → Auto Assemble → Template → AOB Injection** (accept the defaults).
The template contains:

```
aobscanmodule(INJECT,GameAssembly.dll,F3 0F 10 41 44 8B C8 ...)   <- aob
...
code:
  movss xmm0,[rcx+44]     <- replaced instructions
  mov ecx,eax
```

- `aob` = the byte pattern from `aobscanmodule`.
- `offset` = `0` (the pattern starts at the instruction).
- `length` = the total size in bytes of the instructions listed under `code:`.
  The disassembler shows each instruction's bytes; add them up. It must be
  at least 5.

**Important:** the replaced instructions must not contain `jmp`, `call`,
`jcc` (conditional jumps) or `[rip+...]` operands. If they do, pick a
different instruction. Otherwise the game will crash.

Close the template without executing it. The trainer installs the hook
itself.

### 1c. Make sure only *your* player is captured

The same instruction often reads the stats of all six players. Right-click
the instruction → **Find out what addresses this instruction accesses**. If
several addresses appear, you need a filter:

1. Note two addresses: yours (the one from step 1a) and a CPU player's.
   Subtract the stat offset from each to get the two object bases.
2. **Tools → Dissect data/structures**, add both bases as columns and
   compare them. Look for a small integer that is different for your player:
   a team id, a "controlled by human" flag, or a controller index.
3. Use it as the filter, e.g. if offset `0x1C` is `1` for you and `0` for
   CPU players:

```lua
filter = { offset = 0x1C, size = "dword", equals = 1 },
```

Use `size = "byte"` if the field is a single byte (a boolean).

### 1d. The other stats

All your stats normally live in the same object. In the structure dissect
view of **your** object, find the other stats by comparing them with the
stats screen. Each one only needs its offset:

```lua
hooks = {
  player = { module = "GameAssembly.dll", aob = "F3 0F 10 41 44 8B C8 ...",
             offset = 0, length = 7, register = "rcx",
             filter = { offset = 0x1C, size = "dword", equals = 1 } },
  ...
},
stats = {
  { key = "spike", label = "Spike", source = { hook = "player", offset = 0x44 }, type = "float" },
  { key = "serve", label = "Serve", source = { hook = "player", offset = 0x48 }, type = "float" },
  ...
},
```

Remove entries you can't find, and add `max = 99` (or whatever the game's
cap is) if very high values make the match behave strangely.

> **IL2CPP shortcut:** tools like Il2CppDumper can produce a `dump.cs`
> listing classes and field offsets (e.g. `public float spikePower; // 0x44`).
> That gives you the offsets by name and makes 1d nearly instant.

## 2. The mode guard

The guard is a value that tells which mode is running. Every feature stays
off until it matches one of your offline values.

### 2a. Find the mode value

1. Main menu → enter **story mode**. Scan: **4 Bytes**, **Unknown initial
   value**.
2. Back out and enter **practice**. Scan **Changed value**.
3. Enter story again. **Changed value**.
4. Stay in story mode for a while. **Unchanged value** a few times.
5. Scan type **Value between…** `0` and `50`. Real mode values are small
   integers.
6. Look for an address showing a different, stable number for each offline
   mode (e.g. story = 1, practice = 2, vs CPU = 4).
7. With the trainer closed, open the **online menu screen** (don't start a
   match). Check that the value there is **different** from all your offline
   values. If it isn't, pick another candidate.

### 2b. Make it findable after a restart

Either:

- **Pointer chain** (preferred for the guard; no code hook needed):
  right-click the address → **Pointer scan for this address**. Restart the
  game, find the address again, and use **Rescan memory** in the pointer
  scanner to filter. Take a short surviving chain, e.g.
  `"GameAssembly.dll"+01A2B3C0 → B8 → 30`, and write it as
  `{ expr = "[[GameAssembly.dll+1A2B3C0]+B8]+30" }`.
- **A second hook** (`hooks.match`) on an instruction that reads the mode
  every frame, exactly like step 1b, with `source = { hook = "match", offset = 0x.. }`.

```lua
guard = {
  source  = { expr = "[[GameAssembly.dll+1A2B3C0]+B8]+30" },
  type    = "int32",
  allowed = { 1, 2, 4 },
  names   = { [1] = "Story", [2] = "Practice", [4] = "vs CPU" },
},
```

## 3. Stamina

1. In a practice match, scan **Float**, **Unknown initial value**.
2. Use stamina (sprint or jump) → **Decreased value**. Rest → **Increased
   value**. Repeat until a few remain.
3. Max stamina is usually right next to it in the same object. Check with
   structure dissect.
4. If it's in your player object, it's just another offset on the `player`
   hook:

```lua
stamina = {
  current = { hook = "player", offset = 0x60 },
  max     = { hook = "player", offset = 0x64 },
  type    = "float",
},
```

If there's no max field, leave `max = nil` and set `maxValue = 100` (or the
full value you saw).

## 4. Score

1. In a match vs CPU, scan **4 Bytes**, **Exact value** for your current
   score. Score a point → **Exact value** with the new score.
2. Do the same for the opponent.
3. Both scores usually sit in one match object. Use the `match` hook (step
   1b, on an instruction that reads the score) or a pointer chain (step 2b).

```lua
score = {
  mine   = { hook = "match", offset = 0x20 },
  theirs = { hook = "match", offset = 0x24 },
  type   = "int32",
},
```

## 5. Test it

1. Run `python3 tools/build_ct.py` to repack the table (or paste the Lua file
   into **Table → Show Cheat Table Lua Script** and click *Execute*).
2. Open `TheSpikeCross.CT` and allow the Lua script to run.
3. Start story mode. The second line of the trainer window should read
   **Offline mode: Story** in green.
4. Enter a match, then try each feature one at a time, starting with stats
   (`F5`).
5. After the match, open the stats screen. Your saved stats must be
   **unchanged**. If they changed, you hooked the profile copy instead of the
   in-match copy; go back to step 1a.

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Mode guard not configured" | `guard.source` or `guard.allowed` is still empty. |
| "waiting for hook 'player' (enter a match)" | The hooked instruction hasn't run yet. Normal outside a match. If it persists in a match, the instruction doesn't run every frame; pick another. |
| "pattern matches N places" | Make the AOB longer (include more bytes after the instruction). |
| "pattern not found" | The game updated, or `module` is wrong (use `nil` for Mono). Re-do step 1b. |
| "code is already hooked" | Another table or an older script hooked it. Restart the game. |
| Game crashes when a feature turns on | The replaced instructions include a jump, call or `[rip+..]`. Choose another instruction. |
| Values affect a CPU player | Missing or wrong `filter` (step 1c). |
| Everything stopped after a game update | Byte patterns and offsets can move with updates. Redo the affected steps. |
