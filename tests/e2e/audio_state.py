#!/usr/bin/env python3
"""Runs in the guest: checks the PipeWire graph against what a scenario expects.

Prints what differs and exits 1, or exits 0 when the default sink, the cards and the playing stream all match.
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys

# What a card left on "off" means is the watchdog's own definition, not a copy of it.
_loader = importlib.machinery.SourceFileLoader("vekrona_audio_watchdog", os.path.expanduser("~/.local/bin/vekrona-audio-watchdog"))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
watchdog = importlib.util.module_from_spec(_spec)
_loader.exec_module(watchdog)


def objects():
    return json.loads(subprocess.run(["pw-dump"], capture_output=True, text=True, check=True, timeout=20).stdout)


def default_sink(graph):
    for obj in graph:
        if obj["type"].endswith(":Metadata") and obj["props"].get("metadata.name") == "default":
            for entry in obj.get("metadata", []):
                if entry["key"] == "default.audio.sink":
                    return entry["value"]["name"]
    return None


def stream_sink_names(graph, stream_name):
    nodes = {o["id"]: (o.get("info") or {}) for o in graph if o["type"].endswith(":Node")}
    streams = [i for i, info in nodes.items() if info.get("props", {}).get("node.name") == stream_name]
    if not streams:
        return None
    running = [i for i in streams if nodes[i].get("state") == "running"]
    targets = {nodes[l["info"]["input-node-id"]]["props"]["node.name"] for l in graph
               if l["type"].endswith(":Link") and l.get("info") and l["info"]["output-node-id"] in running
               and l["info"]["input-node-id"] in nodes}
    return targets


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--default-sink", required=True, help="text the default sink's name must contain")
    parser.add_argument("--stream", required=True, help="node name of the playing stream")
    parser.add_argument("--cards-may-be-off", action="store_true", help="do not require cards to be on a profile")
    args = parser.parse_args()
    graph = objects()
    problems = []
    default = default_sink(graph)
    if default is None or args.default_sink not in default:
        problems.append(f"the default sink is {default!r}, not one containing {args.default_sink!r}")
    if (left_off := watchdog.cards_left_off(graph)) and not args.cards_may_be_off:
        problems.append("cards left on profile off: " + "; ".join(left_off))
    targets = stream_sink_names(graph, args.stream)
    if targets is None:
        problems.append(f"no stream named {args.stream!r}")
    elif not targets or any(args.default_sink not in t for t in targets):
        problems.append(f"stream {args.stream!r} plays on {sorted(targets) or 'nothing'}, not on a sink containing {args.default_sink!r}")
    for problem in problems:
        print(problem, file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
