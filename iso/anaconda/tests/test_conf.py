import configparser
import unittest
from pathlib import Path

CONF = Path(__file__).resolve().parent.parent / "updates/etc/anaconda/conf.d/90-vekrona.conf"


def hidden_spokes():
    conf = configparser.ConfigParser()
    conf.read_string(CONF.read_text())
    return conf["User Interface"]["hidden_spokes"].split()


class InstallerConfTest(unittest.TestCase):
    def test_software_selection_is_hidden_so_the_kickstart_packages_stay_authoritative(self):
        self.assertIn("SoftwareSelectionSpoke", hidden_spokes())

    def test_installation_source_stays_visible_because_netinst_needs_a_network_source(self):
        self.assertNotIn("SourceSpoke", hidden_spokes())

    def test_text_mode_software_selection_is_hidden_too(self):
        self.assertIn("SoftwareSpoke", hidden_spokes())
