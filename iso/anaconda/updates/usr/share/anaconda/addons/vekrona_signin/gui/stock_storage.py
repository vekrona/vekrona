from gi.repository import GLib

from pyanaconda.core.constants import THREAD_EXECUTE_STORAGE, THREAD_STORAGE, THREAD_STORAGE_WATCHER
from pyanaconda.core.threads import thread_manager

__all__ = ["wait_for_stock_storage"]

STOCK_STORAGE_THREADS = (THREAD_STORAGE, THREAD_STORAGE_WATCHER, THREAD_EXECUTE_STORAGE)
WAITER_THREAD = "VekronaWaitForStockStorage"


def _join_stock_storage_threads():
    for thread_name in STOCK_STORAGE_THREADS:
        thread_manager.wait(thread_name)


def wait_for_stock_storage():
    stock_storage_is_busy = any(thread_manager.exists(name) for name in STOCK_STORAGE_THREADS)
    if not (thread_manager.in_main_thread() and stock_storage_is_busy):
        _join_stock_storage_threads()
        return
    # Anaconda's storage threads hand work back to the main loop and wait for it, so joining them
    # from the main thread deadlocks; run the loop until a helper thread has joined them instead.
    loop = GLib.MainLoop()
    failures = []

    def join_then_wake_the_loop():
        try:
            _join_stock_storage_threads()
        except Exception as error:
            failures.append(error)
        finally:
            GLib.idle_add(loop.quit)

    thread_manager.add_thread(name=WAITER_THREAD, target=join_then_wake_the_loop)
    loop.run()
    if failures:
        raise failures[0]
