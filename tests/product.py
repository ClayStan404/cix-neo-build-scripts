#!/usr/bin/env python3
"""Validate CIX product artifacts and optionally inspect an installed host."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))
import build_state  # noqa: E402
import plan  # noqa: E402

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"python3-yaml is required: {exc}") from exc


class ValidationError(RuntimeError):
    """A product validation check failed."""


def run(command: Sequence[str], *, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        output = exc.stdout.strip() if isinstance(exc, subprocess.CalledProcessError) else ""
        raise ValidationError(
            f"command failed: {shlex.join(command)}{f': {output}' if output else ''}"
        ) from exc
    return result.stdout.strip()


def load_profile(path: Path, name: str) -> dict:
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("version") != 1:
        raise ValidationError(f"unsupported validation profile format: {path}")
    profiles = raw.get("profiles")
    if not isinstance(profiles, dict) or name not in profiles:
        raise ValidationError(f"unknown product profile: {name}")
    profile = profiles[name]
    if not isinstance(profile, dict):
        raise ValidationError(f"invalid product profile: {name}")
    return profile


def validate_artifact_target(
    target: plan.Target, workspace: Path, require_state: bool
) -> dict:
    output = workspace / "output" / target.name
    try:
        artifacts = build_state.collect_artifacts(output, workspace)
    except build_state.StateError as exc:
        raise ValidationError(str(exc)) from exc

    debs = sorted(output.glob("*.deb"))
    if target.builder == "debian" and not debs:
        raise ValidationError(f"Debian target has no .deb artifacts: {target.name}")
    packages = []
    for deb in debs:
        fields = run(
            ("dpkg-deb", "-f", str(deb), "Package", "Version", "Architecture")
        ).splitlines()
        labels = ("Package", "Version", "Architecture")
        if len(fields) != len(labels) or any(
            not field.startswith(f"{label}: ")
            for field, label in zip(fields, labels)
        ):
            raise ValidationError(f"cannot read package identity: {deb}")
        package, version, architecture = (
            field.partition(": ")[2] for field in fields
        )
        if architecture not in {"all", "arm64"}:
            raise ValidationError(
                f"unexpected package architecture {architecture}: {deb}"
            )
        packages.append(
            {"package": package, "version": version, "architecture": architecture}
        )

    checksum = output / "SHA256SUMS"
    if checksum.is_file():
        run(("sha256sum", "--check", "SHA256SUMS"), cwd=output)

    state_path = workspace / "output" / ".cix-state" / "targets" / f"{target.name}.json"
    if require_state:
        if not state_path.is_file():
            raise ValidationError(f"resumable state is missing: {target.name}")
        state = json.loads(state_path.read_text(encoding="utf-8"))
        backend = state.get("backend")
        if backend not in {"sbuild", "local"}:
            raise ValidationError(f"invalid resumable backend for {target.name}: {backend}")
        try:
            fingerprint, _ = build_state.fingerprint(
                target.name,
                backend,
                workspace,
                workspace / "build-scripts" / "build-map.yaml",
                workspace / "output" / ".cix-state",
            )
        except build_state.StateError as exc:
            raise ValidationError(str(exc)) from exc
        valid, reason = build_state.state_is_valid(
            state_path, fingerprint, workspace
        )
        if not valid:
            raise ValidationError(f"invalid resumable state for {target.name}: {reason}")

    return {
        "target": target.name,
        "artifact_count": len(artifacts),
        "packages": packages,
        "checksum_manifest": checksum.is_file(),
        "state_present": state_path.is_file(),
    }


def kernel_headers(workspace: Path, target_name: str) -> Path:
    candidates = sorted(
        (workspace / "output" / target_name).glob("linux-headers-*_arm64.deb")
    )
    if len(candidates) != 1:
        raise ValidationError(
            f"expected one kernel headers package for {target_name}; found {len(candidates)}"
        )
    return candidates[0]


def validate_dkms(profile: dict, workspace: Path) -> list[dict]:
    headers = kernel_headers(workspace, str(profile["kernel_target"]))
    results = []
    for target in profile.get("dkms_targets", []):
        command = (
            str(workspace / "build-scripts" / "tests" / "dkms.sh"),
            str(target),
            "--kernel-headers",
            str(headers),
        )
        output = run(command)
        results.append({"target": target, "result": output.splitlines()[-1]})
    return results


def validate_host_output(profile: dict, output: str) -> dict:
    packages = [str(value) for value in profile.get("live_packages", [])]
    values: dict[str, object] = {"raw": output}
    for line in output.splitlines():
        if line.startswith("architecture="):
            values["architecture"] = line.partition("=")[2]
        elif line.startswith("kernel="):
            values["kernel"] = line.partition("=")[2]
    if values.get("architecture") != "arm64":
        raise ValidationError(f"validation host is not arm64: {values.get('architecture')}")
    kernel = str(values.get("kernel", ""))
    if not fnmatch.fnmatchcase(kernel, str(profile["kernel_glob"])):
        raise ValidationError(
            f"validation host kernel {kernel} does not match {profile['kernel_glob']}"
        )
    installed_packages = {
        line.split(" status=", 1)[0].removeprefix("package=").removesuffix(":arm64")
        for line in output.splitlines()
        if line.startswith("package=") and " status=installed " in line
    }
    for package in packages:
        if package not in installed_packages:
            raise ValidationError(f"required package is not installed: {package}")
    for module in profile.get("live_dkms", []):
        if not any(
            line.startswith(f"{module}/")
            and (": installed" in line or ", installed" in line)
            for line in output.splitlines()
        ):
            raise ValidationError(f"DKMS module is not installed: {module}")
    return values


def inspect_host(profile: dict, host: str) -> dict:
    packages = [str(value) for value in profile.get("live_packages", [])]
    package_words = " ".join(shlex.quote(value) for value in packages)
    script = (
        "set -eu; "
        "printf 'architecture='; dpkg --print-architecture; "
        "printf 'kernel='; uname -r; "
        f"for package in {package_words}; do "
        "dpkg-query -W -f='package=${binary:Package} status=${db:Status-Status} version=${Version}\\n' \"$package\"; "
        "done; "
        "if command -v dkms >/dev/null; then dkms status; "
        "elif [ -x /usr/sbin/dkms ]; then /usr/sbin/dkms status; fi"
    )
    command = ("sh", "-c", script) if host == "local" else ("ssh", host, script)
    return validate_host_output(profile, run(command))


def run_ltp_smoke(workspace: Path) -> list[dict]:
    binary_root = workspace / "output" / "ltp" / "ltp" / "testcases" / "bin"
    selected = ("getpid01", "uname01", "gettimeofday01")
    results = []
    for name in selected:
        binary = binary_root / name
        if not binary.is_file():
            raise ValidationError(f"LTP smoke binary is missing: {binary}")
        output = run((str(binary),), cwd=binary_root)
        results.append({"test": name, "output": output})
    return results


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("profile", choices=("6.6", "7.0"))
    result.add_argument("--host", metavar="HOST", help="Inspect local or a read-only SSH host")
    result.add_argument("--dkms", action="store_true", help="Build every profile DKMS package against packaged headers")
    result.add_argument("--ltp-smoke", action="store_true", help="Run three safe LTP smoke tests from output/ltp")
    result.add_argument("--require-state", action="store_true", help="Require verified cix-build resumable state for every target")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    workspace = Path(__file__).resolve().parents[2]
    profile = load_profile(Path(__file__).with_name("products.yaml"), args.profile)
    started = datetime.now(timezone.utc)
    result = {
        "version": 1,
        "profile": args.profile,
        "created_at": started.replace(microsecond=0).isoformat().replace(
            "+00:00", "Z"
        ),
        "finished_at": None,
        "duration_seconds": None,
        "status": "running",
        "targets": [],
        "dkms": [],
        "ltp_smoke": [],
        "host": None,
    }
    error: Exception | None = None
    try:
        build_map = plan.load_build_map(
            workspace / "build-scripts" / "build-map.yaml", workspace
        )
        build_plan = plan.create_build_set_plan(str(profile["build_set"]), build_map)
        result["targets"] = [
            validate_artifact_target(build_map.targets[name], workspace, args.require_state)
            for name in build_plan["order"]
        ]
        result["dkms"] = validate_dkms(profile, workspace) if args.dkms else []
        result["ltp_smoke"] = run_ltp_smoke(workspace) if args.ltp_smoke else []
        result["host"] = inspect_host(profile, args.host) if args.host else None
        result["status"] = "success"
    except (ValidationError, plan.PlanError, OSError, ValueError) as exc:
        error = exc
        result["status"] = "failed"
        result["error"] = str(exc)

    finished = datetime.now(timezone.utc)
    result["finished_at"] = finished.replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )
    result["duration_seconds"] = int((finished - started).total_seconds())
    report_root = workspace / "output" / "validation-reports"
    report_root.mkdir(parents=True, exist_ok=True)
    report = report_root / (
        f"{started.strftime('%Y%m%dT%H%M%SZ')}-{args.profile}-{os.getpid()}.json"
    )
    temporary = report.with_suffix(".tmp")
    try:
        temporary.write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, report)
    except OSError as exc:
        print(f"ERROR: cannot write validation report: {exc}", file=sys.stderr)
        return 1
    if error is not None:
        print(f"ERROR: {error}", file=sys.stderr)
        print(f"Validation failed: {report}", file=sys.stderr)
        return 1
    print(f"Validation passed: {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
