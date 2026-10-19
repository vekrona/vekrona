import json
import os

from harness import SandboxTestCase

T0 = 1_760_000_000.0
HOUR = 3600
CARD = "5-1.3"


def kernel(t, message, device=None, priority=6, **fields):
    entry = {"PRIORITY": str(priority), "SYSLOG_IDENTIFIER": "kernel", "_TRANSPORT": "kernel",
             "MESSAGE": message, "__REALTIME_TIMESTAMP": str(round(t * 1_000_000))}
    if device:
        entry["_KERNEL_DEVICE"] = f"+usb:{device}"
    entry.update(fields)
    return entry


def userspace(t, identifier, message, priority=3):
    return {"PRIORITY": str(priority), "SYSLOG_IDENTIFIER": identifier, "_TRANSPORT": "journal",
            "MESSAGE": message, "__REALTIME_TIMESTAMP": str(round(t * 1_000_000))}


def resume(t):
    return kernel(t, "PM: suspend exit")


def card_arrives(t, number=9):
    return [
        kernel(t, f"usb {CARD}: new high-speed USB device number {number} using xhci_hcd"),
        kernel(t + 0.2, f"usb {CARD}: New USB device found, idVendor=534d, idProduct=2109, bcdDevice=21.00"),
        kernel(t + 0.2, f"usb {CARD}: Manufacturer: MACROSILICON"),
        kernel(t + 0.2, f"usb {CARD}: Product: USB Video"),
    ]


def card_leaves(t, number=9):
    return [kernel(t, f"usb {CARD}: USB disconnect, device number {number}")]


def uvc_error(t, errno="-71"):
    return kernel(t, f"uvcvideo {CARD}:1.0: Failed to query (GET_DEF) UVC control 2 on unit 2: {errno} (exp. 1).",
                  device=f"{CARD}:1.0", priority=3)


def switch_away(t):
    """The KVM hands the desk to another machine: the hub's children and then the hub itself disconnect."""
    children = [kernel(t + 0.002 * n, f"usb 5-1.{n}: USB disconnect, device number {n + 3}") for n in (1, 2, 3, 4)]
    return children + [kernel(t + 0.01, "usb 5-1: USB disconnect, device number 3")]


def failed_cycle(t, number):
    return [
        kernel(t, f"usb {CARD}: new high-speed USB device number {number} using xhci_hcd"),
        kernel(t + 0.3, f"usb {CARD}: device not accepting address {number}, error -71", priority=3),
        kernel(t + 0.4, f"usb {CARD}: device descriptor read/64, error -71", priority=3),
        kernel(t + 0.5, f"usb {CARD}: can't set config #1, error -71", priority=3),
        kernel(t + 0.6, "usb 5-1-port3: Cannot enable. Maybe the USB cable is bad?", priority=3),
        kernel(t + 0.7, "usb 5-1-port3: attempt power cycle", priority=3),
        uvc_error(t + 0.8),
        kernel(t + 0.9, f"usb {CARD}: 1:1: usb_set_interface failed (-19)", device=CARD, priority=3),
    ]


def flap(t, cycles, step=1.3, first_number=10):
    return [entry for n in range(cycles) for entry in failed_cycle(t + n * step, first_number + n)]


def port_dead(t):
    return kernel(t, "usb 5-1-port3: unable to enumerate USB device", priority=3)


KNOCK_ON_LINES = [
    ("wireplumber", "spa.alsa: can't open control for card hw:3: No such device"),
    ("wireplumber", "error iterating devices: No such device"),
    ("pipewire", "ALSA close failed"),
    ("wireplumber", "spa.v4l2: Cannot open '/dev/video0': No such file or directory"),
    ("wireplumber", "Failed to activate V4L2 device"),
    ("wireplumber", "Object activation aborted: PipeWire proxy destroyed"),
    ("(udev-worker)", "controlC3: /usr/lib/udev/rules.d/78-sound-card.rules:5 ATTR{../uevent}=\"change\": "
                      "Could not chase sysfs attribute \"/sys/devices/x/uevent\", ignoring: No such file or directory"),
]


def knock_ons(t):
    return [userspace(t + 0.1 * n, identifier, message) for n, (identifier, message) in enumerate(KNOCK_ON_LINES)]


class HotplugTestCase(SandboxTestCase):
    def watch(self, entries):
        return self.sandbox.watch(entries)

    def records(self):
        store = self.sandbox.store_dir()
        found = []
        for name in sorted(os.listdir(store)) if os.path.isdir(store) else []:
            path = os.path.join(store, name, "record.json")
            if os.path.isfile(path):
                with open(path) as f:
                    found.append(json.load(f))
        return found

    def unread(self):
        with open(os.path.join(self.sandbox.store_dir(), "unread")) as f:
            return int(f.read())

    def assert_unread_without_a_toast(self, unread):
        self.assertEqual(self.sandbox.sent_notifications(), [], "a USB fault must not toast")
        self.assertEqual(self.unread(), unread)
