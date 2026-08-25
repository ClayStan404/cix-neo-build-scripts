#!/usr/bin/env python3
"""Tests for the CIX PM configuration verifier."""

from __future__ import annotations

import struct
import unittest

import verify_pm_config


def encode_rail(rail: tuple[int, ...]) -> bytes:
    vr_type, pwr_cap, i2c_port, i2c_addr, i2c_buck, vboot, delta = rail
    first = (
        vr_type
        | (pwr_cap << 3)
        | (i2c_port << 19)
        | (i2c_addr << 22)
        | (i2c_buck << 29)
    )
    second = vboot | ((delta & 0x3FF) << 12)
    return struct.pack("<II", first, second)


def validation_block(opp_profile: str | None = None) -> bytes:
    length = 2912 if opp_profile else 128
    data = bytearray(b"\xff" * verify_pm_config.PM_CONFIG_FILE_SIZE)
    struct.pack_into(
        "<HHIIIII",
        data,
        0,
        3,
        0,
        0,
        length,
        verify_pm_config.PM_CONFIG_SIGNATURE,
        0,
        0,
    )
    struct.pack_into("<I", data, 24, 0)
    struct.pack_into("<13H", data, 28, *([verify_pm_config.OPP_NO_LIMIT] * 13))
    offset = 54
    for rail in verify_pm_config.EXPECTED_RAILS:
        data[offset : offset + 8] = encode_rail(rail)
        offset += 8
    if opp_profile:
        data[verify_pm_config.PM_CONFIG_OPP_OFFSET] = (
            1 if opp_profile == "vendor-auto" else 0
        )
        domain_base = verify_pm_config.PM_CONFIG_OPP_OFFSET + 1
        expected_tables = verify_pm_config.expected_opp_tables(opp_profile)
        for domain, expected in enumerate(expected_tables):
            domain_offset = domain_base + domain * verify_pm_config.OPP_DOMAIN_SIZE
            data[domain_offset : domain_offset + verify_pm_config.OPP_DOMAIN_SIZE] = (
                b"\0" * verify_pm_config.OPP_DOMAIN_SIZE
            )
            sustained_idx, *entries = expected
            struct.pack_into("<HH", data, domain_offset, len(entries), sustained_idx)
            for index, entry in enumerate(entries):
                struct.pack_into(
                    "<IIII",
                    data,
                    domain_offset + 4 + index * verify_pm_config.OPP_ENTRY_SIZE,
                    *entry,
                )
    crc1, crc2 = verify_pm_config.checksum(data[:length])
    struct.pack_into("<II", data, 16, crc1, crc2)
    return bytes(data)


class PmConfigVerifierTests(unittest.TestCase):
    def test_accepts_stock_equivalent_profile(self) -> None:
        self.assertIn("stock-equivalent", verify_pm_config.verify(validation_block()))

    def test_rejects_changed_voltage_offset(self) -> None:
        data = bytearray(validation_block())
        data[54 + 6 * 8 + 5] ^= 1
        crc1, crc2 = verify_pm_config.checksum(data[:128])
        struct.pack_into("<II", data, 16, crc1, crc2)
        with self.assertRaisesRegex(
            verify_pm_config.VerificationError, "unexpected PMIC rail configuration"
        ):
            verify_pm_config.verify(bytes(data))

    def test_rejects_default_invalid_pmic_section(self) -> None:
        data = bytearray(validation_block())
        struct.pack_into("<I", data, 24, 0xFFFFFFFF)
        crc1, crc2 = verify_pm_config.checksum(data[:128])
        struct.pack_into("<II", data, 16, crc1, crc2)
        with self.assertRaisesRegex(
            verify_pm_config.VerificationError, "custom PMIC scheme is not valid"
        ):
            verify_pm_config.verify(bytes(data))

    def test_accepts_stock_external_opp_tables(self) -> None:
        result = verify_pm_config.verify(validation_block("stock-opp"), "stock-opp")
        self.assertIn("stock external OPP tables", result)

    def test_accepts_vendor_automatic_with_backup_tables(self) -> None:
        result = verify_pm_config.verify(validation_block("vendor-auto"), "vendor-auto")
        self.assertIn("external OPP selection is disabled", result)
        self.assertIn("source stock backup tables are valid", result)

    def test_rejects_enabled_table_as_vendor_automatic(self) -> None:
        data = bytearray(validation_block("vendor-auto"))
        data[verify_pm_config.PM_CONFIG_OPP_OFFSET] = 0
        crc1, crc2 = verify_pm_config.checksum(data[:2912])
        struct.pack_into("<II", data, 16, crc1, crc2)
        with self.assertRaisesRegex(
            verify_pm_config.VerificationError,
            "external OPP table is not marked disabled",
        ):
            verify_pm_config.verify(bytes(data), "vendor-auto")

    def test_rejects_changed_opp_level(self) -> None:
        data = bytearray(validation_block("stock-opp"))
        first_entry = verify_pm_config.PM_CONFIG_OPP_OFFSET + 1 + 4
        struct.pack_into("<I", data, first_entry, 73)
        crc1, crc2 = verify_pm_config.checksum(data[:2912])
        struct.pack_into("<II", data, 16, crc1, crc2)
        with self.assertRaisesRegex(
            verify_pm_config.VerificationError, "unexpected OPP domain 0 table"
        ):
            verify_pm_config.verify(bytes(data), "stock-opp")


if __name__ == "__main__":
    unittest.main()
