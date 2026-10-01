import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

QMP_PY = Path(__file__).resolve().parents[2] / "iso" / "lib" / "qmp.py"
PROMPT = "Please enter passphrase"
WAIT_TIMEOUT_SEC = "20"
SHORT_TIMEOUT_SEC = "0.5"


def qmp(*args):
    return subprocess.Popen(
        [sys.executable, "-B", str(QMP_PY), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


class WaitSerialTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log = Path(self.tmp.name) / "serial.log"
        self.vm = subprocess.Popen(["sleep", "60"])
        self.addCleanup(self.vm.wait)
        self.addCleanup(self.vm.kill)

    def wait_serial(self, regex, offset=0, timeout=WAIT_TIMEOUT_SEC):
        return qmp(
            "wait-serial", "--log", str(self.log), "--pid", str(self.vm.pid),
            "--offset", str(offset), "--timeout", timeout, regex,
        )

    def test_prompt_without_trailing_newline_matches(self):
        self.log.write_text("booting\nPlease enter passphrase for disk root (luks-1):")
        waiter = self.wait_serial(PROMPT)
        out, err = waiter.communicate(timeout=30)
        self.assertEqual(waiter.returncode, 0, err)
        self.assertIn(PROMPT, out)

    def test_output_written_after_the_wait_started_matches(self):
        self.log.write_text("booting\n")
        waiter = self.wait_serial(PROMPT)
        with self.log.open("a") as log:
            log.write("Please enter passphrase for disk root (luks-1):")
        out, err = waiter.communicate(timeout=30)
        self.assertEqual(waiter.returncode, 0, err)
        self.assertIn(PROMPT, out)

    def test_output_before_the_offset_is_ignored(self):
        first = "Please enter passphrase for disk root (luks-1):"
        self.log.write_text(first)
        waiter = self.wait_serial(PROMPT, offset=len(first), timeout=SHORT_TIMEOUT_SEC)
        _, err = waiter.communicate(timeout=30)
        self.assertEqual(waiter.returncode, 1)
        self.assertIn("did not match", err)

    def test_prompt_after_the_offset_matches(self):
        first = "Please enter passphrase for disk root (luks-1):"
        self.log.write_text(first + "\nbooting\n" + first)
        waiter = self.wait_serial(PROMPT, offset=len(first))
        out, err = waiter.communicate(timeout=30)
        self.assertEqual(waiter.returncode, 0, err)
        self.assertIn(PROMPT, out)

    def test_vm_exit_before_a_match_is_reported(self):
        self.log.write_text("booting\n")
        finished = subprocess.Popen(["true"])
        finished.wait()
        waiter = qmp(
            "wait-serial", "--log", str(self.log), "--pid", str(finished.pid),
            "--timeout", WAIT_TIMEOUT_SEC, PROMPT,
        )
        _, err = waiter.communicate(timeout=30)
        self.assertEqual(waiter.returncode, 1)
        self.assertIn("VM exited", err)


class SerialSendTest(unittest.TestCase):
    def test_text_reaches_the_socket_with_a_newline(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "serial.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(server.close)
            server.bind(path)
            server.listen(1)
            received = []

            def accept():
                connection, _ = server.accept()
                with connection:
                    received.append(connection.makefile("rb").read())

            reader = threading.Thread(target=accept)
            reader.start()
            sender = qmp("--sock", path, "serial-send", "--enter", "vekrona")
            _, err = sender.communicate(timeout=30)
            reader.join(timeout=30)
            self.assertEqual(sender.returncode, 0, err)
            self.assertEqual(received, [b"vekrona\n"])

    def test_missing_socket_is_an_error(self):
        sender = qmp("--sock", "/nonexistent/serial.sock", "serial-send", "x")
        _, err = sender.communicate(timeout=30)
        self.assertEqual(sender.returncode, 1)
        self.assertIn("cannot write to serial socket", err)


if __name__ == "__main__":
    unittest.main()
