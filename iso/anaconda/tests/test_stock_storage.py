import importlib.util
import threading
import unittest

import _paths

HAS_GLIB = importlib.util.find_spec("gi") is not None
WATCHDOG_SEC = 10

if HAS_GLIB:
    from gi.repository import GLib

    from pyanaconda.core.constants import THREAD_STORAGE_WATCHER
    from pyanaconda.core.threads import thread_manager

    from vekrona_signin.gui.stock_storage import wait_for_stock_storage


@unittest.skipUnless(HAS_GLIB, "PyGObject is not installed on this host")
class WaitForStockStorageTest(unittest.TestCase):
    def test_main_thread_can_wait_for_a_storage_thread_that_needs_the_main_loop(self):
        main_loop_served_the_storage_thread = []
        release = threading.Event()
        watchdog = threading.Timer(WATCHDOG_SEC, release.set)

        def storage_thread():
            def served():
                main_loop_served_the_storage_thread.append(True)
                release.set()
                return False

            GLib.idle_add(served)
            release.wait()

        watchdog.start()
        self.addCleanup(watchdog.cancel)
        thread_manager.add_thread(name=THREAD_STORAGE_WATCHER, target=storage_thread)
        wait_for_stock_storage()
        self.assertEqual([True], main_loop_served_the_storage_thread)

    def test_returns_at_once_without_storage_threads(self):
        wait_for_stock_storage()

    def test_a_worker_thread_waits_by_joining(self):
        finished = []
        gate = threading.Event()

        def storage_thread():
            gate.wait()
            finished.append("storage")

        thread_manager.add_thread(name=THREAD_STORAGE_WATCHER, target=storage_thread)

        def worker():
            wait_for_stock_storage()
            finished.append("worker")

        waiter = threading.Thread(target=worker)
        waiter.start()
        gate.set()
        waiter.join(WATCHDOG_SEC)
        self.assertEqual(["storage", "worker"], finished)
