from usb_journal import T0, HotplugTestCase, card_arrives, card_leaves, knock_ons, resume, userspace

SPA_ALSA = ("wireplumber", "spa.alsa: can't open control for card hw:3: No such device")


class KnockOnTest(HotplugTestCase):
    def test_audio_and_video_errors_just_after_a_device_left_are_dropped(self):
        self.watch([*card_arrives(T0), *card_leaves(T0 + 100), *knock_ons(T0 + 101)])
        self.assertEqual(self.records(), [])
        self.assertEqual(self.sandbox.sent_notifications(), [])

    def test_the_stack_may_complain_just_before_the_kernel_line_that_explains_it(self):
        self.watch([*card_arrives(T0), userspace(T0 + 99.5, *SPA_ALSA), *card_leaves(T0 + 100)])
        self.assertEqual(self.records(), [])

    def test_errors_while_the_system_wakes_up_are_dropped(self):
        self.watch([resume(T0), userspace(T0 + 10, *SPA_ALSA)])
        self.assertEqual(self.records(), [])

    def test_the_same_error_with_no_usb_event_around_it_still_surfaces(self):
        self.watch([userspace(T0, *SPA_ALSA)])
        (record,) = self.records()
        self.assertEqual(record["source"], "journal")
        self.assertEqual(self.sandbox.sent_notifications(), [])

    def test_the_same_error_long_after_the_last_usb_event_still_surfaces(self):
        self.watch([*card_arrives(T0), *card_leaves(T0 + 100), userspace(T0 + 116, *SPA_ALSA)])
        self.assertEqual(len(self.records()), 1)

    def test_the_same_error_long_after_a_resume_still_surfaces(self):
        self.watch([resume(T0), userspace(T0 + 31, *SPA_ALSA)])
        self.assertEqual(len(self.records()), 1)

    def test_another_error_from_the_same_program_is_never_dropped(self):
        self.watch([*card_arrives(T0), *card_leaves(T0 + 100),
                    userspace(T0 + 101, "wireplumber", "failed to bind the session")])
        self.assertEqual(len(self.records()), 1)
