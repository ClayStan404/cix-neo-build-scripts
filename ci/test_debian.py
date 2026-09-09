"""Exercise Debian dependency installation and isolated quilt preflight."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class DebianBuilderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cix-debian-test.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.scripts = Path(__file__).resolve().parents[1]
        self.write("debian/demo/control", (
            "Source: demo\nBuild-Depends: debhelper-compat (= 13)\n\n"
            "Package: demo\nArchitecture: all\nDescription: test\n Fixture.\n"
        ))
        self.write("debian/demo/changelog", (
            "demo (1-1) trixie; urgency=medium\n\n  * Fixture.\n\n"
            " -- Test <test@example.invalid>  Wed, 09 Sep 2026 00:00:00 +0000\n"
        ))
        self.write("debian/demo/source/format", "3.0 (quilt)\n")
        self.write("sources/demo/value", "before\n")
        self.write("sources/overlay/extra", "overlay\n")
        self.write("sources/demo/drop/ignored", "excluded\n")
        (self.root / "tmp").mkdir()
        for name in ("demo", "overlay"):
            subprocess.run(["git", "init", "-q", str(self.root / "sources" / name)], check=True)

    def write(self, relative: str, content: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_shell(self, body: str) -> subprocess.CompletedProcess:
        script = r'''
set -Eeuo pipefail
CIX_ROOT="$1"
source "$2/builders/debian.sh"
source "$2/builders/preflight.sh"
cix_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cix_log() { printf '%s\n' "$*"; }
cix_require_command() {
    for name in "$@"; do command -v "$name" >/dev/null || cix_die "$name"; done
}
declare -A TARGET=([name]=demo [description]=demo [flow]=quilt
    [source]=sources/demo [source_git]=sources/demo [debian]=debian/demo [validate]='')
TARGET_SOURCE_EXCLUDES=(drop)
TARGET_SOURCE_OVERLAYS=(sources/overlay=components/overlay)
'''
        return subprocess.run(
            ["bash", "-c", script + body, "debian-test", str(self.root), str(self.scripts)],
            text=True, capture_output=True,
            env={**os.environ, "TMPDIR": str(self.root / "tmp"), "LC_ALL": "C"},
        )

    def patch(self, name: str, path: str, before: str, after: str) -> None:
        self.write(f"debian/demo/patches/{name}", (
            f"--- a/{path}\n+++ b/{path}\n@@ -1 +1 @@\n-{before}\n+{after}\n"
        ))

    def test_quilt_preflight_applies_the_ordered_series_after_overlays(self) -> None:
        self.patch("first.patch", "value", "before", "middle")
        self.patch("second.patch", "value", "middle", "after")
        self.patch("overlay.patch", "components/overlay/extra", "overlay", "patched")
        self.write("debian/demo/patches/series", "# test series\nfirst.patch -p1\nsecond.patch\noverlay.patch\n")
        result = self.run_shell("cix_preflight_debian local\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "sources/demo/value").read_text(), "before\n")
        self.assertEqual((self.root / "sources/overlay/extra").read_text(), "overlay\n")
        self.assertFalse((self.root / "sources/demo/.pc").exists())
        self.assertEqual(list((self.root / "tmp").iterdir()), [])

    def test_quilt_preflight_rejects_unapplicable_and_excluded_input_patches(self) -> None:
        for path, before in (("value", "wrong base"), ("drop/ignored", "excluded")):
            with self.subTest(path=path):
                self.patch("broken.patch", path, before, "after")
                self.write("debian/demo/patches/series", "broken.patch\n")
                result = self.run_shell("cix_preflight_debian local\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list((self.root / "tmp").iterdir()), [])
                self.assertEqual((self.root / "sources/demo/value").read_text(), "before\n")

    def test_missing_overlay_fails_even_without_a_patch_series(self) -> None:
        result = self.run_shell(
            "TARGET_SOURCE_OVERLAYS=(sources/missing=components/overlay)\ncix_preflight_debian local\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source directory is missing", result.stderr)

    def test_same_version_internal_package_is_reinstalled(self) -> None:
        control = (
            "Package: review-dependency\nVersion: 1\nArchitecture: all\n"
            "Maintainer: Test <test@example.invalid>\nDescription: test fixture\n"
        )
        self.write("package/DEBIAN/control", control)
        self.write("package/usr/share/review-dependency/value", "new package contents")
        self.write("status", control + "Status: install ok installed\n\n")
        output = self.root / "output/provider"
        output.mkdir(parents=True)
        subprocess.run(
            ["dpkg-deb", "--root-owner-group", "-Znone", "--build",
             str(self.root / "package"), str(output / "review-dependency_1_all.deb")],
            check=True, capture_output=True,
        )
        result = self.run_shell(r'''
sudo() { [[ "$1" == DEBIAN_FRONTEND=noninteractive ]]; shift; "$@"; }
apt-get() {
    command apt-get --simulate \
        -o "Dir::State::status=${CIX_ROOT}/status" \
        -o Dir::Etc::sourcelist=/dev/null \
        -o Dir::Etc::sourceparts=- "$@"
}
TARGET_BUILD_PACKAGES=(review-dependency=provider)
cix_install_local_internal_dependencies
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 reinstalled", result.stdout)
        self.assertIn("Inst review-dependency", result.stdout)


if __name__ == "__main__":
    unittest.main()
