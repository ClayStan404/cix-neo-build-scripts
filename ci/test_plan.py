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

    def _dependency_fixture(self) -> plan.BuildMap:
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
Description: package B development files
 Test package B.

Package: package-b-runtime
Architecture: any
Description: package B runtime
 Test runtime package B.
""",
        )
        return self.fixture.mapping(
            {
                "version": 5,
                "executor": "scripts/cix-build",
                "targets": {
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
                },
                "projects": {
                    "repo/a": {
                        "path": "sources/a",
                        "rules": [{"paths": ["src/**"], "targets": ["package-a"]}],
                    },
                    "repo/b": {
                        "path": "sources/b",
                        "rules": [{"paths": ["**"], "targets": ["package-b"]}],
                    },
                },
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

    def test_package_names_are_not_builder_types(self) -> None:
        with self.assertRaisesRegex(plan.PlanError, "unsupported builder/flow"):
            plan._target_from_mapping(
                "firmware",
                {
                    "description": "firmware",
                    "builder": "firmware",
                    "flow": "firmware",
                },
            )

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
