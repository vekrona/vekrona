import os
import unittest

from harness import REPO, SandboxTestCase, journal_entry

TDX_MUTE = """
[[mute]]
identifier = "kernel"
message = 'virt/tdx: TDX not supported by the host platform'
reason = "optional CPU feature"
"""

TDX_MESSAGE = "virt/tdx: TDX not supported by the host platform"


class DefaultMutesTest(SandboxTestCase):
    def listed(self):
        return self.sandbox.run("list", "--all").stdout.splitlines()[1:]

    def watch_kernel(self, message, identifier="kernel"):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER=identifier, MESSAGE=message)])

    def test_a_muted_default_makes_no_record(self):
        self.sandbox.install_default_mutes(TDX_MUTE)
        self.watch_kernel(TDX_MESSAGE)
        self.assertEqual(self.listed(), [])

    def test_without_the_default_the_same_entry_is_recorded(self):
        self.watch_kernel(TDX_MESSAGE)
        self.assertEqual(len(self.listed()), 1)

    def test_another_error_from_the_same_identifier_still_surfaces(self):
        self.sandbox.install_default_mutes(TDX_MUTE)
        self.watch_kernel("EXT4-fs error (device vda3): unable to read inode")
        self.assertEqual(len(self.listed()), 1)

    def test_a_longer_message_that_merely_contains_the_pattern_still_surfaces(self):
        self.sandbox.install_default_mutes(TDX_MUTE)
        self.watch_kernel(TDX_MESSAGE + ", and then the machine caught fire")
        self.assertEqual(len(self.listed()), 1)

    def test_the_same_message_from_another_identifier_still_surfaces(self):
        self.sandbox.install_default_mutes(TDX_MUTE)
        self.watch_kernel(TDX_MESSAGE, identifier="not-the-kernel")
        self.assertEqual(len(self.listed()), 1)

    def test_every_file_in_the_directory_applies(self):
        self.sandbox.install_default_mutes(TDX_MUTE, name="10-a.conf")
        self.sandbox.install_default_mutes(TDX_MUTE.replace("kernel", "greetd"), name="20-b.conf")
        self.watch_kernel(TDX_MESSAGE)
        self.watch_kernel(TDX_MESSAGE, identifier="greetd")
        self.assertEqual(self.listed(), [])

    # The broken rule is itself recorded as an error, next to the kernel entry it failed to mute.
    def assert_recorded_beside_the_unmuted_entry(self, detail):
        listed = self.listed()
        self.assertEqual(len(listed), 2, listed)
        (broken,) = [line for line in listed if "invalid mute pattern" in line]
        shown = self.sandbox.run("show", broken.split()[0]).stdout
        self.assertIn(detail, shown)

    def test_an_invalid_default_is_recorded_by_name_and_does_not_mute(self):
        self.sandbox.install_default_mutes('[[mute]]\nidentifier = "kernel"\nmessage = "("\nreason = "x"\n',
                                           name="10-broken.conf")
        self.watch_kernel(TDX_MESSAGE)
        self.assert_recorded_beside_the_unmuted_entry("10-broken.conf")

    def test_a_default_without_a_reason_is_rejected(self):
        self.sandbox.install_default_mutes('[[mute]]\nidentifier = "kernel"\nmessage = "x"\n')
        self.watch_kernel("x")
        self.assert_recorded_beside_the_unmuted_entry("reason")

    def test_a_syntax_error_in_a_default_file_is_recorded_and_does_not_mute(self):
        self.sandbox.install_default_mutes("this is not toml", name="10-garbage.conf")
        self.watch_kernel(TDX_MESSAGE)
        self.assert_recorded_beside_the_unmuted_entry("10-garbage.conf")

    def test_files_not_ending_in_conf_are_ignored(self):
        self.sandbox.install_default_mutes(TDX_MUTE, name="10-test.conf.disabled")
        self.watch_kernel(TDX_MESSAGE)
        self.assertEqual(len(self.listed()), 1)

    def test_a_missing_directory_mutes_nothing(self):
        self.assertFalse(os.path.exists(self.sandbox.default_mutes_dir))
        self.watch_kernel(TDX_MESSAGE)
        self.assertEqual(len(self.listed()), 1)


class ShippedDefaultMutesTest(SandboxTestCase):
    def setUp(self):
        super().setUp()
        with open(os.path.join(REPO, "etc", "vekrona", "errors-mute.d", "10-vendor-noise.conf")) as f:
            self.sandbox.install_default_mutes(f.read())

    def watch_journal_error(self, identifier, message):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER=identifier, MESSAGE=message)])

    def recorded(self):
        return self.sandbox.run("list", "--all").stdout.splitlines()[1:]

    def test_the_boot_noise_of_a_stock_install_is_muted(self):
        self.watch_journal_error("kernel", "virt/tdx: TDX not supported by the host platform")
        self.watch_journal_error("greetd", "gkr-pam: unable to locate daemon control file")
        self.assertEqual(self.recorded(), [])

    def test_other_greetd_and_kernel_errors_still_surface(self):
        self.watch_journal_error("greetd", "gkr-pam: couldn't unlock the login keyring")
        self.watch_journal_error("kernel", "virt/tdx: TDX module initialization failed")
        self.assertEqual(len(self.recorded()), 2)

    def test_a_kernel_entry_with_an_empty_message_is_muted(self):
        self.watch_journal_error("kernel", "")
        self.assertEqual(self.recorded(), [])

    def test_the_hp_omen_acpi_firmware_bug_is_muted_but_another_acpi_error_is_not(self):
        self.watch_journal_error("kernel", "ACPI Error: Region SystemCMOS (ID=5) has no handler (20260408/exfldio-261)")
        self.assertEqual(self.recorded(), [])
        self.watch_journal_error("kernel", "ACPI Error: Region EmbeddedControl (ID=3) has no handler (20260408/exfldio-261)")
        self.assertEqual(len(self.recorded()), 1)


if __name__ == "__main__":
    unittest.main()
