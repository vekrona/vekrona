import unittest
import xml.etree.ElementTree as ElementTree

import _paths

GLADE = _paths.ADDONS_DIR / "vekrona_signin/gui/spokes/vekrona_signin.glade"

SPOKE_WINDOW_IDS = {
    "VekronaSignInWindow",
    "AnacondaSpokeWindow-main_box1",
    "AnacondaSpokeWindow-nav_box1",
    "AnacondaSpokeWindow-nav_area1",
    "AnacondaSpokeWindow-alignment1",
    "AnacondaSpokeWindow-action_area1",
}

CONTRACT_IDS = {
    "mainBox", "disabledLabel", "contentBox", "introLabel",
    "passwordFrame", "passwordLabel", "passwordEntry", "confirmLabel", "confirmEntry",
    "passwordHint", "passwordError",
    "keyFrame", "keyWhatLabel", "keyUseLabel", "keyStepsLabel", "keyStateLabel",
    "keyCombo", "keyCheckButton",
    "keySetupBox", "keyPinLabel", "keyPinEntry", "keyConfirmLabel", "keyConfirmEntry",
    "keyPinHint", "keyRegisterButton",
    "keyRegisteredBox", "keyRemoveButton",
    "keyProgress", "keyError", "keyDetails", "keyDetailsLabel",
    "fpFrame", "fpWhatLabel", "fpUseLabel", "fpStepsLabel", "fpStateLabel",
    "readerCombo", "fpCheckButton", "fingerCombo", "fpEnrollButton",
    "fpRegisteredBox", "fpRemoveButton",
    "fpProgress", "fpError", "fpDetails", "fpDetailsLabel",
}

HANDLERS = {
    "on_password_changed", "on_key_check_clicked", "on_key_register_clicked",
    "on_key_remove_clicked", "on_key_pin_changed", "on_fp_check_clicked",
    "on_fp_enroll_clicked", "on_fp_remove_clicked", "on_key_combo_changed",
    "on_reader_combo_changed",
}
SPOKE_WINDOW_HANDLERS = {"on_back_clicked"}

LONG_TEXT_LABEL_IDS = {
    "disabledLabel", "introLabel", "passwordHint", "passwordError",
    "keyWhatLabel", "keyUseLabel", "keyStepsLabel", "keyStateLabel", "keyPinHint",
    "keyError", "keyDetailsLabel",
    "fpWhatLabel", "fpUseLabel", "fpStepsLabel", "fpStateLabel",
    "fpError", "fpDetailsLabel",
}
ERROR_LABEL_IDS = {"passwordError", "keyError", "fpError"}
FRAME_IDS = {"passwordFrame", "keyFrame", "fpFrame"}


class SignInGladeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = ElementTree.parse(GLADE).getroot()
        cls.objects = {o.get("id"): o for o in cls.root.iter("object") if o.get("id")}

    def properties(self, widget_id):
        return {p.get("name"): (p.text or "") for p in self.objects[widget_id].findall("property")}

    def test_declares_exactly_the_contract_widget_ids(self):
        self.assertEqual(set(self.objects), SPOKE_WINDOW_IDS | CONTRACT_IDS)

    def test_widget_ids_are_unique(self):
        ids = [o.get("id") for o in self.root.iter("object") if o.get("id")]
        self.assertEqual(len(ids), len(set(ids)))

    def test_every_signal_handler_is_in_the_contract(self):
        used = {s.get("handler") for s in self.root.iter("signal")}
        self.assertEqual(used - SPOKE_WINDOW_HANDLERS, HANDLERS)

    def test_requires_gtk3(self):
        gtk = [r for r in self.root.findall("requires") if r.get("lib") == "gtk+"]
        self.assertEqual([r.get("version").split(".")[0] for r in gtk], ["3"])

    def test_long_text_labels_wrap_and_cap_their_width(self):
        for widget_id in LONG_TEXT_LABEL_IDS:
            with self.subTest(widget_id):
                properties = self.properties(widget_id)
                self.assertEqual(properties.get("wrap"), "True")
                self.assertGreater(int(properties.get("max-width-chars", "0")), 0)
                self.assertEqual(properties.get("xalign"), "0")

    def test_error_labels_are_styled_as_errors_and_hidden_until_needed(self):
        for widget_id in ERROR_LABEL_IDS:
            with self.subTest(widget_id):
                classes = [c.get("name") for c in self.objects[widget_id].iter("class")]
                self.assertIn("error", classes)
                properties = self.properties(widget_id)
                self.assertEqual(properties.get("no-show-all"), "True")
                self.assertEqual(properties.get("visible"), "False")

    def test_password_entries_hide_their_text(self):
        for widget_id in ("passwordEntry", "confirmEntry", "keyPinEntry", "keyConfirmEntry"):
            with self.subTest(widget_id):
                properties = self.properties(widget_id)
                self.assertEqual(properties.get("visibility"), "False")
                self.assertEqual(properties.get("input-purpose"), "password")

    def test_panels_are_frames_with_a_bold_title(self):
        for widget_id in FRAME_IDS:
            with self.subTest(widget_id):
                frame = self.objects[widget_id]
                self.assertEqual(frame.get("class"), "GtkFrame")
                title = frame.find("child[@type='label']/object")
                weights = [a.get("value") for a in title.iter("attribute") if a.get("name") == "weight"]
                self.assertEqual(weights, ["bold"])

    def test_content_is_inside_a_scrolled_window_without_horizontal_scrolling(self):
        scrolled = [o for o in self.root.iter("object") if o.get("class") == "GtkScrolledWindow"]
        self.assertEqual(len(scrolled), 1)
        self.assertIn(self.objects["mainBox"], list(scrolled[0].iter("object")))
        policy = {p.get("name"): p.text for p in scrolled[0].findall("property")}
        self.assertEqual(policy.get("hscrollbar-policy"), "never")

    def test_details_are_expanders_with_monospace_labels(self):
        for expander_id, label_id in (("keyDetails", "keyDetailsLabel"), ("fpDetails", "fpDetailsLabel")):
            with self.subTest(expander_id):
                self.assertEqual(self.objects[expander_id].get("class"), "GtkExpander")
                self.assertIn(self.objects[label_id], list(self.objects[expander_id].iter("object")))
                fonts = [a.get("value") for a in self.objects[label_id].iter("attribute") if a.get("name") == "font-desc"]
                self.assertEqual(fonts, ["monospace"])

    def test_margins_stay_moderate_for_1024_by_768(self):
        properties = self.properties("mainBox")
        for side in ("margin-left", "margin-right"):
            self.assertLessEqual(int(properties[side]), 48)


if __name__ == "__main__":
    unittest.main()
