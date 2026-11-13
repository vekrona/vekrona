#!/usr/bin/env python3
"""A stand-in for `vekrona-vpn` that the VPN scenarios put in the guest's ~/.local/bin (tests/e2e/lib/vpn-popout.sh), so that the bar's
pill and popout meet an answer the scenario chose instead of a tunnel and a provider. It follows the CLI contract of the real tool and
keeps its state in STUB_DIR, which the scenario writes and reads:

  status.json   what `status` prints; a missing file makes `status` fail, the way a broken tool does. A scenario may write a tunnel
                that is up with "armed":false: one brought up outside vekrona-vpn
  list.json     what `list` prints; `forget` removes a configuration from it
  calls.log     one line per call, the arguments only (the account number of `mullvad login` is never in them)
  login.stdin   what `mullvad login` read on its stdin
  status.gate   a fifo: while it exists, `status` waits until somebody opens it for writing, so a scenario holds the first answer back
  import-fails  while this file exists, `import` fails with the text in it
  connect-fails while this file exists, `connect` fails with the text in it (and changes nothing)

`connect` and `off` change status.json as the real tool changes the state; `mullvad login` accepts ACCOUNT only."""
import json
import os
import sys

STUB_DIR = os.path.join(os.path.expanduser("~"), ".cache", "vekrona-vpn-stub")
ACCOUNT = "1111222233334444"


def path(name):
    return os.path.join(STUB_DIR, name)


def read_json(name):
    with open(path(name), encoding="utf-8") as handle:
        return json.load(handle)


def write_json(name, value):
    with open(path(name) + ".tmp", "w", encoding="utf-8") as handle:
        json.dump(value, handle)
    os.replace(path(name) + ".tmp", path(name))


def fail(reason):
    print(reason, file=sys.stderr)
    sys.exit(1)


def connection_of(vendor, country, config):
    return {"uuid": config["uuid"] if config else "", "vendor": vendor["id"], "country": country["code"],
            "ipv6": config["ipv6"] if config else country["ipv6"],
            "name": config["name"] if config else country["name"]}


def find(args):
    """The connection that `connect ARGS` names, or None."""
    for vendor in read_json("list.json")["vendors"]:
        for country in vendor["countries"]:
            if args[0] == "mullvad" and vendor["id"] == "mullvad" and country["code"] == args[1]:
                return connection_of(vendor, country, None)
            for config in country["configs"]:
                if config["uuid"] == args[0]:
                    return connection_of(vendor, country, config)
    return None


def connect(args):
    if os.path.exists(path("connect-fails")):
        with open(path("connect-fails"), encoding="utf-8") as handle:
            fail(handle.read().strip())
    connection = find(args)
    if connection is None:
        fail("no such configuration: " + " ".join(args))
    status = read_json("status.json")
    status.update(armed=True, tunnel="up", connection=connection)
    write_json("status.json", status)


def off():
    status = read_json("status.json")
    status.update(armed=False, tunnel="down", connection=None)
    write_json("status.json", status)


def forget(uuid):
    listing = read_json("list.json")
    for vendor in listing["vendors"]:
        for country in vendor["countries"]:
            country["configs"] = [config for config in country["configs"] if config["uuid"] != uuid]
        vendor["countries"] = [country for country in vendor["countries"] if country["configs"] or vendor["id"] == "mullvad"]
    write_json("list.json", listing)


def login():
    account = sys.stdin.read()
    with open(path("login.stdin"), "w", encoding="utf-8") as handle:
        handle.write(account)
    if account.strip() != ACCOUNT:
        fail("unknown account number")
    status = read_json("status.json")
    status["mullvad"]["logged_in"] = True
    write_json("status.json", status)


def main():
    command, *args = sys.argv[1:]
    with open(path("calls.log"), "a", encoding="utf-8") as log:
        log.write(" ".join([command, *args]) + "\n")
    if command in ("status", "list"):
        if command == "status" and os.path.exists(path("status.gate")):
            try:
                open(path("status.gate"), encoding="utf-8").close()
            except FileNotFoundError:
                pass  # released between the check and the open
        try:
            with open(path(command + ".json"), encoding="utf-8") as handle:
                sys.stdout.write(handle.read())
        except FileNotFoundError:
            fail(command + ": the stub has nothing to answer with")
    elif command == "connect":
        connect(args)
    elif command == "off":
        off()
    elif command == "forget":
        forget(args[0])
    elif command == "import":
        if os.path.exists(path("import-fails")):
            with open(path("import-fails"), encoding="utf-8") as handle:
                fail(handle.read().strip())
    elif command == "mullvad" and args == ["login"]:
        login()
    else:
        fail("the stub does not know " + " ".join([command, *args]))


main()
