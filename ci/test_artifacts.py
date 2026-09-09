"""Behavioral checks for required product artifacts."""

import sys
import tempfile
import unittest
from pathlib import Path

import artifacts
import build_state
import plan

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
import product


class ArtifactPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cix-artifact-test.")
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name)
        repository = Path(__file__).resolve().parents[1]
        self.build_map = plan.load_build_map(repository / "build-map.yaml", repository.parent, check_paths=False)

    def write(self, target: str, name: str) -> Path:
        path = self.workspace / "output" / target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")
        return path

    def test_every_registered_direct_flow_has_an_output_policy(self) -> None:
        for target in self.build_map.targets.values():
            if target.builder == "direct":
                with self.subTest(target=target.name):
                    self.assertTrue(artifacts.required_outputs(target))

    def test_product_rejects_cache_and_optional_files_without_primary_outputs(self) -> None:
        for name, leftover in (
            ("kernel", "build/Makefile"),
            ("audio-sof", "downloads/cache.tar.xz"),
            ("radxa-o6-firmware", "LinuxLoader.efi.cap"),
        ):
            self.write(name, leftover)
            with self.subTest(target=name), self.assertRaises(product.ValidationError):
                product.validate_artifact_target(self.build_map.targets[name], self.workspace, False)

    def test_missing_kernel_image_cannot_be_replaced_by_debug_symbols(self) -> None:
        name = "stable-kernel"
        self.write(name, "linux-image-7.0.13-cix-dbg_1_arm64.deb")
        self.write(name, "linux-headers-7.0.13-cix_1_arm64.deb")
        with self.assertRaises(artifacts.ArtifactError):
            artifacts.validate_outputs(self.build_map.targets[name], self.workspace)
        self.write(name, "linux-image-7.0.13-cix_1_arm64.deb")
        artifacts.validate_outputs(self.build_map.targets[name], self.workspace)

    def test_debian_target_requires_all_declared_binary_packages(self) -> None:
        target = self.build_map.targets["libva"]
        control = self.workspace / target.control
        control.parent.mkdir(parents=True)
        control.write_text(
            "Source: libva\n\nPackage: libva2\nArchitecture: any\n\n"
            "Package: libva-dev\nArchitecture: any\n"
        )
        self.write(target.name, "libva2_1_arm64.deb")
        with self.assertRaisesRegex(artifacts.ArtifactError, "libva-dev"):
            artifacts.validate_outputs(target, self.workspace)
        self.write(target.name, "libva-dev_1_arm64.deb")
        artifacts.validate_outputs(target, self.workspace)

    def test_product_firmware_requires_every_signing_and_delivery_variant(self) -> None:
        target = self.build_map.targets["radxa-o6n-firmware"]
        for suffix in ("", "_pr_debug", "_pr2_debug", "_proto", "_proto_debug"):
            for delivery in ("all", "ota"):
                self.write(target.name, f"images/cix_flash_{delivery}_O6N{suffix}.bin")
            self.write(target.name, f"images/ocb/cix_flash_all_O6N{suffix}.bin")
        artifacts.validate_outputs(target, self.workspace)
        missing = self.workspace / "output" / target.name / "images/cix_flash_ota_O6N_pr_debug.bin"
        missing.unlink()
        with self.assertRaisesRegex(artifacts.ArtifactError, "cix_flash_ota_O6N_pr_debug"):
            artifacts.validate_outputs(target, self.workspace)

    def test_success_state_is_not_recorded_for_an_incomplete_kernel(self) -> None:
        target = self.build_map.targets["kernel"]
        self.write(target.name, "build/Makefile")
        with self.assertRaises(artifacts.ArtifactError):
            build_state.record_target(
                target.name, "local", "fixture",
                {"target": plan.target_dict(target), "dependencies": {}},
                0, self.workspace / "build.log", self.workspace,
                self.workspace / "output/.cix-state",
            )


if __name__ == "__main__":
    unittest.main()
