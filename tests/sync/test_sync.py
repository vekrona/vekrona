import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import socket
import socketserver
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
        sync.deliver(original, inbox)
        with open(original, "w") as f:
            f.write("v2")
        sync.deliver(original, inbox)
        self.assertEqual(sorted(os.listdir(self.source_dir)), ["report (2).pdf", "report.pdf"])
        with open(os.path.join(self.source_dir, "report.pdf")) as f1, open(os.path.join(self.source_dir, "report (2).pdf")) as f2:
            self.assertEqual((f1.read(), f2.read()), ("v1", "v2"))

    def test_delivering_a_file_that_cannot_be_read_is_an_error_that_leaves_nothing_behind(self):
        inbox = open_dir(self.source_dir)
        self.addCleanup(os.close, inbox)
        with self.assertRaises(sync.SyncError):
            sync.deliver(os.path.join(self.tmp.name, "missing.txt"), inbox)
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
        self.assertEqual(view["devices"], [{"id": PEER, "name": "Pixel", "connected": True}])

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

    def pairing(self, device, accept, reject):
        self.calls.append(("pairing", device["id"]))

    def offer(self, offer, join):
        self.calls.append(("offer", offer["folder"]))

    def arrival(self, arrival):
        self.calls.append(("arrival", arrival["name"]))


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
            "/rest/config/folders": config_folders,
            "/rest/system/connections": {"connections": {PEER: {"connected": True}}},
            "/rest/cluster/pending/devices": pending_devices or {},
            "/rest/cluster/pending/folders": pending_folders or {},
            "/rest/config/defaults/folder": {"id": "", "devices": []}},
            statuses={"f1": notes_status} if notes_status is not None else {})

    def refresh(self, api, scan_all, finished=()):
        self.watcher.api = api
        self.watcher.snapshot = sync.read_snapshot(api, ME)
        self.watcher.refresh(scan_all=scan_all, finished=set(finished))

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
        self.assertEqual(self.store.read()["devices"], [{"id": PEER, "name": "Pixel", "connected": True}])
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
