import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import shutil
import socket
import socketserver
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler
from unittest import mock

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "bin", "vekrona-sync")

loader = importlib.machinery.SourceFileLoader("vekrona_sync", SCRIPT)
sync = importlib.util.module_from_spec(importlib.util.spec_from_loader("vekrona_sync", loader))
loader.exec_module(sync)

ME = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA"
PEER = "BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB"
THIRD = "CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC"
FOURTH = "DDDDDDD-DDDDDDD-DDDDDDD-DDDDDDD-DDDDDDD-DDDDDDD-DDDDDDD-DDDDDDD"
DROP = sync.drop_folder_id(ME, PEER)


class SanitizeLabelTest(unittest.TestCase):
    def test_a_normal_name_is_kept(self):
        self.assertEqual(sync.sanitize_label("Holiday photos", "abcde-fghij"), "Holiday photos")

    def test_path_tricks_cannot_leave_the_sync_directory(self):
        for label, expected in (("../x", "x"), ("lizard/..", "lizard"), ("a/../../b", "ab"), ("..", "abcde-fghij"),
                                (".", "abcde-fghij"), ("...", "abcde-fghij"), (".hidden", "hidden")):
            with self.subTest(label=label):
                self.assertEqual(sync.sanitize_label(label, "abcde-fghij"), expected)

    def test_an_empty_label_becomes_the_folder_id(self):
        self.assertEqual(sync.sanitize_label("", "abcde-fghij"), "abcde-fghij")

    def test_control_characters_are_dropped(self):
        self.assertEqual(sync.sanitize_label("two\nlines\x00", "abcde-fghij"), "twolines")

    def test_a_folder_id_is_cleaned_like_a_label(self):
        self.assertEqual(sync.sanitize_label("", "../../etc"), "etc")

    def test_nothing_usable_in_the_label_or_the_id_is_an_error(self):
        with self.assertRaises(sync.SyncError):
            sync.sanitize_label("..", "/..")


class DropRuleTest(unittest.TestCase):
    def test_the_id_holds_both_devices_sorted_whatever_the_argument_order(self):
        self.assertEqual(sync.drop_folder_id(PEER, ME), sync.drop_folder_id(ME, PEER))
        self.assertEqual(sync.drop_parties(DROP), (ME, PEER))

    def test_a_drop_is_taken_only_from_the_other_party_to_it(self):
        self.assertTrue(sync.auto_accepts(DROP, PEER, ME))
        self.assertTrue(sync.auto_accepts(DROP, ME, PEER))

    def test_a_drop_offered_by_a_device_that_is_not_the_other_party_stays_a_manual_offer(self):
        self.assertFalse(sync.auto_accepts(DROP, THIRD, ME))
        self.assertFalse(sync.auto_accepts(DROP, ME, ME))

    def test_a_drop_between_two_other_devices_stays_a_manual_offer(self):
        self.assertFalse(sync.auto_accepts(sync.drop_folder_id(PEER, THIRD), PEER, ME))

    def test_ids_that_are_not_a_canonical_drop_are_no_drop(self):
        for folder_id in ("abcde-fghij", "vekrona-drop-", f"vekrona-drop-{PEER}-{ME}", f"vekrona-drop-{ME}-{ME}",
                          f"vekrona-drop-{ME}-{PEER}-x", f"vekrona-drop-{ME}-{PEER.lower()}"):
            with self.subTest(folder_id=folder_id):
                self.assertFalse(sync.auto_accepts(folder_id, PEER, ME))

    def test_a_malformed_device_id_is_refused_at_the_command_line(self):
        for text in ("", "lizard", ME.lower(), ME + "A", "../" + ME):
            with self.subTest(text=text):
                with self.assertRaises(Exception):
                    sync.device_id_arg(text)
        self.assertEqual(sync.device_id_arg(ME), ME)


def open_dir(path):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY)


class PlacementTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.drop = os.path.join(self.tmp.name, "drop")
        self.source_dir = os.path.join(self.drop, "to", ME)
        self.target = os.path.join(self.tmp.name, "Downloads")
        os.makedirs(self.source_dir)
        os.makedirs(self.target)

    def write(self, directory, name, content):
        path = os.path.join(directory, name)
        with open(path, "w") as f:
            f.write(content)
        return path

    def read(self, name):
        with open(os.path.join(self.target, name)) as f:
            return f.read()

    def place(self, name, target_name):
        source_fd, target_fd = open_dir(self.source_dir), open_dir(self.target)
        self.addCleanup(os.close, source_fd)
        self.addCleanup(os.close, target_fd)
        return sync.place_without_overwriting(source_fd, name, target_fd, target_name)

    def test_a_name_that_exists_gets_a_number_before_the_extension_and_the_old_file_is_untouched(self):
        self.write(self.target, "photo.jpg", "first")
        self.write(self.target, "photo (2).jpg", "second")
        self.write(self.source_dir, "photo.jpg", "third")
        self.assertEqual(self.place("photo.jpg", "photo.jpg"), "photo (3).jpg")
        self.assertEqual((self.read("photo.jpg"), self.read("photo (2).jpg"), self.read("photo (3).jpg")),
                         ("first", "second", "third"))

    def test_a_name_without_an_extension_gets_the_number_at_the_end(self):
        self.write(self.target, "notes", "first")
        self.write(self.source_dir, "notes", "second")
        self.assertEqual(self.place("notes", "notes"), "notes (2)")

    def test_a_dangling_link_in_the_target_counts_as_a_taken_name(self):
        os.symlink("/nonexistent", os.path.join(self.target, "a.txt"))
        self.write(self.source_dir, "a.txt", "x")
        self.assertEqual(self.place("a.txt", "a.txt"), "a (2).txt")

    def test_receiving_moves_finished_files_only(self):
        self.write(self.source_dir, "done.txt", "whole")
        self.write(self.source_dir, "~syncthing~half.txt.tmp", "part")
        self.write(self.source_dir, ".syncthing.half.txt.tmp", "part")
        self.write(self.source_dir, "x.sync-conflict-20240101-000000-ABCDEFG.txt", "conflict")
        os.symlink("/etc/passwd", os.path.join(self.source_dir, "link"))
        os.mkdir(os.path.join(self.source_dir, "subdir"))
        with mock.patch.object(sync, "downloads_dir", return_value=self.target):
            arrivals, failures = sync.receive(self.drop, ME, "Pixel")
        self.assertEqual(failures, [])
        self.assertEqual(sorted(a["name"] for a in arrivals),
                         ["done.txt", "x.sync-conflict-20240101-000000-ABCDEFG.txt"])
        self.assertEqual(sorted(a["path"] for a in arrivals), sorted(os.path.join(self.target, a["name"]) for a in arrivals))
        self.assertTrue(all(a["from"] == "Pixel" and a["unseen"] for a in arrivals))
        self.assertEqual(sorted(os.listdir(self.source_dir)),
                         [".syncthing.half.txt.tmp", "link", "subdir", "~syncthing~half.txt.tmp"])

    def test_receiving_from_an_inbox_that_does_not_exist_yet_moves_nothing(self):
        with mock.patch.object(sync, "downloads_dir", side_effect=AssertionError("must not look for Downloads")):
            self.assertEqual(sync.receive(os.path.join(self.tmp.name, "missing"), ME, "Pixel"), ([], []))
            self.assertEqual(sync.receive(self.drop, PEER, "Pixel"), ([], []))

    def test_an_inbox_that_a_peer_replaced_by_a_link_is_refused_and_what_it_points_at_is_left_alone(self):
        victims = os.path.join(self.tmp.name, "victims")
        os.mkdir(victims)
        self.write(victims, "private.txt", "secret")
        os.rmdir(self.source_dir)
        os.symlink(victims, self.source_dir)
        with mock.patch.object(sync, "downloads_dir", return_value=self.target):
            with self.assertRaisesRegex(sync.SyncError, "is a link"):
                sync.receive(self.drop, ME, "Pixel")
        self.assertEqual(os.listdir(victims), ["private.txt"])
        self.assertEqual(os.listdir(self.target), [])

    def test_a_to_directory_that_a_peer_replaced_by_a_link_is_refused_too(self):
        victims = os.path.join(self.tmp.name, "victims")
        os.makedirs(os.path.join(victims, ME))
        self.write(os.path.join(victims, ME), "private.txt", "secret")
        shutil.rmtree(os.path.join(self.drop, "to"))
        os.symlink(victims, os.path.join(self.drop, "to"))
        with mock.patch.object(sync, "downloads_dir", return_value=self.target):
            with self.assertRaisesRegex(sync.SyncError, "is a link"):
                sync.receive(self.drop, ME, "Pixel")
        self.assertEqual(os.listdir(os.path.join(victims, ME)), ["private.txt"])

    def test_delivering_into_an_inbox_that_is_a_link_is_refused(self):
        victims = os.path.join(self.tmp.name, "victims")
        os.mkdir(victims)
        os.rmdir(self.source_dir)
        os.symlink(victims, self.source_dir)
        with self.assertRaisesRegex(sync.SyncError, "is a link"):
            with sync.open_inbox(self.drop, ME, create=True):
                self.fail("the inbox must not open")
        self.assertEqual(os.listdir(victims), [])

    def test_delivering_leaves_no_temp_file_and_never_overwrites(self):
        original = self.write(self.tmp.name, "report.pdf", "v1")
        inbox = open_dir(self.source_dir)
        self.addCleanup(os.close, inbox)
        sync.deliver(original, inbox, frozenset())
        with open(original, "w") as f:
            f.write("v2")
        sync.deliver(original, inbox, frozenset())
        self.assertEqual(sorted(os.listdir(self.source_dir)), ["report (2).pdf", "report.pdf"])
        with open(os.path.join(self.source_dir, "report.pdf")) as f1, open(os.path.join(self.source_dir, "report (2).pdf")) as f2:
            self.assertEqual((f1.read(), f2.read()), ("v1", "v2"))

    def test_delivering_a_file_that_cannot_be_read_is_an_error_that_leaves_nothing_behind(self):
        inbox = open_dir(self.source_dir)
        self.addCleanup(os.close, inbox)
        with self.assertRaises(sync.SyncError):
            sync.deliver(os.path.join(self.tmp.name, "missing.txt"), inbox, frozenset())
        self.assertEqual(os.listdir(self.source_dir), [])


def folder(folder_id, label="Notes", path="/home/u/Sync/Notes", devices=(ME,), **extra):
    return {"id": folder_id, "label": label, "path": path, "devices": [{"deviceID": d} for d in devices], **extra}


def snapshot(**overrides):
    values = dict(
        my_id=ME,
        folders=[folder("f1"), folder(DROP, "vekrona drop", "/home/u/.local/share/vekrona-sync/drops/" + DROP)],
        devices=[{"deviceID": ME, "name": "this"}, {"deviceID": PEER, "name": "Pixel"}],
        connected={PEER}, pending_devices={}, pending_folders={},
        statuses={"f1": {"state": "idle", "globalBytes": 10, "needBytes": 0}}, discovered={}, ignored=frozenset())
    return sync.Snapshot(**{**values, **overrides})


class AssembleTest(unittest.TestCase):
    def test_a_quiet_syncthing_is_idle_and_hides_drops_and_itself(self):
        view = sync.assemble(snapshot())
        self.assertEqual((view["state"], view["problem"]), ("idle", None))
        self.assertEqual(view["folders"], [{"id": "f1", "label": "Notes", "path": "/home/u/Sync/Notes",
                                            "state": "idle", "progress": 100, "problem": None}])
        self.assertEqual(view["devices"], [{"id": PEER, "name": "Pixel", "connected": True, "sharesWithUs": False}])

    def shares_with_us(self, **overrides):
        return sync.assemble(snapshot(**overrides))["devices"][0]["sharesWithUs"]

    def test_a_device_that_is_a_member_of_a_folder_shares_with_us(self):
        self.assertTrue(self.shares_with_us(folders=[folder("f1", devices=(ME, PEER))]))

    def test_a_device_that_offers_a_folder_shares_with_us(self):
        self.assertTrue(self.shares_with_us(pending_folders={"p1": {"offeredBy": {PEER: {"label": "Photos"}}}}))

    def test_a_device_that_is_in_no_folder_and_offers_none_shares_nothing_with_us(self):
        self.assertFalse(self.shares_with_us())
        self.assertFalse(self.shares_with_us(pending_folders={"p1": {"offeredBy": {THIRD: {"label": "Photos"}}}}))

    def test_a_drop_folder_does_not_make_a_device_share_with_us(self):
        self.assertFalse(self.shares_with_us(folders=[folder(DROP, "vekrona drop", "/d", devices=(ME, PEER))],
                                             pending_folders={DROP: {"offeredBy": {PEER: {"label": "vekrona drop"}}}}))

    def test_a_folder_of_other_devices_only_does_not_make_a_device_share_with_us(self):
        self.assertFalse(self.shares_with_us(folders=[folder("f1", devices=(ME, THIRD))]))

    def test_a_folder_that_is_syncing_shows_its_progress(self):
        view = sync.assemble(snapshot(statuses={"f1": {"state": "syncing", "globalBytes": 200, "needBytes": 80}}))
        self.assertEqual((view["state"], view["folders"][0]["progress"]), ("syncing", 60))

    def test_a_folder_without_bytes_has_zero_progress_not_a_division_by_zero(self):
        view = sync.assemble(snapshot(statuses={"f1": {"state": "scanning", "globalBytes": 0, "needBytes": 0}}))
        self.assertEqual(view["folders"][0]["progress"], 0)

    def test_a_problem_wins_over_syncing_and_carries_its_text(self):
        view = sync.assemble(snapshot(
            folders=[folder("f1"), folder("f2", "Other")],
            statuses={"f1": {"state": "syncing", "globalBytes": 1, "needBytes": 1},
                      "f2": {"state": "error", "error": "folder path missing"}}))
        self.assertEqual((view["state"], view["problem"]), ("problem", "folder path missing"))

    def test_files_that_failed_to_sync_are_a_problem_of_an_idle_folder(self):
        view = sync.assemble(snapshot(statuses={"f1": {"state": "idle", "globalBytes": 1, "needBytes": 0,
                                                        "pullErrors": 3}}))
        self.assertEqual((view["state"], view["problem"]), ("problem", "3 items could not be synced"))

    def test_a_paused_folder_is_a_problem(self):
        view = sync.assemble(snapshot(folders=[folder("f1", paused=True)], statuses={}))
        self.assertEqual((view["state"], view["problem"]), ("problem", "Paused"))

    def test_an_unknown_state_is_reported_not_taken_for_idle(self):
        view = sync.assemble(snapshot(statuses={"f1": {"state": "lizard"}}))
        self.assertEqual(view["state"], "problem")

    def test_a_pending_device_has_a_code_to_compare(self):
        view = sync.assemble(snapshot(pending_devices={THIRD: {"name": "", "address": "1.2.3.4:22000"}}))
        self.assertEqual(view["pendingDevices"], [{"id": THIRD, "name": "CCCC-CCC", "code": "CCCC-CCC"}])

    def test_offers_name_the_offering_device(self):
        view = sync.assemble(snapshot(pending_folders={
            "p1": {"offeredBy": {PEER: {"label": "Photos"}}},
            "p2": {"offeredBy": {PEER: {"label": ""}}}}))
        self.assertEqual([(o["folder"], o["label"], o["device"], o["deviceName"]) for o in view["offers"]],
                         [("p1", "Photos", PEER, "Pixel"), ("p2", "p2", PEER, "Pixel")])

    def test_no_drop_is_ever_offered_to_join_not_even_one_a_third_device_made_up(self):
        view = sync.assemble(snapshot(pending_folders={
            DROP: {"offeredBy": {PEER: {"label": "vekrona drop"}}},
            sync.drop_folder_id(PEER, THIRD): {"offeredBy": {THIRD: {"label": "vekrona drop"}}},
            sync.drop_folder_id(ME, THIRD): {"offeredBy": {PEER: {"label": "vekrona drop"}}},
            "vekrona-drop-lizard": {"offeredBy": {PEER: {"label": "vekrona drop"}}}}))
        self.assertEqual(view["offers"], [])

    def test_a_device_that_announced_itself_and_is_on_no_list_is_nearby(self):
        view = sync.assemble(snapshot(discovered={THIRD: {"addresses": ["tcp://10.0.0.2:22000"]}}))
        self.assertEqual(view["nearby"], [{"id": THIRD, "code": "CCCC-CCC", "addresses": ["tcp://10.0.0.2:22000"]}])

    def test_this_computer_and_the_devices_of_every_list_are_not_nearby(self):
        view = sync.assemble(snapshot(
            discovered={d: {"addresses": []} for d in (ME, PEER, THIRD, "D" * 7 + ("-" + "D" * 7) * 7, "E" * 7 + ("-" + "E" * 7) * 7)},
            pending_devices={THIRD: {"name": "", "address": ""}}, ignored=frozenset({"D" * 7 + ("-" + "D" * 7) * 7})))
        self.assertEqual([device["id"] for device in view["nearby"]], ["E" * 7 + ("-" + "E" * 7) * 7])

    def test_nobody_nearby_is_an_empty_list(self):
        self.assertEqual(sync.assemble(snapshot())["nearby"], [])

    def test_the_view_names_this_computer_by_its_id_and_a_code_to_compare(self):
        self.assertEqual(sync.assemble(snapshot())["me"], {"id": ME, "code": "AAAA-AAA"})

    def test_a_folder_that_started_syncing_after_an_error_has_zero_progress_not_a_missing_key(self):
        view = sync.assemble(snapshot(statuses={"f1": {"state": "syncing", "error": None}}))
        self.assertEqual((view["state"], view["folders"][0]["progress"]), ("syncing", 0))


class StateStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.reports = []
        self.store = sync.StateStore(self.reports.append)

    def arrival(self, name):
        return {"name": name, "path": f"/d/{name}", "from": "Pixel", "unseen": True}

    def raw(self):
        with open(self.store.path) as f:
            return json.load(f)

    def test_every_write_carries_the_schema(self):
        publish = lambda: self.store.publish(sync.assemble(snapshot()), [])
        for name, write in (("publish", publish), ("seen", lambda: (publish(), self.store.mark_seen())),
                            ("await", lambda: self.store.await_connection(PEER)), ("offline", lambda: sync.command_offline(None))):
            with self.subTest(write=name):
                if os.path.exists(self.store.path):
                    os.unlink(self.store.path)
                write()
                self.assertEqual(self.raw()["schema"], sync.SCHEMA_VERSION)

    def test_sync_qml_reads_the_schema_the_watcher_writes(self):
        with open(os.path.join(os.path.dirname(os.path.dirname(HERE)), "config", "vekrona-shell", "Sync.qml")) as f:
            self.assertRegex(f.read(), rf"readonly property int schemaVersion: {sync.SCHEMA_VERSION}\n")

    def test_a_file_of_an_older_schema_is_replaced_without_a_complaint_and_keeps_nothing_of_it(self):
        os.makedirs(os.path.dirname(self.store.path))
        with open(self.store.path, "w") as f:
            json.dump({"state": "idle", "folders": [], "offers": [], "pendingDevices": [], "devices": [],
                       "arrivals": [self.arrival("old")]}, f)
        self.assertIsNone(self.store.read())
        self.store.publish(sync.assemble(snapshot()), [])
        self.assertEqual((self.raw()["schema"], self.raw()["arrivals"], self.reports), (sync.SCHEMA_VERSION, [], []))

    def test_seen_marks_every_arrival_and_keeps_the_rest(self):
        self.store.publish(sync.assemble(snapshot()), [self.arrival("a"), self.arrival("b")])
        self.store.mark_seen()
        state = self.store.read()
        self.assertEqual([a["unseen"] for a in state["arrivals"]], [False, False])
        self.assertEqual(state["state"], "idle")

    def test_seen_without_a_state_file_creates_none(self):
        self.store.mark_seen()
        self.assertIsNone(self.store.read())

    def test_seen_when_everything_is_seen_does_not_rewrite_the_file(self):
        self.store.publish(sync.assemble(snapshot()), [self.arrival("a")])
        self.store.mark_seen()
        before = os.stat(self.store.path)
        self.store.mark_seen()
        after = os.stat(self.store.path)
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_publishing_what_the_file_says_already_does_not_rewrite_it(self):
        self.store.publish(sync.assemble(snapshot()), [])
        before = os.stat(self.store.path)
        self.store.publish(sync.assemble(snapshot()), [])
        self.assertEqual(before.st_ino, os.stat(self.store.path).st_ino)

    def test_new_arrivals_come_first_and_only_the_last_twenty_stay(self):
        self.store.publish(sync.assemble(snapshot()), [self.arrival(f"old{i}") for i in range(15)])
        self.store.mark_seen()
        self.store.publish(sync.assemble(snapshot()), [self.arrival(f"new{i}") for i in range(10)])
        arrivals = self.store.read()["arrivals"]
        self.assertEqual(len(arrivals), 20)
        self.assertEqual(arrivals[0]["name"], "new0")
        self.assertEqual([a["unseen"] for a in arrivals], [True] * 10 + [False] * 10)

    def test_the_offline_view_says_so_in_plain_words_and_keeps_the_arrivals(self):
        self.store.publish(sync.assemble(snapshot()), [self.arrival("a")])
        self.store.publish(sync.offline_view(), [])
        state = self.store.read()
        self.assertEqual((state["state"], state["problem"], state["folders"]),
                         ("offline", "Syncthing is not running", []))
        self.assertEqual([a["name"] for a in state["arrivals"]], ["a"])

    def test_a_state_file_that_is_not_json_is_reported_once_and_replaced_by_the_next_state(self):
        os.makedirs(os.path.dirname(self.store.path))
        with open(self.store.path, "w") as f:
            f.write("not json")
        self.store.publish(sync.assemble(snapshot()), [])
        self.assertEqual(len(self.reports), 1)
        self.assertIn(self.store.path, self.reports[0])
        self.assertEqual(self.store.read()["state"], "idle")
        self.assertEqual(len(self.reports), 1)

    def test_a_state_file_of_the_wrong_shape_is_replaced_the_same_way(self):
        os.makedirs(os.path.dirname(self.store.path))
        for content in ("[]", "{}", '{"arrivals": 3}'):
            with self.subTest(content=content):
                with open(self.store.path, "w") as f:
                    f.write(content)
                self.reports.clear()
                self.store.publish(sync.assemble(snapshot()), [])
                self.assertEqual(len(self.reports), 1)
                self.assertEqual(self.store.read()["arrivals"], [])


class FakeSyncthing(sync.Syncthing):
    def __init__(self, answers, statuses=None):
        super().__init__("/nonexistent", "key")
        self.answers = answers
        self.statuses = statuses or {}
        self.writes = []
        self.requests = []

    def request(self, method, path, query=None, body=None, timeout=None):
        self.requests.append((method, path))
        if method != "GET":
            self.writes.append((method, path, body))
            return None
        if path == "/rest/db/status":
            return self.statuses[query["folder"]]
        answer = self.answers[path]
        return answer(query) if callable(answer) else answer


class Recorder:
    def __init__(self):
        self.calls = []
        self.actions = {}

    def pairing(self, device, accept, reject):
        self.calls.append(("pairing", device["id"]))

    def offer(self, offer, join):
        self.calls.append(("offer", offer["folder"]))

    def arrival(self, arrival):
        self.calls.append(("arrival", arrival["name"]))

    def nearby(self, device, pair, ignore):
        self.calls.append(("nearby", device["id"]))
        self.actions[device["id"]] = (pair, ignore)

    def pair_requested(self, code):
        self.calls.append(("pair_requested", code))

    def connected(self, name):
        self.calls.append(("connected", name))


class WatcherTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        for name, value in (("XDG_STATE_HOME", "state"), ("XDG_DATA_HOME", "data")):
            patcher = mock.patch.dict(os.environ, {name: os.path.join(self.tmp.name, value)})
            patcher.start()
            self.addCleanup(patcher.stop)
        self.downloads = os.path.join(self.tmp.name, "Downloads")
        patcher = mock.patch.object(sync, "downloads_dir", return_value=self.downloads)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.drop_path = os.path.join(self.tmp.name, "drop")
        self.inbox = os.path.join(self.drop_path, "to", ME)
        os.makedirs(self.inbox)
        self.notifier = Recorder()
        self.reports = []
        # The devices that answer a connect, in place of the network: the ones of a test's nearby list that are in `here`.
        self.here = set()
        patcher = mock.patch.object(sync, "answering_nearby",
                                    lambda nearby: [device["id"] for device in nearby if device["id"] in self.here])
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = sync.StateStore(self.reports.append)
        self.watcher = sync.Watcher(self.store, self.notifier, self.reports.append)

    def api(self, pending_folders=None, pending_devices=None, drop_devices=(ME, PEER), notes_status=None):
        config_folders = [folder(DROP, "vekrona drop", self.drop_path, devices=drop_devices)]
        if notes_status is not None:
            config_folders.append(folder("f1"))
        return FakeSyncthing({
            "/rest/system/status": {"myID": ME},
            "/rest/config": {"folders": config_folders, "remoteIgnoredDevices": [],
                             "devices": [{"deviceID": ME, "name": "this"}, {"deviceID": PEER, "name": "Pixel"}]},
            "/rest/system/discovery": {},
            "/rest/db/ignores": {"ignore": [], "expanded": [], "error": None},
            "/rest/svc/deviceid": syncthing_judging_ids,
            "/rest/config/devices": [{"deviceID": ME}],
            "/rest/config/defaults/device": {"addresses": ["dynamic"], "name": ""},
            "/rest/config/folders": config_folders,
            "/rest/system/connections": {"connections": {PEER: {"connected": True}}},
            "/rest/cluster/pending/devices": pending_devices or {},
            "/rest/cluster/pending/folders": pending_folders or {},
            "/rest/config/defaults/folder": {"id": "", "devices": []}},
            statuses={"f1": notes_status} if notes_status is not None else {})

    def refresh(self, api, scan_all, finished=(), summarized=(), discovered=None, connected=None):
        self.watcher.api = api
        self.watcher.snapshot = sync.read_snapshot(api, ME)
        self.watcher.refresh(scan_all=scan_all, finished=set(finished), summarized=set(summarized),
                             discovered=scan_all if discovered is None else discovered, connected=connected or {})

    def follow(self, api, *batches):
        """Follows api through the batches of events, then until Syncthing stops answering."""
        remaining = list(batches)
        polls = []

        def events(since, limit=None, timeout_sec=0):
            polls.append(since)
            if limit is not None:
                return []
            if not remaining:
                raise sync.Unreachable("stopped")
            return remaining.pop(0)

        api.events = events
        with self.assertRaises(sync.Unreachable):
            self.watcher.follow(api)
        return polls

    def put(self, name):
        with open(os.path.join(self.inbox, name), "w") as f:
            f.write(name)

    def test_the_startup_scan_receives_files_that_arrived_while_the_watcher_was_down(self):
        self.put("late.txt")
        self.refresh(self.api(), scan_all=True)
        self.assertEqual(os.listdir(self.downloads), ["late.txt"])
        self.assertEqual(os.listdir(self.inbox), [])
        state = self.store.read()
        self.assertEqual([(a["name"], a["from"], a["unseen"]) for a in state["arrivals"]], [("late.txt", "Pixel", True)])
        self.assertEqual(self.notifier.calls, [("arrival", "late.txt")])

    def api_with_drop(self):
        """api() whose answers about the ignore patterns and the files of the drop come from a SyncthingDrop."""
        api = self.api()
        outbox = os.path.join(self.drop_path, "to", PEER)
        os.makedirs(outbox)
        drop = SyncthingDrop(PEER, outbox)
        drop.sent("photo.jpg")
        plain_request = api.request
        api.request = lambda method, path, **kwargs: (drop.request(method, path, **kwargs)
                                                    if path in ("/rest/db/ignores", "/rest/db/file")
                                                    else plain_request(method, path, **kwargs))
        return api, drop, outbox

    def test_a_summary_of_a_drop_has_the_watcher_clean_up_what_it_sent_and_no_other_event_does(self):
        api, drop, outbox = self.api_with_drop()
        self.refresh(api, scan_all=False)
        self.refresh(api, scan_all=False, finished={"f1"})
        self.assertEqual(drop.lines, [])
        self.refresh(api, scan_all=False, summarized={DROP})
        self.assertEqual(drop.lines, [f"/to/{PEER}/photo.jpg"])
        drop.scan()
        self.refresh(api, scan_all=False, summarized={DROP})
        self.assertEqual(os.listdir(outbox), [])

    def test_the_startup_scan_cleans_up_a_drop_whose_receiver_has_the_files(self):
        api, drop, outbox = self.api_with_drop()
        self.refresh(api, scan_all=True)
        self.assertEqual(drop.lines, [f"/to/{PEER}/photo.jpg"])

    def test_a_drop_that_a_third_device_shares_is_not_cleaned_up(self):
        api, drop, outbox = self.api_with_drop()
        api.answers["/rest/config"]["folders"] = [folder(DROP, "vekrona drop", self.drop_path, devices=(ME, PEER, THIRD))]
        self.refresh(api, scan_all=True)
        self.assertEqual(drop.lines, [])
        self.assertEqual(len(self.reports), 1)

    def test_a_paused_drop_is_not_cleaned_up(self):
        api, drop, outbox = self.api_with_drop()
        api.answers["/rest/config"]["folders"] = [folder(DROP, "vekrona drop", self.drop_path, devices=(ME, PEER), paused=True)]
        self.refresh(api, scan_all=True)
        self.assertEqual(drop.lines, [])
        self.assertEqual(self.reports, [])

    def test_a_cleanup_that_fails_is_reported_once_and_the_receiving_goes_on(self):
        api, drop, outbox = self.api_with_drop()
        drop.sent("two\nlines.txt")
        self.put("incoming.txt")
        self.refresh(api, scan_all=True)
        self.refresh(api, scan_all=True)
        self.assertEqual(os.listdir(self.downloads), ["incoming.txt"])
        self.assertEqual(len(self.reports), 1)
        self.assertIn("two\\nlines.txt", self.reports[0])

    def test_a_syncthing_that_stops_answering_during_the_cleanup_ends_the_watcher_pass(self):
        api, drop, outbox = self.api_with_drop()

        def gone(*args, **kwargs):
            raise sync.Unreachable("no socket")

        drop.request = gone
        with self.assertRaises(sync.Unreachable):
            self.refresh(api, scan_all=True)

    def nearby_api(self, *devices):
        api = self.api()
        api.answers["/rest/system/discovery"] = {device: {"addresses": ["tcp://10.0.0.2:22000"]} for device in devices}
        return api

    def proposals(self):
        return [call for call in self.notifier.calls if call[0] == "nearby"]

    def test_a_device_that_announces_itself_and_answers_is_proposed_once_with_a_dot(self):
        self.here = {THIRD}
        self.refresh(self.nearby_api(THIRD), scan_all=False, discovered=True)
        self.assertEqual(self.proposals(), [("nearby", THIRD)])
        state = self.store.read()
        self.assertEqual([(device["id"], device["unseen"]) for device in state["nearby"]], [(THIRD, True)])

    def test_a_device_that_is_heard_again_is_not_proposed_again_whether_it_left_for_a_while_or_the_watcher_restarted(self):
        self.here = {THIRD}
        api = self.nearby_api(THIRD)
        self.refresh(api, scan_all=False, discovered=True)
        self.refresh(api, scan_all=False, discovered=True)
        self.refresh(api, scan_all=True)
        restarted = sync.Watcher(sync.StateStore(self.reports.append), self.notifier, self.reports.append)
        restarted.api = api
        restarted.snapshot = sync.read_snapshot(api, ME)
        restarted.refresh(scan_all=True, finished=set(), summarized=set(), discovered=True, connected={})
        self.assertEqual(len(self.proposals()), 1)

    def test_a_device_that_does_not_answer_is_not_proposed_until_it_does(self):
        api = self.nearby_api(THIRD)
        self.refresh(api, scan_all=False, discovered=True)
        self.assertEqual(self.proposals(), [])
        self.assertEqual(self.store.read()["nearby"][0]["unseen"], False)
        self.here = {THIRD}
        self.refresh(api, scan_all=False, discovered=True)
        self.assertEqual(len(self.proposals()), 1)

    def test_nothing_is_tried_or_proposed_by_an_event_that_heard_no_device(self):
        self.here = {THIRD}
        self.refresh(self.nearby_api(THIRD), scan_all=False, discovered=False)
        self.assertEqual(self.proposals(), [])

    def test_this_computer_its_devices_the_pending_and_the_ignored_are_never_proposed(self):
        self.here = {ME, PEER, THIRD, FOURTH}
        api = self.nearby_api(ME, PEER, THIRD, FOURTH)
        api.answers["/rest/cluster/pending/devices"] = {THIRD: {"name": "Laptop"}}
        api.answers["/rest/config"]["remoteIgnoredDevices"] = [{"deviceID": FOURTH}]
        self.refresh(api, scan_all=True)
        self.assertEqual(self.proposals(), [])

    def test_not_now_proposes_nothing_more_and_the_device_stays_in_the_list_with_its_dot_until_the_popout_is_opened(self):
        self.here = {THIRD}
        api = self.nearby_api(THIRD)
        self.refresh(api, scan_all=False, discovered=True)
        self.refresh(api, scan_all=False, discovered=True)
        self.assertEqual(api.writes, [])
        self.assertEqual(len(self.proposals()), 1)
        self.assertEqual(self.store.read()["nearby"][0]["unseen"], True)
        self.store.mark_seen()
        self.assertEqual(self.store.read()["nearby"][0]["unseen"], False)
        self.refresh(api, scan_all=False, discovered=True)
        self.assertEqual(self.store.read()["nearby"][0]["unseen"], False)
        self.assertEqual(len(self.proposals()), 1)

    def test_the_dot_of_a_device_stays_through_the_events_that_try_no_device(self):
        self.here = {THIRD}
        api = self.nearby_api(THIRD)
        self.refresh(api, scan_all=False, discovered=True)
        self.refresh(api, scan_all=False, discovered=False)
        self.assertEqual(self.store.read()["nearby"][0]["unseen"], True)

    def test_a_dot_cleared_by_the_popout_stays_clear_when_syncthing_restarts_and_the_device_is_heard_again(self):
        self.here = {THIRD}
        api = self.nearby_api(THIRD)
        self.refresh(api, scan_all=False, discovered=True)
        self.store.mark_seen()
        self.store.publish(sync.offline_view(), [])
        self.assertEqual(self.store.read()["nearby"], [])
        self.refresh(api, scan_all=False, discovered=True)
        self.assertEqual(self.store.read()["nearby"][0]["unseen"], False)
        self.assertEqual(len(self.proposals()), 1)

    def test_ignore_puts_the_device_on_the_ignored_list_and_pair_asks_it_and_says_so(self):
        self.here = {THIRD, FOURTH}
        api = self.nearby_api(THIRD, FOURTH)
        self.refresh(api, scan_all=False, discovered=True)
        pair, _ = self.notifier.actions[THIRD]
        _, ignore = self.notifier.actions[FOURTH]
        ignore()
        put = next(body for method, path, body in api.writes if (method, path) == ("PUT", "/rest/config"))
        self.assertEqual([entry["deviceID"] for entry in put["remoteIgnoredDevices"]], [FOURTH])
        pair()
        posted = next(body for method, path, body in api.writes if (method, path) == ("POST", "/rest/config/devices"))
        self.assertEqual(posted["deviceID"], THIRD)
        self.assertIn(("pair_requested", sync.short_code(THIRD)), self.notifier.calls)

    def test_the_first_connection_of_a_device_that_was_asked_to_pair_is_announced_once_with_its_name(self):
        self.here = {THIRD}
        api = self.nearby_api(THIRD)
        self.refresh(api, scan_all=False, discovered=True)
        self.notifier.actions[THIRD][0]()
        self.refresh(api, scan_all=False, connected={FOURTH: "Stranger"})
        self.assertNotIn(("connected", "Stranger"), self.notifier.calls)
        self.refresh(api, scan_all=False, connected={THIRD: "Pixel"})
        self.refresh(api, scan_all=False, connected={THIRD: "Pixel"})
        self.assertEqual([call for call in self.notifier.calls if call[0] == "connected"], [("connected", "Pixel")])

    def test_a_device_that_connected_while_the_watcher_was_down_is_announced_at_the_start(self):
        self.store.await_connection(PEER)
        self.refresh(self.api(), scan_all=True)
        self.assertEqual([call for call in self.notifier.calls if call[0] == "connected"], [("connected", "Pixel")])

    def test_following_proposes_a_device_when_syncthing_reports_it_and_announces_a_connection_with_the_name_it_reports(self):
        self.here = {THIRD}
        api = self.nearby_api(THIRD)
        self.store.await_connection(THIRD)
        discovered = {"id": 1, "type": "DeviceDiscovered", "data": {"device": THIRD, "addrs": []}}
        connected = {"id": 2, "type": "DeviceConnected", "data": {"id": THIRD, "deviceName": "Pixel 9"}}
        self.follow(api, [discovered], [connected])
        self.assertEqual(self.notifier.calls, [("nearby", THIRD), ("connected", "Pixel 9")])

    def test_the_ledger_is_bounded(self):
        for index in range(sync.MAX_LEDGER + 20):
            self.store.await_connection(f"D{index}")
        self.assertEqual(len(self.store.read()["ledger"]["awaiting"]), sync.MAX_LEDGER)
        self.assertEqual(self.store.read()["ledger"]["awaiting"][-1], f"D{sync.MAX_LEDGER + 19}")

    def test_an_event_batch_looks_only_into_the_drops_where_a_file_finished(self):
        self.put("a.txt")
        self.refresh(self.api(), scan_all=False)
        self.assertEqual(os.listdir(self.inbox), ["a.txt"])
        self.refresh(self.api(), scan_all=False, finished={DROP})
        self.assertEqual(os.listdir(self.inbox), [])

    def test_a_file_that_cannot_be_moved_is_reported_and_the_others_still_arrive(self):
        self.put("a.txt")
        self.put("b.txt")
        real_place = sync.place_without_overwriting

        def place(source_fd, source_name, directory_fd, name):
            if name == "a.txt":
                raise OSError("disk full")
            return real_place(source_fd, source_name, directory_fd, name)

        with mock.patch.object(sync, "place_without_overwriting", place):
            self.refresh(self.api(), scan_all=True)
        self.assertEqual(os.listdir(self.downloads), ["b.txt"])
        self.assertEqual(len(self.reports), 1)
        self.assertIn("a.txt", self.reports[0])

    def test_the_drop_of_the_other_party_is_taken_and_never_listed_as_an_offer(self):
        api = self.api(pending_folders={DROP: {"offeredBy": {PEER: {"label": "vekrona drop"}}}}, drop_devices=(ME,))
        self.refresh(api, scan_all=True)
        self.assertEqual(api.writes, [("PATCH", f"/rest/config/folders/{DROP}",
                                       {"devices": [{"deviceID": ME}, {"deviceID": PEER}]})])
        self.assertEqual(self.store.read()["offers"], [])
        self.assertEqual(self.notifier.calls, [])

    def test_a_drop_that_does_not_exist_yet_is_created_shared_by_the_two_devices(self):
        api = self.api(pending_folders={DROP: {"offeredBy": {PEER: {"label": "vekrona drop"}}}})
        api.answers["/rest/config/folders"] = []
        self.refresh(api, scan_all=True)
        method, path, body = api.writes[0]
        self.assertEqual((method, path, body["id"], body["type"], [d["deviceID"] for d in body["devices"]]),
                         ("POST", "/rest/config/folders", DROP, "sendreceive", [ME, PEER]))
        self.assertTrue(body["path"].startswith(os.path.join(self.tmp.name, "data")))

    def test_a_drop_offered_by_a_third_device_is_not_shown_taken_or_notified_and_is_logged_once(self):
        spoof = sync.drop_folder_id(ME, THIRD)
        api = self.api(pending_folders={spoof: {"offeredBy": {PEER: {"label": "vekrona drop"}}},
                                        DROP: {"offeredBy": {THIRD: {"label": "vekrona drop"}}}})
        with mock.patch("sys.stderr") as stderr:
            self.refresh(api, scan_all=True)
            self.refresh(api, scan_all=True)
        self.assertEqual(api.writes, [])
        self.assertEqual(self.store.read()["offers"], [])
        self.assertEqual(self.notifier.calls, [])
        logged = "".join(call.args[0] for call in stderr.write.call_args_list)
        self.assertEqual(logged.count("ignoring the offer"), 2)

    def test_a_drop_that_a_third_device_shares_is_refused_for_receiving_and_reported_once(self):
        self.put("planted.txt")
        api = self.api(drop_devices=(ME, PEER, THIRD))
        self.refresh(api, scan_all=True)
        self.refresh(api, scan_all=True)
        self.assertEqual(os.listdir(self.inbox), ["planted.txt"])
        self.assertEqual(len(self.reports), 1)
        self.assertIn(THIRD, self.reports[0])

    def test_a_drop_that_a_third_device_shares_is_not_taken_over_when_its_other_party_offers_it_again(self):
        api = self.api(pending_folders={DROP: {"offeredBy": {PEER: {"label": "vekrona drop"}}}},
                       drop_devices=(ME, THIRD))
        self.refresh(api, scan_all=True)
        self.assertEqual(api.writes, [])
        self.assertEqual(len(self.reports), 1)
        self.assertIn(THIRD, self.reports[0])

    def test_each_pairing_request_and_offer_is_notified_once_until_it_is_gone(self):
        pending = {"pending_devices": {THIRD: {"name": "Laptop"}},
                   "pending_folders": {"p1": {"offeredBy": {PEER: {"label": "Photos"}}}}}
        self.refresh(self.api(**pending), scan_all=False)
        self.refresh(self.api(**pending), scan_all=False)
        self.assertEqual(sorted(self.notifier.calls), [("offer", "p1"), ("pairing", THIRD)])
        self.refresh(self.api(), scan_all=False)
        self.refresh(self.api(**pending), scan_all=False)
        self.assertEqual(len(self.notifier.calls), 4)

    def test_following_reads_everything_at_start_and_after_a_jump_in_the_ids_and_looks_into_a_drop_where_a_file_finished(self):
        elsewhere = {"id": 1, "type": "ItemFinished", "data": {"folder": "f1", "error": None}}
        in_drop = {"id": 2, "type": "ItemFinished", "data": {"folder": DROP, "error": None}}
        dropped = {"id": 9, "type": "StateChanged", "data": {"folder": "f1", "to": "idle"}}
        api = self.api()
        self.put("sent.txt")
        polls = self.follow(api, [elsewhere], [in_drop], [dropped])
        self.assertEqual(polls, [0, 0, 1, 2, 9])
        self.assertEqual(os.listdir(self.downloads), ["sent.txt"])
        # The start and the batch with the jump from 2 to 9; the finished file in the drop needs no configuration.
        self.assertEqual(api.requests.count(("GET", "/rest/config")), 2)

    def test_a_folder_summary_updates_the_progress_without_asking_syncthing_about_the_folder(self):
        api = self.api(notes_status={"state": "idle", "globalBytes": 100, "needBytes": 0})
        summary = {"id": 1, "type": "FolderSummary",
                   "data": {"folder": "f1", "summary": {"state": "syncing", "globalBytes": 100, "needBytes": 40}}}
        self.follow(api, [summary])
        state = self.store.read()
        self.assertEqual((state["state"], state["folders"][0]["progress"]), ("syncing", 60))
        self.assertEqual(api.requests.count(("GET", "/rest/db/status")), 1)

    def test_a_state_change_updates_the_state_without_asking_syncthing_about_the_folder(self):
        api = self.api(notes_status={"state": "idle", "globalBytes": 100, "needBytes": 0})
        failing = {"id": 1, "type": "StateChanged",
                   "data": {"folder": "f1", "from": "idle", "to": "error", "error": "folder path missing"}}
        self.follow(api, [failing])
        state = self.store.read()
        self.assertEqual((state["state"], state["problem"]), ("problem", "folder path missing"))
        self.assertEqual(api.requests.count(("GET", "/rest/db/status")), 1)

    def test_a_device_coming_and_going_updates_who_is_connected_without_reading_the_configuration(self):
        api = self.api()
        api.answers["/rest/system/connections"] = {"connections": {}}
        gone = {"id": 1, "type": "DeviceConnected", "data": {"id": PEER}}
        self.follow(api, [gone])
        self.assertEqual(self.store.read()["devices"], [{"id": PEER, "name": "Pixel", "connected": True, "sharesWithUs": False}])
        self.assertEqual(api.requests.count(("GET", "/rest/config")), 1)

    def test_a_saved_configuration_and_a_change_of_what_is_pending_read_everything_again(self):
        for event_type in ("ConfigSaved", "PendingDevicesChanged", "PendingFoldersChanged",
                           "DeviceDiscovered"):
            with self.subTest(event_type=event_type):
                api = self.api()
                self.follow(api, [{"id": 1, "type": event_type, "data": {}}])
                self.assertEqual(api.requests.count(("GET", "/rest/config")), 2)

    def test_a_device_discovered_on_the_network_shows_up_nearby_in_the_state_file(self):
        api = self.api()
        api.answers["/rest/system/discovery"] = {THIRD: {"addresses": ["tcp://10.0.0.2:22000"]}}
        self.follow(api, [{"id": 1, "type": "DeviceDiscovered", "data": {"device": THIRD, "addrs": []}}])
        self.assertEqual([device["id"] for device in self.store.read()["nearby"]], [THIRD])

    def test_events_that_cannot_change_the_view_are_skipped(self):
        finished_elsewhere = {"type": "ItemFinished", "data": {"folder": "f1", "error": None}}
        finished_in_drop = {"type": "ItemFinished", "data": {"folder": DROP, "error": None}}
        failed_in_drop = {"type": "ItemFinished", "data": {"folder": DROP, "error": "no space"}}
        self.assertFalse(sync.matters(finished_elsewhere))
        self.assertTrue(sync.matters(finished_in_drop))
        self.assertTrue(sync.matters({"type": "StateChanged", "data": {"folder": "f1"}}))
        self.assertEqual(sync.finished_drops([finished_elsewhere, finished_in_drop, failed_in_drop]), {DROP})
        self.assertEqual(sync.summarized_drops([{"type": "FolderSummary", "data": {"folder": "f1"}},
                                                {"type": "FolderSummary", "data": {"folder": DROP}},
                                                {"type": "StateChanged", "data": {"folder": DROP}}]), {DROP})


def pattern_regex(pattern):
    """The documented syntax of a Syncthing ignore pattern (backslash escapes, * ? [] {}), as a regular expression: an
    implementation of its own, so that the lines of vekrona-sync are judged by something other than its own parser."""
    out, index = [], 0
    while index < len(pattern):
        c = pattern[index]
        if c == "\\":
            out.append(re.escape(pattern[index + 1]))
            index += 2
        elif c == "*":
            out.append("[^/]*")
            index += 1
        elif c == "?":
            out.append("[^/]")
            index += 1
        elif c == "[":
            end = pattern.index("]", index)
            out.append("[" + pattern[index + 1:end] + "]")
            index = end + 1
        elif c == "{":
            end = pattern.index("}", index)
            out.append("(?:" + "|".join(re.escape(alternative) for alternative in pattern[index + 1:end].split(",")) + ")")
            index = end + 1
        elif c in "]}":
            raise ValueError(f"unbalanced {c} in {pattern!r}")
        else:
            out.append(re.escape(c))
            index += 1
    return re.compile("".join(out))


class SyncthingDrop(sync.Syncthing):
    """What Syncthing does with one drop folder, as far as vekrona-sync asks it: the .stignore it keeps, a scan that flags the
    files which a line matches as ignored in the index (and keeps the flag when the file is gone), and for each path the entry
    of this device and the global one, which is the other device's when it has a file of its own. The checks of Syncthing's
    source that the model rests on are listed in the comment above tend_sent."""

    def __init__(self, partner, directory):
        super().__init__("/nonexistent", "key")
        self.partner = partner
        self.directory = directory
        self.lines = []
        self.theirs = {}
        self.indexed = set()
        self.flagged = set()
        self.connected = True
        self.writes = []
        self.refuse_patterns = False

    def sent(self, name, content="x", has=True):
        """A file here, in the index, which the other device has (or not yet)."""
        with open(os.path.join(self.directory, name), "w") as f:
            f.write(content)
        path = f"to/{self.partner}/{sync.db_name(name)}"
        self.indexed.add(path)
        if has:
            self.theirs[path] = {"deleted": False, "version": ["S:1"]}
        return path

    def matches(self, path):
        return any(pattern_regex(sync.db_name(line.strip()).lstrip("/")).fullmatch(path) for line in self.lines
                   if line.strip() and not line.strip().startswith("//"))

    def scan(self):
        self.flagged |= {path for path in self.indexed if self.matches(path)}

    def request(self, method, path, query=None, body=None, timeout=None):
        if path == "/rest/db/ignores":
            if method == "POST":
                self.writes.append((method, path, body))
                self.lines = list(body["ignore"])
            error = "invalid pattern" if self.refuse_patterns and method == "POST" else None
            return {"ignore": list(self.lines), "expanded": [], "error": error}
        if path == "/rest/db/file":
            return self.entry(query["file"])
        raise AssertionError(f"unexpected {method} {path}")

    def entry(self, path):
        local_exists = path in self.indexed
        there = self.theirs.get(path)
        if not local_exists and there is None:
            raise sync.NotFound("Syncthing refused GET /rest/db/file with HTTP 404: No such object in the index")
        flagged = path in self.flagged
        here = {"name": path if local_exists else "", "deleted": False, "invalid": flagged, "ignored": flagged,
                "version": ["S:1"]}
        remote = dict(here) if there is None else {"name": path, "deleted": there["deleted"], "version": there["version"]}
        availability = [{"id": self.partner, "fromTemporary": False}] if there is not None and self.connected else None
        return {"global": remote, "local": here, "availability": availability}


class TendSentTest(unittest.TestCase):
    """The sender's cleanup of a drop whose receiver keeps files (an Android or macOS client)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.drop = os.path.join(self.tmp.name, "drop")
        self.inbox = os.path.join(self.drop, "to", PEER)
        os.makedirs(self.inbox)
        self.api = SyncthingDrop(PEER, self.inbox)

    def tend(self):
        return sync.tend_sent(self.api, DROP, self.drop, PEER)

    def on_disk(self):
        return sorted(os.listdir(self.inbox))

    def test_a_file_the_receiver_has_is_ignored_then_deleted_here_and_the_receivers_copy_is_never_touched(self):
        path = self.api.sent("photo.jpg")
        self.assertEqual(self.tend(), [])
        self.assertEqual(self.api.lines, [f"/to/{PEER}/photo.jpg"])
        self.assertEqual(self.on_disk(), ["photo.jpg"])
        self.assertEqual(self.tend(), [])
        self.assertEqual(self.on_disk(), ["photo.jpg"])
        self.api.scan()
        self.assertEqual(self.tend(), [])
        self.assertEqual(self.on_disk(), [])
        self.assertEqual(self.api.lines, [f"/to/{PEER}/photo.jpg"])
        self.assertEqual(self.api.theirs[path], {"deleted": False, "version": ["S:1"]})
        self.assertEqual([write[0] for write in self.api.writes], ["POST"])

    def test_nothing_is_ignored_or_deleted_before_the_receiver_has_the_very_file(self):
        self.api.sent("not-yet.txt", has=False)
        self.api.sent("older-there.txt")
        self.api.theirs[f"to/{PEER}/older-there.txt"]["version"] = ["S:0"]
        self.assertEqual(self.tend(), [])
        self.api.scan()
        self.assertEqual(self.tend(), [])
        self.assertEqual(self.on_disk(), ["not-yet.txt", "older-there.txt"])
        self.assertEqual(self.api.writes, [])

    def test_nothing_is_ignored_or_deleted_while_the_receiver_is_not_connected(self):
        self.api.sent("away.txt")
        self.api.connected = False
        self.assertEqual(self.tend(), [])
        self.assertEqual(self.api.writes, [])
        self.assertEqual(self.on_disk(), ["away.txt"])

    def test_a_file_that_is_not_in_the_index_yet_waits(self):
        with open(os.path.join(self.inbox, "new.txt"), "w") as f:
            f.write("x")
        self.assertEqual(self.tend(), [])
        self.assertEqual(self.api.writes, [])
        self.assertEqual(self.on_disk(), ["new.txt"])

    def test_the_line_goes_when_the_receiver_deletes_its_copy_and_not_before(self):
        path = self.api.sent("photo.jpg")
        self.tend()
        self.api.scan()
        self.tend()
        self.assertEqual(self.api.lines, [f"/to/{PEER}/photo.jpg"])
        self.api.theirs[path] = {"deleted": True, "version": ["S:1", "R:1"]}
        self.assertEqual(self.tend(), [])
        self.assertEqual(self.api.lines, [])

    def test_a_receiver_that_has_no_entry_of_the_file_does_not_end_the_line(self):
        path = self.api.sent("photo.jpg")
        self.tend()
        self.api.scan()
        self.tend()
        del self.api.theirs[path]
        self.tend()
        self.assertEqual(self.api.lines, [f"/to/{PEER}/photo.jpg"])

    def test_a_line_whose_file_is_still_here_stays_even_when_the_receiver_deleted_its_copy(self):
        path = self.api.sent("photo.jpg")
        self.tend()
        self.api.theirs[path] = {"deleted": True, "version": ["S:1", "R:1"]}
        self.tend()
        self.assertEqual(self.api.lines, [f"/to/{PEER}/photo.jpg"])
        self.assertEqual(self.on_disk(), ["photo.jpg"])

    def test_the_lines_that_are_not_ours_are_kept_in_their_place(self):
        self.api.lines = ["*.tmp", f"/to/{THIRD}/x.txt", "", "// by hand"]
        self.api.sent("a.txt")
        self.tend()
        self.assertEqual(self.api.lines, ["*.tmp", f"/to/{THIRD}/x.txt", "", "// by hand", f"/to/{PEER}/a.txt"])
        self.api.scan()
        self.tend()
        self.api.theirs[f"to/{PEER}/a.txt"] = {"deleted": True, "version": ["S:1", "R:1"]}
        self.tend()
        self.assertEqual(self.api.lines, ["*.tmp", f"/to/{THIRD}/x.txt", "", "// by hand"])

    def test_a_name_with_characters_of_the_pattern_language_ignores_that_file_and_no_other(self):
        names = ["a*b.txt", "[1] {x,y}.txt", "?.txt", "back\\slash", "#hash", "!bang", "(?i)Case", "trailing space ",
                 "tab\t", "a,b", "é.txt", "emoji \U0001F600.png", "x]y", "p}q"]
        decoys = ["aXb.txt", "1 x.txt", "x.txt", "y.txt", "Z.txt", "backslash", "hash", "bang", "case", "trailing space",
                  "tab", "ab", "é.png", "emoji.png", "xy", "pq", "AB"]
        for name in names:
            self.api.sent(name)
        for decoy in decoys:
            self.api.sent(decoy, has=False)
        self.tend()
        self.api.scan()
        self.assertEqual(self.api.flagged, {f"to/{PEER}/{sync.db_name(name)}" for name in names})
        self.tend()
        self.assertEqual(self.on_disk(), sorted(decoys))

    def test_a_name_with_a_line_break_stays_and_is_reported_while_the_others_are_cleaned(self):
        self.api.sent("two\nlines.txt")
        self.api.sent("fine.txt")
        failures = self.tend()
        self.assertEqual(self.api.lines, [f"/to/{PEER}/fine.txt"])
        self.assertEqual(len(failures), 1)
        self.assertIn("two\\nlines.txt", failures[0])

    def test_files_that_are_links_directories_or_half_written_are_left_alone(self):
        os.mkdir(os.path.join(self.inbox, "dir"))
        os.symlink("/etc/hostname", os.path.join(self.inbox, "link"))
        self.api.sent(".syncthing.half.tmp")
        self.assertEqual(self.tend(), [])
        self.assertEqual(self.api.writes, [])

    def test_a_pattern_syncthing_refuses_is_taken_back_and_reported(self):
        self.api.lines = ["*.tmp"]
        self.api.sent("a.txt")
        self.api.refuse_patterns = True
        with self.assertRaisesRegex(sync.SyncError, "refused the ignore patterns.*as before"):
            self.tend()
        self.assertEqual(self.api.lines, ["*.tmp"])

    def test_an_inbox_a_peer_replaced_by_a_link_is_refused_and_the_target_untouched(self):
        victims = os.path.join(self.tmp.name, "victims")
        os.mkdir(victims)
        with open(os.path.join(victims, "private.txt"), "w") as f:
            f.write("secret")
        os.rmdir(self.inbox)
        os.symlink(victims, self.inbox)
        self.api.lines = [f"/to/{PEER}/private.txt"]
        with self.assertRaisesRegex(sync.SyncError, "is a link"):
            self.tend()
        self.assertEqual(os.listdir(victims), ["private.txt"])

    def test_a_drop_without_an_inbox_yet_has_nothing_to_clean(self):
        shutil.rmtree(self.inbox)
        self.assertEqual(self.tend(), [])

    def test_a_file_that_cannot_be_deleted_is_reported_and_the_pass_goes_on(self):
        self.api.sent("a.txt")
        self.api.sent("b.txt")
        self.tend()
        self.api.scan()
        real_unlink = os.unlink

        def unlink(name, *args, **kwargs):
            if name == "a.txt":
                raise PermissionError("read-only")
            return real_unlink(name, *args, **kwargs)

        with mock.patch.object(sync.os, "unlink", unlink):
            failures = self.tend()
        self.assertEqual(self.on_disk(), ["a.txt"])
        self.assertEqual(len(failures), 1)
        self.assertIn("a.txt", failures[0])


class IgnoreLineTest(unittest.TestCase):
    def test_a_line_names_its_file_back_whatever_the_characters(self):
        for name in ("a.txt", "a*b", "[x]", "{a,b}", "back\\slash", "?", "trailing ", " leading", "tab\t", "é",
                     "'quoted'", "\\", "x[ ]"):
            with self.subTest(name=name):
                self.assertEqual(sync.ignored_name(PEER, sync.ignore_line(PEER, name)), sync.db_name(name))

    def test_no_character_of_the_pattern_language_is_left_bare(self):
        self.assertEqual(sync.ignore_line(PEER, "*?[]{}\\"), f"/to/{PEER}/" + r"\*\?\[\]\{\}\\")

    def test_the_lines_of_others_are_none_of_ours(self):
        for line in ("", "*.tmp", "// /to/x", f"/to/{THIRD}/a.txt", f"/to/{PEER}/", f"/to/{PEER}/*.txt", f"/to/{PEER}/a{{b,c}}",
                     f"/to/{PEER}/[ab]", f"/to/{PEER}/ends\\"):
            with self.subTest(line=line):
                self.assertIsNone(sync.ignored_name(PEER, line))

    def test_names_that_no_line_can_hold_are_refused(self):
        for name in ("", "a\nb", "a\rb"):
            with self.subTest(name=name):
                with self.assertRaises(sync.SyncError):
                    sync.ignore_line(PEER, name)


class SendAvoidsIgnoredNamesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.inbox = os.path.join(self.tmp.name, "to", PEER)
        os.makedirs(self.inbox)
        self.fd = os.open(self.inbox, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, self.fd)
        self.file = os.path.join(self.tmp.name, "photo.jpg")
        with open(self.file, "w") as f:
            f.write("new")

    def test_a_file_gets_another_name_when_its_name_has_an_ignore_line(self):
        sync.deliver(self.file, self.fd, frozenset({"photo.jpg", "photo (2).jpg"}))
        self.assertEqual(os.listdir(self.inbox), ["photo (3).jpg"])

    def test_a_name_with_an_ignore_line_is_taken_in_any_normalization(self):
        decomposed = os.path.join(self.tmp.name, "é.txt")
        with open(decomposed, "w") as f:
            f.write("x")
        sync.deliver(decomposed, self.fd, frozenset({sync.db_name("é.txt")}))
        self.assertEqual(len(os.listdir(self.inbox)), 1)
        self.assertNotEqual(sync.db_name(os.listdir(self.inbox)[0]), sync.db_name("é.txt"))

    def test_send_asks_the_ignore_lines_of_the_drop_for_the_names_to_avoid(self):
        api = FakeSyncthing({
            "/rest/system/status": {"myID": ME},
            "/rest/config/folders": [folder(DROP, "vekrona drop", os.path.join(self.tmp.name, "drop"), devices=(ME, PEER))],
            "/rest/config/devices": [{"deviceID": ME}, {"deviceID": PEER}],
            "/rest/db/ignores": {"ignore": [f"/to/{PEER}/photo.jpg"], "expanded": [], "error": None}})
        sync.send(api, PEER, [self.file])
        self.assertEqual(os.listdir(os.path.join(self.tmp.name, "drop", "to", PEER)), ["photo (2).jpg"])


class NotificationTextTest(unittest.TestCase):
    def shown(self, call):
        with mock.patch.object(sync, "run_tool", return_value=mock.Mock(returncode=0, stderr="")) as run:
            call(sync.DesktopNotifier(lambda message: self.fail(message)))
        return run.call_args.args[1]

    def test_the_notifications_of_pairing_say_what_happened_and_what_to_do(self):
        self.assertEqual(self.shown(lambda n: n.pair_requested("ABCD-EFG"))[-2:],
                         ["Pair request sent to ABCD-EFG", "Accept it on the other device."])
        self.assertEqual(self.shown(lambda n: n.connected("Pixel"))[-2:], ["Pixel is now one of your devices", ""])

    def test_the_question_about_a_nearby_device_offers_not_now_first_then_pair_and_ignore(self):
        asked = []
        notifier = sync.DesktopNotifier(lambda message: self.fail(message))
        with mock.patch.object(notifier, "ask", lambda title, body, choices: asked.append((title, body, choices))):
            notifier.nearby({"code": "ABCD-EFG"}, "pair-action", "ignore-action")
        title, body, choices = asked[0]
        self.assertEqual((title, body), ("A Syncthing device ABCD-EFG is nearby", "Pair with it?"))
        self.assertEqual(choices, [("later", "Not now", None), ("pair", "Pair", "pair-action"), ("ignore", "Ignore", "ignore-action")])


class NotifierTest(unittest.TestCase):
    def test_a_notification_tool_that_cannot_be_started_is_reported_not_raised_in_its_thread(self):
        reports = []
        sync.DesktopNotifier(reports.append).wait_for_answer(["/nonexistent/vekrona-update-ask"], {})
        self.assertEqual(len(reports), 1)
        self.assertIn("needs /nonexistent/vekrona-update-ask, which is not installed", reports[0])


class CommandTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": os.path.join(self.tmp.name, "state"),
                                               "XDG_DATA_HOME": os.path.join(self.tmp.name, "data")})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.reports = []
        patcher = mock.patch.object(sync, "report_failure", self.reports.append)
        patcher.start()
        self.addCleanup(patcher.stop)

    def watch_ending_with(self, exc):
        with mock.patch.object(sync.Syncthing, "from_config", side_effect=exc):
            with self.assertRaises(SystemExit) as raised:
                sync.command_watch(None)
        return raised.exception.code

    def test_a_syncthing_that_does_not_answer_ends_the_watcher_with_the_status_that_asks_for_a_later_retry(self):
        with mock.patch("sys.stderr"):
            self.assertEqual(self.watch_ending_with(sync.Unreachable("no socket")), 75)
        self.assertEqual(self.reports, [])

    def test_a_configuration_that_cannot_work_is_reported_and_ends_the_watcher_with_the_status_that_asks_for_no_retry(self):
        self.assertEqual(self.watch_ending_with(sync.ConfigError("the GUI address is not a unix socket")), 78)
        self.assertEqual(self.reports, ["the GUI address is not a unix socket"])

    def test_another_failure_is_no_reason_to_stop_retrying(self):
        with self.assertRaises(sync.SyncError):
            with mock.patch.object(sync.Syncthing, "from_config", side_effect=sync.SyncError("HTTP 500")):
                sync.command_watch(None)

    def printed_by_nearby(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            sync.command_nearby(None)
        return out.getvalue().split()

    def test_the_nearby_command_prints_the_devices_of_the_list_that_answer_and_nothing_without_a_list(self):
        self.assertEqual(self.printed_by_nearby(), [])
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        there = f"tcp://127.0.0.1:{listener.getsockname()[1]}"
        gone = socket.socket()
        gone.bind(("127.0.0.1", 0))
        left = f"tcp://127.0.0.1:{gone.getsockname()[1]}"
        gone.close()
        store = sync.StateStore(self.reports.append)
        view = sync.assemble(snapshot(discovered={THIRD: {"addresses": [there]}, FOURTH: {"addresses": [left]}}))
        self.assertEqual([device["id"] for device in view["nearby"]], [THIRD, FOURTH])
        store.publish(view, [])
        self.assertEqual(self.printed_by_nearby(), [THIRD])

    def test_the_offline_command_writes_the_offline_view_and_keeps_the_arrivals(self):
        store = sync.StateStore(self.reports.append)
        store.publish(sync.assemble(snapshot()), [{"name": "a", "path": "/d/a", "from": "Pixel", "unseen": True}])
        sync.command_offline(None)
        state = store.read()
        self.assertEqual(state["state"], "offline")
        self.assertEqual([a["name"] for a in state["arrivals"]], ["a"])


class JoinAndSendTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = os.path.join(self.tmp.name, "home")
        os.makedirs(home)
        for name, value in (("HOME", home), ("XDG_DATA_HOME", os.path.join(self.tmp.name, "data"))):
            patcher = mock.patch.dict(os.environ, {name: value})
            patcher.start()
            self.addCleanup(patcher.stop)
        self.home = home

    def api(self, pending_folders=None, drop_devices=None):
        folders = [] if drop_devices is None else [folder(DROP, "vekrona drop", os.path.join(self.tmp.name, "drop"),
                                                          devices=drop_devices)]
        return FakeSyncthing({
            "/rest/system/status": {"myID": ME},
            "/rest/cluster/pending/folders": pending_folders or {},
            "/rest/config/folders": folders,
            "/rest/db/ignores": {"ignore": [], "expanded": [], "error": None},
            "/rest/config/devices": [{"deviceID": ME}, {"deviceID": PEER}],
            "/rest/config/defaults/folder": {"id": "", "devices": []}})

    def test_a_drop_cannot_be_joined_not_even_when_a_device_offers_it(self):
        for offered in (DROP, sync.drop_folder_id(ME, THIRD), "vekrona-drop-lizard"):
            with self.subTest(offered=offered):
                api = self.api(pending_folders={offered: {"offeredBy": {THIRD: {"label": "x"}}}})
                with self.assertRaisesRegex(sync.SyncError, "is a drop"):
                    sync.join(api, offered, None)
                self.assertEqual(api.writes, [])

    def test_a_folder_is_joined_into_a_directory_named_after_its_label(self):
        api = self.api(pending_folders={"p1": {"offeredBy": {PEER: {"label": "Photos"}}}})
        sync.join(api, "p1", None)
        self.assertTrue(os.path.isdir(os.path.join(self.home, "Sync", "Photos")))
        self.assertEqual(api.writes[0][1], "/rest/config/folders")

    def api_with_folder(self, devices, offered_by=None, path="/home/u/Sync/Photos"):
        api = self.api(pending_folders={} if offered_by is None else {"p1": {"offeredBy": {d: {"label": "Photos"} for d in offered_by}}})
        api.answers["/rest/config/folders"] = [folder("p1", "Photos", path, devices=devices)]
        return api

    def test_a_folder_that_is_here_gets_shared_with_the_device_that_offers_it_and_is_not_joined_again(self):
        api = self.api_with_folder(devices=(ME,), offered_by=(PEER, THIRD))
        sync.join(api, "p1", None)
        self.assertEqual([(w[0], w[1]) for w in api.writes], [("PATCH", "/rest/config/folders/p1")])
        self.assertEqual([d["deviceID"] for d in api.writes[0][2]["devices"]], [ME, PEER, THIRD])
        self.assertFalse(os.path.exists(os.path.join(self.home, "Sync")))

    def test_a_folder_that_is_here_and_shared_with_the_offering_device_needs_nothing(self):
        for offered_by in ((PEER,), ()):
            with self.subTest(offered_by=offered_by):
                api = self.api_with_folder(devices=(ME, PEER), offered_by=offered_by or None)
                sync.join(api, "p1", None)
                self.assertEqual(api.writes, [])

    def test_a_folder_that_is_here_is_not_moved_to_another_path(self):
        api = self.api_with_folder(devices=(ME,), offered_by=(PEER,))
        with self.assertRaisesRegex(sync.SyncError, "is here already, at /home/u/Sync/Photos"):
            sync.join(api, "p1", "/elsewhere")
        sync.join(api, "p1", "/home/u/Sync/Photos/")
        self.assertEqual(len(api.writes), 1)

    def test_a_link_where_the_folder_would_go_is_refused_whatever_it_points_at(self):
        os.makedirs(os.path.join(self.home, "Sync"))
        elsewhere = os.path.join(self.tmp.name, "elsewhere")
        os.mkdir(elsewhere)
        os.symlink(elsewhere, os.path.join(self.home, "Sync", "Photos"))
        api = self.api(pending_folders={"p1": {"offeredBy": {PEER: {"label": "Photos"}}}})
        with self.assertRaisesRegex(sync.SyncError, "not an empty directory"):
            sync.join(api, "p1", None)
        self.assertEqual(api.writes, [])

    def test_a_directory_that_cannot_be_reached_is_a_sync_error_not_a_traceback(self):
        blocker = os.path.join(self.home, "Sync")
        with open(blocker, "w") as f:
            f.write("a file where the directory should be")
        api = self.api(pending_folders={"p1": {"offeredBy": {PEER: {"label": "Photos"}}}})
        with self.assertRaisesRegex(sync.SyncError, "cannot look at"):
            sync.join(api, "p1", None)
        self.assertEqual(api.writes, [])

    @unittest.skipIf(os.geteuid() == 0, "root creates directories anywhere")
    def test_a_directory_that_cannot_be_created_is_a_sync_error_not_a_traceback(self):
        os.makedirs(os.path.join(self.home, "Sync"), mode=0o500)
        api = self.api(pending_folders={"p1": {"offeredBy": {PEER: {"label": "Photos"}}}})
        with self.assertRaisesRegex(sync.SyncError, "cannot create"):
            sync.join(api, "p1", None)
        self.assertEqual(api.writes, [])

    def test_sending_through_a_drop_that_a_third_device_shares_is_refused_and_sends_nothing(self):
        file = os.path.join(self.tmp.name, "a.txt")
        with open(file, "w") as f:
            f.write("a")
        api = self.api(drop_devices=(ME, PEER, THIRD))
        with self.assertRaisesRegex(sync.SyncError, "no party to it"):
            sync.send(api, PEER, [file])
        self.assertEqual(api.writes, [])
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "drop", "to")))

    def test_sending_puts_the_file_in_the_inbox_of_the_other_device(self):
        file = os.path.join(self.tmp.name, "a.txt")
        with open(file, "w") as f:
            f.write("a")
        api = self.api(drop_devices=(ME,))
        sync.send(api, PEER, [file])
        self.assertEqual(os.listdir(os.path.join(self.tmp.name, "drop", "to", PEER)), ["a.txt"])
        self.assertEqual(api.writes[0][0], "PATCH")


class FolderIdTest(unittest.TestCase):
    FALLBACK = re.compile(r"[0-9a-f]{5}-[0-9a-f]{5}")

    def test_a_name_becomes_lowercase_words_with_dashes(self):
        for name, expected in (("My Notes", "my-notes"), ("notes", "notes"), ("UPPER Case", "upper-case"), ("a_b.c d", "a-b-c-d"),
                               ("Café Menü", "cafe-menu"), ("  spaced   out  ", "spaced-out"), ("-x-", "x"), ("a--b", "a-b"),
                               ("Notes 📒 2024", "notes-2024"), ("2024", "2024")):
            with self.subTest(name=name):
                self.assertEqual(sync.suggest_folder_id(f"/home/u/{name}", set()), expected)

    def test_a_name_that_makes_no_id_gets_a_random_one_of_the_old_shape(self):
        for name in ("", "  ", ".", "..", "  ..  ", "___", "📒", "Фото 2024", "日本", "Notes Фото", "vekrona drop 1", "vekrona-drop"):
            with self.subTest(name=name):
                self.assertRegex(sync.suggest_folder_id(f"/home/u/{name}", set()), self.FALLBACK)
        self.assertRegex(sync.suggest_folder_id("/", set()), self.FALLBACK)

    def test_a_long_name_is_cut_at_the_limit_without_a_dangling_dash(self):
        suggestion = sync.suggest_folder_id("/home/u/" + "word " * 30, set())
        self.assertEqual(suggestion, ("word-" * 13)[:64].rstrip("-"))
        self.assertLessEqual(len(suggestion), 64)
        self.assertFalse(suggestion.endswith("-"))

    def test_a_name_that_a_folder_here_has_is_numbered_within_the_limit(self):
        self.assertEqual(sync.suggest_folder_id("/home/u/My Notes", {"my-notes"}), "my-notes-2")
        self.assertEqual(sync.suggest_folder_id("/home/u/My Notes", {"my-notes", "my-notes-2"}), "my-notes-3")
        long_name = "x" * 64
        numbered = sync.suggest_folder_id("/home/u/" + long_name, {long_name})
        self.assertEqual((len(numbered), numbered.endswith("-2")), (64, True))

    def test_these_ids_are_fine(self):
        for folder_id in ("my-notes", "lizard", "a", "0", "2024", "a-1-b", "x" * 64, "vekrona-drop", "vekrona"):
            with self.subTest(folder_id=folder_id):
                sync.check_folder_id(folder_id, {"other"})

    def test_these_ids_are_refused_with_a_reason_in_plain_words(self):
        for folder_id, reason in (("", "is empty"), (" ", "may have only"), ("..", "may have only"), (".", "may have only"),
                                  ("My-Notes", "may have only"), ("my_notes", "may have only"), ("my notes", "may have only"),
                                  ("über", "may have only"), ("фото", "may have only"), ("📒", "may have only"),
                                  ("-a", "may have only"), ("a-", "may have only"), ("a--b", "may have only"),
                                  ("-", "may have only"), ("a\n", "may have only"), ("x" * 65, "has 65 characters, at most 64"),
                                  ("vekrona-drop-x", "must not start with vekrona-drop-"),
                                  (sync.drop_folder_id(ME, PEER), "must not start with vekrona-drop-"),
                                  ("my-notes", "already has a folder with ID my-notes")):
            with self.subTest(folder_id=folder_id):
                with self.assertRaisesRegex(sync.SyncError, reason):
                    sync.check_folder_id(folder_id, {"my-notes"})


class ShareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.notes = os.path.join(self.tmp.name, "My Notes")
        os.mkdir(self.notes)

    def api(self, folders=()):
        return FakeSyncthing({
            "/rest/system/status": {"myID": ME},
            "/rest/config/folders": list(folders),
            "/rest/config/devices": [{"deviceID": ME}, {"deviceID": PEER}, {"deviceID": THIRD}],
            "/rest/config/defaults/folder": {"id": "", "devices": []}})

    def test_a_folder_is_shared_under_the_given_id_with_every_device_and_labelled_with_its_name(self):
        api = self.api()
        self.assertEqual(sync.share(api, self.notes, "notes-of-mine"), "notes-of-mine")
        body = api.writes[0][2]
        self.assertEqual((api.writes[0][:2], body["id"], body["label"], body["path"]),
                         (("POST", "/rest/config/folders"), "notes-of-mine", "My Notes", self.notes))
        self.assertEqual([d["deviceID"] for d in body["devices"]], [ME, PEER, THIRD])

    def test_without_an_id_the_suggestion_is_used(self):
        api = self.api(folders=[folder("elsewhere", path="/home/u/else")])
        self.assertEqual(sync.share(api, self.notes), "my-notes")
        self.assertEqual(api.writes[0][2]["id"], "my-notes")

    def test_an_id_that_is_taken_shares_nothing_and_says_so(self):
        api = self.api(folders=[folder("my-notes", path="/home/u/else")])
        with self.assertRaisesRegex(sync.SyncError, "This computer already has a folder with ID my-notes"):
            sync.share(api, self.notes, "my-notes")
        self.assertEqual(api.writes, [])

    def test_a_bad_id_shares_nothing(self):
        for folder_id in ("", "..", "My Notes", "x" * 65, "vekrona-drop-x", "-a", "a--b"):
            with self.subTest(folder_id=folder_id):
                api = self.api()
                with self.assertRaises(sync.SyncError):
                    sync.share(api, self.notes, folder_id)
                self.assertEqual(api.writes, [])

    def test_a_path_that_is_no_directory_or_is_shared_already_shares_nothing(self):
        api = self.api(folders=[folder("n", path=self.notes + "/")])
        with self.assertRaisesRegex(sync.SyncError, "is shared already"):
            sync.share(api, self.notes, "other-id")
        with self.assertRaisesRegex(sync.SyncError, "is not a directory"):
            sync.share(api, os.path.join(self.tmp.name, "missing"), "other-id")
        self.assertEqual(api.writes, [])

    def run_cli(self, *argv, folders=()):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["vekrona-sync", *argv]), \
                mock.patch.object(sync.Syncthing, "from_config", return_value=self.api(folders)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                sync.main()
                code = 0
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue(), err.getvalue()

    def test_the_commands_print_the_id_and_a_bad_one_is_a_nonzero_exit_with_the_reason_on_stderr(self):
        self.assertEqual(self.run_cli("suggest-id", self.notes), (0, "my-notes\n", ""))
        self.assertEqual(self.run_cli("share", self.notes, "--id=mine"), (0, "mine\n", ""))
        code, out, err = self.run_cli("share", self.notes, "--id=Not Good")
        self.assertEqual((code != 0, out), (True, ""))
        self.assertIn("may have only lowercase letters", err)
        code, out, err = self.run_cli("share", self.notes, "--id=-x")
        self.assertEqual((code != 0, out), (True, ""))
        self.assertIn("may have only lowercase letters", err)


def syncthing_judging_ids(query):
    """What Syncthing's /rest/svc/deviceid answers: the ID in its own spelling, or the reason it is no ID."""
    spelled = query["id"].upper().replace("-", "")
    if len(spelled) != 56:
        return {"error": f'"{query["id"]}": device ID invalid: incorrect length'} if spelled else {"id": ""}
    return {"id": "-".join(spelled[i:i + 7] for i in range(0, 56, 7))}


class PairingTest(unittest.TestCase):
    def api(self, devices=(ME,), folders=None, pending_devices=None, ignored=()):
        self.folders = [folder("f1"), folder(DROP, "vekrona drop", "/d", devices=(ME, THIRD)), folder("f2", devices=(ME, PEER))] \
            if folders is None else folders
        return FakeSyncthing({
            "/rest/system/status": {"myID": ME},
            "/rest/svc/deviceid": syncthing_judging_ids,
            "/rest/config": {"folders": self.folders, "remoteIgnoredDevices": [{"deviceID": d} for d in ignored]},
            "/rest/config/devices": [{"deviceID": d} for d in devices],
            "/rest/config/defaults/device": {"addresses": ["dynamic"], "name": ""},
            "/rest/cluster/pending/devices": pending_devices or {}})

    def posted_device(self, api):
        return next(body for method, path, body in api.writes if (method, path) == ("POST", "/rest/config/devices"))

    def test_a_device_is_paired_by_its_id_in_any_spelling_and_gets_every_folder_but_the_drops(self):
        for typed in (THIRD, THIRD.lower(), THIRD.replace("-", ""), f"  {THIRD}\n"):
            with self.subTest(typed=typed):
                api = self.api()
                sync.pair_device(api, typed, None)
                self.assertEqual(self.posted_device(api), {"addresses": ["dynamic"], "name": "", "deviceID": THIRD})
                shared = [(path, body["devices"][-1]["deviceID"]) for method, path, body in api.writes if method == "PATCH"]
                self.assertEqual(shared, [("/rest/config/folders/f1", THIRD), ("/rest/config/folders/f2", THIRD)])

    def test_a_name_given_is_the_name_of_the_device(self):
        api = self.api()
        sync.pair_device(api, THIRD, "Pixel")
        self.assertEqual(self.posted_device(api)["name"], "Pixel")

    def test_what_is_no_device_id_is_refused_with_syncthings_reason_and_nothing_is_written(self):
        for typed, reason in (("lizard", "incorrect length"), ("", "no device ID"), ("  \n", "no device ID"),
                              (ME[:-1], "incorrect length")):
            with self.subTest(typed=typed):
                api = self.api()
                with self.assertRaisesRegex(sync.SyncError, reason):
                    sync.pair_device(api, typed, None)
                self.assertEqual(api.writes, [])

    def test_this_computer_and_a_device_of_it_are_not_paired_again(self):
        for typed, reason in ((ME, "own device ID"), (PEER, "one of this computer's devices already")):
            with self.subTest(typed=typed):
                api = self.api(devices=(ME, PEER))
                with self.assertRaisesRegex(sync.SyncError, reason):
                    sync.pair_device(api, typed, None)
                self.assertEqual(api.writes, [])

    def test_accepting_a_pending_device_adds_it_the_same_way(self):
        api = self.api(pending_devices={THIRD: {"name": "Pixel"}})
        sync.accept_device(api, THIRD)
        self.assertEqual(self.posted_device(api), {"addresses": ["dynamic"], "name": "Pixel", "deviceID": THIRD})
        self.assertEqual(len([w for w in api.writes if w[0] == "PATCH"]), 2)

    def test_accepting_a_device_that_did_not_ask_is_an_error(self):
        api = self.api()
        with self.assertRaisesRegex(sync.SyncError, "has not asked"):
            sync.accept_device(api, THIRD)
        self.assertEqual(api.writes, [])

    def test_rejecting_a_pending_device_ignores_it_for_good_and_clears_its_request(self):
        api = self.api(pending_devices={THIRD: {"name": "Pixel", "address": "10.0.0.2:22000"}})
        sync.reject_device(api, THIRD)
        (put,) = [w for w in api.writes if w[0] == "PUT"]
        self.assertEqual(put[1], "/rest/config")
        (ignored,) = put[2]["remoteIgnoredDevices"]
        self.assertEqual((ignored["deviceID"], ignored["name"], ignored["address"]), (THIRD, "Pixel", "10.0.0.2:22000"))
        self.assertRegex(ignored["time"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertIn(("DELETE", "/rest/cluster/pending/devices", None), api.writes)

    def test_rejecting_a_device_that_is_ignored_already_keeps_the_list_and_still_clears_the_request(self):
        api = self.api(pending_devices={THIRD: {"name": "Pixel"}}, ignored=(THIRD,))
        sync.reject_device(api, THIRD)
        self.assertEqual([w[0] for w in api.writes], ["DELETE"])

    def test_rejecting_a_device_that_did_not_ask_is_an_error(self):
        api = self.api()
        with self.assertRaisesRegex(sync.SyncError, "has not asked"):
            sync.reject_device(api, THIRD)
        self.assertEqual(api.writes, [])


class QrTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": os.path.join(self.tmp.name, "state")})
        patcher.start()
        self.addCleanup(patcher.stop)

    def state_files(self):
        return os.listdir(os.path.join(self.tmp.name, "state", "vekrona"))

    def test_the_code_is_written_where_the_path_says_and_replaces_an_older_one(self):
        def qrencode(argv, **kwargs):
            self.assertEqual(argv[-1], ME)
            with open(argv[argv.index("-o") + 1], "w") as f:
                f.write("png of " + ME)
            return mock.Mock(returncode=0, stderr="")
        with mock.patch.object(sync.subprocess, "run", side_effect=qrencode):
            sync.write_qr(ME)
            path = sync.write_qr(ME)
        with open(path) as f:
            self.assertEqual(f.read(), "png of " + ME)
        self.assertEqual(self.state_files(), ["device-id.png"])

    def test_a_qrencode_that_fails_is_an_error_that_leaves_no_half_written_file(self):
        def qrencode(argv, **kwargs):
            with open(argv[argv.index("-o") + 1], "w") as f:
                f.write("half")
            return mock.Mock(returncode=1, stderr="Failed to encode")
        with mock.patch.object(sync.subprocess, "run", side_effect=qrencode):
            with self.assertRaisesRegex(sync.SyncError, "Failed to encode"):
                sync.write_qr(ME)
        self.assertEqual(self.state_files(), [])

    def test_a_missing_qrencode_says_what_to_install_and_leaves_no_file(self):
        with mock.patch.dict(os.environ, {"PATH": self.tmp.name}):
            with self.assertRaisesRegex(sync.MissingTool, r"the QR code needs qrencode, which is not installed.*install\.sh 30"):
                sync.write_qr(ME)
        self.assertEqual(self.state_files(), [])


class ToolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"PATH": self.tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_every_tool_that_is_not_installed_is_named_with_what_it_was_for_and_the_stage_that_installs_it(self):
        for tool, purpose in (("qrencode", "the QR code"), ("syncthing", "finding Syncthing's configuration"),
                              ("notify-send", "telling that a file arrived")):
            with self.subTest(tool=tool):
                with self.assertRaisesRegex(sync.MissingTool, f"{purpose} needs {tool}, which is not installed.*install.sh 30"):
                    sync.run_tool(purpose, [tool])

    def test_syncthings_config_file_of_a_machine_without_syncthing_is_not_a_traceback(self):
        sync.syncthing_config_file.cache_clear()
        with self.assertRaisesRegex(sync.MissingTool, "syncthing, which is not installed"):
            sync.syncthing_config_file()

    def test_downloads_falls_back_to_the_home_directory_without_xdg_user_dir(self):
        self.assertEqual(sync.downloads_dir(), os.path.join(os.path.expanduser("~"), "Downloads"))

    def test_downloads_does_not_hide_an_xdg_user_dir_that_hangs(self):
        with mock.patch.object(sync.subprocess, "run", side_effect=sync.subprocess.TimeoutExpired("xdg-user-dir", 10)):
            with self.assertRaisesRegex(sync.SyncError, "cannot run xdg-user-dir for finding Downloads"):
                sync.downloads_dir()

    def test_a_tool_that_cannot_be_started_is_a_sync_error(self):
        not_executable = os.path.join(self.tmp.name, "broken")
        with open(not_executable, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(not_executable, 0o644)
        with self.assertRaisesRegex(sync.SyncError, "cannot run broken for testing"):
            sync.run_tool("testing", [not_executable.replace(self.tmp.name + "/", "")])

    def test_a_missing_notify_send_is_reported_not_raised_when_a_file_arrives(self):
        reports = []
        sync.DesktopNotifier(reports.append).arrival({"name": "a.txt", "from": "Pixel", "path": "/home/u/Downloads/a.txt"})
        self.assertEqual(len(reports), 1)
        self.assertIn("notify-send, which is not installed", reports[0])


class NearbyTest(unittest.TestCase):
    """Devices are on 127.0.0.1: a listener that accepts is a device that is there, a port nobody listens on is one that left."""

    def setUp(self):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.addCleanup(self.listener.close)
        self.there = self.listener.getsockname()[1]
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        self.gone = closed.getsockname()[1]
        closed.close()

    def device(self, device_id, *addresses):
        return {"id": device_id, "code": sync.short_code(device_id), "addresses": list(addresses)}

    def test_a_device_that_accepts_a_connection_is_there_and_one_that_refuses_has_left(self):
        nearby = [self.device(PEER, f"tcp://127.0.0.1:{self.there}"), self.device(THIRD, f"tcp://127.0.0.1:{self.gone}")]
        self.assertEqual(sync.answering_nearby(nearby), [PEER])

    def test_one_address_that_answers_is_enough(self):
        nearby = [self.device(PEER, f"tcp://127.0.0.1:{self.gone}", f"quic://127.0.0.1:{self.there}",
                              f"tcp://127.0.0.1:{self.there}")]
        self.assertEqual(sync.answering_nearby(nearby), [PEER])

    def test_a_connect_that_times_out_counts_as_gone(self):
        nearby = [self.device(PEER, "tcp://127.0.0.1:22000")]
        with mock.patch.object(sync.socket, "create_connection", side_effect=TimeoutError("timed out")):
            self.assertEqual(sync.answering_nearby(nearby), [])

    def test_the_list_keeps_its_order_and_an_empty_one_is_empty(self):
        nearby = [self.device(THIRD, f"tcp://127.0.0.1:{self.there}"), self.device(PEER, f"tcp://127.0.0.1:{self.there}")]
        self.assertEqual(sync.answering_nearby(nearby), [THIRD, PEER])
        self.assertEqual(sync.answering_nearby([]), [])

    def test_a_device_with_no_address_to_try_stays_listed(self):
        for addresses in ([], [f"quic://127.0.0.1:{self.there}"], ["tcp://example.invalid:22000"], ["tcp://127.0.0.1:0"],
                          ["tcp://127.0.0.1:99999"], ["tcp://127.0.0.1"], ["lizard"], [""]):
            with self.subTest(addresses=addresses):
                self.assertEqual(sync.answering_nearby([self.device(PEER, *addresses)]), [PEER])

    def test_a_device_with_no_address_to_try_stays_listed_next_to_devices_that_are_tried(self):
        nearby = [self.device(PEER, f"tcp://127.0.0.1:{self.there}"), self.device(THIRD, f"quic://127.0.0.1:{self.there}"),
                  self.device(FOURTH, f"tcp://127.0.0.1:{self.gone}")]
        self.assertEqual(sync.answering_nearby(nearby), [PEER, THIRD])

    def test_ipv6_and_the_tcp4_and_tcp6_schemes_are_tried(self):
        self.assertEqual(sync.tcp_endpoints(["tcp4://10.0.0.5:22000", "tcp6://[fe80::1%eth0]:22001", "tcp://[::1]:22002"]),
                         [("10.0.0.5", 22000), ("fe80::1%eth0", 22001), ("::1", 22002)])


class UnixHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/rest/ok":
            body = json.dumps({"key": self.headers["X-API-Key"], "path": self.path}).encode()
            status = 200
        elif self.path == "/rest/empty":
            body, status = b"", 200
        elif self.path.startswith("/rest/db/file?") and "file=known" not in self.path:
            body, status = b"No such object in the index\n" if "folder=drop" in self.path else b"folder missing\n", 404
        else:
            body, status = b"folder is paused\n", 500
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.socket_path = os.path.join(self.tmp.name, "gui.sock")
        self.server = socketserver.UnixStreamServer(self.socket_path, UnixHandler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.api = sync.Syncthing(self.socket_path, "secret")

    def test_a_request_goes_over_the_socket_with_the_api_key(self):
        self.assertEqual(self.api.request("GET", "/rest/ok"), {"key": "secret", "path": "/rest/ok"})

    def test_an_empty_answer_is_none(self):
        self.assertIsNone(self.api.request("GET", "/rest/empty"))

    def test_a_refusal_carries_syncthings_message(self):
        with self.assertRaisesRegex(sync.SyncError, "HTTP 500: folder is paused"):
            self.api.request("GET", "/rest/other")

    def test_a_file_the_index_does_not_have_is_none_and_any_other_refusal_is_an_error(self):
        self.assertIsNone(self.api.file_entry("drop", "to/x/gone.txt"))
        with self.assertRaises(sync.NotFound):
            self.api.file_entry("nonexistent-folder", "to/x/gone.txt")

    def test_a_missing_socket_is_unreachable_not_a_plain_error(self):
        with self.assertRaises(sync.Unreachable):
            sync.Syncthing(os.path.join(self.tmp.name, "none.sock"), "k").request("GET", "/rest/ok")


class GuiEndpointTest(unittest.TestCase):
    def endpoint(self, address):
        with tempfile.TemporaryDirectory() as tmp:
            config = os.path.join(tmp, "config.xml")
            with open(config, "w") as f:
                f.write(f"<configuration><gui><address>{address}</address><apikey>k</apikey></gui></configuration>")
            return sync.gui_endpoint(config)

    def test_a_bare_path_and_a_unix_url_name_the_same_socket(self):
        self.assertEqual(self.endpoint("/run/user/1000/syncthing/gui.sock"), ("/run/user/1000/syncthing/gui.sock", "k"))
        self.assertEqual(self.endpoint("unix:///run/user/1000/syncthing/gui.sock?mode=0600"),
                         ("/run/user/1000/syncthing/gui.sock", "k"))

    def test_a_tcp_address_is_refused(self):
        with self.assertRaisesRegex(sync.SyncError, "not a unix socket"):
            self.endpoint("127.0.0.1:8384")

    def test_a_config_that_does_not_exist_yet_is_unreachable(self):
        with self.assertRaises(sync.Unreachable):
            sync.gui_endpoint("/nonexistent/config.xml")


if __name__ == "__main__":
    unittest.main()
