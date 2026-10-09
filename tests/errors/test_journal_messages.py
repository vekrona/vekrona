from harness import SandboxTestCase, journal_entry

QML_ERROR = "\x1b[31m ERROR\x1b[97m qml\x1b[0m: VekronaSwayWorkspaces: barConfig.widgetPadding is missing"


class JournalMessagesTest(SandboxTestCase):
    def recorded(self):
        out = self.sandbox.run("show", self.sandbox.latest_error_id()).stdout
        return dict(line.split(": ", 1) for line in out.splitlines() if ": " in line)

    def listed(self):
        return self.sandbox.run("list", "--all").stdout.splitlines()[1:]

    def test_a_qml_error_that_dms_logs_at_info_priority_is_recorded_without_colour_codes(self):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER="dms", PRIORITY="6", MESSAGE=QML_ERROR)])
        record = self.recorded()
        self.assertEqual(record["title"], "dms: VekronaSwayWorkspaces: barConfig.widgetPadding is missing")
        self.assertEqual(record["summary"], "VekronaSwayWorkspaces: barConfig.widgetPadding is missing")

    def test_a_qml_error_that_the_vekrona_shell_logs_at_info_priority_is_recorded_without_colour_codes(self):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER="vekrona-shell", PRIORITY="6", MESSAGE=QML_ERROR)])
        record = self.recorded()
        self.assertEqual(record["title"], "vekrona-shell: VekronaSwayWorkspaces: barConfig.widgetPadding is missing")
        self.assertEqual(record["summary"], "VekronaSwayWorkspaces: barConfig.widgetPadding is missing")

    def test_a_qml_error_arriving_as_a_byte_array_is_recorded(self):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER="dms", PRIORITY="6",
                                          MESSAGE=list(QML_ERROR.encode()))])
        self.assertEqual(len(self.listed()), 1)

    def test_dms_info_and_warning_lines_are_not_errors(self):
        self.sandbox.watch([
            journal_entry(SYSLOG_IDENTIFIER="dms", PRIORITY="6", MESSAGE="\x1b[33m  WARN\x1b[97m qml\x1b[0m: slow"),
            journal_entry(SYSLOG_IDENTIFIER="dms", PRIORITY="6", MESSAGE="\x1b[32m  INFO\x1b[97m qml\x1b[0m: ok"),
        ])
        self.assertEqual(self.listed(), [])

    def test_another_program_cannot_pass_info_lines_off_as_qml_errors(self):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER="other", PRIORITY="6", MESSAGE=QML_ERROR)])
        self.assertEqual(self.listed(), [])

    def test_an_error_with_an_empty_message_says_so(self):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER="kernel", MESSAGE="")])
        record = self.recorded()
        self.assertEqual(record["title"], "kernel: empty error message")
        self.assertIn("MESSAGE is empty", record["summary"])

    def test_an_error_whose_message_is_only_whitespace_is_also_empty(self):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER="kernel", MESSAGE=" \n\t")])
        self.assertEqual(self.recorded()["title"], "kernel: empty error message")

    def test_an_error_whose_message_is_a_byte_array_is_decoded(self):
        self.sandbox.watch([journal_entry(MESSAGE=list("disk érror".encode()))])
        self.assertEqual(self.recorded()["summary"], "disk érror")
