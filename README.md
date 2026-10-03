# The Spike Cross: offline trainer for Cheat Engine

A Lua trainer for **The Spike Cross** (Steam, PC) that runs inside
Cheat Engine. It helps with grinding and single-player play: story mode,
practice and matches against the CPU.

## Features

| Feature | Hotkey | What it does |
|---|---|---|
| Stat lock | `F5` | Holds your player's in-match stats at a multiplier (default 1.5×) or at values you type in. Releasing it writes the original values back. |
| Stamina lock | `F6` | Keeps stamina at max. |
| Speedhack | `F7`, `F8` / `F9` | Game speed from 0.25× to 5× (Cheat Engine speedhack). |
| Score | `F10` / `F11` | +1 to your score / −1 to the opponent's (never below 0). Buttons in the window do ±1 for both sides. |

### What it does not do, and why

The Spike Cross is free-to-play with online PvP and paid premium currency
(which also buys gold for training). So the trainer **does not** touch:

- gold or premium currency,
- training or upgrade shortcuts,
- character, costume or skill unlocks,
- anything stored in your saved profile.

Those are paid items, and saved-profile changes carry over into online
matches against real players.

### The mode guard

Every feature is locked behind a **mode guard**. You configure it once with
the values that mean "story", "practice" and so on. If the current mode is
not in that list, or the guard is not set up or can't be read, every feature
switches off, the original values are restored, the trainer's code hooks are
removed, and game speed returns to 1.0. It fails closed: anything unknown
counts as "not offline".

## Status

- **Implemented:** trainer logic, UI, hotkeys, code-hook installer, mode
  guard, `.CT` packaging.
- **Tested:** logic tests against a mocked Cheat Engine API
  (`tests/run_tests.lua`, run in CI).
- **Not verified:** nothing has been run inside Cheat Engine or against the
  game yet. **No addresses are filled in.** They have to be found on your
  machine with your game version. See the setup guide.

## Getting started

1. Install [Cheat Engine](https://www.cheatengine.org/) 7.5 or newer.
2. Follow **[docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)** to find the values
   and fill in `CONFIG` at the top of `src/TheSpikeCross.lua`.
3. Rebuild the table: `python3 tools/build_ct.py`.
4. Open `TheSpikeCross.CT` in Cheat Engine and allow its Lua script to run.
   A small trainer window opens. It attaches to the game automatically when
   the game starts.

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
