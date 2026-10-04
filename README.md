# The Spike Cross: offline trainer for Cheat Engine

A Lua trainer for **The Spike Cross** (Steam, PC) that runs inside
Cheat Engine. It helps with grinding and single-player play: story mode and
training mode.

## Features

| Feature | Hotkey | What it does |
|---|---|---|
| Lock my stats | `F5` | Holds your player's Attack, Defense, Speed and Jump at a multiplier (default 1.5×) or at values you type in. |
| Weaker CPU opponents | `Num3` | Multiplies the opposing team's stats (default 0.6×). Never touches your own player. |
| Team stamina at max | `F6` | Keeps your team's stamina bar full. |
| Perfect timing | `Num1` | Widens the receive and spike timing windows (default 3×). |
| Skill gauge full | `Num2` | Keeps the skill gauge full. |
| Freeze match timer | `Num4` | Stops a match clock, if your stage has one. |
| ~~Match point / Score ±1~~ | – | **Off.** The game closes itself the instant its score is changed (tested with a single +1), so these buttons are disabled. The trainer does not try to get around that protection. |
| Speedhack | `F7`, `F8` / `F9` | Game speed from 0.25× to 5× (Cheat Engine speedhack). |
| Presets | – | Save and load your stat targets, multipliers and speed by name. |

Whenever a feature switches off, the in-match values it changed are put
back.

### What it does not do, and why

The Spike Cross is free-to-play with online PvP, gacha recruiting and paid
premium currency (which also buys gold for training). So the trainer
**does not** touch:

- gold, premium currency or recruiting,
- training, upgrade or breakthrough shortcuts,
- character, costume or skill unlocks,
- anything stored in your saved profile.

Those are paid items, and saved-profile changes carry over into online
matches against real players. It also makes no attempt to hide from
anti-cheat. Anti-cheat matters only online, and online play is outside this
tool's scope.

### The mode guard

Every feature is locked behind a **mode guard**. You configure it once with
the values that mean "story" and "training". If the current mode is not in
that list, or the guard is not set up or can't be read, every feature
switches off, the original values are restored, the trainer's code hooks are
removed, and game speed returns to 1.0. It fails closed: anything unknown
counts as "not offline". Nightmare Arena, Faction Battle, event and
leaderboard modes stay out of the list.

## Status

- **Implemented:** all features above, the window, hotkeys, the code-hook
  installer (records up to 16 objects per hook), groups, mode guard,
  presets, and `.CT` packaging.
- **Tested:** 35 logic tests against a mocked Cheat Engine API
  (`tests/run_tests.lua`, run in CI).
- **Checked in Cheat Engine:** the table loads, the window opens, the
  trainer attaches to `TheSpike-Cross.exe`, and re-running the script shuts
  the old copy down cleanly.
- **Not verified yet:** hooks, guard and features against the real game.
  **No addresses are filled in.** They have to be found on your machine with
  your game version. See the setup guide.

## Getting started

1. Install the latest [Cheat Engine](https://www.cheatengine.org/).
2. Follow **[docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)** to find the values
   and fill in `CONFIG` at the top of `src/TheSpikeCross.lua`.
3. Rebuild the table: `python3 tools/build_ct.py`.
4. Open `TheSpikeCross.CT` in Cheat Engine and allow its Lua script to run.
   A small trainer window opens. It attaches to `TheSpike-Cross.exe`
   automatically when the game starts.

Alternatively, skip step 3 and paste `src/TheSpikeCross.lua` into
**Table → Show Cheat Table Lua Script**, then click **Execute script**.

## Repository layout

```
src/TheSpikeCross.lua   the trainer (CONFIG is at the top)
TheSpikeCross.CT        cheat table carrying the script (generated)
docs/SETUP_GUIDE.md     step-by-step guide for finding every value
tools/build_ct.py       packs the Lua file into the .CT
tests/                  mocked Cheat Engine API + logic tests
```

## Development

```sh
lua5.3 tests/run_tests.lua          # logic tests (Cheat Engine uses Lua 5.3)
luac5.3 -p src/TheSpikeCross.lua    # syntax check
python3 tools/build_ct.py           # regenerate TheSpikeCross.CT
python3 tools/build_ct.py --check   # CI: is the .CT in sync?
```

Always edit `src/TheSpikeCross.lua`, not the `.CT`. The `.CT` is generated
from it.
