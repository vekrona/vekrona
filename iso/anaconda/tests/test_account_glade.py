import unittest
import xml.etree.ElementTree as ElementTree

import _paths

GLADE = _paths.ADDONS_DIR / "vekrona_account/gui/spokes/vekrona_account.glade"

FIELDS = {
    "fullNameLabel": "fullNameEntry",
    "usernameLabel": "usernameEntry",
    "hostnameLabel": "hostnameEntry",
    "timezoneLabel": "timezoneEntry",
}


class AccountGladeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = ElementTree.parse(GLADE).getroot()
        cls.objects = {o.get("id"): o for o in root.iter("object") if o.get("id")}

    def properties(self, widget_id):
        return {p.get("name"): (p.text or "") for p in self.objects[widget_id].findall("property")}

    def test_every_field_label_has_a_mnemonic_for_its_entry(self):
        for label_id, entry_id in FIELDS.items():
            with self.subTest(label_id):
                properties = self.properties(label_id)
                self.assertEqual(properties.get("mnemonic-widget"), entry_id)
                self.assertEqual(properties.get("use-underline"), "True")
                self.assertIn("_", properties["label"])

    def test_field_mnemonics_are_distinct(self):
        keys = {self.properties(label_id)["label"].split("_", 1)[1][0].lower() for label_id in FIELDS}
        self.assertEqual(len(keys), len(FIELDS))

    def test_error_labels_start_hidden(self):
        for widget_id in ("usernameError", "hostnameError", "timezoneError"):
            with self.subTest(widget_id):
                properties = self.properties(widget_id)
                self.assertEqual(properties.get("visible"), "False")
                self.assertEqual(properties.get("no-show-all"), "True")


if __name__ == "__main__":
    unittest.main()
