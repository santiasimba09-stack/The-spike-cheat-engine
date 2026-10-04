# Setup guide: finding the values

The trainer ships with every address empty because they can only be found on
your machine with your game version. This guide walks through finding each one
with Cheat Engine and putting it into `CONFIG` at the top of
`src/TheSpikeCross.lua`.

Do all of this in **story mode or training mode**. You never need to enter an
online match: the mode guard only needs to know which values mean "offline",
and everything else is blocked automatically.

Contents:

0. [About the game build](#0-about-the-game-build)
1. [The mode guard](#1-the-mode-guard) (required; nothing works without it)
2. [The players hook and groups](#2-the-players-hook-and-groups)
3. [Stats](#3-stats)
4. [The match object: score, team stamina, timer](#4-the-match-object-score-team-stamina-timer)
5. [Skill gauge](#5-skill-gauge)
6. [Perfect timing](#6-perfect-timing)
7. [Test it](#7-test-it)
8. [Presets](#8-presets)
9. [Troubleshooting](#9-troubleshooting)

---

## 0. About the game build

The Steam build of The Spike Cross is a **native (C++) game**, not Unity:
everything is in `TheSpike-Cross.exe` (about 129 MB), next to
`abseil_dll.dll`, `zlib1.dll` and the `.yytex` texture files. That means:

- the hooks scan **`TheSpike-Cross.exe`** (already set as `module` in
  `CONFIG.hooks`);
- there are no Mono or IL2CPP helpers; you work with plain addresses,
  offsets and the disassembler;
- `CONFIG.processName` is already `"TheSpike-Cross.exe"`.

Two Cheat Engine settings help:

- **Edit → Settings → Scan settings**: tick *MEM_PRIVATE* and *MEM_IMAGE*.
- **Dissect data/structures** can often show C++ class names (RTTI) for an
  object, e.g. `class Player` or `class MatchManager`. When you see
  them, they confirm you're looking at the right object.

Stats in this game, from its own help screen: **Attack** (called Strength
internally), **Defense**, **Speed** and **Jump**. Stamina is a **team bar**,
not a per-player value. A set is won at 25 points, with win-by-two up to a
**hard cap of 50**.

## 1. The mode guard

The guard is a value that tells which mode is running. Every feature stays
off until it matches one of your offline values.

### 1a. Which modes count as offline

Put these in `allowed`:

- **Story mode** (main and side chapters)
- **Training mode**

Keep these out. They feed rankings, event rewards or paid items, or involve
other players:

- online / ranked / friend matches
- **Nightmare Arena** (round time limit with paid extension tickets)
- **Faction Battle** and other events with points, contributions or
  leaderboards
- minigames with best records

### 1b. Find the mode value

1. Main menu → enter a **story** stage. Scan: **4 Bytes**, **Unknown initial
   value**.
2. Back out and enter **training**. Scan **Changed value**.
3. Enter story again. **Changed value**.
4. Stay in story for a while. **Unchanged value**, a few times.
5. Scan type **Value between…** `0` and `50`. Mode values are small
   integers.
6. Look for an address that shows a different, stable number for story and
   for training (e.g. story = 1, training = 2).
7. With the trainer closed, open the **online menu screen** (don't start a
   match) and check that the value there is **different** from your offline
   values. If it isn't, pick another candidate.

### 1b+. Test it right away (this session only)

Before making it permanent, you can point the running trainer at the address
you found. Paste this into the bottom box of Cheat Engine's **Lua Engine**
window (not into the table script) and click **Execute**. Use your own
address and values:

```lua
local g = SpikeCrossTrainer.CONFIG.guard
g.source     = { expr = "2DDFECDA598" }
g.type       = "int32"
g.allowed    = { 7, 2 }
g.names      = { [7] = "Story", [2] = "Training" }
g.sessionPid = SpikeCrossTrainer._state.pid
```

The trainer's second line should read **Offline mode: Story** (green) in
story and **Blocked: mode …** (red) in the menu. `sessionPid` makes the guard
expire if the game restarts, because a plain address like this one means
nothing in a new game process.

### 1c. Make it findable after a restart

Use a **pointer chain**: right-click the address → **Pointer scan for this
address**. Restart the game, find the address again, and use **Rescan
memory** in the pointer scanner to filter. Keep a short chain that
survives, e.g. `"TheSpike-Cross.exe"+01A2B3C0 → B8 → 30`:

```lua
guard = {
  source  = { expr = "[[TheSpike-Cross.exe+1A2B3C0]+B8]+30" },
  type    = "int32",
  allowed = { 1, 2 },
  names   = { [1] = "Story", [2] = "Training" },
},
```

(A hook source such as `{ hook = "match", offset = 0x.. }` works too, but a
pointer chain needs no code changes in the game, so prefer it for the
guard.)

## 2. The players hook and groups

The players hook records every player object the game works on during a
match. Groups then pick out **you** and the **CPU opponents**.

### 2a. Find your Attack value

1. Note your player's Attack on the stats screen, e.g. **63**.
2. Start a training match.
3. Scan **Float**, **Exact value** `63`. If nothing useful turns up, try
   **4 Bytes**, and also `630` or `6300` in case the game stores ×10 or ×100.
4. Usually several results remain: the saved profile copy and the in-match
   copy. For each one, right-click → **Find out what accesses this
   address**. The **in-match copy** is accessed constantly while the match
   runs, and the profile copy barely at all.

> You want the in-match copy. The trainer only edits that copy, puts the
> original back afterwards, and never touches your saved profile.

### 2b. Pick the instruction to hook

In the access list of the in-match copy, choose an instruction that:

- has a count that keeps climbing every frame;
- reads the value through a register plus an offset, e.g.
  `movss xmm0,[rcx+44]`. That gives you **register `rcx`** and Attack's
  **offset `0x44`**.

Right-click it → **Find out what addresses this instruction accesses**. The
right instruction lists **all six players** (one address per player); that
is exactly what the players hook wants.

Click **Show disassembler** on it, then generate a pattern with
**Tools → Auto Assemble → Template → AOB Injection** (accept the defaults):

```
aobscanmodule(INJECT,TheSpike-Cross.exe,F3 0F 10 41 44 8B C8 ...)   <- aob
...
code:
  movss xmm0,[rcx+44]     <- replaced instructions
  mov ecx,eax
```

- `aob` = the byte pattern from `aobscanmodule`.
- `offset` = `0` (the pattern starts at the instruction).
- `length` = the total size in bytes of the instructions under `code:`. The
  disassembler shows each instruction's bytes; add them up. It must be at
  least 5.

**Important:** the replaced instructions must not contain `jmp`, `call`,
`jcc` (conditional jumps) or `[rip+...]` operands. If they do, pick a
different instruction. Otherwise the game will crash.

Close the template without executing it; the trainer installs the hook
itself.

```lua
hooks = {
  players = { module = "TheSpike-Cross.exe", aob = "F3 0F 10 41 44 8B C8 ...",
              offset = 0, length = 7, register = "rcx" },
  ...
},
```

### 2c. Groups: you and the CPU opponents

1. From step 2b's address list, note **your** address and one **opponent's**
   address. Subtract Attack's offset (`0x44`) from each to get the object
   bases.
2. **Tools → Dissect data/structures**: add your base and the opponent's
   base, plus a **teammate's** base, as columns.
3. Look for two small integer fields:
   - one that is different **only for you**, e.g. "controlled by human" = 1
     (maybe a single byte);
   - one that is the **same for you and your teammates** and different for
     the opponents, e.g. team = 1 vs 2.

```lua
groups = {
  me  = { hook = "players", where = { offset = 0x1C, type = "byte",  equals = 1 } },
  cpu = { hook = "players", where = { offset = 0x20, type = "int32", equals = 2 } },
},
```

The trainer refuses to guess: if `me` matches more than one object it writes
nothing and says how many it saw. The CPU feature also always skips your own
player, even if the `cpu` filter is too loose.

## 3. Stats

All four stats live in the same player object. In the structure dissect view
of **your** object, find Defense, Speed and Jump by comparing with the stats
screen. Each one only needs its offset:

```lua
stats = {
  { key = "attack",  label = "Attack",  offset = 0x44, type = "float" },
  { key = "defense", label = "Defense", offset = 0x48, type = "float" },
  { key = "speed",   label = "Speed",   offset = 0x4C, type = "float" },
  { key = "jump",    label = "Jump",    offset = 0x50, type = "float" },
},
```

The same offsets are used for **your stats** (group `me`) and for **weaker
CPU opponents** (group `cpu`). Add `max = 99` (or the game's cap) to a stat
if very high values make the match behave strangely.

## 4. The match object: score, team stamina, timer

These usually live in one match or team object.

### Score

> **Skip this.** The Steam build closes itself the instant its score is
> changed (tested on 2026-10-04 with a single +1), so score editing is
> switched off in the trainer (`score.enabled = false`). The steps below are
> kept only for reference.

1. In a training match, scan **4 Bytes**, **Exact value** for your score.
   Score a point → **Exact value** with the new score.
2. Do the same for the opponent's score.
3. On your score, **Find out what accesses this address** and pick an
   instruction that runs every frame (the scoreboard draws it constantly).
   Hook it as `hooks.match`, exactly like step 2b. This instruction should
   only list **one** address.

```lua
hooks = {
  ...
  match = { module = "TheSpike-Cross.exe", aob = "...", offset = 0, length = 6, register = "rbx" },
},
score = {
  mine   = { hook = "match", offset = 0x20 },
  theirs = { hook = "match", offset = 0x24 },
  type   = "int32",
  target = 25,   -- change if a story stage plays to fewer points
  cap    = 50,
},
```

**Match point** sets your score one point short of winning: 24 in a normal
set, or one ahead of the opponent during deuce, never past 49.

### Team stamina

1. In a training match, scan **Float**, **Unknown initial value**.
2. Let your team receive a few hard balls (stamina drops) → **Decreased
   value**. Wait → **Unchanged** or **Increased**, depending on what the bar
   does.
3. The max is often right next to it. Check with structure dissect.
4. If it sits in the match object, it's another offset on the `match` hook:

```lua
{ key = "stamina", label = "Team stamina at max", hotkey = "VK_F6", restore = false,
  values = {
    { label = "Team stamina", source = { hook = "match", offset = 0x60 }, type = "float",
      mode = "max", max = { hook = "match", offset = 0x64 } },
  } },
```

No max field? Leave `max = nil` and set `maxValue = 100` (or whatever a full
bar reads).

### Match timer (only if your stage has one)

If a story or training match shows a clock, find it like stamina
(*Decreased value* while it counts down) and put it in the `timer` hold with
`mode = "freeze"`. Nightmare Arena's round limit is not reachable: that mode
stays out of the guard's allowed list.

## 5. Skill gauge

1. In a match, scan **Float** (or **4 Bytes**), **Unknown initial value**.
2. Let the gauge fill a bit → **Increased value**. Use the skill →
   **Decreased value**. Repeat.
3. If it's in your player object, use the `me` group; if it's per team, use
   the `match` hook:

```lua
{ key = "gauge", label = "Skill gauge full", hotkey = "VK_NUMPAD2", restore = false,
  values = {
    { label = "Skill gauge", source = { group = "me", offset = 0x90 }, type = "float",
      mode = "max", maxValue = 100 },
  } },
```

## 6. Perfect timing

This is the hardest one to find, because the game judges timing inside code
rather than storing a simple value. The usual approach is to widen the
**timing window** the game compares against:

1. Find a value that changes when you get a **PERFECT** receive: scan
   **4 Bytes**, **Unknown initial value**; do a perfect receive → **Changed**;
   a normal receive → **Changed**; nothing → **Unchanged**. The result is
   often a small enum (miss / good / perfect) or a "perfect" counter.
2. Right-click it → **Find out what writes to this address**. Open the
   writing instruction in the disassembler and scroll up a little. You're
   looking for a comparison against a constant, such as
   `comiss xmm0,[TheSpike-Cross.exe+2F1A40]`.
3. That constant is the timing window. Its address is fixed inside the exe,
   so use it as an expression and multiply it:

```lua
{ key = "timing", label = "Perfect timing", hotkey = "VK_NUMPAD1", restore = true,
  values = {
    { label = "Receive timing window", source = { expr = "TheSpike-Cross.exe+2F1A40" },
      type = "float", mode = "multiply", factor = 3 },
  } },
```

Do the same for spikes and serves if they use separate windows. Two notes:

- Some games share one constant for every player, so CPU players may get
  the wider window too. Pair it with **Weaker CPU opponents** if needed.
- `restore = true` puts the original window back when you switch it off.

## 7. Test it

1. Run `python3 tools/build_ct.py` to repack the table (or paste the Lua file
   into **Table → Show Cheat Table Lua Script** and click *Execute*).
2. Open `TheSpikeCross.CT` and allow the Lua script to run.
3. Start a story stage. The second line of the trainer window should read
   **Offline mode: Story** in green.
4. Enter a match and try one feature at a time, starting with stats
   (`F5`). The value columns show what the trainer sees ("2 seen", the
   current stamina, and so on).
5. After the match, open the stats screen. Your saved stats must be
   **unchanged**. If they changed, you hooked the profile copy; go back to
   step 2a.

## 8. Presets

The preset row at the bottom of the window saves your stat target boxes,
both multipliers and the game speed under a name. Type a name and press
**Save**; pick one and press **Load**. Presets are stored in
`%APPDATA%\TheSpikeCrossTrainer_presets.lua` (set `CONFIG.presets.file` to
put them elsewhere).

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Mode guard not configured" | `guard.source` or `guard.allowed` is still empty. |
| "waiting for hook 'players' (enter a match)" | The hooked instruction hasn't run yet. Normal outside a match. If it persists in a match, the instruction doesn't run every frame; pick another. |
| "6 objects in group 'me'; add a filter" | `groups.me.where` is missing or matches everyone (step 2c). |
| "no object in group 'cpu' yet" | The `cpu` filter matches nobody; check its offset and value. |
| "pattern matches N places" | Make the AOB longer (include more bytes after the instruction). |
| "pattern not found" | The game updated. Redo step 2b for that hook. |
| "code is already hooked" | Another table or an older script hooked it. Restart the game. |
| Game crashes when a feature turns on | The replaced instructions include a jump, call or `[rip+..]`. Choose another instruction. |
| Everything stopped after a game update | Patterns, offsets and pointer chains can move with updates. Redo the affected steps. |
