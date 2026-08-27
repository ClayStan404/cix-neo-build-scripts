#!/usr/bin/env python3
"""Tests for installed-product validation output."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))

import product


class ProductValidationTests(unittest.TestCase):
    def test_debian_dkms_status_and_qualified_package_are_accepted(self) -> None:
        profile = {
            "kernel_glob": "7.0.*-cix*",
            "live_packages": ["cix-vpu-driver-dkms"],
            "live_dkms": ["cix-vpu-driver"],
        }
        output = "\n".join(
            (
                "architecture=arm64",
                "kernel=7.0.13-cix",
                "package=cix-vpu-driver-dkms:arm64 status=installed version=1.0.1-1",
                "cix-vpu-driver/1.0.1, 7.0.13-cix, aarch64: installed",
            )
        )

        result = product.validate_host_output(profile, output)

        self.assertEqual(result["architecture"], "arm64")
        self.assertEqual(result["kernel"], "7.0.13-cix")


if __name__ == "__main__":
    unittest.main()
