#!/usr/bin/env python3
"""Make generated HDL snapshots independent of the machine that generated them.

HDL Coder writes the absolute path of its output directory into every file it
emits (the `// File Name:` header of each Verilog file, and paths inside
hdlcodegenstatus.json and the HTML reports). Those paths describe the
generating workstation, not the design: they leak local directory layout and
make two otherwise identical snapshots differ. This rewrites every absolute
path that ends in a target directory under fpga/generated/<target>/ to the
repository-relative path, with forward slashes. The HDL itself is untouched.

    python tools/normalize_generated_hdl.py            # rewrite in place
    python tools/normalize_generated_hdl.py --check    # exit 1 if any absolute path remains

Run it after model/simulink/run_hdl_generation.m, before committing a new
snapshot. tests/test_generated_hdl_paths.py runs the check in CI.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GENERATED = ROOT / "fpga" / "generated"
TEXT_SUFFIXES = {".v", ".vhd", ".json", ".html", ".htm", ".js", ".m", ".txt", ".do", ".tcl", ".xml"}
SEP = r"(?:\\\\|\\|/)"
# A Windows drive path or a POSIX home/tmp path, up to the target directory.
ABSOLUTE = r"(?:[A-Za-z]:" + SEP + r"|/(?:home|tmp|Users|mnt)/)"


def target_pattern(target: str) -> re.Pattern[str]:
    return re.compile(ABSOLUTE + r"[^\"'\n<>|]*?" + SEP + re.escape(target) + r"(?P<rest>(?:" + SEP
                      + r"[^\"'\n<>| ]*)?)")


def normalize_text(text: str, target: str) -> str:
    pattern = target_pattern(target)

    def repl(m: re.Match[str]) -> str:
        rest = re.sub(SEP, "/", m.group("rest"))
        return f"fpga/generated/{target}{rest}"

    return pattern.sub(repl, text)


def files() -> list[tuple[Path, str]]:
    out = []
    for target_dir in sorted(p for p in GENERATED.iterdir() if p.is_dir()):
        for f in sorted(target_dir.rglob("*")):
            if f.is_file() and f.suffix.lower() in TEXT_SUFFIXES:
                out.append((f, target_dir.name))
    return out


def absolute_paths(text: str) -> list[str]:
    return re.findall(r"(?:[A-Za-z]:(?:\\\\|\\)[^\s\"'<>]+|/(?:home|Users|mnt)/[^\s\"'<>]+)", text)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true", help="only report files that still hold absolute paths")
    args = ap.parse_args()
    changed, offending = 0, []
    for f, target in files():
        text = f.read_text(encoding="utf-8", errors="surrogateescape")
        if args.check:
            hits = absolute_paths(text)
            if hits:
                offending.append((f, hits[0]))
            continue
        new = normalize_text(text, target)
        if new != text:
            f.write_text(new, encoding="utf-8", errors="surrogateescape", newline="")
            changed += 1
    if args.check:
        for f, hit in offending:
            print(f"{f.relative_to(ROOT).as_posix()}: {hit[:100]}")
        return 1 if offending else 0
    print(f"normalized {changed} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
