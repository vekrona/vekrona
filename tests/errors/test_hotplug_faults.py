import json
import os

from harness import write_executable
from usb_journal import (CARD, HOUR, T0, HotplugTestCase, card_arrives, failed_cycle, flap, port_dead,
                         switch_away, uvc_error)

FLAP_END = T0 + HOUR + 549 * 1.3 + 1.5

FLAPPING = "USB device keeps reconnecting"
DEAD = "USB port left disabled"
FAILING = "USB device keeps failing"

JOURNALCTL_WITH_PRIME = """#!/bin/sh
printf 'journalctl %s\\n' "$*" >> "$FAKE_LOG"
case "$*" in *"-k -q -o json"*) exec cat "$FAKE_PRIME" ;; esac
for arg; do
  if [ "$arg" = "-f" ]; then exec cat "$FAKE_JOURNAL"; fi
done
"""


class FlappingPortTest(HotplugTestCase):
    def test_550_failed_reconnects_make_one_record_and_light_the_dot_without_a_toast(self):
        self.watch([*card_arrives(T0), *flap(T0 + HOUR, 550)])
        (record,) = self.records()
        self.assertEqual((record["source"], record["title"]), ("usb", FLAPPING))
        self.assertEqual(
            record["summary"],
            "USB port 5-1-port3 (MACROSILICON 534d:2109): 2200 enumeration failures, 550 reconnects in 12 min; "
            "still flapping")
        self.assertEqual(record["count"], 2200)
        self.assert_unread_without_a_toast(1)

    def test_the_port_dying_updates_that_record_and_keeps_the_dot_lit(self):
        self.watch([*card_arrives(T0), *flap(T0 + HOUR, 550), port_dead(FLAP_END)])
        (record,) = self.records()
        self.assertEqual(record["title"], DEAD)
        self.assertTrue(record["summary"].endswith("550 reconnects in 12 min; port left disabled"), record["summary"])
        self.assert_unread_without_a_toast(1)

    def test_an_acked_fault_that_gets_worse_lights_the_dot_again_without_a_toast(self):
        self.watch([*card_arrives(T0), *flap(T0 + HOUR, 550)])
        (record,) = self.records()
        self.sandbox.run("ack", record["id"])
        self.assertEqual(self.unread(), 0)
        self.watch([*card_arrives(T0), *flap(T0 + HOUR, 550), port_dead(FLAP_END)])
        (record,) = self.records()
        self.assertEqual((record["title"], record["status"]), (DEAD, "new"))
        self.assert_unread_without_a_toast(1)

    def test_a_port_that_is_dead_at_once_is_a_fault_without_waiting_for_a_flap(self):
        self.watch([*card_arrives(T0), *failed_cycle(T0 + HOUR, 10), port_dead(T0 + HOUR + 1.5)])
        (record,) = self.records()
        self.assertEqual(record["title"], DEAD)
        self.assert_unread_without_a_toast(1)

    def test_a_flap_that_ends_with_the_device_unplugged_is_still_one_record(self):
        self.watch([*card_arrives(T0), *flap(T0 + HOUR, 60), *switch_away(T0 + HOUR + 100)])
        (record,) = self.records()
        self.assertEqual(record["title"], FLAPPING)
        self.assert_unread_without_a_toast(1)

    def test_the_context_names_the_port_and_the_bus(self):
        for tool in ("lsusb", "udevadm"):
            write_executable(os.path.join(self.sandbox.fakes, tool), "#!/bin/sh\nexit 0\n")
        self.watch([*card_arrives(T0), *flap(T0 + HOUR, 60)])
        (record,) = self.records()
        with open(os.path.join(self.sandbox.store_dir(), record["id"], "context.txt")) as f:
            commands = [line for line in f.read().splitlines() if line.startswith("$ ")]
        self.assertEqual(commands[0].split(" --grep ")[0], "$ journalctl -k --since -10min -o short-iso")
        self.assertIn("\\b5-1\\.3\\b", commands[0])
        self.assertIn("\\b5-1-port3\\b", commands[0])
        self.assertEqual(commands[1:], ["$ lsusb -t", f"$ udevadm info /sys/bus/usb/devices/{CARD}"])


class StableDeviceTest(HotplugTestCase):
    def test_a_device_that_errors_while_connected_for_long_is_a_fault(self):
        self.watch([*card_arrives(T0), uvc_error(T0 + HOUR)])
        (record,) = self.records()
        self.assertEqual((record["source"], record["title"]), ("usb", FAILING))
        self.assertTrue(record["summary"].startswith(
            "USB device 5-1.3 (MACROSILICON 534d:2109) keeps failing while connected: 1 error, last: uvcvideo"),
            record["summary"])
        self.assert_unread_without_a_toast(1)

    def test_repeats_count_up_the_same_record(self):
        self.watch([*card_arrives(T0), *(uvc_error(T0 + HOUR + n) for n in range(3))])
        (record,) = self.records()
        self.assertEqual(record["count"], 3)
        self.assertIn("3 errors", record["summary"])
        self.assert_unread_without_a_toast(1)

    def test_a_recurrence_long_after_the_dedupe_window_is_counted(self):
        self.watch([*card_arrives(T0), *(uvc_error(T0 + HOUR + n * 700) for n in range(3))])
        (record,) = self.records()
        self.assertEqual(record["count"], 3)
        self.assert_unread_without_a_toast(1)

    def test_a_muted_fault_stays_silent(self):
        self.watch([*card_arrives(T0), uvc_error(T0 + HOUR)])
        (record,) = self.records()
        self.sandbox.run("mute", record["id"])
        self.watch([*card_arrives(T0), uvc_error(T0 + HOUR), uvc_error(T0 + HOUR + 1)])
        (record,) = self.records()
        self.assertEqual((record["status"], record["count"]), ("muted", 1))
        self.assert_unread_without_a_toast(0)


class ColdStartTest(HotplugTestCase):
    def watch_after_restart(self, recent_kernel_entries):
        write_executable(os.path.join(self.sandbox.fakes, "journalctl"), JOURNALCTL_WITH_PRIME)
        prime = os.path.join(self.sandbox.root, "prime.jsonl")
        with open(prime, "w") as f:
            f.write("".join(json.dumps(entry) + "\n" for entry in recent_kernel_entries))
        self.sandbox.env["FAKE_PRIME"] = prime
        os.makedirs(self.sandbox.store_dir())
        with open(os.path.join(self.sandbox.store_dir(), "cursor"), "w") as f:
            f.write("s=last-seen\n")
        self.watch([uvc_error(T0 + 10)])

    def test_a_device_that_connected_just_before_the_watcher_started_is_still_enumerating(self):
        self.watch_after_restart(card_arrives(T0))
        self.assertEqual(self.records(), [])

    def test_without_that_history_the_same_error_comes_from_a_long_connected_device(self):
        self.watch_after_restart([])
        (record,) = self.records()
        self.assertEqual(record["title"], FAILING)
