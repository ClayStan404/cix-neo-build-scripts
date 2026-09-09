"""Exercise resumable builds with real Git inputs and disposable Debian packages."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

import build_state
import plan


class ResumeIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cix-resume-test.")
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name)
        self.state_root = self.workspace / "output/.cix-state"
        self.map_path = self.workspace / "build-scripts/build-map.yaml"
        targets = {}
        for name, dependency in (("base", ""), ("provider", "base"), ("consumer", "provider")):
            self.write(f"sources/{name}/input", "original")
            build_depends = f"Build-Depends: package-{dependency}\n" if dependency else ""
            self.write(
                f"debian/{name}/control",
                f"Source: package-{name}\n{build_depends}\nPackage: package-{name}\n"
                "Architecture: all\nDescription: test package\n Fixture.\n",
            )
            targets[name] = {
                "description": name, "builder": "debian", "flow": "quilt",
                "source": f"sources/{name}", "source_git": f"sources/{name}",
                "debian": f"debian/{name}",
            }
        self.write("sources/shared/input", "shared library")
        (self.workspace / "sources/provider/shared").symlink_to("../shared")
        targets["provider"]["inputs"] = ["sources/provider/shared"]
        self.write("build-scripts/cix-build", "#!/bin/sh\n")
        (self.workspace / "build-scripts/cix-build").chmod(0o755)
        for name in ("ci/plan.py", "ci/build_state.py", "ci/artifacts.py", "sbuild/config.pl"):
            self.write(f"build-scripts/{name}", "fixture")
        self.map_path.write_text(yaml.safe_dump({
            "version": 7,
            "executor": "build-scripts/cix-build",
            "targets": targets,
            "projects": {
                name: {"path": f"sources/{name}", "rules": [{"paths": ["**"], "targets": [name]}]}
                for name in targets
            },
        }))
        repositories = ["build-scripts", "debian", "sources/base", "sources/provider", "sources/consumer", "sources/shared"]
        self.write(".repo/project.list", "\n".join(repositories))
        for name in repositories:
            repository = self.workspace / name
            self.run_command("git", "init", "-q", str(repository))
            self.run_command("git", "-C", str(repository), "add", ".")
            self.run_command(
                "git", "-C", str(repository), "-c", "user.name=Test",
                "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                "commit", "-qm", "fixture",
            )
        for name in targets:
            self.package(name, "original")
            self.record(name)

    def write(self, name: str, content: str) -> Path:
        path = self.workspace / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_command(self, *command: str) -> None:
        subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def package(self, name: str, content: str) -> None:
        directory = f"packaging/{name}"
        self.write(f"{directory}/DEBIAN/control", (
            f"Package: package-{name}\nVersion: 1\nArchitecture: all\n"
            "Maintainer: Test <test@example.invalid>\nDescription: test fixture\n"
        ))
        self.write(f"{directory}/usr/share/{name}/input", content)
        output = self.workspace / "output" / name
        output.mkdir(parents=True, exist_ok=True)
        self.run_command(
            "dpkg-deb", "--root-owner-group", "-Znone", "--build",
            str(self.workspace / directory), str(output / f"package-{name}_1_all.deb"),
        )

    def fingerprint(self, name: str = "consumer") -> tuple[str, dict]:
        return build_state.fingerprint(name, "local", self.workspace, self.map_path, self.state_root)

    def record(self, name: str) -> dict:
        value, details = self.fingerprint(name)
        return build_state.record_target(
            name, "local", value, details, 0, self.workspace / "build.log",
            self.workspace, self.state_root,
        )

    def test_unchanged_verified_dependencies_can_resume(self) -> None:
        value, details = self.fingerprint()
        self.assertTrue(details["dependencies"]["provider"]["verified"])
        self.assertTrue(build_state.state_is_valid(self.state_root / "targets/consumer.json", value, self.workspace)[0])

    def test_same_version_rebuilt_dependency_invalidates_consumer(self) -> None:
        before, _ = self.fingerprint()
        provider_before, _ = self.fingerprint("provider")
        self.package("provider", "rebuilt package, same version")
        changed, details = self.fingerprint()
        self.assertNotEqual(before, changed)
        self.assertFalse(details["dependencies"]["provider"]["verified"])
        self.record("provider")
        provider_after, _ = self.fingerprint("provider")
        after, details = self.fingerprint()
        self.assertEqual(provider_before, provider_after)
        self.assertNotEqual(before, after)
        self.assertTrue(details["dependencies"]["provider"]["verified"])
        self.assertFalse(build_state.state_is_valid(self.state_root / "targets/consumer.json", after, self.workspace)[0])

    def test_transitive_dependency_changes_are_detected(self) -> None:
        before, _ = self.fingerprint()
        self.package("base", "rebuilt base")
        self.record("base")
        after, details = self.fingerprint()
        self.assertNotEqual(before, after)
        self.assertFalse(details["dependencies"]["provider"]["verified"])

    def test_source_changes_invalidate_old_dependency_state(self) -> None:
        before, _ = self.fingerprint()
        self.write("sources/provider/input", "new source, old binary")
        after, details = self.fingerprint()
        self.assertNotEqual(before, after)
        self.assertFalse(details["dependencies"]["provider"]["verified"])

    def test_missing_dependency_package_invalidates_consumer(self) -> None:
        before, _ = self.fingerprint()
        (self.workspace / "output/provider/package-provider_1_all.deb").unlink()
        after, details = self.fingerprint()
        self.assertNotEqual(before, after)
        self.assertFalse(details["dependencies"]["provider"]["verified"])
        self.assertFalse(build_state.state_is_valid(
            self.state_root / "targets/consumer.json", after, self.workspace
        )[0])

    def test_linked_repository_and_build_configuration_are_inputs(self) -> None:
        for relative in ("sources/shared/input", "build-scripts/sbuild/config.pl", "build-scripts/ci/artifacts.py"):
            with self.subTest(path=relative):
                before, _ = self.fingerprint("provider")
                self.write(relative, "changed")
                after, _ = self.fingerprint("provider")
                self.assertNotEqual(before, after)

    def test_missing_or_corrupt_provider_state_never_becomes_resumable(self) -> None:
        path = self.state_root / "targets/provider.json"
        for content in (None, "not json"):
            with self.subTest(state=content):
                if content is None:
                    path.unlink()
                else:
                    path.write_text(content)
                state = self.record("consumer")
                self.assertFalse(state["resumable"])
                valid, _ = build_state.state_is_valid(
                    self.state_root / "targets/consumer.json", state["fingerprint"], self.workspace
                )
                self.assertFalse(valid)

    def test_old_state_version_is_invalidated(self) -> None:
        path = self.state_root / "targets/consumer.json"
        state = json.loads(path.read_text())
        state["version"] = 2
        path.write_text(json.dumps(state))
        self.assertFalse(build_state.state_is_valid(path, state["fingerprint"], self.workspace)[0])


if __name__ == "__main__":
    unittest.main()
