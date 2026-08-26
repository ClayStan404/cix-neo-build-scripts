#!/usr/bin/env python3
"""Validate the explicit migration ledger for legacy build entry points."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "legacy-build-map.yaml"
DEFAULT_BUILD_MAP = ROOT / "build-map.yaml"
ALLOWED_STATUSES = {"implemented", "partial", "pending", "blocked", "retired"}


class CoverageError(ValueError):
    """Raised when the legacy coverage ledger is inconsistent."""


def _load_yaml(path: Path) -> dict[str, Any]:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise CoverageError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise CoverageError(f"{path} must contain a YAML mapping")
    return value


def validate_ledger(
    ledger_path: Path = DEFAULT_LEDGER,
    build_map_path: Path = DEFAULT_BUILD_MAP,
    legacy_root: Path | None = None,
) -> Counter[str]:
    ledger = _load_yaml(ledger_path)
    build_map = _load_yaml(build_map_path)

    if ledger.get("version") != 1:
        raise CoverageError("legacy build map version must be 1")

    snapshot = ledger.get("snapshot")
    if not isinstance(snapshot, dict):
        raise CoverageError("snapshot must be a mapping")
    entrypoints = snapshot.get("entrypoints")
    if not isinstance(entrypoints, list) or not all(
        isinstance(entry, str) for entry in entrypoints
    ):
        raise CoverageError("snapshot.entrypoints must be a list of names")
    if entrypoints != sorted(entrypoints):
        raise CoverageError("snapshot.entrypoints must be sorted")
    if len(entrypoints) != len(set(entrypoints)):
        raise CoverageError("snapshot.entrypoints contains duplicates")
    if snapshot.get("entrypoint_count") != len(entrypoints):
        raise CoverageError("snapshot.entrypoint_count does not match the list")
    if any(
        Path(entry).name != entry
        or not entry.startswith("build-")
        or not entry.endswith(".sh")
        for entry in entrypoints
    ):
        raise CoverageError("snapshot contains an invalid build entry point name")

    default_status = ledger.get("default_status")
    if default_status not in ALLOWED_STATUSES:
        raise CoverageError(f"unsupported default_status: {default_status!r}")
    overrides = ledger.get("overrides", {})
    if not isinstance(overrides, dict):
        raise CoverageError("overrides must be a mapping")

    unknown_overrides = sorted(set(overrides) - set(entrypoints))
    if unknown_overrides:
        raise CoverageError(
            "override names are absent from the snapshot: "
            + ", ".join(unknown_overrides)
        )

    targets = build_map.get("targets", {})
    build_sets = build_map.get("build_sets", {})
    replacements = set(targets) | set(build_sets)
    counts: Counter[str] = Counter({default_status: len(entrypoints)})
    for entry, override in overrides.items():
        if not isinstance(override, dict):
            raise CoverageError(f"override for {entry} must be a mapping")
        status = override.get("status")
        if status not in ALLOWED_STATUSES:
            raise CoverageError(f"unsupported status for {entry}: {status!r}")
        counts[default_status] -= 1
        counts[status] += 1

        if status in {"implemented", "partial"}:
            replacement = override.get("replacement")
            if replacement not in replacements:
                raise CoverageError(
                    f"{status} entry {entry} has unknown replacement: "
                    f"{replacement!r}"
                )
            if status == "partial" and not override.get("reason"):
                raise CoverageError(f"partial entry {entry} must have a reason")
        elif status == "blocked" and not override.get("reason"):
            raise CoverageError(f"blocked entry {entry} must have a reason")
        elif status == "retired" and not override.get("reason"):
            raise CoverageError(f"retired entry {entry} must have a reason")

    if legacy_root is not None:
        pattern = snapshot.get("entrypoint_glob")
        if not isinstance(pattern, str) or not pattern:
            raise CoverageError("snapshot.entrypoint_glob must be a string")
        live_entrypoints = sorted(path.name for path in legacy_root.glob(pattern))
        missing = sorted(set(entrypoints) - set(live_entrypoints))
        added = sorted(set(live_entrypoints) - set(entrypoints))
        if missing or added:
            details = []
            if missing:
                details.append("removed: " + ", ".join(missing))
            if added:
                details.append("added: " + ", ".join(added))
            raise CoverageError("legacy entry point drift; " + "; ".join(details))

    return +counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--build-map", type=Path, default=DEFAULT_BUILD_MAP)
    parser.add_argument(
        "--legacy-root",
        type=Path,
        help="compare the snapshot with a checked-out legacy build-scripts directory",
    )
    args = parser.parse_args()

    try:
        counts = validate_ledger(args.ledger, args.build_map, args.legacy_root)
    except CoverageError as error:
        parser.error(str(error))

    print(json.dumps({"status": "ok", "counts": counts}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
