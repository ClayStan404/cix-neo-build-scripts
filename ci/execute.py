#!/usr/bin/env python3
"""Execute a change-derived CIX build plan for Jenkins or a local CI worker."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Sequence

import plan


def dependency_closure(
    targets: set[str], forward: Mapping[str, frozenset[str]]
) -> set[str]:
    result = set(targets)
    pending = list(targets)
    while pending:
        target = pending.pop()
        for dependency in forward.get(target, frozenset()):
            if dependency not in result:
                result.add(dependency)
                pending.append(dependency)
    return result


def execute_target(
    workspace: Path, target: plan.Target, backend: str, resume: bool
) -> int:
    command = [str(workspace / "build-scripts" / "cix-build"), target.name]
    if target.builder == "debian":
        command.extend(("--backend", backend))
    if resume:
        command.append("--resume")
    print(f">>> CI execute: {' '.join(command)}", flush=True)
    return subprocess.run(command, cwd=workspace).returncode


def preflight_target(workspace: Path, target: plan.Target, backend: str) -> int:
    command = [
        str(workspace / "build-scripts" / "cix-build"),
        target.name,
        "--preflight-only",
    ]
    if target.builder == "debian":
        command.extend(("--backend", backend))
    print(f">>> CI preflight: {' '.join(command)}", flush=True)
    return subprocess.run(command, cwd=workspace).returncode


def preflight_plan(
    workspace: Path,
    build_map: plan.BuildMap,
    order: Sequence[str],
    backend: str,
) -> dict[str, int]:
    results = {}
    for name in order:
        status = preflight_target(workspace, build_map.targets[name], backend)
        results[name] = status
        if status != 0:
            break
    return results


def execute_plan(
    workspace: Path,
    build_map: plan.BuildMap,
    selected: set[str],
    backend: str,
    resume: bool,
    jobs: int,
) -> tuple[list[str], dict[str, int]]:
    graph = plan.build_dependency_graph(build_map)
    forward = plan.build_environment_forward(graph, build_map)
    expanded = dependency_closure(selected, forward)
    order = plan.topological_sort(expanded, forward)
    pending = set(order)
    completed: set[str] = set()
    results: dict[str, int] = {}

    while pending:
        ready = [
            target
            for target in order
            if target in pending
            and not ((set(forward.get(target, frozenset())) & expanded) - completed)
        ]
        if not ready:
            raise plan.PlanError("CI executor cannot find a dependency-ready target")
        batch = ready[:jobs]
        with ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = {
                executor.submit(
                    execute_target,
                    workspace,
                    build_map.targets[target],
                    backend,
                    resume,
                ): target
                for target in batch
            }
            for future in as_completed(futures):
                target = futures[future]
                status = future.result()
                results[target] = status
                pending.remove(target)
                if status == 0:
                    completed.add(target)
        failed = [target for target in batch if results[target] != 0]
        if failed:
            break
    return order, results


def package_targets(workspace: Path, targets: Sequence[str]) -> list[str]:
    """Return targets that produced repository-publishable Debian packages."""
    return [
        target
        for target in targets
        if any((workspace / "output" / target).glob("*.deb"))
    ]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("changes", nargs="*", help="Changed manifest projects or paths; stdin is used when omitted")
    result.add_argument("--backend", choices=("sbuild", "local"), default="sbuild")
    result.add_argument("--jobs", type=int, default=1, help="Maximum independent targets built concurrently")
    result.add_argument("--resume", action="store_true")
    result.add_argument("--apt-repo", type=Path, help="Publish successful .deb files to a new temporary APT repository")
    result.add_argument("--dry-run", action="store_true")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.jobs < 1:
        print("ERROR: --jobs must be positive", file=sys.stderr)
        return 2
    workspace = Path(__file__).resolve().parents[2]
    changes = args.changes or [line.strip() for line in sys.stdin if line.strip()]
    started = datetime.now(timezone.utc)
    report = {
        "version": 1,
        "started_at": started.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "finished_at": None,
        "duration_seconds": None,
        "status": "running",
        "backend": args.backend,
        "resume": args.resume,
        "jobs": args.jobs,
        "changes": changes,
        "seeds": [],
        "affected": [],
        "prerequisites": [],
        "order": [],
        "preflight_results": {},
        "results": {},
        "apt_repository": None,
    }
    try:
        build_map = plan.load_build_map(
            workspace / "build-scripts" / "build-map.yaml", workspace
        )
        selected_plan = plan.create_plan(changes, build_map)
        selected = set(selected_plan["affected"])
        graph = plan.build_dependency_graph(build_map)
        forward = plan.build_environment_forward(graph, build_map)
        expanded = dependency_closure(selected, forward)
        order = plan.topological_sort(expanded, forward) if expanded else []
        report.update(
            seeds=selected_plan["seeds"],
            affected=selected_plan["affected"],
            prerequisites=sorted(expanded - selected),
            order=order,
            reasons=selected_plan["reasons"],
        )
        if args.dry_run:
            finished = datetime.now(timezone.utc)
            report["status"] = "planned"
            report["finished_at"] = finished.replace(microsecond=0).isoformat().replace(
                "+00:00", "Z"
            )
            report["duration_seconds"] = int((finished - started).total_seconds())
            print(json.dumps(report, indent=2, sort_keys=True))
            return 0
        if order:
            preflight_results = preflight_plan(
                workspace, build_map, order, args.backend
            )
            report["preflight_results"] = preflight_results
            preflight_failed = [
                target for target, status in preflight_results.items() if status != 0
            ]
            if preflight_failed:
                raise RuntimeError(
                    "preflight failed: " + ", ".join(sorted(preflight_failed))
                )
            _, results = execute_plan(
                workspace, build_map, selected, args.backend, args.resume, args.jobs
            )
            report["results"] = results
            failed = [target for target, status in results.items() if status != 0]
            if failed:
                raise RuntimeError("build failed: " + ", ".join(sorted(failed)))
        published_targets = package_targets(workspace, order)
        if args.apt_repo and published_targets:
            destination = args.apt_repo
            if not destination.is_absolute():
                destination = workspace / destination
            command = [
                str(workspace / "build-scripts" / "ci" / "publish_apt.py"),
                "--output",
                str(destination),
                *published_targets,
            ]
            subprocess.run(command, cwd=workspace, check=True)
            try:
                report["apt_repository"] = destination.relative_to(workspace).as_posix()
            except ValueError:
                report["apt_repository"] = str(destination)
        report["status"] = "success"
    except (plan.PlanError, OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        report["status"] = "failed"
        report["error"] = str(exc)
    finally:
        finished = datetime.now(timezone.utc)
        report["finished_at"] = finished.replace(microsecond=0).isoformat().replace("+00:00", "Z")
        report["duration_seconds"] = int((finished - started).total_seconds())
        if not args.dry_run:
            report_root = workspace / "output" / "jenkins-reports"
            report_root.mkdir(parents=True, exist_ok=True)
            report_path = report_root / f"{started.strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}.json"
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print(f">>> Jenkins result: {report_path}")
    return 0 if report["status"] == "success" else 1


if __name__ == "__main__":
    raise SystemExit(main())
