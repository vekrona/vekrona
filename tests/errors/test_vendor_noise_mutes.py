import os
import unittest

from harness import REPO, SandboxTestCase, journal_entry

# Messages this desktop logged verbatim, each harmless or a hardware fault software cannot fix.
HARMLESS = [
    ("bluetoothd", "Failed to set mode: Failed (0x03)"),
    ("bluetoothd", "Failed to add device D4:D4:DA:5D:68:1E (1): Failed (0x03)"),
    ("kernel", "Bluetooth: hci0: ACL packet for unknown connection handle 3837"),
    ("dbus-broker-launch", "Activation request for 'org.bluez' failed."),
    ("dbus-broker-launch", "Activation request for 'org.freedesktop.Avahi' failed."),
    ("kernel", "usb 5-1.4: cannot submit urb 0, error -19: no device"),
    ("kernel", "usb 5-1.4: Unable to submit urb #0: -19 at snd_usb_queue_pending_output_urbs"),
    ("pipewire", "spa.alsa: hw:USBp: snd_pcm_drop: No such device"),
    ("pipewire", "spa.alsa: hw:USBp: snd_pcm_status error: No such device"),
    ("pipewire", "spa.alsa: sw_params: No such device"),
    ("pipewire", "spa.alsa: swparams: No such device"),
    ("pipewire", "spa.alsa: hw:USBp: snd_pcm_start: Broken pipe"),
    ("pipewire", "spa.alsa: hw:USBp: snd_pcm_start: File descriptor in bad state"),
    ("(udev-worker)", 'controlC0: /usr/lib/udev/rules.d/78-sound-card.rules:5 ATTR{../uevent}="change": Could not chase '
                      'sysfs attribute "/sys/devices/pci0000:00/0000:00:08.1/0000:09:00.4/usb5/5-1/5-1.3/5-1.3:1.2/sound/'
                      'card0/controlC0/../uevent", ignoring: No such file or directory'),
    ("kernel", "usb 5-1-port3: Cannot enable. Maybe the USB cable is bad?"),
    ("kernel", "usb 5-1-port3: unable to enumerate USB device"),
    ("dbus-broker-launch", "Activation request for 'org.freedesktop.nm_dispatcher' failed."),
    ("systemd-logind", "Refusing suspend operation, sleep is inhibited by UID 1000/xiii, PID 1529323/systemd-inhibit."),
    ("systemd-cryptsetup", "Specified device /dev/hidraw0 is not a FIDO2 device."),
    ("sshd-session", "error: kex_exchange_identification: read: Connection reset by peer"),
]

# Close relatives that point at a real fault, so they must still reach the dot.
REAL = [
    ("bluetoothd", "Failed to add device D4:D4:DA:5D:68:1E (1): Not Powered (0x0f)"),
    ("kernel", "Bluetooth: hci0: command 0x0c52 tx timeout"),
    ("dbus-broker-launch", "Activation request for 'org.freedesktop.Notifications' failed."),
    ("kernel", "usb 5-1.4: cannot submit urb 0, error -71: protocol error"),
    ("pipewire", "spa.alsa: hw:USBp: snd_pcm_drop: Input/output error"),
    ("wireplumber", "spa.alsa: hw:USBp: snd_pcm_drop: No such device"),
    ("(udev-worker)", 'controlC0: /usr/lib/udev/rules.d/78-sound-card.rules:5 ATTR{../uevent}="change": Could not chase '
                      'sysfs attribute "/sys/x/../uevent", ignoring: Permission denied'),
    ("kernel", "usb 5-1-port3: over-current condition"),
    ("systemd-logind", "Failed to suspend system. System resumed again: Input/output error"),
    ("systemd-cryptsetup", "Failed to activate with FIDO2 security token: Operation not permitted"),
    ("sshd-session", "error: PAM: Authentication failure for xiii from 192.168.50.42"),
]


class ShippedVendorNoiseMutesTest(SandboxTestCase):
    def setUp(self):
        super().setUp()
        with open(os.path.join(REPO, "etc", "vekrona", "errors-mute.d", "10-vendor-noise.conf")) as f:
            self.sandbox.install_default_mutes(f.read())

    def recorded_after(self, messages):
        self.sandbox.watch([journal_entry(SYSLOG_IDENTIFIER=identifier, MESSAGE=message)
                            for identifier, message in messages])
        return self.sandbox.run("list", "--all").stdout.splitlines()[1:]

    def test_device_gone_and_rfkill_noise_makes_no_record(self):
        self.assertEqual(self.recorded_after(HARMLESS), [])

    def test_the_real_faults_beside_that_noise_still_surface(self):
        self.assertEqual(len(self.recorded_after(REAL)), len(REAL))


if __name__ == "__main__":
    unittest.main()
