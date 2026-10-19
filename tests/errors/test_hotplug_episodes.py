import importlib.machinery
import importlib.util
import os
import unittest

from harness import REPO
from usb_journal import HOUR, T0, HotplugTestCase, card_arrives, card_leaves, flap, kernel, uvc_error

_loader = importlib.machinery.SourceFileLoader("vekrona_error", os.path.join(REPO, "bin", "vekrona-error"))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
vekrona_error = importlib.util.module_from_spec(_spec)
_loader.exec_module(vekrona_error)

FLAPPING = "USB device keeps reconnecting"
FAILING = "USB device keeps failing"


def clean_cycles(t, cycles, step=10):
    """A device that enumerates fine every time and leaves again, as a loose connector does."""
    return [entry for n in range(cycles) for entry in
            [*card_arrives(t + n * step, number=20 + n), *card_leaves(t + n * step + 5, number=20 + n)]]


class CleanFlapTest(HotplugTestCase):
    def test_a_port_that_reconnects_cleanly_over_and_over_is_a_fault(self):
        self.watch([*card_arrives(T0), *clean_cycles(T0 + HOUR, 9)])
        (record,) = self.records()
        self.assertEqual((record["source"], record["title"]), ("usb", FLAPPING))
        self.assertIn("0 enumeration failures", record["summary"])
        self.assert_unread_without_a_toast(1)

    def test_a_device_that_comes_back_twice_is_not(self):
        self.watch([*card_arrives(T0), *clean_cycles(T0 + HOUR, 2)])
        self.assertEqual(self.records(), [])


class NewEpisodeTest(unittest.TestCase):
    def test_a_second_episode_after_a_quiet_minute_raises_the_record_again(self):
        tracker = vekrona_error.HotplugTracker()
        records = []
        for entry in [*card_arrives(T0), *flap(T0 + HOUR, 60), *flap(T0 + 2 * HOUR, 60)]:
            records += tracker.process(entry, vekrona_error.classify(entry, vekrona_error.UnitExitMemory()))
        records += tracker.flush()
        faults = [record for record in records if record.get("fault")]
        raised = [record for record in faults if record["raise"]]
        self.assertEqual(len(raised), 2, "one record raised for each episode, none for the updates in between")
        self.assertGreater(len(faults), 2)


class SuspendWindowTest(HotplugTestCase):
    def test_a_usb_error_stamped_between_the_suspend_entry_and_its_exit_is_part_of_the_resume(self):
        self.watch([
            *card_arrives(T0),
            kernel(T0 + HOUR, "PM: suspend entry (deep)"),
            uvc_error(T0 + HOUR + 20),
            kernel(T0 + HOUR + 30, "PM: suspend exit"),
        ])
        self.assertEqual(self.records(), [])

    def test_a_usb_error_well_after_the_exit_is_a_fault(self):
        self.watch([
            *card_arrives(T0),
            kernel(T0 + HOUR, "PM: suspend entry (deep)"),
            kernel(T0 + HOUR + 30, "PM: suspend exit"),
            uvc_error(T0 + HOUR + 65),
        ])
        (record,) = self.records()
        self.assertEqual(record["title"], FAILING)
