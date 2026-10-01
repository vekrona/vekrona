import tempfile
import unittest
from pathlib import Path

import _paths

from vekrona_signin.core import fprint
from vekrona_signin.core.device_description import DeviceDescription
from vekrona_signin.core.device_scan import DeviceScan, HintCode
from vekrona_signin.core.diagnose import usb_devices
from vekrona_signin.core.security_key import scan_security_keys


class FakeUsbTree:
    def __init__(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)

    def cleanup(self):
        self._directory.cleanup()

    def add(self, name, **attributes):
        device = self.root / name
        device.mkdir()
        for attribute, value in attributes.items():
            (device / attribute).write_text(f"{value}\n")


class FakeDescriptor:
    def __init__(self, path, vid=0x1050, pid=0x0407, product_name="YubiKey OTP+FIDO+CCID"):
        self.path = path
        self.vid = vid
        self.pid = pid
        self.product_name = product_name


class FakeDescriptorReader:
    def __init__(self, outcomes):
        self._outcomes = outcomes

    def __call__(self, path):
        outcome = self._outcomes[path]
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class UsbFixtureCase(unittest.TestCase):
    def setUp(self):
        self.usb = FakeUsbTree()
        self.addCleanup(self.usb.cleanup)

    def add_yubikey(self):
        self.usb.add(
            "1-1", idVendor="1050", idProduct="0407", manufacturer="Yubico", product="YubiKey OTP+FIDO+CCID"
        )


class UsbDevicesTest(UsbFixtureCase):
    def test_device_is_described_by_ids_manufacturer_and_product(self):
        self.add_yubikey()
        self.assertEqual(usb_devices(self.usb.root), ["1050:0407 Yubico YubiKey OTP+FIDO+CCID"])

    def test_device_without_strings_is_described_by_ids_alone(self):
        self.usb.add("1-2", idVendor="27c6", idProduct="55b4")
        self.assertEqual(usb_devices(self.usb.root), ["27c6:55b4"])

    def test_interfaces_and_hubs_are_not_listed(self):
        self.usb.add("usb1", idVendor="1d6b", idProduct="0002", bDeviceClass="09")
        self.usb.add("1-1:1.0", bInterfaceClass="03")
        self.assertEqual(usb_devices(self.usb.root), [])


class SecurityKeyScanTest(UsbFixtureCase):
    def scan(self, hidraw, outcomes):
        return scan_security_keys(
            self.usb.root, lambda: hidraw, FakeDescriptorReader(outcomes)
        )

    def test_fido_device_is_listed_by_path_with_its_ids(self):
        self.add_yubikey()
        scan = self.scan(["/dev/hidraw3"], {"/dev/hidraw3": FakeDescriptor("/dev/hidraw3")})
        devices = DeviceDescription.from_structure_list(scan.devices)
        self.assertEqual(
            [(device.id, device.name) for device in devices],
            [("/dev/hidraw3", "YubiKey OTP+FIDO+CCID (1050:0407)")],
        )
        self.assertEqual((scan.hint_code, scan.problem), (HintCode.OK, ""))
        self.assertEqual(scan.usb_seen, ["1050:0407 Yubico YubiKey OTP+FIDO+CCID"])

    def test_hid_device_that_is_not_ctap_is_skipped_silently(self):
        scan = self.scan(
            ["/dev/hidraw0", "/dev/hidraw1"],
            {"/dev/hidraw0": ValueError("not CTAP"), "/dev/hidraw1": FakeDescriptor("/dev/hidraw1")},
        )
        self.assertEqual([device.id for device in DeviceDescription.from_structure_list(scan.devices)], ["/dev/hidraw1"])
        self.assertEqual(scan.problem, "")

    def test_nothing_plugged_in_is_no_usb_device_without_a_problem(self):
        scan = self.scan([], {})
        self.assertEqual((scan.hint_code, scan.problem, scan.usb_seen), (HintCode.NO_USB_DEVICE, "", []))
        self.assertEqual(scan.devices, [])

    def test_usb_device_that_is_no_security_key_is_reported_as_unusable(self):
        self.usb.add("1-3", idVendor="046d", idProduct="c52b", manufacturer="Logitech", product="Receiver")
        scan = self.scan(["/dev/hidraw0"], {"/dev/hidraw0": ValueError("not CTAP")})
        self.assertEqual(scan.hint_code, HintCode.USB_SEEN_BUT_UNUSABLE)
        self.assertIn("none is a security key", scan.problem)
        self.assertEqual(scan.usb_seen, ["046d:c52b Logitech Receiver"])

    def test_permission_error_is_access_denied_and_names_the_node(self):
        self.add_yubikey()
        scan = self.scan(["/dev/hidraw3"], {"/dev/hidraw3": PermissionError(13, "Permission denied")})
        self.assertEqual(scan.hint_code, HintCode.ACCESS_DENIED)
        self.assertIn("/dev/hidraw3", scan.problem)
        self.assertIn("PermissionError", scan.problem)

    def test_other_failure_is_recorded_not_swallowed(self):
        self.add_yubikey()
        scan = self.scan(["/dev/hidraw3"], {"/dev/hidraw3": OSError(25, "Inappropriate ioctl")})
        self.assertEqual(scan.hint_code, HintCode.USB_SEEN_BUT_UNUSABLE)
        self.assertIn("Inappropriate ioctl", scan.problem)

    def test_failure_on_one_node_does_not_hide_a_working_key(self):
        scan = self.scan(
            ["/dev/hidraw0", "/dev/hidraw1"],
            {"/dev/hidraw0": OSError(5, "I/O error"), "/dev/hidraw1": FakeDescriptor("/dev/hidraw1")},
        )
        self.assertEqual(scan.hint_code, HintCode.OK)
        self.assertEqual(len(scan.devices), 1)
        self.assertIn("I/O error", scan.problem)

    def test_scan_survives_the_dbus_structure_round_trip(self):
        self.add_yubikey()
        scan = self.scan(["/dev/hidraw3"], {"/dev/hidraw3": FakeDescriptor("/dev/hidraw3")})
        restored = DeviceScan.from_structure(DeviceScan.to_structure(scan))
        self.assertEqual(restored.hint_code, HintCode.OK)
        self.assertEqual(restored.usb_seen, scan.usb_seen)
        self.assertEqual(restored.devices, scan.devices)


class FakeReader:
    def __init__(self, device_id, name):
        self._device_id = device_id
        self._name = name

    def get_device_id(self):
        return self._device_id

    def get_name(self):
        return self._name


class FakeFPrint:
    def __init__(self, readers=(), error=None):
        self._readers = list(readers)
        self._error = error

    def Context(self):
        return self

    def get_devices(self):
        if self._error:
            raise self._error
        return self._readers


class FingerprintScanTest(UsbFixtureCase):
    def scan(self, load_fprint):
        return fprint.scan_readers(self.usb.root, load_fprint)

    def test_reader_is_listed_by_device_id_and_name(self):
        scan = self.scan(lambda: FakeFPrint([FakeReader("0", "Goodix MOC")]))
        devices = DeviceDescription.from_structure_list(scan.devices)
        self.assertEqual([(device.id, device.name) for device in devices], [("0", "Goodix MOC")])
        self.assertEqual((scan.hint_code, scan.problem), (HintCode.OK, ""))

    def test_no_reader_is_no_usb_device_even_with_other_usb_devices_present(self):
        self.add_yubikey()
        scan = self.scan(lambda: FakeFPrint())
        self.assertEqual((scan.hint_code, scan.problem), (HintCode.NO_USB_DEVICE, ""))
        self.assertEqual(scan.usb_seen, ["1050:0407 Yubico YubiKey OTP+FIDO+CCID"])

    def test_missing_library_is_reported_with_the_import_error(self):
        def load():
            raise ImportError("No module named 'gi'")

        scan = self.scan(load)
        self.assertEqual(scan.hint_code, HintCode.LIBRARY_MISSING)
        self.assertIn("No module named 'gi'", scan.problem)

    def test_missing_typelib_is_reported_as_missing_library(self):
        def load():
            raise ValueError("Namespace FPrint not available")

        self.assertEqual(self.scan(load).hint_code, HintCode.LIBRARY_MISSING)

    def test_context_failure_is_recorded_not_swallowed(self):
        self.add_yubikey()
        scan = self.scan(lambda: FakeFPrint(error=RuntimeError("usb context failed")))
        self.assertEqual(scan.hint_code, HintCode.USB_SEEN_BUT_UNUSABLE)
        self.assertIn("usb context failed", scan.problem)


if __name__ == "__main__":
    unittest.main()
