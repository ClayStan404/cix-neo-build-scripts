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
                "version": 6,
                "executor": "scripts/cix-build",
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

    def test_all_plan_contains_every_target_in_dependency_order(self) -> None:
        build_map = self._dependency_fixture()
        result = plan.create_all_plan(build_map)

        self.assertEqual(result["affected"], ["package-a", "package-b"])
        self.assertEqual(result["order"], ["package-b", "package-a"])
        self.assertEqual(
            result["commands"],
            ["scripts/cix-build package-b", "scripts/cix-build package-a"],
        )
        self.assertEqual(result["reasons"]["package-a"], ["full build requested"])

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
                "version": 6,
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

    def test_all_plan_orders_runtime_prerequisites_for_build_dependencies(
        self,
    ) -> None:
        build_map = self._dependency_fixture(runtime_transitive=True)
        result = plan.create_all_plan(build_map)

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

    def test_stable_kernel_is_a_kernel_flow(self) -> None:
        target = plan._target_from_mapping(
            "stable-kernel",
            {
                "description": "stable kernel",
                "builder": "direct",
                "flow": "kernel-stable-tarball",
                "version": "7.0.13",
                "patch_source": "sources/linux-main",
            },
        )

        self.assertEqual(target.builder, "direct")
        self.assertEqual(target.flow, "kernel-stable-tarball")
        self.assertEqual(target.version, "7.0.13")
        self.assertIsNone(target.control)
        self.assertIn("TARGET[version]=7.0.13", plan.target_shell(target))

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

    def test_radxa_boards_use_the_shared_direct_firmware_flow(self) -> None:
        for board in ("O6", "O6N"):
            with self.subTest(board=board):
                target = plan._target_from_mapping(
                    f"radxa-{board.lower()}-firmware",
                    {
                        "description": f"Radxa {board} firmware",
                        "builder": "direct",
                        "flow": "radxa-firmware",
                        "source": "sources/radxa-o6",
                        "board": board,
                    },
                )

                self.assertEqual(target.builder, "direct")
                self.assertEqual(target.flow, "radxa-firmware")
                self.assertEqual(target.source, "sources/radxa-o6")
                self.assertEqual(target.board, board)
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

    def test_all_target_name_is_reserved(self) -> None:
        with self.assertRaisesRegex(plan.PlanError, "reserved"):
            plan._target_from_mapping(
                "all",
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
