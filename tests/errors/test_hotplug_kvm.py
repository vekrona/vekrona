from usb_journal import (CARD, HOUR, T0, HotplugTestCase, card_arrives, failed_cycle, kernel, knock_ons, resume,
                         switch_away, uvc_error)


class KvmSwitchTest(HotplugTestCase):
    def assert_silent(self):
        self.assertEqual(self.records(), [])
        self.assertEqual(self.sandbox.sent_notifications(), [])

    def test_switching_away_is_silent_even_though_the_stack_complains_about_the_devices_that_left(self):
        away = T0 + HOUR
        self.watch([
            *card_arrives(T0),
            kernel(away - 0.01, f"usb {CARD}: cannot submit urb 0, error -19: no device", priority=3),
            *switch_away(away),
            uvc_error(away + 0.1, "-19"),
            kernel(away + 0.2, "usb 5-1.4: 1:1: usb_set_interface failed (-19)", device="5-1.4", priority=3),
            *knock_ons(away + 0.5),
            kernel(away + 20, f"usb {CARD}: cannot submit urb 0, error -19: no device", priority=3),
        ])
        self.assert_silent()

    def test_switching_back_through_a_resume_is_silent_when_the_devices_settle(self):
        back = T0 + HOUR
        cycles = [entry for n in range(14) for entry in failed_cycle(back + 2 + n * 2.8, 20 + n)]
        self.watch([
            *card_arrives(T0),
            *switch_away(T0 + 600),
            resume(back),
            *knock_ons(back + 5),
            *cycles,
            *card_arrives(back + 41, number=40),
            *knock_ons(back + 45),
        ])
        self.assert_silent()

    def test_an_error_right_after_a_resume_is_part_of_the_resume(self):
        back = T0 + 2 * HOUR
        self.watch([*card_arrives(T0), resume(back), uvc_error(back + 5)])
        self.assert_silent()

    def test_the_same_error_once_the_system_has_settled_is_a_fault(self):
        back = T0 + 2 * HOUR
        self.watch([*card_arrives(T0), resume(back), uvc_error(back + 120)])
        (record,) = self.records()
        self.assertEqual(record["source"], "usb")

    def test_a_device_behind_a_hub_that_just_connected_is_still_enumerating(self):
        back = T0 + HOUR
        self.watch([*card_arrives(T0), kernel(back, "usb 5-1: new high-speed USB device number 3 using xhci_hcd"),
                    uvc_error(back + 10)])
        self.assert_silent()
