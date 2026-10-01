import unittest

from harness import SandboxTestCase


class PickTest(SandboxTestCase):
    def setUp(self):
        super().setUp()
        self.sandbox.ingest_report("first problem")
        self.newest = self.sandbox.ingest_report("second problem")

    def pick(self, rofi_output, rofi_status="0"):
        return self.sandbox.run("pick", extra_env={
            "FAKE_ROFI_OUTPUT": rofi_output, "FAKE_ROFI_STATUS": rofi_status})

    def agent_calls(self):
        return [c for c in self.sandbox.external_calls() if c.startswith("vekrona-agent")]

    def test_the_menu_forbids_custom_input(self):
        self.pick("0")
        rofi_calls = [c for c in self.sandbox.external_calls() if c.startswith("rofi ")]
        self.assertIn("-no-custom", rofi_calls[0].split())

    def test_selecting_an_entry_launches_the_agent_on_that_error(self):
        result = self.pick("0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.agent_calls(), [f"vekrona-agent --pick --error {self.newest}"])

    def test_the_minus_one_of_custom_input_does_not_launch_the_oldest_error(self):
        result = self.pick("-1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected selection", result.stderr)
        self.assertEqual(self.agent_calls(), [])

    def test_a_non_integer_selection_is_an_error_not_a_traceback(self):
        result = self.pick("hello")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected selection", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_an_out_of_range_index_is_an_error(self):
        result = self.pick("7")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected selection", result.stderr)
        self.assertEqual(self.agent_calls(), [])

    def test_cancelling_is_quiet(self):
        result = self.pick("", rofi_status="1")
        self.assertEqual((result.returncode, result.stderr), (0, ""))

    def test_a_rofi_failure_is_loud(self):
        result = self.pick("", rofi_status="3")
        self.assertEqual(result.returncode, 1)
        self.assertIn("rofi exited with status 3", result.stderr)


if __name__ == "__main__":
    unittest.main()
