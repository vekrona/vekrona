import unittest

import _paths


class AddOnLoggingTest(unittest.TestCase):
    def test_every_logger_is_under_anaconda_so_the_installer_writes_it_to_its_log(self):
        for path in sorted(_paths.ADDONS_DIR.rglob("*.py")):
            with self.subTest(path.relative_to(_paths.ADDONS_DIR)):
                self.assertNotIn("logging.getLogger(", path.read_text())


if __name__ == "__main__":
    unittest.main()
