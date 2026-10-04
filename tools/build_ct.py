#!/usr/bin/env python3
"""Pack src/TheSpikeCross.lua into TheSpikeCross.CT (a Cheat Engine table).

The table has no memory records; it only carries the Lua script, which
Cheat Engine offers to execute when the table is opened.

Usage:
    python3 tools/build_ct.py           # write TheSpikeCross.CT
    python3 tools/build_ct.py --check   # fail if TheSpikeCross.CT is out of date
"""
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "TheSpikeCross.lua"
OUT = ROOT / "TheSpikeCross.CT"


def render() -> str:
    lua = SRC.read_text(encoding="utf-8").replace("\r\n", "\n")
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<CheatTable CheatEngineTableVersion="42">\n'
        "  <CheatEntries/>\n"
        "  <LuaScript>" + escape(lua) + "</LuaScript>\n"
        "</CheatTable>\n"
    )


def main() -> int:
    content = render()
    if "--check" in sys.argv[1:]:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != content:
            print("TheSpikeCross.CT is out of date; run: python3 tools/build_ct.py")
            return 1
        print("TheSpikeCross.CT is up to date")
        return 0
    OUT.write_text(content, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
