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

    def test_a_muted_default_makes_no_record_and_no_toast(self):
        self.sandbox.install_default_mutes(TDX_MUTE)
        self.watch_kernel(TDX_MESSAGE)
        self.assertEqual(self.listed(), [])
        self.assertEqual(self.sandbox.sent_notifications(), [])

    def test_without_the_default_the_same_entry_is_recorded_and_toasted(self):
        self.watch_kernel(TDX_MESSAGE)
        self.assertEqual(len(self.listed()), 1)
        self.assertEqual(len(self.sandbox.sent_notifications()), 1)

    def test_another_error_from_the_same_identifier_still_surfaces(self):
        self.sandbox.install_default_mutes(TDX_MUTE)
        self.watch_kernel("EXT4-fs error (device vda3): unable to read inode")
        self.assertEqual(len(self.listed()), 1)
        self.assertEqual(len(self.sandbox.sent_notifications()), 1)

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

    def test_an_invalid_default_is_toasted_by_name_and_does_not_mute(self):
        self.sandbox.install_default_mutes('[[mute]]\nidentifier = "kernel"\nmessage = "("\nreason = "x"\n',
                                           name="10-broken.conf")
        self.watch_kernel(TDX_MESSAGE)
        bodies = [n["body"] for n in self.sandbox.sent_notifications()]
        self.assertTrue(any("10-broken.conf" in body and "invalid mute" in body for body in bodies), bodies)
        self.assertEqual(len(self.listed()), 1)

    def test_a_default_without_a_reason_is_rejected(self):
        self.sandbox.install_default_mutes('[[mute]]\nidentifier = "kernel"\nmessage = "x"\n')
        self.watch_kernel("x")
        self.assertEqual(len(self.listed()), 1)
        self.assertTrue(any("reason" in n["body"] for n in self.sandbox.sent_notifications()))

    def test_a_syntax_error_in_a_default_file_is_toasted_and_does_not_mute(self):
        self.sandbox.install_default_mutes("this is not toml", name="10-garbage.conf")
        self.watch_kernel(TDX_MESSAGE)
        self.assertTrue(any("10-garbage.conf" in n["body"] for n in self.sandbox.sent_notifications()))
        self.assertEqual(len(self.listed()), 1)

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
        self.assertEqual(self.sandbox.sent_notifications(), [])

    def test_other_greetd_and_kernel_errors_still_surface(self):
        self.watch_journal_error("greetd", "gkr-pam: couldn't unlock the login keyring")
        self.watch_journal_error("kernel", "virt/tdx: TDX module initialization failed")
        self.assertEqual(len(self.recorded()), 2)


if __name__ == "__main__":
    unittest.main()
