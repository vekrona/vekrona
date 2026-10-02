import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

KICKSTART_DIR = Path(__file__).resolve().parent.parent.parent / "kickstart"
STATE_DIR = "/usr/lib/sysimage/libdnf5"
SWAY_ENVIRONMENT = 'version = "1.0"\n[environments.sway-desktop-environment]\ngroups = ["swaywm"]\n'
CORE_ONLY = 'version = "1.0"\n[groups.core]\nuserinstalled = true\npackages = []\npackage_types = ["mandatory", "default", "conditional"]\n'


def render_release(out):
    subprocess.run(["bash", str(KICKSTART_DIR / "render.sh"), "release", str(out)],
                   check=True, capture_output=True)
    return Path(out).read_text()


def package_guard(kickstart):
    blocks = re.findall(r"^%post (?!--nochroot)[^\n]*\n(.*?)^%end", kickstart, re.M | re.S)
    guards = [b for b in blocks if "package set" in b]
    assert len(guards) == 1, "expected exactly one package guard %post"
    return guards[0]


def run_guard(script, state=None, rpms=()):
    """Run the guard against fake dnf5 state files and an rpm knowing only `rpms`."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        state_dir = tmp / "state"
        state_dir.mkdir()
        for name, text in (state or {}).items():
            (state_dir / name).write_text(text)
        (tmp / "python3").symlink_to(sys.executable)
        rpm = tmp / "rpm"
        rpm.write_text(
            "#!/usr/bin/env bash\n"
            'for p in "${@:3}"; do\n'
            '  case " $VEKRONA_INSTALLED " in\n'
            '    *" $p "*) echo "$p" ;;\n'
            '    *) echo "package $p is not installed" ;;\n'
            "  esac\n"
            "done\n"
            "exit 1\n"
        )
        rpm.chmod(0o755)
        env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "VEKRONA_INSTALLED": " ".join(rpms)}
        return subprocess.run(["bash", "-c", script.replace(STATE_DIR, str(state_dir))],
                              env=env, capture_output=True, text=True)


class PackageGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as tmp:
            cls.guard = package_guard(render_release(Path(tmp) / "release.ks"))

    def assertAborts(self, result, *mentioned):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        for text in mentioned:
            self.assertIn(text, result.stderr)

    def test_no_state_files_means_nothing_selected_so_install_passes(self):
        self.assertEqual(run_guard(self.guard).returncode, 0)

    def test_empty_environments_pass(self):
        state = {"environments.toml": 'version = "1.0"\nenvironments = {}\n'}
        self.assertEqual(run_guard(self.guard, state).returncode, 0)

    def test_core_group_only_passes(self):
        state = {"environments.toml": 'version = "1.0"\nenvironments = {}\n', "groups.toml": CORE_ONLY}
        self.assertEqual(run_guard(self.guard, state, ["git", "sudo"]).returncode, 0)

    def test_installed_environment_aborts_naming_it(self):
        result = run_guard(self.guard, {"environments.toml": SWAY_ENVIRONMENT})
        self.assertAborts(result, "environment sway-desktop-environment", "default package set")

    def test_extra_group_aborts_naming_it(self):
        state = {"groups.toml": CORE_ONLY + '[groups.swaywm-extended]\nuserinstalled = true\n'}
        self.assertAborts(run_guard(self.guard, state), "group swaywm-extended")

    def test_malformed_state_aborts_instead_of_passing(self):
        for name in ("environments.toml", "groups.toml"):
            with self.subTest(name=name):
                self.assertAborts(run_guard(self.guard, {name: "version = [unterminated"}),
                                  "cannot read dnf5 state")

    def test_login_manager_aborts_even_when_state_looks_clean(self):
        for pkg in ("sddm", "gdm", "lightdm", "plasma-workspace", "gnome-shell"):
            with self.subTest(pkg=pkg):
                self.assertAborts(run_guard(self.guard, {"groups.toml": CORE_ONLY}, [pkg]), f"package {pkg}")

    def test_guard_runs_in_the_chroot_with_erroronfail_so_failure_aborts_the_install(self):
        kickstart = (KICKSTART_DIR / "common.ks.tmpl").read_text()
        self.assertRegex(kickstart, r"(?m)^%post --erroronfail --log=\S*package-guard\.log$")
