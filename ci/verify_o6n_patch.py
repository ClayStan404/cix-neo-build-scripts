#!/usr/bin/env python3
"""Reject O6N patches that reference PCDs missing from all DEC files."""

from __future__ import annotations

import re
import sys
from pathlib import Path


PCD = re.compile(r"\b(g[A-Za-z0-9]+TokenSpaceGuid\.Pcd[A-Za-z0-9_]+)\b")


def added_patch_lines(patch: Path) -> list[str]:
    return [
        line[1:]
        for line in patch.read_text(encoding="utf-8", errors="replace").splitlines()
        if line.startswith("+") and not line.startswith("+++")
    ]


def declarations(source_root: Path, patch: Path) -> set[str]:
    result: set[str] = set()
    for dec in source_root.rglob("*.dec"):
        result.update(PCD.findall(dec.read_text(encoding="utf-8", errors="replace")))

    current_file = ""
    for line in patch.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
        elif current_file.endswith(".dec") and line.startswith("+"):
            result.update(PCD.findall(line[1:]))
    return result


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_o6n_patch.py UEFI_SOURCE_ROOT PATCH")
    source_root = Path(sys.argv[1])
    patch = Path(sys.argv[2])
    referenced = set(PCD.findall("\n".join(added_patch_lines(patch))))
    missing = sorted(referenced - declarations(source_root, patch))
    if missing:
        for token in missing:
            print(f"ERROR: O6N patch references undeclared PCD: {token}", file=sys.stderr)
        return 1
    print(f"O6N patch PCD validation passed ({len(referenced)} referenced tokens)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
