#!/usr/bin/env python3
"""Verify the exact Sky1 PM firmware ABI used by O6 tuning images."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


PM_FIRMWARE_SOURCE_REVISION = "a2327331813f"
PM_FIRMWARE_CONFIG_ABI = (3, 4)
PM_CONFIG_SCHEMA = (3, 0)
EXPECTED_SHA256 = {
    "debug": "f6f248f2cdda9c60dc4942f09bf0a9060bd651732a21a5607f8e16b4c65ec24d",
    "release": "1f30e5c65858f591e8171b43d05e8712659a261e40111b26a04897d8c85a2947",
}


class VerificationError(RuntimeError):
    """The PM firmware is not the revision validated for BIOS tuning."""


def verify(data: bytes, build_type: str) -> str:
    if build_type not in EXPECTED_SHA256:
        raise VerificationError(f"unsupported PM firmware build type: {build_type}")
    if PM_FIRMWARE_SOURCE_REVISION.encode() not in data:
        raise VerificationError(
            "PM firmware does not contain source revision "
            f"{PM_FIRMWARE_SOURCE_REVISION}"
        )

    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256[build_type]:
        raise VerificationError(
            f"unexpected {build_type} PM firmware SHA-256: {digest}"
        )

    return (
        f"Sky1 {build_type} PM firmware {PM_FIRMWARE_SOURCE_REVISION} is "
        f"compatible with PM config ABI v{PM_FIRMWARE_CONFIG_ABI[0]}."
        f"{PM_FIRMWARE_CONFIG_ABI[1]} and pinned schema "
        f"v{PM_CONFIG_SCHEMA[0]}.{PM_CONFIG_SCHEMA[1]}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-type", choices=tuple(EXPECTED_SHA256), required=True)
    parser.add_argument("firmware", type=Path, help="pm_fw.bin to verify")
    args = parser.parse_args()
    try:
        result = verify(args.firmware.read_bytes(), args.build_type)
    except (OSError, VerificationError) as exc:
        parser.error(str(exc))
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
