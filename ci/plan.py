#!/usr/bin/env python3
"""Create a CI build plan from changed repo projects and Debian metadata.

Input consists of one change per line. Each line can be one of:

* a manifest project name, which marks the whole project as changed;
* ``PROJECT:relative/path``;
* a path relative to the repo workspace.

The mapping file selects seed build targets. Internal build dependencies are
derived exclusively from Debian Build-Depends fields, never from build scripts.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable, Mapping, Sequence

try:
    import yaml
    from debian.deb822 import Deb822, PkgRelation
except ImportError as exc:  # pragma: no cover - exercised by host setup checks
    sys.stderr.write(
        "ERROR: plan.py requires the Debian packages python3-yaml and "
        f"python3-debian: {exc}\n"
    )
    raise SystemExit(2) from exc


class PlanError(RuntimeError):
    """A mapping, Debian metadata, or dependency graph error."""


@dataclass(frozen=True)
class Target:
    name: str
    script: str
    control: str | None


@dataclass(frozen=True)
class Rule:
    paths: tuple[str, ...]
    targets: tuple[str, ...]


@dataclass(frozen=True)
class Project:
    name: str
    path: str
    rules: tuple[Rule, ...]
    ignore: tuple[str, ...]


@dataclass(frozen=True)
class BuildMap:
    workspace: Path
    targets: Mapping[str, Target]
    projects: Mapping[str, Project]


@dataclass(frozen=True)
class DependencyGraph:
    forward: Mapping[str, frozenset[str]]
    reverse: Mapping[str, frozenset[str]]
    edge_packages: Mapping[tuple[str, str], frozenset[str]]
    produced_packages: Mapping[str, str]


def _mapping(value: object, context: str) -> dict:
    if not isinstance(value, dict):
        raise PlanError(f"{context} must be a mapping")
    return value


def _string(value: object, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PlanError(f"{context} must be a non-empty string")
    return value.strip()


def _string_list(value: object, context: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise PlanError(f"{context} must be a non-empty list")
    return tuple(_string(item, f"{context} entry") for item in value)


def _relative_path(value: object, context: str) -> str:
    raw = _string(value, context)
    path = PurePosixPath(raw)
    if path.is_absolute() or ".." in path.parts:
        raise PlanError(f"{context} must stay inside the workspace: {raw}")
    return path.as_posix().rstrip("/")


def load_build_map(map_path: Path, workspace: Path, check_paths: bool = True) -> BuildMap:
    try:
        raw = yaml.safe_load(map_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise PlanError(f"cannot read mapping file {map_path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise PlanError(f"invalid YAML in {map_path}: {exc}") from exc

    root = _mapping(raw, "mapping root")
    if root.get("version") != 1:
        raise PlanError("mapping version must be 1")

    target_data = _mapping(root.get("targets"), "targets")
    targets: dict[str, Target] = {}
    for target_name, value in target_data.items():
        name = _string(target_name, "target name")
        entry = _mapping(value, f"target {name}")
        script = _relative_path(entry.get("script"), f"target {name} script")
        control_value = entry.get("control")
        control = (
            _relative_path(control_value, f"target {name} control")
            if control_value is not None
            else None
        )
        targets[name] = Target(name=name, script=script, control=control)

    if not targets:
        raise PlanError("targets must not be empty")

    project_data = _mapping(root.get("projects"), "projects")
    projects: dict[str, Project] = {}
    project_paths: dict[str, str] = {}
    mapped_targets: set[str] = set()

    for project_name, value in project_data.items():
        name = _string(project_name, "project name")
        entry = _mapping(value, f"project {name}")
        path = _relative_path(entry.get("path"), f"project {name} path")
        if path in project_paths:
            raise PlanError(
                f"projects {project_paths[path]} and {name} use the same path: {path}"
            )
        project_paths[path] = name

        raw_rules = entry.get("rules", [])
        if not isinstance(raw_rules, list):
            raise PlanError(f"project {name} rules must be a list")
        rules: list[Rule] = []
        for index, rule_value in enumerate(raw_rules):
            rule_data = _mapping(rule_value, f"project {name} rule {index}")
            patterns = _string_list(
                rule_data.get("paths"), f"project {name} rule {index} paths"
            )
            rule_targets = _string_list(
                rule_data.get("targets"), f"project {name} rule {index} targets"
            )
            unknown = sorted(set(rule_targets) - set(targets))
            if unknown:
                raise PlanError(
                    f"project {name} rule {index} references unknown targets: "
                    + ", ".join(unknown)
                )
            mapped_targets.update(rule_targets)
            rules.append(Rule(paths=patterns, targets=rule_targets))

        raw_ignore = entry.get("ignore", [])
        if not isinstance(raw_ignore, list):
            raise PlanError(f"project {name} ignore must be a list")
        ignore = tuple(
            _string(pattern, f"project {name} ignore entry") for pattern in raw_ignore
        )
        if not rules and not ignore:
            raise PlanError(f"project {name} must have rules or explicit ignore entries")
        projects[name] = Project(name=name, path=path, rules=tuple(rules), ignore=ignore)

    unmapped = sorted(set(targets) - mapped_targets)
    if unmapped:
        raise PlanError("targets are not referenced by any project: " + ", ".join(unmapped))

    workspace = workspace.resolve()
    if check_paths:
        for target in targets.values():
            script_path = workspace / target.script
            if not script_path.is_file():
                raise PlanError(f"target {target.name} script does not exist: {script_path}")
            if not os.access(script_path, os.X_OK):
                raise PlanError(f"target {target.name} script is not executable: {script_path}")
            if target.control:
                control_path = workspace / target.control
                if not control_path.is_file():
                    raise PlanError(
                        f"target {target.name} control does not exist: {control_path}"
                    )
        for project in projects.values():
            project_path = workspace / project.path
            if not project_path.is_dir():
                raise PlanError(f"project path does not exist: {project_path}")

    return BuildMap(workspace=workspace, targets=targets, projects=projects)


def _relation_names(value: str, context: str) -> set[str]:
    # Debian permits a trailing comma in relationship fields. python-debian
    # accepts it but emits an unnecessary warning for the empty final item.
    value = value.strip().rstrip(",").rstrip()
    if not value:
        return set()
    try:
        relations = PkgRelation.parse_relations(value)
    except Exception as exc:
        raise PlanError(f"cannot parse {context}: {exc}") from exc
    return {
        alternative["name"]
        for group in relations
        for alternative in group
        if alternative.get("name")
    }


def _parse_control(control_path: Path) -> tuple[set[str], set[str]]:
    try:
        with control_path.open(encoding="utf-8") as stream:
            paragraphs = list(Deb822.iter_paragraphs(stream))
    except OSError as exc:
        raise PlanError(f"cannot read Debian control {control_path}: {exc}") from exc

    if not paragraphs or "Source" not in paragraphs[0]:
        raise PlanError(f"Debian control has no Source stanza: {control_path}")

    source = paragraphs[0]
    produced: set[str] = set()
    for paragraph in paragraphs[1:]:
        package = paragraph.get("Package")
        if package:
            produced.add(package.strip())
        provides = paragraph.get("Provides")
        if provides:
            produced.update(_relation_names(provides, f"Provides in {control_path}"))

    if not produced:
        raise PlanError(f"Debian control defines no binary packages: {control_path}")

    build_dependencies: set[str] = set()
    for field in ("Build-Depends", "Build-Depends-Arch", "Build-Depends-Indep"):
        value = source.get(field)
        if value:
            build_dependencies.update(
                _relation_names(value, f"{field} in {control_path}")
            )
    return produced, build_dependencies


def build_dependency_graph(build_map: BuildMap) -> DependencyGraph:
    produced_by_target: dict[str, set[str]] = defaultdict(set)
    dependencies_by_target: dict[str, set[str]] = defaultdict(set)
    provider: dict[str, str] = {}

    for target in build_map.targets.values():
        if not target.control:
            continue
        control_path = build_map.workspace / target.control
        produced, dependencies = _parse_control(control_path)
        produced_by_target[target.name].update(produced)
        dependencies_by_target[target.name].update(dependencies)
        for package in produced:
            previous = provider.get(package)
            if previous and previous != target.name:
                raise PlanError(
                    f"internal package {package} is produced by both {previous} and "
                    f"{target.name}"
                )
            provider[package] = target.name

    forward: dict[str, set[str]] = {
        target_name: set() for target_name in build_map.targets
    }
    reverse: dict[str, set[str]] = {
        target_name: set() for target_name in build_map.targets
    }
    edge_packages: dict[tuple[str, str], set[str]] = defaultdict(set)

    for dependent, package_names in dependencies_by_target.items():
        for package in package_names:
            dependency = provider.get(package)
            if not dependency or dependency == dependent:
                continue
            forward[dependent].add(dependency)
            reverse[dependency].add(dependent)
            edge_packages[(dependent, dependency)].add(package)

    frozen_forward = {key: frozenset(value) for key, value in forward.items()}
    frozen_reverse = {key: frozenset(value) for key, value in reverse.items()}
    graph = DependencyGraph(
        forward=frozen_forward,
        reverse=frozen_reverse,
        edge_packages={key: frozenset(value) for key, value in edge_packages.items()},
        produced_packages=dict(provider),
    )
    topological_sort(set(build_map.targets), graph.forward)
    return graph


def _matches(path: str, pattern: str) -> bool:
    normalized = path.lstrip("./")
    normalized_pattern = pattern.lstrip("./")
    if normalized_pattern == "**":
        return True
    if normalized_pattern.endswith("/**"):
        prefix = normalized_pattern[:-3].rstrip("/")
        if normalized == prefix or normalized.startswith(prefix + "/"):
            return True
    return fnmatch.fnmatchcase(normalized, normalized_pattern)


def _resolve_change(change: str, build_map: BuildMap) -> tuple[Project, str | None]:
    if change in build_map.projects:
        return build_map.projects[change], None

    for project_name, project in build_map.projects.items():
        prefix = project_name + ":"
        if change.startswith(prefix):
            relative = change[len(prefix) :]
            if not relative:
                return project, None
            path = PurePosixPath(relative)
            if path.is_absolute() or ".." in path.parts:
                raise PlanError(
                    f"change path must stay inside project {project_name}: {relative}"
                )
            normalized = path.as_posix()
            return project, None if normalized == "." else normalized

    workspace_path = PurePosixPath(change)
    if workspace_path.is_absolute() or ".." in workspace_path.parts:
        raise PlanError(f"change path must stay inside the workspace: {change}")
    normalized = workspace_path.as_posix().lstrip("./")
    candidates = sorted(
        build_map.projects.values(), key=lambda item: len(item.path), reverse=True
    )
    for project in candidates:
        if normalized == project.path:
            return project, None
        prefix = project.path + "/"
        if normalized.startswith(prefix):
            return project, normalized[len(prefix) :]
    raise PlanError(f"change does not belong to a mapped project: {change}")


def map_changes(
    changes: Iterable[str], build_map: BuildMap
) -> tuple[set[str], dict[str, list[str]], list[str]]:
    seeds: set[str] = set()
    reasons: dict[str, list[str]] = defaultdict(list)
    normalized_changes: list[str] = []

    for raw_change in changes:
        change = raw_change.strip()
        if not change or change.startswith("#"):
            continue
        project, relative = _resolve_change(change, build_map)
        normalized_changes.append(
            project.name if relative is None else f"{project.name}:{relative}"
        )

        if relative is None:
            matched_targets = {
                target for rule in project.rules for target in rule.targets
            }
            for target in sorted(matched_targets):
                seeds.add(target)
                reasons[target].append(f"project changed: {project.name}")
            continue

        matched_targets: set[str] = set()
        for rule in project.rules:
            if any(_matches(relative, pattern) for pattern in rule.paths):
                matched_targets.update(rule.targets)
        ignored = any(_matches(relative, pattern) for pattern in project.ignore)

        if matched_targets and ignored:
            raise PlanError(
                f"change matches both a build rule and ignore rule: {project.name}:{relative}"
            )
        if not matched_targets and not ignored:
            raise PlanError(f"unmapped change: {project.name}:{relative}")
        for target in sorted(matched_targets):
            seeds.add(target)
            reasons[target].append(f"path changed: {project.name}:{relative}")

    return seeds, reasons, normalized_changes


def reverse_closure(seeds: set[str], graph: DependencyGraph) -> set[str]:
    affected = set(seeds)
    queue = deque(sorted(seeds))
    while queue:
        dependency = queue.popleft()
        for dependent in sorted(graph.reverse.get(dependency, ())):
            if dependent not in affected:
                affected.add(dependent)
                queue.append(dependent)
    return affected


def topological_sort(nodes: set[str], forward: Mapping[str, frozenset[str]]) -> list[str]:
    indegree = {node: 0 for node in nodes}
    dependents: dict[str, set[str]] = defaultdict(set)
    for dependent in nodes:
        for dependency in forward.get(dependent, ()):
            if dependency in nodes:
                indegree[dependent] += 1
                dependents[dependency].add(dependent)

    ready = sorted(node for node, count in indegree.items() if count == 0)
    order: list[str] = []
    while ready:
        node = ready.pop(0)
        order.append(node)
        for dependent in sorted(dependents[node]):
            indegree[dependent] -= 1
            if indegree[dependent] == 0:
                ready.append(dependent)
        ready.sort()

    if len(order) != len(nodes):
        cyclic = sorted(node for node, count in indegree.items() if count > 0)
        raise PlanError("internal Build-Depends graph contains a cycle: " + ", ".join(cyclic))
    return order


def create_plan(changes: Iterable[str], build_map: BuildMap) -> dict:
    graph = build_dependency_graph(build_map)
    seeds, reasons, normalized_changes = map_changes(changes, build_map)
    affected = reverse_closure(seeds, graph)
    order = topological_sort(affected, graph.forward) if affected else []

    for dependent in sorted(affected):
        for dependency in sorted(graph.forward.get(dependent, ())):
            if dependency not in affected:
                continue
            packages = ", ".join(sorted(graph.edge_packages[(dependent, dependency)]))
            reasons[dependent].append(
                f"reverse Build-Depends of {dependency} via {packages}"
            )

    return {
        "changes": normalized_changes,
        "seeds": sorted(seeds),
        "affected": sorted(affected),
        "order": order,
        "scripts": [build_map.targets[target].script for target in order],
        "reasons": {target: reasons[target] for target in sorted(reasons)},
    }


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    script_path = Path(__file__).resolve()
    default_workspace = script_path.parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "changes",
        nargs="*",
        help="project, PROJECT:path, or workspace-relative path; stdin is used when omitted",
    )
    parser.add_argument(
        "--map",
        dest="map_path",
        type=Path,
        default=script_path.with_name("build-map.yaml"),
        help="mapping YAML path",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=default_workspace,
        help="repo workspace root",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate the mapping, scripts, controls, and dependency graph",
    )
    parser.add_argument(
        "--format", choices=("json", "text"), default="json", help="output format"
    )
    parser.add_argument(
        "--mode",
        choices=("seeds", "affected", "order", "scripts"),
        default="order",
        help="list printed by text output",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        build_map = load_build_map(args.map_path.resolve(), args.workspace.resolve())
        graph = build_dependency_graph(build_map)
        if args.check and not args.changes:
            result = {
                "status": "ok",
                "projects": sorted(build_map.projects),
                "targets": sorted(build_map.targets),
                "internal_packages": dict(sorted(graph.produced_packages.items())),
            }
        else:
            changes = args.changes if args.changes else list(sys.stdin)
            result = create_plan(changes, build_map)
    except PlanError as exc:
        sys.stderr.write(f"ERROR: {exc}\n")
        return 1

    if args.format == "text":
        values = result.get(args.mode)
        if values is None:
            sys.stderr.write(f"ERROR: output mode {args.mode} is unavailable with --check\n")
            return 2
        for value in values:
            print(value)
    else:
        print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
