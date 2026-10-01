import unittest

import _paths

from vekrona_signin.gui.spokes import devwatch
from vekrona_signin.gui.spokes.devwatch import BackendUnavailable, DeviceWatcher


class FakeScheduler:
    def __init__(self):
        self.callbacks = {}
        self.delays = []
        self._next_token = 0

    def schedule(self, delay_ms, callback):
        self._next_token += 1
        self.callbacks[self._next_token] = callback
        self.delays.append(delay_ms)
        return self._next_token

    def cancel(self, token):
        del self.callbacks[token]

    def run_due(self):
        due, self.callbacks = list(self.callbacks.values()), {}
        for callback in due:
            callback()


class FakeBackend:
    def __init__(self):
        self.notify = None
        self.stopped = False

    def start(self, notify):
        self.notify = notify

    def stop(self):
        self.stopped = True


class MissingBackend:
    def start(self, notify):
        raise BackendUnavailable("not installed")


class DeviceWatcherTest(unittest.TestCase):
    def setUp(self):
        self.scheduler = FakeScheduler()
        self.changes = 0
        self.backend = FakeBackend()

    def on_change(self):
        self.changes += 1

    def watcher(self, *factories, **options):
        return DeviceWatcher(self.on_change, scheduler=self.scheduler, backend_factories=factories, **options)

    def started_watcher(self):
        watcher = self.watcher(lambda: self.backend)
        watcher.start()
        return watcher

    def test_burst_of_events_yields_one_change(self):
        self.started_watcher()
        for _ in range(20):
            self.backend.notify()
        self.scheduler.run_due()
        self.assertEqual(self.changes, 1)

    def test_separate_bursts_yield_separate_changes(self):
        self.started_watcher()
        self.backend.notify()
        self.scheduler.run_due()
        self.backend.notify()
        self.scheduler.run_due()
        self.assertEqual(self.changes, 2)

    def test_no_change_before_debounce_elapses(self):
        self.started_watcher()
        self.backend.notify()
        self.assertEqual(self.changes, 0)

    def test_debounce_delay_is_configurable(self):
        watcher = self.watcher(lambda: self.backend, debounce_ms=123)
        watcher.start()
        self.backend.notify()
        self.assertEqual(self.scheduler.delays, [123])

    def test_events_after_stop_yield_nothing(self):
        watcher = self.started_watcher()
        watcher.stop()
        self.backend.notify()
        self.scheduler.run_due()
        self.assertEqual(self.changes, 0)

    def test_stop_cancels_a_pending_change(self):
        watcher = self.started_watcher()
        self.backend.notify()
        watcher.stop()
        self.scheduler.run_due()
        self.assertEqual(self.changes, 0)

    def test_stop_disconnects_the_backend(self):
        watcher = self.started_watcher()
        watcher.stop()
        self.assertTrue(self.backend.stopped)
        self.assertFalse(watcher.available)

    def test_stop_without_start_is_harmless(self):
        self.watcher(lambda: self.backend).stop()

    def test_available_after_start(self):
        watcher = self.watcher(lambda: self.backend)
        self.assertFalse(watcher.available)
        watcher.start()
        self.assertTrue(watcher.available)

    def test_falls_back_to_next_backend(self):
        watcher = self.watcher(MissingBackend, lambda: self.backend)
        watcher.start()
        self.assertTrue(watcher.available)
        self.backend.notify()
        self.scheduler.run_due()
        self.assertEqual(self.changes, 1)

    def test_without_any_backend_watcher_is_unavailable_and_start_does_not_raise(self):
        watcher = self.watcher(MissingBackend, MissingBackend)
        with self.assertLogs(devwatch.log, level="WARNING"):
            watcher.start()
        self.assertFalse(watcher.available)

    def test_unavailable_backend_is_reported_in_the_log(self):
        watcher = self.watcher(MissingBackend)
        with self.assertLogs(devwatch.log, level="WARNING") as logs:
            watcher.start()
        self.assertIn("not installed", "\n".join(logs.output))


if __name__ == "__main__":
    unittest.main()
