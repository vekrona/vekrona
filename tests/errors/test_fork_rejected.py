from harness import SandboxTestCase, journal_entry

SCOPE = "app-ghostty-surface-1234.scope"
CGROUP = f"/user.slice/user-1000.slice/user@1000.service/app.slice/{SCOPE}"
REJECTION = f"cgroup: fork rejected by pids controller in {CGROUP}"


def kernel_entry(message, **fields):
    return journal_entry(SYSLOG_IDENTIFIER="kernel", PRIORITY="6", _TRANSPORT="kernel", MESSAGE=message, **fields)


class ForkRejectedTest(SandboxTestCase):
    def recorded(self):
        out = self.sandbox.run("show", self.sandbox.latest_error_id()).stdout
        return dict(line.split(": ", 1) for line in out.splitlines() if ": " in line)

    def listed(self):
        return self.sandbox.run("list", "--all").stdout.splitlines()[1:]

    def test_a_scope_that_hits_its_process_limit_is_recorded_though_the_kernel_logs_it_at_info_priority(self):
        self.sandbox.watch([kernel_entry(REJECTION)])
        record = self.recorded()
        self.assertEqual(record["title"], f"fork rejected: {SCOPE} hit its process limit")
        self.assertEqual(record["summary"], REJECTION)

    def test_repeated_rejections_in_one_scope_make_one_record(self):
        self.sandbox.watch([kernel_entry(REJECTION)] * 3)
        self.assertEqual(len(self.listed()), 1)

    def test_rejections_in_two_scopes_make_two_records(self):
        self.sandbox.watch([kernel_entry(REJECTION), kernel_entry(REJECTION.replace("1234", "5678"))])
        self.assertEqual(len(self.listed()), 2)

    def test_the_context_is_the_kernel_log(self):
        self.sandbox.watch([kernel_entry(REJECTION)])
        self.assertIn("journalctl -k -n 200 -o short-iso", self.sandbox.external_calls())

    def test_another_program_cannot_pass_the_message_off_as_a_kernel_line(self):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER="kernel", PRIORITY="6", MESSAGE=REJECTION)])
        self.assertEqual(self.listed(), [])

    def test_other_kernel_info_lines_are_not_errors(self):
        self.sandbox.watch([kernel_entry("cgroup: fork rejected by pids controller"), kernel_entry("usb 1-1: new device")])
        self.assertEqual(self.listed(), [])
