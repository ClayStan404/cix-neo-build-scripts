#!/usr/bin/env python3
"""Validate the vendor-safe O6 memory configuration used by tuning firmware."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


QUICK_CONFIG_SIZE = 32
MEMORY_HEADER_SIZE = 64
BLOCK_ENTRY_SIZE = 4
BLOCK_HEADER_SIZE = 16

MEMORY_HEADER_SIGNATURE = 0x42434443
MEMORY_CONFIG_GUID = 0x1001
LPDDR5_BUS_GUID = 0x1005
PHY_PAD_GUID = 0x1006
BIOS_SETUP_GUID = 0x1007
TRAIN_OPTIMIZE_GUID = 0x100B

MEMORY_CONFIG_SIGNATURE = 0x464E4F43
BIOS_SETUP_SIGNATURE = 0x54455342
MEMORY_FREQUENCY_AUTO = 0xFFFF
MEMORY_FREQUENCY_6400 = 3200

EXPLICIT_FREQUENCIES = {
    800,
    1067,
    1375,
    1600,
    1867,
    2133,
    2400,
    2750,
    3000,
    3200,
}

VENDOR_LIMITS = {
    0xFFFF: 2750,
    0x0001: 2750,
    0x0002: 2750,
    0x0004: 2750,
    0x0010: 2750,
    0x0020: 2750,
    0x0040: 2750,
    0x0080: 2400,
    0x0100: 2750,
    0x0200: 2750,
    0x0400: 2750,
    0x0800: 2400,
    0x1000: 3000,
}

ALLOWED_FREQUENCIES = EXPLICIT_FREQUENCIES | {MEMORY_FREQUENCY_AUTO}

TUNING_ENTRY_SIZES = {
    LPDDR5_BUS_GUID: 16,
    PHY_PAD_GUID: 20,
    TRAIN_OPTIMIZE_GUID: 8,
}


class VerificationError(RuntimeError):
    """Raised when an O6 memory configuration is unsafe or malformed."""


def validate_requested_frequency(frequency: int) -> int:
    """Validate and return a BIOS memory data-rate request."""
    if frequency not in ALLOWED_FREQUENCIES:
        raise VerificationError(f"unsupported memory frequency value: {frequency}")
    return frequency


def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _checked_slice(data: bytes, offset: int, size: int, description: str) -> bytes:
    if offset < 0 or size < 0 or offset + size > len(data):
        raise VerificationError(f"{description} is outside the image")
    return data[offset : offset + size]


def _valid_checksum(data: bytes) -> bool:
    return sum(data) & 0xFF == 0xFF


def verify(data: bytes) -> str:
    """Validate stock recovery limits and the compiled 6400 training coverage."""
    header = _checked_slice(
        data, QUICK_CONFIG_SIZE, MEMORY_HEADER_SIZE, "memory configuration header"
    )
    if _u32(header, 0) != MEMORY_HEADER_SIGNATURE:
        raise VerificationError("unexpected memory configuration signature")

    major = _u16(header, 8)
    minor = _u16(header, 10)
    table_offset = _u16(header, 12)
    block_count = header[14]
    header_size = header[16]
    total_size = _u16(header, 18)
    if (major, minor) != (2, 0):
        raise VerificationError(f"unsupported memory configuration version: {major}.{minor}")
    if header_size != MEMORY_HEADER_SIZE:
        raise VerificationError(f"unexpected memory header size: {header_size}")
    if not _valid_checksum(header[:header_size]):
        raise VerificationError("memory configuration header checksum mismatch")
    _checked_slice(data, QUICK_CONFIG_SIZE, total_size, "memory configuration payload")

    table_start = QUICK_CONFIG_SIZE + table_offset
    table = _checked_slice(
        data,
        table_start,
        block_count * BLOCK_ENTRY_SIZE,
        "memory configuration block table",
    )

    limits: dict[int, int] = {}
    setup_frequencies: list[int] = []
    tuning_blocks = 0
    for index in range(block_count):
        guid, relative_offset = struct.unpack_from(
            "<HH", table, index * BLOCK_ENTRY_SIZE
        )
        block_offset = QUICK_CONFIG_SIZE + relative_offset
        block_header = _checked_slice(
            data, block_offset, BLOCK_HEADER_SIZE, f"block {index} header"
        )
        block_size = _u16(block_header, 8)
        board_mask = _u16(block_header, 12)
        block = _checked_slice(data, block_offset, block_size, f"block {index}")
        if block_size < BLOCK_HEADER_SIZE:
            raise VerificationError(f"block {index} is smaller than its header")
        if not _valid_checksum(block):
            raise VerificationError(f"block {index} checksum mismatch")

        if guid == MEMORY_CONFIG_GUID:
            if _u32(block, 0) != MEMORY_CONFIG_SIGNATURE:
                raise VerificationError(f"block {index} has an invalid CONF signature")
            if board_mask in limits:
                raise VerificationError(
                    f"duplicate memory limit for board mask 0x{board_mask:04x}"
                )
            limits[board_mask] = _u16(block, BLOCK_HEADER_SIZE)
        elif guid == BIOS_SETUP_GUID:
            if _u32(block, 0) != BIOS_SETUP_SIGNATURE:
                raise VerificationError(f"block {index} has an invalid BSET signature")
            setup_frequencies.append(_u16(block, BLOCK_HEADER_SIZE))
        elif guid in TUNING_ENTRY_SIZES:
            entry_size = TUNING_ENTRY_SIZES[guid]
            payload_size = block_size - BLOCK_HEADER_SIZE
            if payload_size == 0 or payload_size % entry_size:
                raise VerificationError(f"block {index} has an invalid tuning layout")
            frequencies = {
                _u16(block, offset)
                for offset in range(BLOCK_HEADER_SIZE, block_size, entry_size)
            }
            if MEMORY_FREQUENCY_6400 not in frequencies:
                raise VerificationError(
                    f"block {index} lacks a 6400 MT/s tuning entry"
                )
            tuning_blocks += 1

    if limits != VENDOR_LIMITS:
        raise VerificationError(
            f"unexpected vendor board limits: {limits!r}"
        )
    if setup_frequencies != [MEMORY_FREQUENCY_AUTO]:
        raise VerificationError(
            f"vendor memory setup is not Automatic: {setup_frequencies!r}"
        )
    if tuning_blocks != 6:
        raise VerificationError(
            f"expected 6 memory tuning blocks, found {tuning_blocks}"
        )

    return (
        "O6 memory config is valid: vendor board limits are preserved, "
        "BSET defaults to Automatic, and 6400 MT/s tuning ranges are present"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("memory_config", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.memory_config.read_bytes())
    except (OSError, VerificationError) as error:
        parser.error(str(error))
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
