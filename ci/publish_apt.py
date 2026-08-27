#!/usr/bin/env python3
"""Publish built CIX Debian packages as an unsigned temporary APT repository."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence


class PublishError(RuntimeError):
    """APT repository publication cannot continue safely."""


def run(command: Sequence[str], *, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) else str(exc)
        raise PublishError(f"command failed: {' '.join(command)}: {detail}") from exc
    return result.stdout


def deb_fields(path: Path) -> tuple[str, str, str]:
    lines = run(
        ("dpkg-deb", "-f", str(path), "Package", "Version", "Architecture")
    ).splitlines()
    labels = ("Package", "Version", "Architecture")
    if len(lines) != len(labels) or any(
        not line.startswith(f"{label}: ") for line, label in zip(lines, labels)
    ):
        raise PublishError(f"cannot read package identity: {path}")
    package, version, architecture = (
        line.partition(": ")[2] for line in lines
    )
    if architecture not in {"all", "arm64"}:
        raise PublishError(f"unsupported package architecture {architecture}: {path}")
    return package, version, architecture


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("targets", nargs="+", help="Build targets whose top-level .deb files are published")
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--suite", default="trixie")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    workspace = Path(__file__).resolve().parents[2]
    destination = args.output.resolve()
    try:
        if destination.exists() and any(destination.iterdir()):
            raise PublishError(f"output directory must be empty: {destination}")
        destination.mkdir(parents=True, exist_ok=True)
        pool = destination / "pool" / "main" / "c" / "cix"
        packages_dir = destination / "dists" / args.suite / "main" / "binary-arm64"
        pool.mkdir(parents=True)
        packages_dir.mkdir(parents=True)

        identities: dict[tuple[str, str, str], Path] = {}
        manifest = []
        for target in args.targets:
            for source in sorted((workspace / "output" / target).glob("*.deb")):
                identity = deb_fields(source)
                previous = identities.get(identity)
                if previous:
                    raise PublishError(
                        f"duplicate package {identity[0]} {identity[1]} {identity[2]}: {previous} and {source}"
                    )
                identities[identity] = source
                target_name = source.name
                if (pool / target_name).exists():
                    target_name = f"{target}-{source.name}"
                published = pool / target_name
                shutil.copy2(source, published)
                manifest.append(
                    {
                        "target": target,
                        "package": identity[0],
                        "version": identity[1],
                        "architecture": identity[2],
                        "path": published.relative_to(destination).as_posix(),
                        "size": published.stat().st_size,
                        "sha256": sha256(published),
                    }
                )
        if not manifest:
            raise PublishError("selected targets contain no top-level .deb packages")

        packages = run(("dpkg-scanpackages", "--multiversion", "pool", "/dev/null"), cwd=destination)
        packages_path = packages_dir / "Packages"
        packages_path.write_text(packages, encoding="utf-8")
        (packages_dir / "Packages.gz").write_bytes(gzip.compress(packages.encode(), mtime=0))
        release = run(
            (
                "apt-ftparchive",
                "-o", f"APT::FTPArchive::Release::Suite={args.suite}",
                "-o", f"APT::FTPArchive::Release::Codename={args.suite}",
                "-o", "APT::FTPArchive::Release::Components=main",
                "-o", "APT::FTPArchive::Release::Architectures=arm64 all",
                "release", f"dists/{args.suite}",
            ),
            cwd=destination,
        )
        (destination / "dists" / args.suite / "Release").write_text(release, encoding="utf-8")
        metadata = {
            "version": 1,
            "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "suite": args.suite,
            "signed": False,
            "packages": manifest,
        }
        (destination / "manifest.json").write_text(
            json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        (destination / "README").write_text(
            "Temporary unsigned CIX CI repository. Serve this directory over HTTP and use:\n"
            f"deb [trusted=yes arch=arm64] URL {args.suite} main\n",
            encoding="utf-8",
        )
        print(f"Published {len(manifest)} packages: {destination}")
    except (PublishError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
