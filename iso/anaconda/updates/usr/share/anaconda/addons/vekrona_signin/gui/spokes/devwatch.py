import glob

from pyanaconda.anaconda_loggers import get_module_logger

log = get_module_logger(__name__)

__all__ = ["BackendUnavailable", "DeviceWatcher", "GLibScheduler", "GUdevBackend", "GioMonitorBackend"]

DEFAULT_DEBOUNCE_MS = 400
GUDEV_SUBSYSTEMS = ["hidraw", "usb"]
DEV_DIRECTORY = "/dev"
USB_BUS_DIRECTORIES = "/dev/bus/usb/[0-9]*"


class BackendUnavailable(Exception):
    pass


class GLibScheduler:
    def schedule(self, delay_ms, callback):
        from gi.repository import GLib

        def fire():
            callback()
            return GLib.SOURCE_REMOVE

        return GLib.timeout_add(delay_ms, fire)

    def cancel(self, token):
        from gi.repository import GLib

        GLib.source_remove(token)


class GUdevBackend:
    def __init__(self):
        self._client = None
        self._handler_id = None

    def start(self, notify):
        try:
            import gi
            gi.require_version("GUdev", "1.0")
            from gi.repository import GUdev
        except (ImportError, ValueError) as error:
            raise BackendUnavailable(f"GUdev is not available: {error}") from error
        client = GUdev.Client.new(GUDEV_SUBSYSTEMS)
        self._handler_id = client.connect("uevent", lambda _client, _action, _device: notify())
        self._client = client

    def stop(self):
        if self._client is not None:
            self._client.disconnect(self._handler_id)
        self._client = None
        self._handler_id = None


class GioMonitorBackend:
    def __init__(self):
        self._monitors = []

    def start(self, notify):
        try:
            from gi.repository import Gio, GLib
        except ImportError as error:
            raise BackendUnavailable(f"Gio is not available: {error}") from error
        directories = [DEV_DIRECTORY, *sorted(glob.glob(USB_BUS_DIRECTORIES))]
        try:
            for directory in directories:
                monitor = Gio.File.new_for_path(directory).monitor_directory(Gio.FileMonitorFlags.NONE, None)
                handler_id = monitor.connect("changed", lambda *_arguments: notify())
                self._monitors.append((monitor, handler_id))
        except GLib.Error as error:
            self.stop()
            raise BackendUnavailable(f"cannot monitor {directory}: {error.message}") from error

    def stop(self):
        for monitor, handler_id in self._monitors:
            monitor.disconnect(handler_id)
            monitor.cancel()
        self._monitors = []


class DeviceWatcher:
    def __init__(self, on_change, debounce_ms=DEFAULT_DEBOUNCE_MS, scheduler=None,
                 backend_factories=(GUdevBackend, GioMonitorBackend)):
        self._on_change = on_change
        self._debounce_ms = debounce_ms
        self._scheduler = scheduler if scheduler is not None else GLibScheduler()
        self._backend_factories = backend_factories
        self._backend = None
        self._pending = None

    @property
    def available(self):
        return self._backend is not None

    def start(self):
        if self._backend is not None:
            return
        for factory in self._backend_factories:
            backend = factory()
            try:
                backend.start(self._notify)
            except BackendUnavailable as error:
                log.warning("device watcher backend %s unavailable: %s", factory.__name__, error)
                continue
            self._backend = backend
            log.info("device watcher uses %s", factory.__name__)
            return
        log.warning("no device watcher backend is available; devices are not detected automatically")

    def stop(self):
        backend, self._backend = self._backend, None
        if backend is not None:
            backend.stop()
        self._cancel_pending()

    def _notify(self):
        if self._backend is None:
            return
        self._cancel_pending()
        self._pending = self._scheduler.schedule(self._debounce_ms, self._fire)

    def _fire(self):
        self._pending = None
        self._on_change()

    def _cancel_pending(self):
        pending, self._pending = self._pending, None
        if pending is not None:
            self._scheduler.cancel(pending)
