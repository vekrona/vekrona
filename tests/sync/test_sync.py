import importlib.machinery
import importlib.util
import json
import os
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


class PlacementTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source_dir = os.path.join(self.tmp.name, "inbox")
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

    def test_a_name_that_exists_gets_a_number_before_the_extension_and_the_old_file_is_untouched(self):
        self.write(self.target, "photo.jpg", "first")
        self.write(self.target, "photo (2).jpg", "second")
        source = self.write(self.source_dir, "photo.jpg", "third")
        placed = sync.place_without_overwriting(source, self.target, "photo.jpg")
        self.assertEqual(os.path.basename(placed), "photo (3).jpg")
        self.assertEqual((self.read("photo.jpg"), self.read("photo (2).jpg"), self.read("photo (3).jpg")),
                         ("first", "second", "third"))

    def test_a_name_without_an_extension_gets_the_number_at_the_end(self):
        self.write(self.target, "notes", "first")
        source = self.write(self.source_dir, "notes", "second")
        self.assertEqual(os.path.basename(sync.place_without_overwriting(source, self.target, "notes")), "notes (2)")

    def test_a_dangling_link_in_the_target_counts_as_a_taken_name(self):
        os.symlink("/nonexistent", os.path.join(self.target, "a.txt"))
        source = self.write(self.source_dir, "a.txt", "x")
        self.assertEqual(os.path.basename(sync.place_without_overwriting(source, self.target, "a.txt")), "a (2).txt")

    def test_receiving_moves_finished_files_only(self):
        self.write(self.source_dir, "done.txt", "whole")
        self.write(self.source_dir, "~syncthing~half.txt.tmp", "part")
        self.write(self.source_dir, ".syncthing.half.txt.tmp", "part")
        self.write(self.source_dir, "x.sync-conflict-20240101-000000-ABCDEFG.txt", "conflict")
        os.symlink("/etc/passwd", os.path.join(self.source_dir, "link"))
        os.mkdir(os.path.join(self.source_dir, "subdir"))
        with mock.patch.object(sync, "downloads_dir", return_value=self.target):
            arrivals, failures = sync.receive(self.source_dir, "Pixel")
        self.assertEqual(failures, [])
        self.assertEqual(sorted(a["name"] for a in arrivals),
                         ["done.txt", "x.sync-conflict-20240101-000000-ABCDEFG.txt"])
        self.assertTrue(all(a["from"] == "Pixel" and a["unseen"] for a in arrivals))
        self.assertEqual(sorted(os.listdir(self.source_dir)),
                         [".syncthing.half.txt.tmp", "link", "subdir", "~syncthing~half.txt.tmp"])

    def test_receiving_from_an_inbox_that_does_not_exist_yet_moves_nothing(self):
        with mock.patch.object(sync, "downloads_dir", side_effect=AssertionError("must not look for Downloads")):
            self.assertEqual(sync.receive(os.path.join(self.tmp.name, "missing"), "Pixel"), ([], []))

    def test_delivering_leaves_no_temp_file_and_never_overwrites(self):
        original = self.write(self.source_dir, "report.pdf", "v1")
        sync.deliver(original, self.target)
        with open(original, "w") as f:
            f.write("v2")
        sync.deliver(original, self.target)
        self.assertEqual(sorted(os.listdir(self.target)), ["report (2).pdf", "report.pdf"])
        self.assertEqual((self.read("report.pdf"), self.read("report (2).pdf")), ("v1", "v2"))


def folder(folder_id, label="Notes", path="/home/u/Sync/Notes", devices=(ME,), **extra):
    return {"id": folder_id, "label": label, "path": path, "devices": [{"deviceID": d} for d in devices], **extra}


def snapshot(**overrides):
    values = dict(
        my_id=ME,
        folders=[folder("f1"), folder(DROP, "vekrona drop", "/home/u/.local/share/vekrona-sync/drops/" + DROP)],
        devices=[{"deviceID": ME, "name": "this"}, {"deviceID": PEER, "name": "Pixel"}],
        connected={PEER}, pending_devices={}, pending_folders={},
        statuses={"f1": {"state": "idle", "globalBytes": 10, "needBytes": 0}})
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

    def test_offers_name_the_offering_device_and_leave_out_the_drop_that_is_taken_automatically(self):
        view = sync.assemble(snapshot(pending_folders={
            "p1": {"offeredBy": {PEER: {"label": "Photos"}}},
            "p2": {"offeredBy": {PEER: {"label": ""}}},
            DROP: {"offeredBy": {PEER: {"label": "vekrona drop"}}},
            sync.drop_folder_id(PEER, THIRD): {"offeredBy": {PEER: {"label": "vekrona drop"}}}}))
        self.assertEqual([(o["folder"], o["label"], o["device"], o["deviceName"]) for o in view["offers"]],
                         [("p1", "Photos", PEER, "Pixel"), ("p2", "p2", PEER, "Pixel"),
                          (sync.drop_folder_id(PEER, THIRD), "vekrona drop", PEER, "Pixel")])


class StateStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = sync.StateStore()

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

    def test_new_arrivals_come_first_and_only_the_last_twenty_stay(self):
        self.store.publish(sync.assemble(snapshot()), [self.arrival(f"old{i}") for i in range(15)])
        self.store.mark_seen()
        self.store.publish(sync.assemble(snapshot()), [self.arrival(f"new{i}") for i in range(10)])
        arrivals = self.store.read()["arrivals"]
        self.assertEqual(len(arrivals), 20)
        self.assertEqual(arrivals[0]["name"], "new0")
        self.assertEqual([a["unseen"] for a in arrivals], [True] * 10 + [False] * 10)

    def test_an_outage_is_written_as_offline_and_keeps_the_arrivals(self):
        self.store.publish(sync.assemble(snapshot()), [self.arrival("a")])
        sync.Outage(self.store).began(sync.Unreachable("no socket"))
        state = self.store.read()
        self.assertEqual((state["state"], state["problem"], state["folders"]), ("offline", "no socket", []))
        self.assertEqual([a["name"] for a in state["arrivals"]], ["a"])

    def test_a_state_file_that_is_not_json_is_an_error(self):
        os.makedirs(os.path.dirname(self.store.path))
        with open(self.store.path, "w") as f:
            f.write("not json")
        with self.assertRaises(sync.SyncError):
            self.store.mark_seen()


class FakeSyncthing(sync.Syncthing):
    def __init__(self, answers):
        super().__init__("/nonexistent", "key")
        self.answers = answers
        self.writes = []

    def request(self, method, path, query=None, body=None, timeout=None):
        if method != "GET":
            self.writes.append((method, path, body))
            return None
        return self.answers[path]


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
        self.store = sync.StateStore()
        self.watcher = sync.Watcher(self.store, self.notifier, self.reports.append)

    def api(self, pending_folders=None, pending_devices=None, drop_devices=(ME, PEER)):
        return FakeSyncthing({
            "/rest/system/status": {"myID": ME},
            "/rest/config": {"folders": [folder(DROP, "vekrona drop", self.drop_path, devices=drop_devices)],
                             "devices": [{"deviceID": ME, "name": "this"}, {"deviceID": PEER, "name": "Pixel"}]},
            "/rest/config/folders": [folder(DROP, "vekrona drop", self.drop_path, devices=drop_devices)],
            "/rest/system/connections": {"connections": {PEER: {"connected": True}}},
            "/rest/cluster/pending/devices": pending_devices or {},
            "/rest/cluster/pending/folders": pending_folders or {},
            "/rest/config/defaults/folder": {"id": "", "devices": []}})

    def refresh(self, api, scan_all, finished=()):
        self.watcher.api = api
        self.watcher.refresh(ME, scan_all=scan_all, finished=set(finished))

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

        def place(source, directory, name):
            if name == "a.txt":
                raise OSError("disk full")
            return real_place(source, directory, name)

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

    def test_each_pairing_request_and_offer_is_notified_once_until_it_is_gone(self):
        pending = {"pending_devices": {THIRD: {"name": "Laptop"}},
                   "pending_folders": {"p1": {"offeredBy": {PEER: {"label": "Photos"}}}}}
        self.refresh(self.api(**pending), scan_all=False)
        self.refresh(self.api(**pending), scan_all=False)
        self.assertEqual(sorted(self.notifier.calls), [("offer", "p1"), ("pairing", THIRD)])
        self.refresh(self.api(), scan_all=False)
        self.refresh(self.api(**pending), scan_all=False)
        self.assertEqual(len(self.notifier.calls), 4)

    def test_following_refreshes_at_start_and_then_only_for_events_that_matter(self):
        elsewhere = {"id": 1, "type": "ItemFinished", "data": {"folder": "f1", "error": None}}
        in_drop = {"id": 2, "type": "ItemFinished", "data": {"folder": DROP, "error": None}}
        dropped = {"id": 9, "type": "StateChanged", "data": {"folder": "f1"}}
        api = self.api()
        batches = [[elsewhere], [in_drop], [dropped]]
        polls = []

        def events(since, limit=None, timeout_sec=0):
            polls.append(since)
            if limit is not None:
                return []
            if not batches:
                raise sync.Unreachable("stopped")
            return batches.pop(0)

        api.events = events
        self.put("sent.txt")
        configs = []
        original = api.request

        def counting(method, path, query=None, body=None, timeout=None):
            if path == "/rest/config" and method == "GET":
                configs.append(1)
            return original(method, path, query, body, timeout)

        api.request = counting
        with self.assertRaises(sync.Unreachable):
            self.watcher.follow(api, lambda: None)
        self.assertEqual(polls, [0, 0, 1, 2, 9])
        # The start, the finished file in the drop, and the batch with the jump from 2 to 9.
        self.assertEqual(len(configs), 3)

    def test_events_that_cannot_change_the_view_are_skipped(self):
        finished_elsewhere = {"type": "ItemFinished", "data": {"folder": "f1", "error": None}}
        finished_in_drop = {"type": "ItemFinished", "data": {"folder": DROP, "error": None}}
        failed_in_drop = {"type": "ItemFinished", "data": {"folder": DROP, "error": "no space"}}
        self.assertFalse(sync.matters(finished_elsewhere))
        self.assertTrue(sync.matters(finished_in_drop))
        self.assertTrue(sync.matters({"type": "StateChanged", "data": {"folder": "f1"}}))
        self.assertEqual(sync.finished_drops([finished_elsewhere, finished_in_drop, failed_in_drop]), {DROP})


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
