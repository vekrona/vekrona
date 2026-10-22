import json
import os
import stat
import unittest

from harness import SandboxTestCase

NOT_A_RECORD = ["[1]", '"text"', "null", "{}", "7"]


class RecordSchemaTest(SandboxTestCase):
    def record_path(self, error_id):
        return os.path.join(self.sandbox.store_dir(), error_id, "record.json")

    def stored(self, error_id):
        with open(self.record_path(error_id)) as f:
            return json.load(f)

    def overwrite(self, error_id, record):
        with open(self.record_path(error_id), "w") as f:
            f.write(record if isinstance(record, str) else json.dumps(record))

    def assert_quarantined(self, error_id):
        self.assertTrue(os.path.isfile(self.record_path(error_id) + ".corrupt"))
        self.assertFalse(os.path.exists(self.record_path(error_id)))

    # The journal of these tests ends at once, which ends the watcher with status 1 so that systemd restarts it. A watcher that
    # could not read the store never gets as far as following the journal.
    def assert_watcher_reached_the_journal(self, result):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("journalctl exited unexpectedly", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_json_that_is_not_a_record_is_quarantined_and_the_watcher_still_starts(self):
        for content in NOT_A_RECORD:
            with self.subTest(content=content):
                error_id = self.sandbox.ingest_report(f"corrupted into {content}")
                self.overwrite(error_id, content)
                result = self.sandbox.watch([])
                self.assert_watcher_reached_the_journal(result)
                self.assert_quarantined(error_id)

    def test_a_record_missing_a_field_the_store_indexes_is_quarantined_and_the_watcher_still_starts(self):
        error_id = self.sandbox.ingest_report("lost its fingerprint")
        record = self.stored(error_id)
        del record["fingerprint"]
        self.overwrite(error_id, record)
        result = self.sandbox.watch([])
        self.assert_watcher_reached_the_journal(result)
        self.assert_quarantined(error_id)

    def test_a_record_with_a_count_that_is_not_a_number_is_quarantined(self):
        error_id = self.sandbox.ingest_report("count gone wrong")
        record = self.stored(error_id)
        record["count"] = "many"
        self.overwrite(error_id, record)
        self.assertEqual(self.sandbox.run("list", "--all").returncode, 0)
        self.assert_quarantined(error_id)

    def test_a_record_stored_under_another_id_is_quarantined(self):
        error_id = self.sandbox.ingest_report("moved")
        record = self.stored(error_id)
        record["id"] = "20260101T000000-deadbeef"
        self.overwrite(error_id, record)
        self.sandbox.run("list", "--all")
        self.assert_quarantined(error_id)

    def test_the_corruption_is_recorded_as_an_error(self):
        error_id = self.sandbox.ingest_report("corrupted")
        self.overwrite(error_id, "[1]")
        self.sandbox.watch([])
        self.assertIn("corrupt error record", self.sandbox.run("list").stdout)

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_removing_a_record_that_cannot_be_removed_fails_instead_of_claiming_it_is_gone(self):
        error_id = self.sandbox.ingest_report("stuck")
        record_dir = os.path.join(self.sandbox.store_dir(), error_id)
        os.chmod(record_dir, stat.S_IRUSR | stat.S_IXUSR)
        self.addCleanup(os.chmod, record_dir, stat.S_IRWXU)
        result = self.sandbox.run("rm", error_id)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("removed:", result.stdout)
        self.assertIn("failed to remove", result.stderr)
        self.assertTrue(os.path.isfile(self.record_path(error_id)))


if __name__ == "__main__":
    unittest.main()
