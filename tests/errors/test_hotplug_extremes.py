from harness import journal_entry
from usb_journal import CARD, HOUR, T0, HotplugTestCase, card_arrives, card_leaves, kernel, uvc_error


class HotplugExtremesTest(HotplugTestCase):
    def test_another_device_on_the_same_port_starts_a_new_history_without_an_internal_error(self):
        result = self.watch([
            *card_arrives(T0), *card_leaves(T0 + 10),
            kernel(T0 + 20, f"usb {CARD}: new full-speed USB device number 10 using xhci_hcd"),
            kernel(T0 + 20.2, f"usb {CARD}: New USB device found, idVendor=046d, idProduct=0825, bcdDevice= 0.11"),
        ])
        self.assertEqual(self.records(), [])
        self.assertNotIn("failed to process", result.stderr)

    def test_an_empty_message_without_a_device_is_an_ordinary_error(self):
        self.watch([kernel(T0, "", priority=3)])
        (record,) = self.records()
        self.assertEqual((record["source"], record["title"]), ("journal", "kernel: empty error message"))

    def test_an_empty_message_from_a_usb_device_is_a_fault_with_a_readable_summary(self):
        self.watch([kernel(T0, "", device=CARD, priority=3)])
        (record,) = self.records()
        self.assertEqual(record["source"], "usb")
        self.assertIn("last: (empty message)", record["summary"])

    def test_a_path_that_is_not_a_usb_path_is_an_ordinary_error(self):
        self.watch([
            kernel(T0, "usb 5-: device descriptor read/64, error -71", priority=3),
            kernel(T0 + 1, "usb 5-1.x: device not accepting address 4, error -71", priority=3),
            kernel(T0 + 2, "something broke", device="garbage", priority=3),
        ])
        records = self.records()
        self.assertEqual([record["source"] for record in records], ["journal"] * 3)

    def test_an_error_of_a_device_that_is_not_on_usb_is_not_a_usb_port(self):
        self.watch([
            kernel(T0, "tps6598x 5-0021: failed to read the status: -110", priority=3),
            kernel(T0 + 1, "ee1004 0-0050: probe with driver ee1004 failed with error -5", priority=3),
        ])
        records = self.records()
        self.assertEqual([record["source"] for record in records], ["journal"] * 2)

    def test_an_error_of_a_usb_interface_driver_is_still_a_usb_port(self):
        self.watch([kernel(T0, "uvcvideo 5-1.3:1.0: Failed to query (GET_DEF) UVC control 2 on unit 2: -71 (exp. 1).", priority=3)])
        (record,) = self.records()
        self.assertEqual(record["source"], "usb")

    def test_an_error_without_a_timestamp_cannot_be_placed_and_surfaces_as_it_is(self):
        entry = uvc_error(T0)
        del entry["__REALTIME_TIMESTAMP"]
        self.watch([*card_arrives(T0 - HOUR), entry])
        (record,) = self.records()
        self.assertEqual(record["source"], "journal")

    def test_a_usb_event_without_a_timestamp_is_reported_and_the_next_entries_still_land(self):
        broken = kernel(T0, f"usb {CARD}: USB disconnect, device number 9")
        del broken["__REALTIME_TIMESTAMP"]
        result = self.watch([broken, journal_entry(MESSAGE="after the broken one")])
        self.assertIn("__REALTIME_TIMESTAMP", result.stderr)
        self.assertIn("after the broken one", [record["summary"] for record in self.records()])

    def test_an_error_stamped_before_the_disconnect_that_arrives_first_still_belongs_to_it(self):
        self.watch([*card_arrives(T0), kernel(T0 + HOUR, f"usb {CARD}: USB disconnect, device number 9"),
                    uvc_error(T0 + HOUR - 0.01, "-19")])
        self.assertEqual(self.records(), [])

    def test_an_entry_stamped_long_before_the_rest_is_judged_where_it_belongs(self):
        self.watch([*card_arrives(T0), uvc_error(T0 + HOUR), uvc_error(T0 + 10)])
        (record,) = self.records()
        self.assertEqual(record["count"], 1)
        self.assert_unread_without_a_toast(1)
