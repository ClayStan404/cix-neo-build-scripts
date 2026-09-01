#!/usr/bin/env python3
"""Verify CIX v3 PM configuration validation and experiment profiles."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


PM_CONFIG_FILE_SIZE = 4096
PM_CONFIG_HEADER_SIZE = 24
PM_CONFIG_SIGNATURE = int.from_bytes(b"PMCF", "little")
PM_CONFIG_VERSION = (3, 0)
OPP_NO_LIMIT = 4000
PM_CONFIG_OPP_OFFSET = 152
PM_CONFIG_VMIN_DISABLE_OFFSET = 3331
PM_CONFIG_VMIN_PROFILE_OFFSET = 3335
PM_CONFIG_VMIN_ENABLE_VALUE = 0x67997CDA
PM_CONFIG_FIELD_INVALID_VALUE = 0x00000001
OPP_DOMAIN_COUNT = 13
OPP_ENTRY_COUNT = 13
OPP_ENTRY_SIZE = struct.calcsize("<IIII")
OPP_DOMAIN_SIZE = struct.calcsize("<HH") + OPP_ENTRY_COUNT * OPP_ENTRY_SIZE

EXPECTED_RAILS = (
    (2, 2500, 0, 0x45, 1, 790, 0),
    (2, 6500, 1, 0x45, 2, 790, 0),
    (2, 6500, 0, 0x45, 0, 790, 0),
    (2, 8000, 0, 0x45, 2, 790, 0),
    (2, 8000, 0, 0x45, 3, 790, 0),
    (2, 5500, 1, 0x45, 3, 790, 0),
    (2, 12000, 1, 0x45, 1, 790, 10),
    (2, 9000, 1, 0x45, 0, 790, 0),
)

# Stock tables shipped by the current CIX v3.4 PackageTool. Each entry is
# (level, voltage, frequency, power); a table tuple starts with sustained_idx.
EXPECTED_OPP_TABLES = (
    (5, (72, 800, 350000, 0), (216, 800, 350000, 0), (350, 800, 350000, 0),
     (600, 800, 0, 0), (800, 800, 0, 0), (1100, 800, 0, 0)),
    (5, (72, 800, 350000, 0), (216, 800, 350000, 0), (350, 800, 350000, 0),
     (600, 800, 0, 0), (800, 800, 0, 0), (1000, 800, 0, 0)),
    (1, (800, 790, 0, 138), (1800, 790, 0, 790)),
    (3, (800, 750, 0, 156), (1200, 750, 0, 372), (1500, 750, 0, 614),
     (1800, 790, 0, 841), (2200, 790, 0, 1360), (2400, 850, 0, 1663),
     (2500, 920, 0, 2292)),
    (3, (800, 750, 0, 156), (1200, 750, 0, 372), (1500, 750, 0, 614),
     (1800, 790, 0, 841), (2200, 790, 0, 1360), (2500, 850, 0, 1663),
     (2600, 920, 0, 2292)),
    (3, (800, 750, 0, 149), (1200, 750, 0, 355), (1500, 750, 0, 584),
     (1800, 790, 0, 799), (2100, 790, 0, 1114), (2200, 850, 0, 1292),
     (2300, 890, 0, 1396)),
    (3, (800, 750, 0, 149), (1200, 750, 0, 355), (1500, 750, 0, 584),
     (1800, 790, 0, 799), (2100, 850, 0, 1114), (2200, 890, 0, 1292)),
    (1, (500, 790, 0, 0), (1300, 790, 0, 0)),
    (2, (400, 0, 0, 0), (600, 0, 0, 0), (800, 0, 0, 0),
     (1200, 0, 0, 0)),
    (5, (150, 0, 0, 0), (300, 0, 0, 0), (480, 0, 0, 0),
     (600, 0, 0, 0), (800, 0, 0, 0), (1200, 0, 0, 0)),
    (1, (500, 0, 0, 0), (1500, 0, 0, 0)),
    (2, (375, 0, 0, 0), (600, 0, 0, 0), (750, 0, 0, 0)),
)

OPP_PROFILES = ("stock-opp", "vendor-auto")


class VerificationError(RuntimeError):
    """The generated PM configuration is unsafe or malformed."""


def checksum(data: bytes) -> tuple[int, int]:
    """Return the CIX two-word rolling checksum with CRC fields cleared."""
    checked = bytearray(data)
    checked[16:24] = b"\0" * 8
    cka = 0
    ckb = 0
    for (word,) in struct.iter_unpack("<I", checked):
        cka = (cka + word) & 0xFFFFFFFF
        ckb = (ckb + cka) & 0xFFFFFFFF
    return cka, ckb


def decode_rail(data: bytes, offset: int) -> tuple[int, ...]:
    first, second = struct.unpack_from("<II", data, offset)
    delta = (second >> 12) & 0x3FF
    if delta & 0x200:
        delta -= 0x400
    return (
        first & 0x7,
        (first >> 3) & 0xFFFF,
        (first >> 19) & 0x7,
        (first >> 22) & 0x7F,
        (first >> 29) & 0x7,
        second & 0xFFF,
        delta,
    )


def expected_opp_tables(profile: str) -> tuple:
    if profile in ("stock-opp", "vendor-auto"):
        return EXPECTED_OPP_TABLES
    raise VerificationError(f"unsupported OPP profile: {profile}")


def verify_external_opp(data: bytes, profile: str) -> None:
    expected_tables = expected_opp_tables(profile)
    if len(expected_tables) != OPP_DOMAIN_COUNT - 1:
        raise VerificationError("OPP verifier has an invalid domain count")
    expected_validity = 1 if profile == "vendor-auto" else 0
    if data[PM_CONFIG_OPP_OFFSET] != expected_validity:
        state = "disabled" if expected_validity else "valid"
        raise VerificationError(f"external OPP table is not marked {state}")

    domain_base = PM_CONFIG_OPP_OFFSET + 1
    empty_entry = (0, 0, 0, 0)
    for domain, expected in enumerate(expected_tables):
        offset = domain_base + domain * OPP_DOMAIN_SIZE
        size, sustained_idx = struct.unpack_from("<HH", data, offset)
        expected_sustained, *expected_entries = expected
        if (size, sustained_idx) != (len(expected_entries), expected_sustained):
            raise VerificationError(
                f"unexpected OPP domain {domain} header: "
                f"size={size}, sustained_idx={sustained_idx}"
            )
        entries = tuple(
            struct.unpack_from("<IIII", data, offset + 4 + index * OPP_ENTRY_SIZE)
            for index in range(OPP_ENTRY_COUNT)
        )
        expected_padded = tuple(expected_entries) + (empty_entry,) * (
            OPP_ENTRY_COUNT - len(expected_entries)
        )
        if entries != expected_padded:
            raise VerificationError(f"unexpected OPP domain {domain} table")

    unused_offset = domain_base + len(expected_tables) * OPP_DOMAIN_SIZE
    unused_domain = data[unused_offset : unused_offset + OPP_DOMAIN_SIZE]
    if unused_domain != b"\xff" * OPP_DOMAIN_SIZE:
        raise VerificationError(
            f"unused OPP domain {OPP_DOMAIN_COUNT - 1} was unexpectedly configured"
        )


def verify_fused_vmin(data: bytes) -> None:
    vmin_disable, vmin_profile = struct.unpack_from(
        "<II", data, PM_CONFIG_VMIN_DISABLE_OFFSET
    )
    if vmin_disable != PM_CONFIG_VMIN_ENABLE_VALUE:
        raise VerificationError(
            "fused Vmin is not explicitly enabled: "
            f"0x{vmin_disable:08x}"
        )
    if vmin_profile != PM_CONFIG_FIELD_INVALID_VALUE:
        raise VerificationError(
            f"unexpected global Vmin profile override: 0x{vmin_profile:08x}"
        )


def verify(data: bytes, profile: str = "pmic") -> str:
    if len(data) != PM_CONFIG_FILE_SIZE:
        raise VerificationError(
            f"expected a {PM_CONFIG_FILE_SIZE}-byte block, got {len(data)} bytes"
        )

    major, minor, _timestamp, length, signature, crc1, crc2 = struct.unpack_from(
        "<HHIIIII", data
    )
    if (major, minor) != PM_CONFIG_VERSION:
        raise VerificationError(f"expected PM config v3.0, got v{major}.{minor}")
    if signature != PM_CONFIG_SIGNATURE:
        raise VerificationError(f"invalid signature: 0x{signature:08x}")
    if length < 118 or length > len(data) or length % 4:
        raise VerificationError(f"invalid checksummed length: {length}")
    calculated = checksum(data[:length])
    if calculated != (crc1, crc2):
        raise VerificationError(
            "checksum mismatch: "
            f"stored=({crc1:08x},{crc2:08x}) "
            f"calculated=({calculated[0]:08x},{calculated[1]:08x})"
        )

    (pmic_scheme,) = struct.unpack_from("<I", data, PM_CONFIG_HEADER_SIZE)
    if pmic_scheme != 0:
        raise VerificationError(
            f"custom PMIC scheme is not valid: 0x{pmic_scheme:08x}"
        )

    opp_max = struct.unpack_from("<13H", data, PM_CONFIG_HEADER_SIZE + 4)
    if opp_max != (OPP_NO_LIMIT,) * 13:
        raise VerificationError(f"unexpected OPP limits: {opp_max}")

    rail_offset = PM_CONFIG_HEADER_SIZE + 4 + struct.calcsize("<13H")
    rails = tuple(
        decode_rail(data, rail_offset + index * 8) for index in range(8)
    )
    if rails != EXPECTED_RAILS:
        raise VerificationError(f"unexpected PMIC rail configuration: {rails}")

    if profile in OPP_PROFILES:
        verify_external_opp(data, profile)
        if profile == "vendor-auto":
            verify_fused_vmin(data)
            return (
                "PM config v3.0 custom PMIC is valid, external OPP selection "
                "is disabled, fused Vmin is enabled, and source stock backup "
                "tables are valid"
            )
        return "PM config v3.0 custom PMIC and source stock external OPP tables are valid"
    if profile != "pmic":
        raise VerificationError(f"unsupported validation profile: {profile}")
    return "PM config v3.0 checksum and stock-equivalent custom PMIC profile are valid"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--profile",
        choices=("pmic", *OPP_PROFILES),
        default="pmic",
        help="validation profile (default: pmic)",
    )
    parser.add_argument("config", type=Path, help="csu_pm_config.bin to verify")
    args = parser.parse_args()
    try:
        result = verify(args.config.read_bytes(), args.profile)
    except (OSError, VerificationError) as exc:
        parser.error(str(exc))
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
