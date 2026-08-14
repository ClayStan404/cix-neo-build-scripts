#!/usr/bin/env python3
"""Verify the stock-equivalent CIX v3 PM configuration validation block."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


PM_CONFIG_FILE_SIZE = 4096
PM_CONFIG_HEADER_SIZE = 24
PM_CONFIG_SIGNATURE = int.from_bytes(b"PMCF", "little")
PM_CONFIG_VERSION = (3, 0)
OPP_NO_LIMIT = 4000

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


def verify(data: bytes) -> str:
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

    return (
        "PM config v3.0 checksum and stock-equivalent custom PMIC profile are valid"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path, help="csu_pm_config.bin to verify")
    args = parser.parse_args()
    try:
        result = verify(args.config.read_bytes())
    except (OSError, VerificationError) as exc:
        parser.error(str(exc))
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
