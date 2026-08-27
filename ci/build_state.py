#!/usr/bin/env python3
"""Fingerprint build inputs and maintain resumable target/run state."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Iterable, Sequence

import plan


STATE_VERSION = 2
EXCLUDED_ARTIFACT_ROOTS = {"tests", "toolchain", "work"}


class StateError(RuntimeError):
    """A build-state operation cannot be completed safely."""


def _run(
    command: Sequence[str], *, cwd: Path | None = None, binary: bool = False
) -> str | bytes:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = ""
        if isinstance(exc, subprocess.CalledProcessError):
            detail = exc.stderr.decode(errors="replace").strip()
        raise StateError(f"command failed: {' '.join(command)}: {detail or exc}") from exc
    return result.stdout if binary else result.stdout.decode().strip()


def _atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def _read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise StateError(f"cannot read JSON state {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise StateError(f"JSON state is not an object: {path}")
    return value


def _sha256_artifact(path: Path) -> str:
    digest = hashlib.sha256()
    if path.is_symlink():
        digest.update(os.fsencode(os.readlink(path)))
        return digest.hexdigest()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _repository_signature(
    repository: Path, workspace: Path, paths: tuple[PurePosixPath, ...]
) -> dict:
    pathspecs = tuple(path.as_posix() for path in paths)
    tree = _run(
        ("git", "ls-tree", "-r", "-z", "HEAD", "--", *pathspecs),
        cwd=repository,
        binary=True,
    )
    assert isinstance(tree, bytes)
    diff = _run(
        ("git", "diff", "--binary", "HEAD", "--", *pathspecs),
        cwd=repository,
        binary=True,
    )
    assert isinstance(diff, bytes)
    untracked_output = _run(
        (
            "git",
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            *pathspecs,
        ),
        cwd=repository,
        binary=True,
    )
    assert isinstance(untracked_output, bytes)
    untracked = [item for item in untracked_output.split(b"\0") if item]
    digest = hashlib.sha256()
    digest.update(tree)
    digest.update(b"\0diff\0")
    digest.update(diff)
    for raw_name in sorted(untracked):
        relative = Path(os.fsdecode(raw_name))
        candidate = repository / relative
        digest.update(b"\0untracked\0")
        digest.update(raw_name)
        if candidate.is_file() and not candidate.is_symlink():
            digest.update(candidate.read_bytes())
        elif candidate.is_symlink():
            digest.update(os.readlink(candidate).encode())

    return {
        "path": repository.relative_to(workspace).as_posix(),
        "paths": list(pathspecs),
        "tree": hashlib.sha256(tree).hexdigest(),
        "dirty": bool(diff or untracked),
        "digest": digest.hexdigest(),
    }


def _project_paths(workspace: Path) -> tuple[PurePosixPath, ...]:
    project_list = workspace / ".repo" / "project.list"
    if not project_list.is_file():
        return ()
    return tuple(
        PurePosixPath(line.strip())
        for line in project_list.read_text(encoding="utf-8").splitlines()
        if line.strip()
    )


def _target_input_paths(target: plan.Target) -> tuple[PurePosixPath, ...]:
    values = {
        *(
            value
            for value in (
                target.source,
                target.source_git,
                target.debian,
                target.patch_source,
            )
            if value
        ),
    }
    values.update(overlay.split("=", 1)[0] for overlay in target.source_overlays)
    values.update(
        {
            "build-scripts/cix-build",
            "build-scripts/builders/common.sh",
            "build-scripts/builders/preflight.sh",
        }
    )
    if target.builder == "direct":
        values.update(
            {
                "build-scripts/builders/direct.sh",
                "build-scripts/builders/direct",
                "build-scripts/patches",
            }
        )
    else:
        values.update(
            {
                "build-scripts/builders/debian.sh",
                "build-scripts/builders/debian",
            }
        )
    return tuple(sorted(PurePosixPath(value) for value in values))


def _input_repositories(
    workspace: Path, target: plan.Target
) -> tuple[tuple[Path, tuple[PurePosixPath, ...]], ...]:
    inputs = _target_input_paths(target)
    candidates = set(_project_paths(workspace))
    candidates.update(PurePosixPath(value) for value in ("build-scripts", "debian"))
    selected: dict[Path, set[PurePosixPath]] = {}

    for candidate in candidates:
        matching_inputs = tuple(
            input_path
            for input_path in inputs
            if (
            candidate == input_path
            or candidate.is_relative_to(input_path)
            or input_path.is_relative_to(candidate)
            )
        )
        if not matching_inputs:
            continue
        repository = workspace / candidate
        if not repository.exists():
            continue
        try:
            root = Path(
                str(
                    _run(
                        ("git", "rev-parse", "--show-toplevel"),
                        cwd=repository,
                    )
                )
            ).resolve()
        except StateError:
            continue
        if root != workspace and not root.is_relative_to(workspace):
            continue
        for input_path in matching_inputs:
            input_absolute = (workspace / input_path).resolve()
            if root == input_absolute or root.is_relative_to(input_absolute):
                relative = PurePosixPath(".")
            elif input_absolute.is_relative_to(root):
                relative = PurePosixPath(input_absolute.relative_to(root).as_posix())
            else:
                continue
            selected.setdefault(root, set()).add(relative)

    if not selected:
        raise StateError(f"no Git inputs found for target {target.name}")
    result = []
    for repository, paths in sorted(selected.items()):
        if PurePosixPath(".") in paths:
            paths = {PurePosixPath(".")}
        result.append((repository, tuple(sorted(paths))))
    return tuple(result)


def _dependency_states(
    target: plan.Target,
    build_map: plan.BuildMap,
    state_root: Path,
) -> dict[str, str | None]:
    graph = plan.build_dependency_graph(build_map)
    providers = sorted(
        set(plan.build_environment_packages(target.name, graph, build_map).values())
    )
    result: dict[str, str | None] = {}
    for provider in providers:
        state_path = state_root / "targets" / f"{provider}.json"
        if not state_path.is_file():
            result[provider] = None
            continue
        try:
            result[provider] = _read_json(state_path).get("fingerprint")
        except StateError:
            result[provider] = None
    return result


def fingerprint(
    target_name: str,
    backend: str,
    workspace: Path,
    map_path: Path,
    state_root: Path,
) -> tuple[str, dict]:
    build_map = plan.load_build_map(map_path, workspace, check_paths=True)
    target = build_map.targets.get(target_name)
    if target is None:
        raise StateError(f"unknown build target: {target_name}")
    repositories = [
        _repository_signature(repository, workspace, paths)
        for repository, paths in _input_repositories(workspace, target)
    ]
    details = {
        "version": STATE_VERSION,
        "target": plan.target_dict(target),
        "backend": backend if target.builder == "debian" else "direct",
        "repositories": repositories,
        "dependencies": _dependency_states(target, build_map, state_root),
    }
    encoded = json.dumps(details, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest(), details


def _artifact_paths(output: Path) -> Iterable[Path]:
    if not output.is_dir():
        return ()
    return (
        path
        for path in sorted(output.rglob("*"))
        if (path.is_file() or path.is_symlink())
        and not path.relative_to(output).parts[0].startswith(".")
        and path.relative_to(output).parts[0] not in EXCLUDED_ARTIFACT_ROOTS
    )


def collect_artifacts(output: Path, workspace: Path) -> list[dict]:
    artifacts = []
    for artifact in _artifact_paths(output):
        metadata = artifact.lstat()
        artifacts.append(
            {
                "path": artifact.relative_to(workspace).as_posix(),
                "type": "symlink" if artifact.is_symlink() else "file",
                "mode": stat.S_IMODE(metadata.st_mode),
                "size": metadata.st_size,
                "sha256": _sha256_artifact(artifact),
            }
        )
    if not artifacts:
        raise StateError(f"target produced no publishable artifacts: {output}")
    return artifacts


def state_is_valid(
    state_path: Path, expected_fingerprint: str, workspace: Path
) -> tuple[bool, str]:
    if not state_path.is_file():
        return False, "state is missing"
    try:
        state = _read_json(state_path)
    except StateError as exc:
        return False, str(exc)
    if state.get("version") != STATE_VERSION:
        return False, "state version changed"
    if state.get("fingerprint") != expected_fingerprint:
        return False, "input fingerprint changed"
    artifacts = state.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        return False, "artifact inventory is missing"
    target = state.get("target")
    if (
        not isinstance(target, str)
        or not target
        or "/" in target
        or target in {".", ".."}
    ):
        return False, "state target is invalid"
    output = workspace / "output" / target
    output_relative = PurePosixPath("output") / target
    inventory_paths: set[str] = set()
    for entry in artifacts:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            return False, "artifact inventory is invalid"
        relative = PurePosixPath(entry["path"])
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or not relative.is_relative_to(output_relative)
        ):
            return False, "artifact inventory path is invalid"
        relative_string = relative.as_posix()
        if relative_string in inventory_paths:
            return False, f"artifact inventory contains a duplicate: {relative}"
        inventory_paths.add(relative_string)
        artifact = workspace / relative
        expected_type = entry.get("type")
        if expected_type not in {"file", "symlink"}:
            return False, f"artifact type is invalid: {entry['path']}"
        if artifact.is_symlink():
            actual_type = "symlink"
        elif artifact.is_file():
            actual_type = "file"
        else:
            return False, f"artifact is missing: {entry['path']}"
        if actual_type != expected_type:
            return False, f"artifact type changed: {entry['path']}"
        metadata = artifact.lstat()
        if stat.S_IMODE(metadata.st_mode) != entry.get("mode"):
            return False, f"artifact mode changed: {entry['path']}"
        if metadata.st_size != entry.get("size"):
            return False, f"artifact size changed: {entry['path']}"
        if _sha256_artifact(artifact) != entry.get("sha256"):
            return False, f"artifact digest changed: {entry['path']}"
    current_paths = {
        artifact.relative_to(workspace).as_posix()
        for artifact in _artifact_paths(output)
    }
    if current_paths != inventory_paths:
        added = sorted(current_paths - inventory_paths)
        removed = sorted(inventory_paths - current_paths)
        detail = []
        if added:
            detail.append("added " + ", ".join(added))
        if removed:
            detail.append("removed " + ", ".join(removed))
        return False, "artifact inventory changed: " + "; ".join(detail)
    return True, "state and artifacts match"


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def record_target(
    target: str,
    backend: str,
    fingerprint_value: str,
    details: dict,
    duration: int,
    log: Path,
    workspace: Path,
    state_root: Path,
) -> dict:
    output = workspace / "output" / target
    state = {
        "version": STATE_VERSION,
        "target": target,
        "backend": backend,
        "fingerprint": fingerprint_value,
        "inputs": details,
        "completed_at": _utc_now(),
        "duration_seconds": duration,
        "log": log.relative_to(workspace).as_posix(),
        "artifacts": collect_artifacts(output, workspace),
    }
    _atomic_json(state_root / "targets" / f"{target}.json", state)
    return state


def init_run(
    selector: str,
    action: str,
    backend: str,
    targets: list[str],
    workspace: Path,
    report_root: Path,
) -> Path:
    run_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}"
    run_dir = report_root / run_id
    report = {
        "version": STATE_VERSION,
        "selector": selector,
        "action": action,
        "backend": backend,
        "started_at": _utc_now(),
        "finished_at": None,
        "duration_seconds": None,
        "status": "running",
        "targets_requested": targets,
        "targets": [],
    }
    (run_dir / "logs").mkdir(parents=True, exist_ok=False)
    report_path = run_dir / "build-result.json"
    _atomic_json(report_path, report)
    return report_path.relative_to(workspace)


def update_run(
    report_path: Path,
    target: str,
    status: str,
    phase: str,
    duration: int,
    fingerprint_value: str | None,
    log: Path | None,
    workspace: Path,
    state_root: Path,
) -> None:
    report = _read_json(report_path)
    entry = {
        "target": target,
        "status": status,
        "phase": phase,
        "duration_seconds": duration,
        "fingerprint": fingerprint_value,
        "log": log.relative_to(workspace).as_posix() if log else None,
        "artifacts": [],
    }
    state_path = state_root / "targets" / f"{target}.json"
    if status in {"built", "resumed"} and state_path.is_file():
        entry["artifacts"] = _read_json(state_path).get("artifacts", [])
    entries = report.get("targets")
    if not isinstance(entries, list):
        raise StateError(f"run report target list is invalid: {report_path}")
    entries.append(entry)
    _atomic_json(report_path, report)


def finish_run(report_path: Path, status: str, duration: int) -> None:
    report = _read_json(report_path)
    report["status"] = status
    report["duration_seconds"] = duration
    report["finished_at"] = _utc_now()
    _atomic_json(report_path, report)


def _parser() -> argparse.ArgumentParser:
    script = Path(__file__).resolve()
    workspace = script.parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=workspace)
    parser.add_argument(
        "--map", dest="map_path", type=Path, default=script.parent.parent / "build-map.yaml"
    )
    parser.add_argument("--state-root", type=Path)
    parser.add_argument("--report-root", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)

    fingerprint_parser = subparsers.add_parser("fingerprint")
    fingerprint_parser.add_argument("target")
    fingerprint_parser.add_argument("--backend", choices=("sbuild", "local"), required=True)
    fingerprint_parser.add_argument("--details", action="store_true")

    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("target")
    check_parser.add_argument("--fingerprint", required=True)

    record_parser = subparsers.add_parser("record")
    record_parser.add_argument("target")
    record_parser.add_argument("--backend", required=True)
    record_parser.add_argument("--fingerprint", required=True)
    record_parser.add_argument("--duration", type=int, required=True)
    record_parser.add_argument("--log", type=Path, required=True)

    remove_parser = subparsers.add_parser("remove")
    remove_parser.add_argument("target")

    init_parser = subparsers.add_parser("run-init")
    init_parser.add_argument("--selector", required=True)
    init_parser.add_argument("--action", required=True)
    init_parser.add_argument("--backend", required=True)
    init_parser.add_argument("targets", nargs="+")

    update_parser = subparsers.add_parser("run-update")
    update_parser.add_argument("report", type=Path)
    update_parser.add_argument("--target", required=True)
    update_parser.add_argument(
        "--status", choices=("built", "resumed", "failed", "preflight"), required=True
    )
    update_parser.add_argument("--phase", choices=("preflight", "build"), required=True)
    update_parser.add_argument("--duration", type=int, required=True)
    update_parser.add_argument("--fingerprint")
    update_parser.add_argument("--log", type=Path)

    finish_parser = subparsers.add_parser("run-finish")
    finish_parser.add_argument("report", type=Path)
    finish_parser.add_argument("--status", choices=("success", "failed"), required=True)
    finish_parser.add_argument("--duration", type=int, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    workspace = args.workspace.resolve()
    map_path = args.map_path.resolve()
    state_root = (
        args.state_root.resolve()
        if args.state_root
        else workspace / "output" / ".cix-state"
    )
    report_root = (
        args.report_root.resolve()
        if args.report_root
        else workspace / "output" / "build-reports"
    )
    try:
        if args.command == "fingerprint":
            value, details = fingerprint(
                args.target, args.backend, workspace, map_path, state_root
            )
            print(json.dumps({"fingerprint": value, "inputs": details}, sort_keys=True) if args.details else value)
        elif args.command == "check":
            valid, reason = state_is_valid(
                state_root / "targets" / f"{args.target}.json",
                args.fingerprint,
                workspace,
            )
            print(reason)
            return 0 if valid else 1
        elif args.command == "record":
            value, details = fingerprint(
                args.target, args.backend, workspace, map_path, state_root
            )
            if value != args.fingerprint:
                raise StateError(
                    f"inputs changed while building {args.target}; refusing resumable state"
                )
            state = record_target(
                args.target,
                args.backend,
                value,
                details,
                args.duration,
                args.log.resolve(),
                workspace,
                state_root,
            )
            print(json.dumps(state, sort_keys=True))
        elif args.command == "remove":
            (state_root / "targets" / f"{args.target}.json").unlink(missing_ok=True)
        elif args.command == "run-init":
            print(
                init_run(
                    args.selector,
                    args.action,
                    args.backend,
                    args.targets,
                    workspace,
                    report_root,
                )
            )
        elif args.command == "run-update":
            report = args.report if args.report.is_absolute() else workspace / args.report
            update_run(
                report,
                args.target,
                args.status,
                args.phase,
                args.duration,
                args.fingerprint,
                args.log.resolve() if args.log else None,
                workspace,
                state_root,
            )
        elif args.command == "run-finish":
            report = args.report if args.report.is_absolute() else workspace / args.report
            finish_run(report, args.status, args.duration)
    except (StateError, plan.PlanError) as exc:
        sys.stderr.write(f"ERROR: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
