#!/usr/bin/env python3
"""Runs in the vekrona-dev guest, fed to `python3 -` through `vekrona-dev run`, for the Sync scenarios.

  configure PEER_HOME LISTEN    edit the config.xml that `syncthing generate` wrote for HOME=PEER_HOME: the GUI on a unix
                                socket PEER_HOME/gui.sock, the sync port on LISTEN (host:port), and no discovery, relays or NAT
                                (the guest's own Syncthing keeps its defaults, so two daemons share one machine)
  rest METHOD PATH [JSON]       call the REST API of the Syncthing that HOME selects, through the installed vekrona-sync (the same
                                socket lookup as the tool under test), and print the answer as JSON"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import xml.etree.ElementTree as ET


def configure(peer_home, listen):
    path = os.path.join(peer_home, ".local", "state", "syncthing", "config.xml")
    tree = ET.parse(path)
    root = tree.getroot()
    root.find("gui/address").text = os.path.join(peer_home, "gui.sock")
    options = root.find("options")
    for stale in options.findall("listenAddress"):
        options.remove(stale)
    ET.SubElement(options, "listenAddress").text = f"tcp://{listen}"
    for name in ("globalAnnounceEnabled", "localAnnounceEnabled", "relaysEnabled", "natEnabled"):
        options.find(name).text = "false"
    tree.write(path)


def rest(method, path, body):
    loader = importlib.machinery.SourceFileLoader("vekrona_sync", os.path.realpath(shutil.which("vekrona-sync")))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("vekrona_sync", loader))
    loader.exec_module(module)
    print(json.dumps(module.Syncthing.from_config().request(method, path, body=body)))


def main():
    command, *args = sys.argv[1:]
    if command == "configure":
        configure(*args)
    elif command == "rest":
        method, path, *body = args
        rest(method, path, json.loads(body[0]) if body else None)
    else:
        sys.exit(f"unknown command {command}")


main()
