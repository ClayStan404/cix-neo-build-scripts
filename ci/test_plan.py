#!/usr/bin/env python3
"""Tests for the CIX Neo CI build planner."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plan  # noqa: E402


class PlannerFixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cix-ci-plan-test.")
        self.root = Path(self.temporary.name)

    def close(self) -> None:
        self.temporary.cleanup()

    def write(self, relative: str, content: str, executable: bool = False) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        if executable:
            path.chmod(path.stat().st_mode | 0o111)

    def mkdir(self, relative: str) -> None:
        (self.root / relative).mkdir(parents=True, exist_ok=True)

    def mapping(self, data: dict) -> plan.BuildMap:
        map_path = self.root / "build-map.yaml"
        map_path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
        return plan.load_build_map(map_path, self.root)


class BuildPlannerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = PlannerFixture()

    def tearDown(self) -> None:
        self.fixture.close()

    def _dependency_fixture(
        self, transitive: bool = False, runtime_transitive: bool = False
    ) -> plan.BuildMap:
        self.fixture.write("scripts/cix-build", "#!/bin/sh\n", executable=True)
        self.fixture.mkdir("sources/a")
        self.fixture.mkdir("sources/b")
        self.fixture.write(
            "debian/a/control",
            """Source: package-a
Build-Depends: debhelper-compat (= 13), package-b-dev (>= 1.2)

Package: package-a
Architecture: any
Depends: ${misc:Depends}, package-b-runtime
Description: package A
 Test package A.
""",
        )
        self.fixture.write(
            "debian/b/control",
            """Source: package-b
Build-Depends: debhelper-compat (= 13)

Package: package-b-dev
Architecture: any
Depends: package-b-runtime
Description: package B development files
 Test package B.

Package: package-b-runtime
Architecture: any
Description: package B runtime
 Test runtime package B.
""",
        )
        targets = {
            "package-a": {
                "description": "package A",
                "builder": "debian",
                "flow": "quilt",
                "source": "sources/a",
                "source_git": "sources/a",
                "debian": "debian/a",
            },
            "package-b": {
                "description": "package B",
                "builder": "debian",
                "flow": "quilt",
                "source": "sources/b",
                "source_git": "sources/b",
                "debian": "debian/b",
            },
        }
        projects = {
            "repo/a": {
                "path": "sources/a",
                "rules": [{"paths": ["src/**"], "targets": ["package-a"]}],
            },
            "repo/b": {
                "path": "sources/b",
                "rules": [{"paths": ["**"], "targets": ["package-b"]}],
            },
        }
        if transitive or runtime_transitive:
            self.fixture.mkdir("sources/c")
            self.fixture.write(
                "debian/c/control",
                """Source: package-c
Build-Depends: debhelper-compat (= 13)

Package: package-c-dev
Architecture: any
Description: package C development files
 Test package C.

Package: package-c-runtime
Architecture: any
Description: package C runtime
 Test runtime package C.
""",
            )
            control_b = self.fixture.root / "debian/b/control"
            control_b_content = control_b.read_text(encoding="utf-8")
            if transitive:
                control_b_content = control_b_content.replace(
                    "Build-Depends: debhelper-compat (= 13)",
                    "Build-Depends: debhelper-compat (= 13), package-c-dev",
                )
            if runtime_transitive:
                control_b_content = control_b_content.replace(
                    "Package: package-b-runtime\nArchitecture: any",
                    "Package: package-b-runtime\nArchitecture: any\n"
                    "Depends: package-c-runtime",
                )
            control_b.write_text(control_b_content, encoding="utf-8")
            targets["package-c"] = {
                "description": "package C",
                "builder": "debian",
                "flow": "quilt",
                "source": "sources/c",
                "source_git": "sources/c",
                "debian": "debian/c",
            }
            projects["repo/c"] = {
                "path": "sources/c",
                "rules": [{"paths": ["**"], "targets": ["package-c"]}],
            }

        return self.fixture.mapping(
            {
                "version": 7,
                "executor": "scripts/cix-build",
                "build_sets": {
                    "all-test": {
                        "description": "Complete test build",
                        "targets": list(targets),
                    }
                },
                "targets": targets,
                "projects": projects,
            }
        )

    def test_reverse_build_dependency_is_rebuilt_in_order(self) -> None:
        build_map = self._dependency_fixture()
        result = plan.create_plan(["repo/b:src/library.c"], build_map)

        self.assertEqual(result["seeds"], ["package-b"])
        self.assertEqual(result["affected"], ["package-a", "package-b"])
        self.assertEqual(result["order"], ["package-b", "package-a"])
        self.assertEqual(
            result["commands"],
            ["scripts/cix-build package-b", "scripts/cix-build package-a"],
        )
        self.assertIn(
            "reverse Build-Depends of package-b via package-b-dev",
            result["reasons"]["package-a"],
        )

    def test_build_set_plan_contains_declared_targets_in_dependency_order(self) -> None:
        build_map = self._dependency_fixture()
        result = plan.create_build_set_plan("all-test", build_map)

        self.assertEqual(result["build_set"], "all-test")
        self.assertEqual(result["order"], ["package-b", "package-a"])
        self.assertEqual(
            result["commands"],
            ["scripts/cix-build package-b", "scripts/cix-build package-a"],
        )
        self.assertEqual(
            result["reasons"]["package-a"],
            ["build set requested: all-test"],
        )

    def test_all_targets_plan_contains_every_target_in_dependency_order(self) -> None:
        build_map = self._dependency_fixture(transitive=True)
        result = plan.create_all_targets_plan(build_map)

        self.assertEqual(
            result["affected"], ["package-a", "package-b", "package-c"]
        )
        self.assertEqual(result["order"], ["package-c", "package-b", "package-a"])
        self.assertEqual(
            result["commands"],
            [
                "scripts/cix-build package-c",
                "scripts/cix-build package-b",
                "scripts/cix-build package-a",
            ],
        )

    def test_build_set_rejects_missing_internal_dependency(self) -> None:
        build_map = self._dependency_fixture()
        incomplete = plan.BuildMap(
            workspace=build_map.workspace,
            executor=build_map.executor,
            targets=build_map.targets,
            build_sets={
                "incomplete": plan.BuildSet(
                    name="incomplete",
                    description="Incomplete test build",
                    targets=("package-a",),
                ),
                "complete": plan.BuildSet(
                    name="complete",
                    description="Complete test build",
                    targets=("package-a", "package-b"),
                ),
            },
            projects=build_map.projects,
        )

        with self.assertRaisesRegex(
            plan.PlanError, "incomplete: package-a requires package-b"
        ):
            plan.create_build_set_plan("incomplete", incomplete)

    def test_disjoint_build_sets_use_external_standard_package(self) -> None:
        build_map = self._dependency_fixture()
        variants = plan.BuildMap(
            workspace=build_map.workspace,
            executor=build_map.executor,
            targets=build_map.targets,
            build_sets={
                "variant-a": plan.BuildSet(
                    name="variant-a",
                    description="Package A with distribution dependencies",
                    targets=("package-a",),
                ),
                "variant-b": plan.BuildSet(
                    name="variant-b",
                    description="Private package B build",
                    targets=("package-b",),
                ),
            },
            projects=build_map.projects,
        )

        graph = plan.build_dependency_graph(variants)
        result = plan.create_build_set_plan("variant-a", variants)

        self.assertEqual(graph.forward["package-a"], frozenset())
        self.assertEqual(result["order"], ["package-a"])

    def test_runtime_depends_does_not_create_build_edge(self) -> None:
        build_map = self._dependency_fixture()
        graph = plan.build_dependency_graph(build_map)

        self.assertEqual(graph.forward["package-a"], frozenset({"package-b"}))
        self.assertNotIn("package-b-runtime", graph.edge_packages[("package-a", "package-b")])

    def test_target_definition_is_data_driven(self) -> None:
        build_map = self._dependency_fixture()
        target = build_map.targets["package-a"]

        self.assertEqual(target.builder, "debian")
        self.assertEqual(target.flow, "quilt")
        self.assertEqual(target.source, "sources/a")
        self.assertEqual(target.control, "debian/a/control")
        shell = plan.target_shell(target)
        self.assertIn("TARGET[builder]=debian", shell)
        self.assertIn("TARGET[flow]=quilt", shell)
        self.assertIn("TARGET[source]=sources/a", shell)
        self.assertIn("TARGET_BUILD_PACKAGES=()", shell)

    def test_quilt_source_excludes_are_validated_and_exported(self) -> None:
        self.fixture.mkdir("sources/package/demo")
        target = plan._target_from_mapping(
            "package",
            {
                "description": "package",
                "builder": "debian",
                "flow": "quilt",
                "source": "sources/package",
                "source_git": "sources/package",
                "source_excludes": ["demo"],
                "debian": "debian/package",
            },
        )

        self.assertEqual(target.source_excludes, ("demo",))
        self.assertIn("TARGET_SOURCE_EXCLUDES=(demo)", plan.target_shell(target))

        with self.assertRaisesRegex(plan.PlanError, "stay inside the workspace"):
            plan._target_from_mapping(
                "invalid-package",
                {
                    "description": "invalid package",
                    "builder": "debian",
                    "flow": "quilt",
                    "source": "sources/package",
                    "source_git": "sources/package",
                    "source_excludes": ["../demo"],
                    "debian": "debian/package",
                },
            )

    def test_quilt_source_overlays_are_validated_and_exported(self) -> None:
        target = plan._target_from_mapping(
            "package",
            {
                "description": "package",
                "builder": "debian",
                "flow": "quilt",
                "source": "sources/package",
                "source_git": "sources/package",
                "source_overlays": ["sources/second=vendor/second"],
                "debian": "debian/package",
            },
        )

        self.assertEqual(
            target.source_overlays, ("sources/second=vendor/second",)
        )
        self.assertIn(
            "TARGET_SOURCE_OVERLAYS=(sources/second=vendor/second)",
            plan.target_shell(target),
        )

        with self.assertRaisesRegex(plan.PlanError, "SOURCE=DESTINATION"):
            plan._target_from_mapping(
                "invalid-package",
                {
                    "description": "invalid package",
                    "builder": "debian",
                    "flow": "quilt",
                    "source": "sources/package",
                    "source_git": "sources/package",
                    "source_overlays": ["sources/second"],
                    "debian": "debian/package",
                },
            )

    def test_debian_git_uses_the_source_control_file(self) -> None:
        target = plan._target_from_mapping(
            "package",
            {
                "description": "Debian Git package",
                "builder": "debian",
                "flow": "debian-git",
                "source": "sources/debian/package",
                "debian": "debian/package-overlay",
            },
        )

        self.assertEqual(target.control, "sources/debian/package/debian/control")
        self.assertEqual(target.control_overlay, "debian/package-overlay/control")
        self.assertIn("TARGET[flow]=debian-git", plan.target_shell(target))

    def test_debian_git_control_overlay_adds_internal_build_dependency(self) -> None:
        self.fixture.write("scripts/cix-build", "#!/bin/sh\n", executable=True)
        self.fixture.write(
            "sources/debian/package/debian/control",
            """Source: package
Build-Depends: debhelper-compat (= 13)

Package: package
Architecture: any
Description: package
 Test package.
""",
        )
        self.fixture.write(
            "debian/package-overlay/control",
            """Source: package
Build-Depends: cix-vpu-driver-dev (>= 1.0.1)
""",
        )
        self.fixture.mkdir("sources/vpu")
        self.fixture.write(
            "debian/vpu/control",
            """Source: cix-vpu-driver
Build-Depends: debhelper-compat (= 13)

Package: cix-vpu-driver-dev
Architecture: all
Description: CIX VPU development files
 Test package.
""",
        )
        build_map = self.fixture.mapping(
            {
                "version": 7,
                "executor": "scripts/cix-build",
                "targets": {
                    "package": {
                        "description": "Debian Git package",
                        "builder": "debian",
                        "flow": "debian-git",
                        "source": "sources/debian/package",
                        "debian": "debian/package-overlay",
                    },
                    "vpu-dkms": {
                        "description": "VPU driver",
                        "builder": "debian",
                        "flow": "quilt",
                        "source": "sources/vpu",
                        "source_git": "sources/vpu",
                        "debian": "debian/vpu",
                    },
                },
                "projects": {
                    "repo/package": {
                        "path": "sources/debian/package",
                        "rules": [{"paths": ["**"], "targets": ["package"]}],
                    },
                    "repo/vpu": {
                        "path": "sources/vpu",
                        "rules": [{"paths": ["**"], "targets": ["vpu-dkms"]}],
                    },
                    "repo/debian": {
                        "path": "debian",
                        "rules": [{"paths": ["**"], "targets": ["*"]}],
                    },
                },
            }
        )

        graph = plan.build_dependency_graph(build_map)

        self.assertEqual(graph.forward["package"], frozenset({"vpu-dkms"}))
        self.assertEqual(
            graph.edge_packages[("package", "vpu-dkms")],
            frozenset({"cix-vpu-driver-dev"}),
        )

    def test_target_shell_exposes_internal_build_package_set(self) -> None:
        build_map = self._dependency_fixture()
        graph = plan.build_dependency_graph(build_map)
        target = build_map.targets["package-a"]
        packages = {
            f"{package}={provider}"
            for package, provider in plan.build_environment_packages(
                target.name, graph
            ).items()
        }
        shell = plan.target_shell(target, packages)
        self.assertIn(
            "TARGET_BUILD_PACKAGES=(package-b-dev=package-b package-b-runtime=package-b)",
            shell,
        )

    def test_target_shell_excludes_dependencies_used_only_to_build_a_provider(
        self,
    ) -> None:
        build_map = self._dependency_fixture(transitive=True)
        graph = plan.build_dependency_graph(build_map)
        target = build_map.targets["package-a"]
        packages = {
            f"{package}={provider}"
            for package, provider in plan.build_environment_packages(
                target.name, graph
            ).items()
        }

        shell = plan.target_shell(target, packages)
        self.assertIn("package-b-dev=package-b", shell)
        self.assertIn("package-b-runtime=package-b", shell)
        self.assertNotIn("package-c-dev=package-c", shell)
        self.assertNotIn("package-c-runtime=package-c", shell)

    def test_target_shell_includes_runtime_closure_of_build_packages(self) -> None:
        build_map = self._dependency_fixture(runtime_transitive=True)
        graph = plan.build_dependency_graph(build_map)
        target = build_map.targets["package-a"]
        packages = {
            f"{package}={provider}"
            for package, provider in plan.build_environment_packages(
                target.name, graph
            ).items()
        }

        shell = plan.target_shell(target, packages)
        self.assertEqual(graph.forward["package-b"], frozenset())
        self.assertEqual(
            graph.package_dependencies["package-b-runtime"],
            frozenset({"package-c-runtime"}),
        )
        self.assertNotIn("package-c-dev=package-c", shell)
        self.assertIn("package-c-runtime=package-c", shell)

    def test_build_set_orders_runtime_prerequisites_for_build_dependencies(
        self,
    ) -> None:
        build_map = self._dependency_fixture(runtime_transitive=True)
        result = plan.create_build_set_plan("all-test", build_map)

        self.assertLess(
            result["order"].index("package-c"),
            result["order"].index("package-a"),
        )

    def test_direct_target_can_provide_a_build_package(self) -> None:
        target = plan._target_from_mapping(
            "kernel",
            {
                "description": "kernel",
                "builder": "direct",
                "flow": "kernel-worktree",
                "source": "sources/linux",
                "debian": "debian/kernel",
                "build_packages": ["cix-linux-libc-dev"],
            },
        )

        self.assertEqual(target.build_packages, ("cix-linux-libc-dev",))
        self.assertEqual(target.build_provides, ())

    def test_stable_kernel_versions_share_the_kernel_flow(self) -> None:
        for name, version in (
            ("stable-kernel-6.18", "6.18.48"),
            ("stable-kernel", "7.0.13"),
            ("stable-kernel-7.1", "7.1.12"),
        ):
            with self.subTest(name=name):
                target = plan._target_from_mapping(
                    name,
                    {
                        "description": "stable kernel",
                        "builder": "direct",
                        "flow": "kernel-stable-tarball",
                        "version": version,
                        "patch_source": "sources/linux-main",
                    },
                )

                self.assertEqual(target.builder, "direct")
                self.assertEqual(target.flow, "kernel-stable-tarball")
                self.assertEqual(target.version, version)
                self.assertIsNone(target.control)
                self.assertIn(
                    f"TARGET[version]={version}", plan.target_shell(target)
                )

    def test_mainline_kernel_build_map_versions_and_routing(self) -> None:
        mapping_path = Path(__file__).resolve().parents[1] / "build-map.yaml"
        mapping = yaml.safe_load(mapping_path.read_text(encoding="utf-8"))
        expected = {
            "stable-kernel-6.18": ("6.18.48", "patches-6.18/**"),
            "stable-kernel": ("7.0.13", "patches-7.0/**"),
            "stable-kernel-7.1": ("7.1.12", "patches-7.1/**"),
        }

        self.assertEqual(
            mapping["build_sets"]["mainline-kernels"]["targets"],
            list(expected),
        )
        rules = mapping["projects"]["cix-linux-main"]["rules"]
        for name, (version, patch_pattern) in expected.items():
            with self.subTest(name=name):
                target = mapping["targets"][name]
                self.assertEqual(target["flow"], "kernel-stable-tarball")
                self.assertEqual(target["version"], version)
                self.assertTrue(
                    any(
                        patch_pattern in rule["paths"]
                        and rule["targets"] == [name]
                        for rule in rules
                    )
                )

    def test_audio_sof_is_a_direct_firmware_flow(self) -> None:
        target = plan._target_from_mapping(
            "audio-sof",
            {
                "description": "audio SOF firmware",
                "builder": "direct",
                "flow": "sof-firmware",
                "source": "sources/audio-sof",
                "debian": "debian/audio-sof",
                "build_packages": ["cix-audio-sof"],
            },
        )

        self.assertEqual(target.builder, "direct")
        self.assertEqual(target.flow, "sof-firmware")
        self.assertEqual(target.build_packages, ("cix-audio-sof",))
        self.assertIsNone(target.control)

    def test_sky1_boards_use_the_shared_direct_firmware_flow(self) -> None:
        boards = (
            ("radxa-o6-firmware", "O6"),
            ("radxa-o6n-firmware", "O6N"),
            ("sky1-merak-firmware", "Merak"),
            ("sky1-edge-firmware", "Edge"),
        )
        for target_name, board in boards:
            with self.subTest(target=target_name):
                target = plan._target_from_mapping(
                    target_name,
                    {
                        "description": f"Sky1 {board} firmware",
                        "builder": "direct",
                        "flow": "sky1-firmware",
                        "source": "sources/radxa-o6",
                        "board": board,
                    },
                )

                self.assertEqual(target.builder, "direct")
                self.assertEqual(target.flow, "sky1-firmware")
                self.assertEqual(target.source, "sources/radxa-o6")
                self.assertEqual(target.board, board)
                self.assertIsNone(target.control)

    def test_development_uefi_uses_an_explicit_soc_and_board_selector(self) -> None:
        target = plan._target_from_mapping(
            "sky1p-crb1-uefi",
            {
                "description": "Sky1P CRB1 development UEFI",
                "builder": "direct",
                "flow": "uefi-development",
                "source": "sources/uefi-development",
                "board": "Sky1P-Crb1",
            },
        )

        self.assertEqual(target.flow, "uefi-development")
        self.assertEqual(target.source, "sources/uefi-development")
        self.assertEqual(target.board, "Sky1P-Crb1")
        self.assertIsNone(target.control)

    def test_standalone_mm_uses_its_dedicated_source_tree(self) -> None:
        target = plan._target_from_mapping(
            "uefi-stmm",
            {
                "description": "Sky1 Standalone MM",
                "builder": "direct",
                "flow": "uefi-stmm",
                "source": "sources/uefi-stmm",
            },
        )

        self.assertEqual(target.flow, "uefi-stmm")
        self.assertEqual(target.source, "sources/uefi-stmm")
        self.assertIsNone(target.board)
        self.assertIsNone(target.control)

    def test_secure_firmware_components_use_direct_source_flows(self) -> None:
        components = (
            ("sky1-tf-a", "sources/secure-firmware"),
            ("sky1-pbl", "sources/secure-firmware"),
            ("sky1-optee", "sources/secure-firmware"),
            ("sky1-se-firmware", "sources/radxa-o6"),
        )

        for target_name, source in components:
            with self.subTest(target=target_name):
                target = plan._target_from_mapping(
                    target_name,
                    {
                        "description": f"Sky1 {target_name}",
                        "builder": "direct",
                        "flow": target_name,
                        "source": source,
                    },
                )

                self.assertEqual(target.flow, target_name)
                self.assertEqual(target.source, source)
                self.assertIsNone(target.board)
                self.assertIsNone(target.control)

    def test_radxa_engineering_firmware_is_a_direct_flow(self) -> None:
        target = plan._target_from_mapping(
            "radxa-o6-firmware-engineering",
            {
                "description": "Radxa O6 engineering firmware",
                "builder": "direct",
                "flow": "sky1-firmware-engineering",
                "source": "sources/radxa-o6",
                "board": "O6",
            },
        )

        self.assertEqual(target.flow, "sky1-firmware-engineering")
        self.assertEqual(target.board, "O6")
        self.assertIsNone(target.control)

    def test_pmtool_is_a_direct_artifact_flow(self) -> None:
        target = plan._target_from_mapping(
            "pmtool",
            {
                "description": "CIX PM inspection tool",
                "builder": "direct",
                "flow": "pmtool",
                "source": "sources/cix-binary",
            },
        )

        self.assertEqual(target.flow, "pmtool")
        self.assertEqual(target.source, "sources/cix-binary")
        self.assertIsNone(target.control)

    def test_package_names_are_not_builder_types(self) -> None:
        with self.assertRaisesRegex(plan.PlanError, "unsupported builder/flow"):
            plan._target_from_mapping(
                "firmware",
                {
                    "description": "firmware",
                    "builder": "firmware",
                    "flow": "payload",
                },
            )

    def test_command_selector_target_names_are_reserved(self) -> None:
        for name in ("all", "clean-all", "distclean"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(plan.PlanError, "reserved"):
                    plan._target_from_mapping(
                        name,
                        {
                            "description": "reserved target",
                            "builder": "direct",
                            "flow": "kernel-worktree",
                            "source": "sources/linux",
                            "debian": "debian/kernel",
                        },
                    )

    def test_payload_file_mapping_is_validated(self) -> None:
        target = plan._target_from_mapping(
            "firmware",
            {
                "description": "firmware",
                "builder": "debian",
                "flow": "payload",
                "source": "sources/firmware",
                "source_git": "sources/firmware",
                "debian": "debian/firmware",
                "payload_dir": "firmware",
                "files": ["flat.bin", "nested=firmware/vendor"],
                "required_files": ["flat.bin"],
            },
        )

        self.assertEqual(target.files, ("flat.bin", "nested=firmware/vendor"))

        with self.assertRaisesRegex(plan.PlanError, "stay inside the workspace"):
            plan._target_from_mapping(
                "invalid-firmware",
                {
                    "description": "invalid firmware",
                    "builder": "debian",
                    "flow": "payload",
                    "source": "sources/firmware",
                    "source_git": "sources/firmware",
                    "debian": "debian/firmware",
                    "payload_dir": "firmware",
                    "files": ["firmware.bin=../outside"],
                    "required_files": ["firmware.bin"],
                },
            )

    def test_rule_target_wildcard_expands_to_all_targets(self) -> None:
        self.assertEqual(
            plan._rule_targets(["*"], "test rule", {"zeta", "alpha"}),
            ("alpha", "zeta"),
        )

        with self.assertRaisesRegex(plan.PlanError, "cannot combine"):
            plan._rule_targets(["*", "alpha"], "test rule", {"alpha"})

    def test_workspace_path_maps_to_project(self) -> None:
        build_map = self._dependency_fixture()
        result = plan.create_plan(["sources/a/src/main.c"], build_map)

        self.assertEqual(result["seeds"], ["package-a"])
        self.assertEqual(result["order"], ["package-a"])

    def test_unmapped_change_fails_closed(self) -> None:
        build_map = self._dependency_fixture()

        with self.assertRaisesRegex(plan.PlanError, "unmapped change"):
            plan.create_plan(["repo/a:README.md"], build_map)

    def test_project_change_rejects_parent_traversal(self) -> None:
        build_map = self._dependency_fixture()

        with self.assertRaisesRegex(plan.PlanError, "stay inside project"):
            plan.create_plan(["repo/b:../outside"], build_map)

    def test_explicit_ignore_produces_empty_plan(self) -> None:
        build_map = self._dependency_fixture()
        project = build_map.projects["repo/a"]
        replaced = plan.Project(
            name=project.name,
            path=project.path,
            rules=(plan.Rule(paths=("src/**",), targets=("package-a",)),),
            ignore=("README.md",),
        )
        modified = plan.BuildMap(
            workspace=build_map.workspace,
            executor=build_map.executor,
            targets=build_map.targets,
            build_sets=build_map.build_sets,
            projects={**build_map.projects, "repo/a": replaced},
        )

        result = plan.create_plan(["repo/a:README.md"], modified)
        self.assertEqual(result["seeds"], [])
        self.assertEqual(result["order"], [])

    def test_cycle_is_rejected(self) -> None:
        build_map = self._dependency_fixture()
        control_b = self.fixture.root / "debian/b/control"
        content = control_b.read_text(encoding="utf-8")
        control_b.write_text(
            content.replace(
                "Build-Depends: debhelper-compat (= 13)",
                "Build-Depends: debhelper-compat (= 13), package-a",
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(plan.PlanError, "cycle"):
            plan.build_dependency_graph(build_map)


if __name__ == "__main__":
    unittest.main()
