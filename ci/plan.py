#!/usr/bin/env python3
"""Create a CI build plan from changed repo projects and Debian metadata.

Input consists of one change per line. Each line can be one of:

* a manifest project name, which marks the whole project as changed;
* ``PROJECT:relative/path``;
* a path relative to the repo workspace.

The mapping file selects seed build targets. Rebuild impact is derived
exclusively from Debian Build-Depends fields, never from build scripts. Binary
Depends and Pre-Depends are used only to make internal build dependencies
installable and to order complete builds from an empty output directory.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shlex
import sys
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable, Mapping, Sequence

try:
    import yaml
except ImportError as exc:  # pragma: no cover - exercised by host setup checks
    sys.stderr.write(
        f"ERROR: plan.py requires the Debian package python3-yaml: {exc}\n"
    )
    raise SystemExit(2) from exc


class PlanError(RuntimeError):
    """A mapping, Debian metadata, or dependency graph error."""


@dataclass(frozen=True)
class Target:
    name: str
    description: str
    builder: str
    flow: str
    board: str | None
    version: str | None
    source: str | None
    source_git: str | None
    debian: str | None
    patch_source: str | None
    validate: str | None
    payload_dir: str | None
    files: tuple[str, ...]
    required_files: tuple[str, ...]
    source_excludes: tuple[str, ...]
    source_overlays: tuple[str, ...]
    build_packages: tuple[str, ...]
    build_provides: tuple[str, ...]
    lfs: bool

    @property
    def control(self) -> str | None:
        if self.builder != "debian":
            return None
        if self.flow == "debian-git" and self.source is not None:
            return f"{self.source}/debian/control"
        if self.debian is None:
            return None
        return f"{self.debian}/control"

    @property
    def control_overlay(self) -> str | None:
        if (
            self.builder == "debian"
            and self.flow == "debian-git"
            and self.debian is not None
        ):
            return f"{self.debian}/control"
        return None


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
class BuildSet:
    name: str
    description: str
    targets: tuple[str, ...]


@dataclass(frozen=True)
class BuildMap:
    workspace: Path
    executor: str
    targets: Mapping[str, Target]
    build_sets: Mapping[str, BuildSet]
    projects: Mapping[str, Project]


@dataclass(frozen=True)
class DependencyGraph:
    forward: Mapping[str, frozenset[str]]
    reverse: Mapping[str, frozenset[str]]
    edge_packages: Mapping[tuple[str, str], frozenset[str]]
    produced_packages: Mapping[str, str]
    package_dependencies: Mapping[str, frozenset[str]]


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


def _rule_targets(
    value: object, context: str, available_targets: Iterable[str]
) -> tuple[str, ...]:
    selected = _string_list(value, context)
    available = set(available_targets)
    if "*" in selected:
        if selected != ("*",):
            raise PlanError(f"{context} cannot combine * with named targets")
        return tuple(sorted(available))
    unknown = sorted(set(selected) - available)
    if unknown:
        raise PlanError(f"{context} references unknown targets: {', '.join(unknown)}")
    return selected


def _optional_string(value: object, context: str) -> str | None:
    return None if value is None else _string(value, context)


def _relative_path(value: object, context: str) -> str:
    raw = _string(value, context)
    path = PurePosixPath(raw)
    if path.is_absolute() or ".." in path.parts:
        raise PlanError(f"{context} must stay inside the workspace: {raw}")
    return path.as_posix().rstrip("/")


def _optional_relative_path(value: object, context: str) -> str | None:
    return None if value is None else _relative_path(value, context)


def _payload_file(value: object, context: str) -> str:
    raw = _string(value, context)
    if raw.count("=") > 1:
        raise PlanError(f"{context} must use SOURCE or SOURCE=DESTINATION: {raw}")
    source, separator, destination = raw.partition("=")
    source = _relative_path(source, f"{context} source")
    if not separator:
        return source
    destination = _relative_path(destination, f"{context} destination")
    return f"{source}={destination}"


def _source_overlay(value: object, context: str) -> str:
    raw = _string(value, context)
    if raw.count("=") != 1:
        raise PlanError(f"{context} must use SOURCE=DESTINATION: {raw}")
    source, destination = raw.split("=", 1)
    source = _relative_path(source, f"{context} source")
    destination = _relative_path(destination, f"{context} destination")
    return f"{source}={destination}"


def _target_from_mapping(name: str, entry: dict) -> Target:
    context = f"target {name}"
    allowed = {
        "builder",
        "board",
        "build_packages",
        "build_provides",
        "debian",
        "description",
        "files",
        "flow",
        "lfs",
        "patch_source",
        "payload_dir",
        "required_files",
        "source",
        "source_excludes",
        "source_git",
        "source_overlays",
        "validate",
        "version",
    }
    unknown = sorted(set(entry) - allowed)
    if unknown:
        raise PlanError(f"{context} has unknown fields: {', '.join(unknown)}")

    if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", name):
        raise PlanError(f"invalid target name: {name}")
    if name == "all":
        raise PlanError("target name is reserved by the full-build selector: all")
    description = _string(entry.get("description"), f"{context} description")
    builder = _string(entry.get("builder"), f"{context} builder")
    flow = _string(entry.get("flow"), f"{context} flow")
    board = _optional_string(entry.get("board"), f"{context} board")
    version = _optional_string(entry.get("version"), f"{context} version")
    source = _optional_relative_path(entry.get("source"), f"{context} source")
    source_git = _optional_relative_path(
        entry.get("source_git"), f"{context} source_git"
    )
    debian = _optional_relative_path(entry.get("debian"), f"{context} debian")
    patch_source = _optional_relative_path(
        entry.get("patch_source"), f"{context} patch_source"
    )
    validate = _optional_string(entry.get("validate"), f"{context} validate")
    payload_dir = _optional_relative_path(
        entry.get("payload_dir"), f"{context} payload_dir"
    )
    files = ()
    if "files" in entry:
        raw_files = _string_list(entry["files"], f"{context} files")
        files = tuple(
            _payload_file(item, f"{context} files entry")
            if (builder, flow) == ("debian", "payload")
            else item
            for item in raw_files
        )
    required_files = (
        tuple(
            _relative_path(item, f"{context} required_files entry")
            for item in _string_list(
                entry["required_files"], f"{context} required_files"
            )
        )
        if "required_files" in entry
        else ()
    )
    source_excludes = (
        tuple(
            _relative_path(item, f"{context} source_excludes entry")
            for item in _string_list(
                entry["source_excludes"], f"{context} source_excludes"
            )
        )
        if "source_excludes" in entry
        else ()
    )
    source_overlays = (
        tuple(
            _source_overlay(item, f"{context} source_overlays entry")
            for item in _string_list(
                entry["source_overlays"], f"{context} source_overlays"
            )
        )
        if "source_overlays" in entry
        else ()
    )
    build_packages = (
        _string_list(entry["build_packages"], f"{context} build_packages")
        if "build_packages" in entry
        else ()
    )
    for package in build_packages:
        if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package):
            raise PlanError(f"{context} has invalid build package name: {package}")
    if len(build_packages) != len(set(build_packages)):
        raise PlanError(f"{context} build_packages contains duplicates")
    build_provides = (
        _string_list(entry["build_provides"], f"{context} build_provides")
        if "build_provides" in entry
        else ()
    )
    for package in build_provides:
        if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package):
            raise PlanError(f"{context} has invalid provided package name: {package}")
    if len(build_provides) != len(set(build_provides)):
        raise PlanError(f"{context} build_provides contains duplicates")
    lfs = entry.get("lfs", False)
    if not isinstance(lfs, bool):
        raise PlanError(f"{context} lfs must be a boolean")

    schemas = {
        ("direct", "kernel-worktree"): (
            {"source", "debian"},
            {"source", "debian"},
        ),
        ("direct", "kernel-stable-tarball"): (
            {"version", "patch_source"},
            {"version", "patch_source"},
        ),
        ("direct", "sof-firmware"): (
            {"source", "debian"},
            {"source", "debian"},
        ),
        ("direct", "radxa-firmware"): (
            {"source", "board"},
            {"source", "board"},
        ),
        ("direct", "radxa-pm-validation"): (
            {"source", "board"},
            {"source", "board"},
        ),
        ("direct", "radxa-opp-validation"): (
            {"source", "board"},
            {"source", "board"},
        ),
        ("direct", "radxa-pm-tuning"): (
            {"source", "board"},
            {"source", "board"},
        ),
        ("direct", "pmtool"): (
            {"source"},
            {"source"},
        ),
        ("debian", "quilt"): (
            {"source", "source_git", "debian"},
            {
                "source",
                "source_git",
                "debian",
                "validate",
                "source_excludes",
                "source_overlays",
            },
        ),
        ("debian", "debian-git"): (
            {"source", "debian"},
            {"source", "debian"},
        ),
        ("debian", "native"): (
            {"source_git", "debian"},
            {"source_git", "debian"},
        ),
        ("debian", "payload"): (
            {
                "source",
                "source_git",
                "debian",
                "files",
            },
            {
                "source",
                "source_git",
                "debian",
                "payload_dir",
                "files",
                "required_files",
                "lfs",
            },
        ),
    }
    schema = schemas.get((builder, flow))
    if schema is None:
        raise PlanError(f"{context} has unsupported builder/flow: {builder}/{flow}")
    required, flow_fields = schema
    parsed_fields = {
        "source": source,
        "board": board,
        "source_git": source_git,
        "debian": debian,
        "version": version,
        "patch_source": patch_source,
        "validate": validate,
        "payload_dir": payload_dir,
        "files": files,
        "required_files": required_files,
        "source_excludes": source_excludes,
        "source_overlays": source_overlays,
        "lfs": lfs,
    }
    missing = sorted(
        field
        for field in required
        if field not in entry or parsed_fields[field] in {None, (), ""}
    )
    if missing:
        raise PlanError(f"{context} requires fields: {', '.join(missing)}")
    unsupported = sorted(
        set(entry)
        - {
            "description",
            "builder",
            "flow",
            "build_packages",
            "build_provides",
        }
        - flow_fields
    )
    if unsupported:
        raise PlanError(
            f"{context} {builder}/{flow} does not support fields: "
            + ", ".join(unsupported)
        )
    if validate not in {None, "dkms"}:
        raise PlanError(f"{context} has unsupported validation: {validate}")
    if (builder, flow) == ("debian", "payload"):
        uses_default_destination = any("=" not in item for item in files)
        if uses_default_destination and payload_dir is None:
            raise PlanError(
                f"{context} payload_dir is required for files without a destination"
            )
    if version is not None and not re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+", version
    ):
        raise PlanError(f"{context} version must use X.Y.Z: {version}")
    if board is not None and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", board):
        raise PlanError(f"{context} has invalid board name: {board}")

    return Target(
        name=name,
        description=description,
        builder=builder,
        flow=flow,
        board=board,
        version=version,
        source=source,
        source_git=source_git,
        debian=debian,
        patch_source=patch_source,
        validate=validate,
        payload_dir=payload_dir,
        files=files,
        required_files=required_files,
        source_excludes=source_excludes,
        source_overlays=source_overlays,
        build_packages=build_packages,
        build_provides=build_provides,
        lfs=lfs,
    )


def load_build_map(
    map_path: Path, workspace: Path, check_paths: bool = True
) -> BuildMap:
    try:
        raw = yaml.safe_load(map_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise PlanError(f"cannot read mapping file {map_path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise PlanError(f"invalid YAML in {map_path}: {exc}") from exc

    root = _mapping(raw, "mapping root")
    unknown_root = sorted(
        set(root) - {"version", "executor", "build_sets", "targets", "projects"}
    )
    if unknown_root:
        raise PlanError(f"mapping root has unknown fields: {', '.join(unknown_root)}")
    if root.get("version") != 7:
        raise PlanError("mapping version must be 7")

    executor = _relative_path(root.get("executor"), "executor")

    target_data = _mapping(root.get("targets"), "targets")
    targets: dict[str, Target] = {}
    for target_name, value in target_data.items():
        name = _string(target_name, "target name")
        entry = _mapping(value, f"target {name}")
        targets[name] = _target_from_mapping(name, entry)

    if not targets:
        raise PlanError("targets must not be empty")

    build_set_data = _mapping(root.get("build_sets", {}), "build_sets")
    build_sets: dict[str, BuildSet] = {}
    covered_targets: set[str] = set()
    for build_set_name, value in build_set_data.items():
        name = _string(build_set_name, "build set name")
        context = f"build set {name}"
        if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", name):
            raise PlanError(f"invalid build set name: {name}")
        if name == "all" or name in targets:
            raise PlanError(
                f"build set name conflicts with a reserved or target name: {name}"
            )
        entry = _mapping(value, context)
        unknown = sorted(set(entry) - {"description", "targets"})
        if unknown:
            raise PlanError(
                f"{context} has unknown fields: {', '.join(unknown)}"
            )
        description = _string(entry.get("description"), f"{context} description")
        selected_targets = _string_list(entry.get("targets"), f"{context} targets")
        if len(selected_targets) != len(set(selected_targets)):
            raise PlanError(f"{context} targets contains duplicates")
        unknown_targets = sorted(set(selected_targets) - set(targets))
        if unknown_targets:
            raise PlanError(
                f"{context} references unknown targets: {', '.join(unknown_targets)}"
            )
        covered_targets.update(selected_targets)
        build_sets[name] = BuildSet(
            name=name,
            description=description,
            targets=selected_targets,
        )

    if build_sets:
        uncovered_targets = sorted(set(targets) - covered_targets)
        if uncovered_targets:
            raise PlanError(
                "targets are not assigned to a build set: "
                + ", ".join(uncovered_targets)
            )

    project_data = _mapping(root.get("projects"), "projects")
    projects: dict[str, Project] = {}
    project_paths: dict[str, str] = {}
    mapped_targets: set[str] = set()

    for project_name, value in project_data.items():
        name = _string(project_name, "project name")
        entry = _mapping(value, f"project {name}")
        unknown = sorted(set(entry) - {"path", "rules", "ignore"})
        if unknown:
            raise PlanError(
                f"project {name} has unknown fields: {', '.join(unknown)}"
            )
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
            unknown = sorted(set(rule_data) - {"paths", "targets"})
            if unknown:
                raise PlanError(
                    f"project {name} rule {index} has unknown fields: "
                    + ", ".join(unknown)
                )
            patterns = _string_list(
                rule_data.get("paths"), f"project {name} rule {index} paths"
            )
            rule_targets = _rule_targets(
                rule_data.get("targets"),
                f"project {name} rule {index} targets",
                targets,
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
        projects[name] = Project(
            name=name, path=path, rules=tuple(rules), ignore=ignore
        )

    unmapped = sorted(set(targets) - mapped_targets)
    if unmapped:
        raise PlanError("targets are not referenced by any project: " + ", ".join(unmapped))

    workspace = workspace.resolve()
    if check_paths:
        executor_path = workspace / executor
        if not executor_path.is_file():
            raise PlanError(f"build executor does not exist: {executor_path}")
        if not os.access(executor_path, os.X_OK):
            raise PlanError(f"build executor is not executable: {executor_path}")
        for target in targets.values():
            validate_target_paths(target, workspace)
        for project in projects.values():
            project_path = workspace / project.path
            if not project_path.is_dir():
                raise PlanError(f"project path does not exist: {project_path}")

    return BuildMap(
        workspace=workspace,
        executor=executor,
        targets=targets,
        build_sets=build_sets,
        projects=projects,
    )


def validate_target_paths(target: Target, workspace: Path) -> None:
    for field_name in ("source", "source_git", "debian", "patch_source"):
        relative = getattr(target, field_name)
        if relative is None:
            continue
        path = workspace / relative
        if not path.is_dir():
            raise PlanError(
                f"target {target.name} {field_name} directory does not exist: {path}"
            )
    if target.control:
        control_path = workspace / target.control
        if not control_path.is_file():
            raise PlanError(
                f"target {target.name} control does not exist: {control_path}"
            )
    if target.source:
        for source_exclude in target.source_excludes:
            excluded_path = workspace / target.source / source_exclude
            if not excluded_path.exists():
                raise PlanError(
                    f"target {target.name} source_excludes path does not exist: "
                    f"{excluded_path}"
                )
    for source_overlay in target.source_overlays:
        source, _ = source_overlay.split("=", 1)
        overlay_path = workspace / source
        if not overlay_path.is_dir():
            raise PlanError(
                f"target {target.name} source_overlays directory does not exist: "
                f"{overlay_path}"
            )


def target_dict(target: Target) -> dict:
    return {
        "name": target.name,
        "description": target.description,
        "builder": target.builder,
        "flow": target.flow,
        "board": target.board,
        "version": target.version,
        "source": target.source,
        "source_git": target.source_git,
        "debian": target.debian,
        "patch_source": target.patch_source,
        "validate": target.validate,
        "payload_dir": target.payload_dir,
        "files": list(target.files),
        "required_files": list(target.required_files),
        "source_excludes": list(target.source_excludes),
        "source_overlays": list(target.source_overlays),
        "build_packages": list(target.build_packages),
        "build_provides": list(target.build_provides),
        "lfs": target.lfs,
    }


def target_shell(
    target: Target,
    internal_build_packages: Iterable[str] = (),
) -> str:
    values = {
        "name": target.name,
        "builder": target.builder,
        "flow": target.flow,
        "board": target.board or "",
        "version": target.version or "",
        "description": target.description,
        "source": target.source or "",
        "source_git": target.source_git or "",
        "debian": target.debian or "",
        "patch_source": target.patch_source or "",
        "validate": target.validate or "",
        "payload_dir": target.payload_dir or "",
        "lfs": "1" if target.lfs else "0",
    }
    lines = [
        f"TARGET[{name}]={shlex.quote(value)}" for name, value in values.items()
    ]
    for name, items in (
        ("TARGET_FILES", target.files),
        ("TARGET_REQUIRED_FILES", target.required_files),
        ("TARGET_SOURCE_EXCLUDES", target.source_excludes),
        ("TARGET_SOURCE_OVERLAYS", target.source_overlays),
        ("TARGET_BUILD_PACKAGES", tuple(sorted(internal_build_packages))),
    ):
        quoted = " ".join(shlex.quote(item) for item in items)
        lines.append(f"{name}=({quoted})")
    return "\n".join(lines)


def _relation_names(value: str, context: str) -> set[str]:
    # Debian permits a trailing comma in relationship fields. python-debian
    # accepts it but emits an unnecessary warning for the empty final item.
    value = value.strip().rstrip(",").rstrip()
    if not value:
        return set()
    # Substitution variables are expanded by debhelper and cannot identify an
    # internal package at planning time. Preserve relations whose version uses
    # a substitution variable by replacing only that version with a parseable
    # placeholder.
    entries = [entry.strip() for entry in value.split(",")]
    entries = [
        re.sub(r"\$\{[^}]+\}", "0", entry)
        for entry in entries
        if not re.fullmatch(r"\$\{[^}]+\}", entry)
    ]
    value = ", ".join(entries)
    if not value:
        return set()
    try:
        from debian.deb822 import PkgRelation

        relations = PkgRelation.parse_relations(value)
    except ImportError as exc:
        raise PlanError(
            "CI dependency planning requires the Debian package python3-debian"
        ) from exc
    except Exception as exc:
        raise PlanError(f"cannot parse {context}: {exc}") from exc
    return {
        alternative["name"]
        for group in relations
        for alternative in group
        if alternative.get("name")
    }


def _parse_control(
    control_path: Path,
    control_overlay_path: Path | None = None,
) -> tuple[set[str], set[str], set[str], dict[str, set[str]]]:
    try:
        from debian.deb822 import Deb822

        with control_path.open(encoding="utf-8") as stream:
            paragraphs = list(Deb822.iter_paragraphs(stream))
    except ImportError as exc:
        raise PlanError(
            "CI dependency planning requires the Debian package python3-debian"
        ) from exc
    except OSError as exc:
        raise PlanError(f"cannot read Debian control {control_path}: {exc}") from exc

    if not paragraphs or "Source" not in paragraphs[0]:
        raise PlanError(f"Debian control has no Source stanza: {control_path}")

    source = paragraphs[0]
    binary_packages: set[str] = set()
    provided_packages: set[str] = set()
    runtime_dependencies: dict[str, set[str]] = {}
    for paragraph in paragraphs[1:]:
        package = paragraph.get("Package")
        if package:
            package = package.strip()
            binary_packages.add(package)
            runtime_dependencies[package] = set()
        provides = paragraph.get("Provides")
        if provides:
            provided_packages.update(
                _relation_names(provides, f"Provides in {control_path}")
            )
        if not package:
            continue
        for field in ("Pre-Depends", "Depends"):
            value = paragraph.get(field)
            if value:
                runtime_dependencies[package].update(
                    _relation_names(value, f"{field} in {control_path}")
                )

    if not binary_packages:
        raise PlanError(f"Debian control defines no binary packages: {control_path}")

    build_dependencies: set[str] = set()
    for field in ("Build-Depends", "Build-Depends-Arch", "Build-Depends-Indep"):
        value = source.get(field)
        if value:
            build_dependencies.update(
                _relation_names(value, f"{field} in {control_path}")
            )

    if control_overlay_path is not None:
        try:
            with control_overlay_path.open(encoding="utf-8") as stream:
                overlay_paragraphs = list(Deb822.iter_paragraphs(stream))
        except OSError as exc:
            raise PlanError(
                f"cannot read Debian control overlay {control_overlay_path}: {exc}"
            ) from exc

        if len(overlay_paragraphs) != 1:
            raise PlanError(
                "Debian control overlay must contain exactly one Source stanza: "
                f"{control_overlay_path}"
            )
        overlay = overlay_paragraphs[0]
        build_fields = (
            "Build-Depends",
            "Build-Depends-Arch",
            "Build-Depends-Indep",
        )
        unsupported = sorted(set(overlay) - {"Source"} - set(build_fields))
        if unsupported:
            raise PlanError(
                f"Debian control overlay {control_overlay_path} has unsupported fields: "
                + ", ".join(unsupported)
            )
        if overlay.get("Source") != source.get("Source"):
            raise PlanError(
                f"Debian control overlay Source in {control_overlay_path} does not "
                f"match {control_path}"
            )
        for field in build_fields:
            value = overlay.get(field)
            if value:
                build_dependencies.update(
                    _relation_names(value, f"{field} in {control_overlay_path}")
                )
    return (
        binary_packages,
        provided_packages,
        build_dependencies,
        runtime_dependencies,
    )


def _targets_share_build_set(
    dependent: str, dependency: str, build_map: BuildMap
) -> bool:
    if not build_map.build_sets:
        return True
    return any(
        dependent in build_set.targets and dependency in build_set.targets
        for build_set in build_map.build_sets.values()
    )


def build_dependency_graph(build_map: BuildMap) -> DependencyGraph:
    dependencies_by_target: dict[str, set[str]] = defaultdict(set)
    provider: dict[str, str] = {}
    package_dependencies: dict[str, set[str]] = {}

    for target in build_map.targets.values():
        binary_packages = set(target.build_packages)
        package_identities = set(binary_packages)
        package_identities.update(target.build_provides)
        if target.control:
            control_path = build_map.workspace / target.control
            control_overlay_path = None
            if target.control_overlay:
                candidate = build_map.workspace / target.control_overlay
                if candidate.exists():
                    if not candidate.is_file():
                        raise PlanError(
                            f"target {target.name} control overlay is not a file: "
                            f"{candidate}"
                        )
                    control_overlay_path = candidate
            (
                control_packages,
                provided_packages,
                dependencies,
                control_package_dependencies,
            ) = _parse_control(control_path, control_overlay_path)
            binary_packages.update(control_packages)
            package_identities.update(control_packages)
            package_identities.update(provided_packages)
            dependencies_by_target[target.name].update(dependencies)
            package_dependencies.update(control_package_dependencies)
        for package in package_identities:
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
            if not _targets_share_build_set(dependent, dependency, build_map):
                if package.startswith("cix-"):
                    raise PlanError(
                        f"target {dependent} requires internal package {package} from "
                        f"{dependency}, but they do not share a build set"
                    )
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
        package_dependencies={
            key: frozenset(value) for key, value in package_dependencies.items()
        },
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


def build_environment_packages(
    target: str, graph: DependencyGraph, build_map: BuildMap | None = None
) -> dict[str, str]:
    """Return exact internal packages needed to install target Build-Depends."""
    packages: dict[str, str] = {}
    queue = deque(
        sorted(
            package
            for dependency in graph.forward.get(target, ())
            for package in graph.edge_packages[(target, dependency)]
        )
    )
    while queue:
        package = queue.popleft()
        if package in packages:
            continue
        provider = graph.produced_packages.get(package)
        if provider is None:
            continue
        if build_map is not None and not _targets_share_build_set(
            target, provider, build_map
        ):
            if package.startswith("cix-"):
                raise PlanError(
                    f"target {target} requires internal runtime package {package} "
                    f"from {provider}, but they do not share a build set"
                )
            continue
        packages[package] = provider
        queue.extend(
            sorted(
                required
                for required in graph.package_dependencies.get(package, ())
                if required in graph.produced_packages and required not in packages
            )
        )
    return packages


def build_environment_forward(
    graph: DependencyGraph, build_map: BuildMap | None = None
) -> dict[str, frozenset[str]]:
    """Return target edges required by a clean complete build."""
    result: dict[str, frozenset[str]] = {}
    for target in graph.forward:
        dependencies = set(graph.forward[target])
        dependencies.update(
            provider
            for provider in build_environment_packages(
                target, graph, build_map
            ).values()
            if provider != target
        )
        result[target] = frozenset(dependencies)
    return result


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
        raise PlanError(
            "internal package dependency graph contains a cycle: "
            + ", ".join(cyclic)
        )
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
        "commands": [
            shlex.join((build_map.executor, target)) for target in order
        ],
        "reasons": {target: reasons[target] for target in sorted(reasons)},
    }


def create_build_set_plan(build_set_name: str, build_map: BuildMap) -> dict:
    """Create a dependency-ordered plan for one declared product build set."""
    build_set = build_map.build_sets.get(build_set_name)
    if build_set is None:
        raise PlanError(f"unknown build set: {build_set_name}")

    graph = build_dependency_graph(build_map)
    forward = build_environment_forward(graph, build_map)
    targets = set(build_set.targets)
    missing_dependencies = {
        target: sorted(forward.get(target, frozenset()) - targets)
        for target in sorted(targets)
        if forward.get(target, frozenset()) - targets
    }
    if missing_dependencies:
        details = "; ".join(
            f"{target} requires {', '.join(dependencies)}"
            for target, dependencies in missing_dependencies.items()
        )
        raise PlanError(f"build set {build_set_name} is incomplete: {details}")

    order = topological_sort(targets, forward)
    return {
        "build_set": build_set_name,
        "changes": [],
        "seeds": sorted(targets),
        "affected": sorted(targets),
        "order": order,
        "commands": [
            shlex.join((build_map.executor, target)) for target in order
        ],
        "reasons": {
            target: [f"build set requested: {build_set_name}"]
            for target in sorted(targets)
        },
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
        default=script_path.parent.parent / "build-map.yaml",
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
        help="validate the mapping, executor, controls, and dependency graph",
    )
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--target",
        metavar="NAME",
        help="read one target definition for the build command",
    )
    selection.add_argument(
        "--list-targets",
        action="store_true",
        help="list target names and descriptions",
    )
    selection.add_argument(
        "--list-build-sets",
        action="store_true",
        help="list product build sets and descriptions",
    )
    selection.add_argument(
        "--build-set",
        metavar="NAME",
        help="create a dependency-ordered plan for one product build set",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text", "shell"),
        default="json",
        help="output format; shell is valid only with --target",
    )
    parser.add_argument(
        "--mode",
        choices=("seeds", "affected", "order", "commands"),
        default="order",
        help="list printed by text output",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        if (
            args.target
            or args.list_targets
            or args.list_build_sets
            or args.build_set
        ) and (
            args.check or args.changes
        ):
            raise PlanError("target selection cannot be combined with changes or --check")
        if args.check and args.changes:
            raise PlanError("--check does not accept changes")
        if args.format == "shell" and not args.target:
            raise PlanError("shell output requires --target")

        inspect_only = bool(args.target or args.list_targets or args.list_build_sets)
        build_map = load_build_map(
            args.map_path.resolve(),
            args.workspace.resolve(),
            check_paths=not inspect_only,
        )
        if args.list_targets:
            result = {
                "targets": [
                    target_dict(build_map.targets[name])
                    for name in sorted(build_map.targets)
                ]
            }
        elif args.list_build_sets:
            result = {
                "build_sets": [
                    {
                        "name": build_set.name,
                        "description": build_set.description,
                        "targets": list(build_set.targets),
                    }
                    for build_set in build_map.build_sets.values()
                ]
            }
        elif args.target:
            target = build_map.targets.get(args.target)
            if target is None:
                raise PlanError(f"unknown build target: {args.target}")
            validate_target_paths(target, build_map.workspace)
            result = target_dict(target)
            graph = build_dependency_graph(build_map)
            environment_packages = build_environment_packages(
                target.name, graph, build_map
            )
            internal_build_packages = sorted(
                f"{package}={provider}"
                for package, provider in environment_packages.items()
            )
            result["internal_build_packages"] = internal_build_packages
        elif args.build_set:
            result = create_build_set_plan(args.build_set, build_map)
        else:
            if args.check:
                graph = build_dependency_graph(build_map)
                result = {
                    "status": "ok",
                    "build_sets": {
                        name: list(build_set.targets)
                        for name, build_set in build_map.build_sets.items()
                    },
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

    if args.format == "shell":
        print(
            target_shell(
                build_map.targets[args.target],
                result["internal_build_packages"],
            )
        )
    elif args.format == "text" and args.list_targets:
        for target in result["targets"]:
            print(f"{target['name']}\t{target['description']}")
    elif args.format == "text" and args.list_build_sets:
        for build_set in result["build_sets"]:
            print(f"{build_set['name']}\t{build_set['description']}")
    elif args.format == "text" and args.target:
        for key, value in result.items():
            print(f"{key}: {value}")
    elif args.format == "text":
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
