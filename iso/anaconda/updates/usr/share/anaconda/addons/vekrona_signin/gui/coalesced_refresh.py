__all__ = ["CoalescedRefresh"]


class CoalescedRefresh:
    def __init__(self, defer, refresh):
        self._defer = defer
        self._refresh = refresh
        self._scheduled = False
        self._running = False
        self._dirty = False

    def request(self):
        self._dirty = True
        if self._scheduled or self._running:
            return
        self._scheduled = True
        self._defer(self._run)

    def _run(self):
        self._scheduled = False
        self._running = True
        try:
            while self._dirty:
                self._dirty = False
                self._refresh()
        finally:
            self._running = False
