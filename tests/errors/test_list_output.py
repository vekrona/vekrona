import json
import os
import unittest

from harness import SandboxTestCase, report_entry

MULTI_LINE_TITLE = "vekrona-lock: cannot start the lock screen:\nJob for vekrona-lock.service failed\n\tsee journalctl"
ONE_LINE_TITLE = "vekrona-lock: cannot start the lock screen: Job for vekrona-lock.service failed see journalctl"


class ListOutputTest(SandboxTestCase):
    def listed_rows(self):
        return self.sandbox.run("list", "--all").stdout.split("\n")[1:-1]

    def test_a_report_with_a_multi_line_title_lists_as_one_line(self):
        self.sandbox.watch([report_entry(MULTI_LINE_TITLE)])
        (row,) = self.listed_rows()
        self.assertTrue(row.endswith(ONE_LINE_TITLE), row)
        self.assertIn(f"title: {ONE_LINE_TITLE}\n", self.sandbox.run("show", row.split()[0]).stdout)

    def test_a_stored_record_with_a_multi_line_title_lists_as_one_line(self):
        error_id = self.sandbox.ingest_report("a title")
        path = os.path.join(self.sandbox.store_dir(), error_id, "record.json")
        with open(path) as f:
            record = json.load(f)
        record["title"] = MULTI_LINE_TITLE
        with open(path, "w") as f:
            json.dump(record, f)
        (row,) = self.listed_rows()
        self.assertTrue(row.endswith(ONE_LINE_TITLE), row)


HOSTILE = "red\x1b[31m\x1b]52;c;cGF3bmVk\x07 gone\x9b2J\x00 done"
DEFANGED = "red\ufffd[31m\ufffd]52;c;cGF3bmVk\ufffd gone\ufffd2J\ufffd done"


# The text of a record came from the journal, and a terminal obeys the control characters in it.
class ControlCharactersTest(SandboxTestCase):
    def setUp(self):
        super().setUp()
        self.error_id = self.sandbox.ingest_report("a title")
        self.record_path = os.path.join(self.sandbox.store_dir(), self.error_id, "record.json")

    def rewrite_record(self, **fields):
        with open(self.record_path) as f:
            record = json.load(f)
        record.update(fields)
        with open(self.record_path, "w") as f:
            json.dump(record, f)

    def test_list_prints_no_control_characters_of_a_title(self):
        self.rewrite_record(title=HOSTILE)
        out = self.sandbox.run("list", "--all").stdout
        self.assertTrue(out.rstrip("\n").endswith(DEFANGED), out)

    def test_show_prints_no_control_characters_of_any_field(self):
        self.rewrite_record(title=HOSTILE, summary=HOSTILE, exe=HOSTILE)
        out = self.sandbox.run("show", self.error_id).stdout
        self.assertEqual(out.count(DEFANGED), 3, out)
        self.assertNotRegex(out, "[\x00-\x08\x0b-\x1f\x7f-\x9f]")

    def test_show_prints_the_captured_context_without_control_characters_but_keeps_its_lines_and_tabs(self):
        with open(os.path.join(self.sandbox.store_dir(), self.error_id, "context.txt"), "w") as f:
            f.write(f"$ journalctl\n\t{HOSTILE}\nprogress\r100%\n")
        out = self.sandbox.run("show", self.error_id).stdout
        self.assertIn(f"\n\t{DEFANGED}\nprogress\ufffd100%\n", out)
        self.assertNotRegex(out, "[\x00-\x08\x0b-\x1f\x7f-\x9f]")


if __name__ == "__main__":
    unittest.main()
