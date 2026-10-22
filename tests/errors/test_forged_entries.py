import os
import unittest

from harness import (SandboxTestCase, coredump_entry, journal_entry, report_entry,
                     system_unit_failed_entry, user_manager_fields, user_unit_failed_entry,
                     MESSAGE_ID_KERNEL_OOM, MESSAGE_ID_OOMD_KILL, MESSAGE_ID_UNIT_FAILED, OOMD_EXE, SYSTEMD_EXE)

ATTACKER = "-Hattacker.example"


class ForgedJournalEntriesTest(SandboxTestCase):
    def sources_listed(self):
        rows = self.sandbox.run("list", "--all").stdout.splitlines()[1:]
        return [row.split()[1] for row in rows]

    def external_calls_mentioning(self, needle):
        return [call for call in self.sandbox.external_calls() if needle in call]

    def forged_unit_entry(self, **fields):
        return journal_entry(MESSAGE_ID=MESSAGE_ID_UNIT_FAILED, SYSLOG_IDENTIFIER="systemd",
                             _PID="31337", _UID=str(os.getuid()), _EXE="/usr/bin/evil", **fields)

    def test_a_forged_system_unit_never_reaches_an_external_command(self):
        self.sandbox.watch([self.forged_unit_entry(UNIT=ATTACKER)])
        self.assertEqual(self.external_calls_mentioning("attacker"), [])

    def test_a_forged_user_unit_never_reaches_an_external_command(self):
        self.sandbox.watch([self.forged_unit_entry(USER_UNIT=ATTACKER)])
        self.assertEqual(self.external_calls_mentioning("attacker"), [])

    def test_a_forged_unit_failure_is_not_recorded_as_a_unit_failure(self):
        self.sandbox.watch([self.forged_unit_entry(UNIT="innocent.service")])
        self.assertNotIn("unit", self.sources_listed())
        self.assertEqual(self.external_calls_mentioning("innocent.service"), [])

    def test_another_users_manager_is_not_trusted_for_user_units(self):
        other_uid = str(os.getuid() + 1)
        entry = user_unit_failed_entry("theirs.service")
        entry.update(_UID=other_uid, _SYSTEMD_UNIT=f"user@{other_uid}.service")
        self.sandbox.watch([entry])
        self.assertEqual(self.external_calls_mentioning("theirs.service"), [])

    def test_a_trusted_sender_naming_an_option_instead_of_a_unit_is_not_run(self):
        self.sandbox.watch([system_unit_failed_entry(ATTACKER), user_unit_failed_entry(ATTACKER)])
        self.assertEqual(self.external_calls_mentioning("attacker"), [])

    def test_a_forged_coredump_never_reaches_coredumpctl(self):
        self.sandbox.watch([coredump_entry("--evil", _EXE="/usr/bin/evil", _SYSTEMD_UNIT="x.service")])
        self.assertEqual(self.external_calls_mentioning("--evil"), [])
        self.assertFalse([c for c in self.sandbox.external_calls() if c.startswith("coredumpctl")])

    def test_a_coredump_whose_handler_exe_journald_could_not_read_is_still_recorded(self):
        self.sandbox.watch([coredump_entry("1234", _EXE=None)])
        self.assertEqual(self.sources_listed(), ["coredump"])

    def test_a_coredump_from_the_handler_with_a_non_numeric_pid_is_not_run(self):
        self.sandbox.watch([coredump_entry("--evil")])
        self.assertFalse([c for c in self.sandbox.external_calls() if c.startswith("coredumpctl")])

    def test_a_report_cannot_claim_the_unit_or_coredump_source(self):
        self.sandbox.watch([report_entry("fake", source="unit"), report_entry("fake2", source="coredump")])
        self.assertEqual(set(self.sources_listed()), {"manual"})

    def test_legitimate_failures_are_captured_with_the_unit_after_a_double_dash(self):
        self.sandbox.watch([
            system_unit_failed_entry("sys-thing.service"),
            user_unit_failed_entry("user-thing.service"),
            coredump_entry("1234"),
        ])
        calls = self.sandbox.external_calls()
        self.assertIn("systemctl status -- sys-thing.service", calls)
        self.assertIn("systemctl --user status -- user-thing.service", calls)
        self.assertIn("coredumpctl info -- 1234", calls)
        self.assertEqual(sorted(self.sources_listed()), ["coredump", "unit", "unit"])

    def test_escaped_and_templated_unit_names_are_accepted(self):
        names = ["systemd-cryptsetup@luks\\x2d248623e7.service", "dbus-:1.3-org.gnome.Settings@0.service"]
        self.sandbox.watch([system_unit_failed_entry(name) for name in names])
        self.assertEqual(self.sources_listed(), ["unit", "unit"])

    def oom_entry(self, message_id, message="killed a process", **sender):
        return journal_entry(MESSAGE_ID=message_id, PRIORITY="6", MESSAGE=message, PID="4321",
                             **{"_PID": "31337", "_UID": str(os.getuid()), "_EXE": "/usr/bin/evil", **sender})

    def test_an_oom_kill_from_a_process_that_is_not_the_system_is_not_recorded_as_one(self):
        self.sandbox.watch([self.oom_entry(MESSAGE_ID_KERNEL_OOM), self.oom_entry(MESSAGE_ID_OOMD_KILL)])
        self.assertEqual(self.sources_listed(), [])

    def test_an_oom_kill_of_systemd_oomd_is_recorded_when_oomd_says_it(self):
        self.sandbox.watch([self.oom_entry(MESSAGE_ID_OOMD_KILL, _UID="0", _EXE=OOMD_EXE)])
        self.assertEqual(self.sources_listed(), ["oom"])

    def test_an_oom_kill_of_the_kernel_is_recorded_when_a_manager_says_it(self):
        self.sandbox.watch([self.oom_entry(MESSAGE_ID_KERNEL_OOM, "the system manager killed a process", _UID="0", _EXE=SYSTEMD_EXE, _PID="1"),
                            self.oom_entry(MESSAGE_ID_KERNEL_OOM, "the user manager killed a process", **user_manager_fields())])
        self.assertEqual(self.sources_listed(), ["oom", "oom"])

    def test_a_report_from_another_user_is_not_recorded_as_a_report(self):
        forged = report_entry("fake")
        forged.update(_UID=str(os.getuid() + 1), PRIORITY="6")
        self.sandbox.watch([forged])
        self.assertEqual(self.sources_listed(), [])

    def test_a_report_from_root_is_recorded(self):
        entry = report_entry("from the update unit")
        entry.update(_UID="0")
        self.sandbox.watch([entry])
        self.assertEqual(self.sources_listed(), ["manual"])

    def test_pids_and_identifiers_of_other_records_follow_a_double_dash(self):
        self.sandbox.watch([journal_entry(_PID="777", MESSAGE="boom")])
        self.assertIn("journalctl -n 200 -o short-iso -- _PID=777", self.sandbox.external_calls())


if __name__ == "__main__":
    unittest.main()
