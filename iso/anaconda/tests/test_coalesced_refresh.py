import unittest

import _paths

from vekrona_signin.gui.coalesced_refresh import CoalescedRefresh


class Deferred:
    def __init__(self):
        self.pending = []

    def __call__(self, callback):
        self.pending.append(callback)

    def run_all(self):
        while self.pending:
            self.pending.pop(0)()


class CoalescedRefreshTest(unittest.TestCase):
    def setUp(self):
        self.deferred = Deferred()
        self.runs = 0
        self.depth = 0
        self.deepest = 0
        self.during_refresh = lambda: None
        self.refresher = CoalescedRefresh(self.deferred, self.refresh)

    def refresh(self):
        self.runs += 1
        self.depth += 1
        self.deepest = max(self.deepest, self.depth)
        try:
            self.during_refresh()
        finally:
            self.depth -= 1

    def test_nothing_runs_before_the_main_loop_gets_to_it(self):
        self.refresher.request()
        self.assertEqual(self.runs, 0)

    def test_requests_before_the_run_are_one_refresh(self):
        for _ in range(3):
            self.refresher.request()
        self.deferred.run_all()
        self.assertEqual(self.runs, 1)

    def test_requests_during_a_refresh_run_it_again_after_it_and_never_inside_it(self):
        def two_signals_arrive():
            if self.runs == 1:
                self.refresher.request()
                self.refresher.request()

        self.during_refresh = two_signals_arrive
        self.refresher.request()
        self.deferred.run_all()
        self.assertEqual(self.runs, 2)
        self.assertEqual(self.deepest, 1)

    def test_a_failing_refresh_does_not_block_later_requests(self):
        def fail_once():
            if self.runs == 1:
                raise RuntimeError("boom")

        self.during_refresh = fail_once
        self.refresher.request()
        with self.assertRaises(RuntimeError):
            self.deferred.run_all()
        self.refresher.request()
        self.deferred.run_all()
        self.assertEqual(self.runs, 2)


if __name__ == "__main__":
    unittest.main()
