import importlib.machinery
import importlib.util
import json
import os
import select
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
sys.path.insert(0, os.path.join(REPO, "tests"))
from require_vm import require_vm  # noqa: E402

require_vm()

_loader = importlib.machinery.SourceFileLoader("vekrona_audio_watchdog", os.path.join(REPO, "bin", "vekrona-audio-watchdog"))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
watchdog = importlib.util.module_from_spec(_spec)
_loader.exec_module(watchdog)


def node(name, media_class="Audio/Sink"):
    return {"type": "PipeWire:Interface:Node", "info": {"props": {"node.name": name, "media.class": media_class}}}


def defaults(sink=None, source=None):
    entries = [{"key": key, "value": {"name": name}} for key, name in
               (("default.audio.sink", sink), ("default.audio.source", source)) if name is not None]
    return {"type": "PipeWire:Interface:Metadata", "props": {"metadata.name": "default"}, "metadata": entries}


def card(name, active, profiles, api="alsa"):
    return {"type": "PipeWire:Interface:Device", "info": {
        "props": {"device.name": name, "device.api": api},
        "params": {"Profile": [{"name": active}], "EnumProfile": [{"name": n, "available": a} for n, a in profiles]}}}


ANALOG = [("off", "yes"), ("output:analog-stereo", "yes"), ("pro-audio", "unknown")]
HDMI = [("off", "yes"), ("output:hdmi-stereo", "no"), ("pro-audio", "unknown")]
CAPTURE_ONLY_PRO_AUDIO = [("off", "yes"), ("pro-audio", "yes")]


class StaleDefaultsTest(unittest.TestCase):
    def test_a_default_that_names_an_existing_node_is_fine(self):
        graph = [node("a"), node("b"), defaults(sink="b")]
        self.assertEqual(watchdog.stale_defaults(graph), [])

    def test_a_default_naming_a_vanished_node_while_another_sink_exists_is_a_problem(self):
        graph = [node("onboard"), defaults(sink="scarlett")]
        self.assertEqual(len(watchdog.stale_defaults(graph)), 1)
        self.assertIn("'scarlett'", watchdog.stale_defaults(graph)[0])

    def test_no_default_at_all_while_a_sink_exists_is_a_problem(self):
        self.assertEqual(len(watchdog.stale_defaults([node("onboard"), defaults()])), 1)
        self.assertEqual(len(watchdog.stale_defaults([node("onboard")])), 1)

    def test_a_stale_default_with_no_sink_to_take_over_is_a_state_not_a_problem(self):
        self.assertEqual(watchdog.stale_defaults([defaults(sink="scarlett")]), [])
        self.assertEqual(watchdog.stale_defaults([]), [])

    def test_sinks_and_sources_are_judged_apart(self):
        graph = [node("out"), node("in", "Audio/Source"), defaults(sink="out", source="gone")]
        problems = watchdog.stale_defaults(graph)
        self.assertEqual(len(problems), 1)
        self.assertIn("default.audio.source", problems[0])

    def test_a_removed_object_without_info_is_ignored(self):
        self.assertEqual(watchdog.stale_defaults([{"type": "PipeWire:Interface:Node", "info": None}]), [])


class CardsLeftOffTest(unittest.TestCase):
    def test_an_analog_card_on_off_is_a_problem(self):
        problems = watchdog.cards_left_off([card("onboard", "off", ANALOG)])
        self.assertEqual(len(problems), 1)
        self.assertIn("output:analog-stereo", problems[0])

    def test_an_analog_card_on_a_real_profile_is_fine(self):
        self.assertEqual(watchdog.cards_left_off([card("onboard", "output:analog-stereo", ANALOG)]), [])

    def test_off_is_right_for_cards_with_nothing_available_but_pro_audio(self):
        graph = [card("hdmi", "off", HDMI), card("capture", "off", CAPTURE_ONLY_PRO_AUDIO)]
        self.assertEqual(watchdog.cards_left_off(graph), [])

    def test_a_profile_of_unknown_availability_counts_as_usable(self):
        scarlett = [("off", "yes"), ("HiFi", "unknown"), ("pro-audio", "yes")]
        self.assertEqual(len(watchdog.cards_left_off([card("scarlett", "off", scarlett)])), 1)

    def test_other_device_kinds_are_not_cards(self):
        self.assertEqual(watchdog.cards_left_off([card("bluez", "off", ANALOG, api="bluez5")]), [])
        self.assertEqual(watchdog.cards_left_off([card("camera", "off", ANALOG, api="v4l2")]), [])

    def test_a_card_with_no_active_profile_yet_is_not_a_problem(self):
        graph = [{"type": "PipeWire:Interface:Device", "info": {
            "props": {"device.name": "new", "device.api": "alsa"}, "params": {}}}]
        self.assertEqual(watchdog.cards_left_off(graph), [])


class StoredProfileTest(unittest.TestCase):
    def test_a_card_stored_as_off_was_turned_off_on_purpose(self):
        graph = [card("onboard", "off", ANALOG)]
        self.assertEqual(watchdog.cards_left_off(graph, {"onboard": "off"}), [])

    def test_a_card_stored_as_something_else_or_not_at_all_is_still_a_problem(self):
        graph = [card("onboard", "off", ANALOG)]
        self.assertEqual(len(watchdog.cards_left_off(graph, {"onboard": "output:analog-stereo"})), 1)
        self.assertEqual(len(watchdog.cards_left_off(graph, {"another": "off"})), 1)
        self.assertEqual(len(watchdog.cards_left_off(graph, {})), 1)

    def test_the_stored_profiles_are_read_from_wireplumbers_state_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "default-profile")
            with open(path, "w") as state:
                state.write("[default-profile]\nalsa_card.usb-X-00=output:analog-stereo\nalsa_card.pci-0=off\n"
                            "[other]\nalsa_card.x=off\n")
            self.assertEqual(watchdog.stored_profiles(path),
                             {"alsa_card.usb-X-00": "output:analog-stereo", "alsa_card.pci-0": "off"})

    def test_no_state_file_means_nothing_is_stored(self):
        self.assertEqual(watchdog.stored_profiles("/nonexistent/default-profile"), {})


class MonitorTest(unittest.TestCase):
    def setUp(self):
        self.read_end, self.write_end = os.pipe()
        self.addCleanup(os.close, self.read_end)
        self.monitor = watchdog.Monitor(self.read_end)

    def print_(self, *documents):
        os.write(self.write_end, "".join(json.dumps(document) + "\n" for document in documents).encode())

    def test_a_burst_of_changes_is_read_in_one_go(self):
        self.print_([dict(node("a"), id=1)])
        self.print_([dict(node("b"), id=2)])
        self.print_([dict(node("c"), id=3)])
        self.assertEqual(self.monitor.read(), (True, True))
        self.assertEqual(select.select([self.read_end], [], [], 0)[0], [], "everything the monitor had printed must be read")
        os.close(self.write_end)

    def test_clients_coming_and_going_are_not_a_change_of_the_graph(self):
        client = {"id": 59, "type": "PipeWire:Interface:Client", "info": {"props": {}}}
        self.print_([client])
        self.print_([{"id": 59, "info": None}])
        self.assertEqual(self.monitor.read(), (True, False))
        os.close(self.write_end)

    def test_the_removal_of_a_node_is_a_change_and_the_removal_of_a_client_is_not(self):
        listed = dict(node("a"), id=7)
        client = {"id": 59, "type": "PipeWire:Interface:Client", "info": {"props": {}}}
        self.print_([listed, client])
        self.monitor.read()
        self.print_([{"id": 59, "info": None}])
        self.assertEqual(self.monitor.read(), (True, False))
        self.print_([{"id": 7, "info": None}])
        self.assertEqual(self.monitor.read(), (True, True))
        os.close(self.write_end)

    def test_a_document_that_arrives_in_two_pieces_is_read_once_it_is_whole(self):
        document = json.dumps([dict(card("onboard", "off", ANALOG), id=4)]).encode()
        os.write(self.write_end, document[:20])
        self.assertEqual(self.monitor.read(), (True, False))
        os.write(self.write_end, document[20:] + b"\n")
        self.assertEqual(self.monitor.read(), (True, True))
        os.close(self.write_end)

    def test_an_ended_monitor_is_reported(self):
        os.close(self.write_end)
        self.assertEqual(self.monitor.read(), (False, False))


if __name__ == "__main__":
    unittest.main()
