pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Vekrona"

// What `vekrona-vpn` says, read once for every bar and for the launcher: the state (`status`), the connections (`list`), and the
// one way to run a command of the tool. The state follows /run/vekrona-vpn/state.json (the root helper writes it when the kill
// switch changes; absent while it was never armed) and `nmcli monitor` (NetworkManager's events). Nothing polls.
Singleton {
    id: root

    // The layout of `vekrona-vpn status` and `list` that this file reads. The backend keeps its own copy of the number (SCHEMA in
    // lib/vekrona_vpn.py): raise both together. The scenarios of tests/e2e read the backend's number for their stand-in's answers,
    // so one that finds the two apart fails.
    readonly property int schemaVersion: 1
    // The country code that the backend (bin/vekrona-vpn, `import`) gives a configuration whose country it could not tell.
    readonly property string unknownCountry: "??"
    // The vendor whose countries come from a relay list, need a login and have no configurations of their own.
    readonly property string mullvadId: "mullvad"
    readonly property var tunnels: ["down", "activating", "up"]
    // What each phase shows. off: no tunnel, no kill switch. activating: a tunnel coming up. on: the tunnel up and the kill switch
    // armed (filled icon). exposed: a tunnel up that the kill switch does not guard, one brought up outside `vekrona-vpn`, so
    // traffic can leave around it. blocked: the kill switch holds traffic back while there is no tunnel. unknown: the state
    // cannot be read, which must not show as "off".
    readonly property var phases: ({
            off: {
                icon: "vpn_key_off",
                text: "Off",
                detail: ""
            },
            activating: {
                icon: "pending",
                text: "Connecting",
                detail: ""
            },
            on: {
                icon: "vpn_lock",
                text: "Connected",
                detail: ""
            },
            exposed: {
                icon: "no_encryption",
                text: "Not protected",
                detail: "A tunnel is up, but the kill switch is off: traffic can leave around it. Connect from here to arm it."
            },
            blocked: {
                icon: "gpp_bad",
                text: "Blocked",
                detail: "The kill switch holds all traffic back while there is no tunnel."
            },
            unknown: {
                icon: "shield_question",
                text: "Status unknown",
                detail: ""
            }
        })
    // What the consumers read until the first `status` answered; the phase is "unknown" until then.
    readonly property var unsettled: ({
            schema: schemaVersion,
            armed: false,
            tunnel: "down",
            connection: null,
            mullvad: {
                logged_in: false
            }
        })
    // `vekrona-vpn status` rarely takes long; one that hangs must not stop every later refresh.
    readonly property int statusTimeoutMs: 15000
    // The wait before `nmcli monitor` is started again after it stopped: it doubles with every stop, up to the maximum, and starts
    // over at a stop of a monitor that had run longer than that wait. (A line of output proves nothing: a monitor that prints one
    // line and dies would be started again every second for ever.) The timer runs only while the monitor is dead.
    readonly property int retryFirstMs: 1000
    readonly property int retryMaxMs: 60000

    // What the last `vekrona-vpn status` said, and why the last one failed, "" while it did not.
    property var status: unsettled
    property string statusFailure: ""
    // Whether a `status` was read once: until then the state is not known, and the pill must not say "off".
    property bool statusSettled: false
    // Whether a `status` runs, and whether something changed since it started (the next one then starts when it ends).
    property bool statusRunning: false
    property bool statusStale: false
    // Whether `nmcli monitor` runs. While it does not, changes of the network go unseen, so the state may be stale.
    property bool monitorAlive: false
    // The wait before the next start of the monitor.
    property int retryMs: retryFirstMs
    // The wait the running monitor was started after (retryMs is already the next one by then), and when it started (Date.now());
    // both are read only while monitorAlive.
    property int monitorWaitedMs: retryFirstMs
    property double monitorStartedAt: 0
    // The vendors of the last `vekrona-vpn list`, and why the last one failed.
    property var catalog: []
    property string listFailure: ""
    property var listRun: null

    // Why the state cannot be trusted, "" while it can.
    readonly property string unknownReason: statusFailure !== "" ? statusFailure : monitorAlive ? "" : "nmcli monitor is not running: changes of the network go unseen"
    readonly property string phase: unknownReason !== "" || !statusSettled ? "unknown"
        : status.tunnel === "up" ? (status.armed ? "on" : "exposed")
        : status.tunnel === "activating" ? "activating"
        : status.armed ? "blocked" : "off"
    // The icon, text and detail of the phase.
    readonly property var look: phases[phase]
    readonly property bool mullvadLoggedIn: status.mullvad.logged_in
    // "Vendor, country, name" of the connection in use, "" without one.
    readonly property string connectionLabel: {
        const connection = status.connection;
        if (connection === null)
            return "";
        const vendorLabel = catalog.find(candidate => candidate.id === connection.vendor)?.label ?? connection.vendor;
        return [vendorLabel, connection.country === unknownCountry ? "" : connection.country, connection.name].filter(part => part !== "").join(", ");
    }

    // Turns the text of `vekrona-vpn status` into the status; throws on text that is not valid.
    function parseStatus(text: string): var {
        const next = JSON.parse(text);
        checkSchema(next);
        if (typeof next.armed !== "boolean" || !tunnels.includes(next.tunnel) || typeof next.mullvad?.logged_in !== "boolean")
            throw new Error("unexpected status " + text.trim());
        return next;
    }

    // Turns the text of `vekrona-vpn list` into the vendors; throws on text that is not valid.
    function parseList(text: string): var {
        const next = JSON.parse(text);
        checkSchema(next);
        for (const entry of next.vendors) {
            for (const place of entry.countries) {
                if (entry.id !== mullvadId && place.configs.length === 0)
                    throw new Error(entry.label + " lists " + place.name + " without a configuration");
            }
        }
        return next.vendors;
    }

    // Reads the output of `vekrona-vpn <command>` with `parse`: {value, failure}, where failure is "" when the output was valid, else why
    // not (logged, which records it).
    function readOutput(command: string, parse, text: string): var {
        try {
            return {
                value: parse(text),
                failure: ""
            };
        } catch (e) {
            console.error("vekrona-vpn " + command + ": " + e);
            return {
                value: null,
                failure: String(e.message ?? e)
            };
        }
    }

    function checkSchema(parsed: var): void {
        if (parsed.schema !== schemaVersion)
            throw new Error("vekrona-vpn speaks schema " + parsed.schema + " and this shell reads " + schemaVersion + ": update vekrona");
    }

    // Asks for the state again; a change that comes while the answer is awaited asks once more when it arrives, so a burst of
    // changes costs at most two runs.
    function refresh(): void {
        if (statusRunning) {
            statusStale = true;
            return;
        }
        statusRunning = true;
        statusStale = false;
        const argv = ["vekrona-vpn", "status"];
        Exec.runWithin(argv, statusTimeoutMs, (code, stdout, stderr) => {
            if (code !== 0) {
                statusFailure = Exec.failure(argv, code, stderr);
            } else {
                const read = readOutput("status", parseStatus, stdout);
                if (read.failure === "") {
                    status = read.value;
                    statusSettled = true;
                }
                statusFailure = read.failure;
            }
            statusRunning = false;
            if (statusStale)
                refresh();
        });
    }

    function loadList(): void {
        listRun?.kill();
        listRun = Exec.runOr(["vekrona-vpn", "list"], stdout => {
            const read = readOutput("list", parseList, stdout);
            if (read.failure === "")
                catalog = read.value;
            listFailure = read.failure;
        }, reason => listFailure = reason);
    }

    // Runs a vekrona-vpn command and calls onOk(stdout) or onFail(reason) when it ended. The state is asked for again then, since
    // a command that changed nothing (a refusal) sends no change signal.
    function command(args: list<string>, onOk, onFail): void {
        Exec.runOr(["vekrona-vpn"].concat(args), stdout => {
            onOk(stdout);
            refresh();
        }, reason => {
            onFail(reason);
            refresh();
        });
    }

    // Logs in to Mullvad and loads the countries it then offers; onFail(reason) when the tool refuses. The account number goes in
    // on stdin, which no process list shows.
    function logIn(account: string, onOk, onFail): void {
        const argv = ["vekrona-vpn", "mullvad", "login"];
        Exec.runWithInput(argv, account + "\n", (code, stdout, stderr) => {
            if (code !== 0) {
                onFail(Exec.failure(argv, code, stderr));
            } else {
                onOk();
                loadList();
            }
            refresh();
        });
    }

    // Whether the vendor lists nothing until the account is logged in.
    function needsLogin(vendorId: string): bool {
        return vendorId === mullvadId && !mullvadLoggedIn;
    }

    // The ways to connect to `country` of `vendor`, the one place that knows them: Mullvad connects by the country's code, one
    // choice; any other vendor has a configuration per choice. A choice is {key, name, detail (what a row of the country shows
    // when it is the only one), context (where a flat list places it), uuid (null for Mullvad: nothing to forget), args (the
    // arguments of the `vekrona-vpn` call that connects)}.
    function connectChoices(vendor: var, country: var): var {
        if (vendor.id === mullvadId) {
            return [
                {
                    key: country.code,
                    name: country.name,
                    detail: country.code,
                    context: vendor.label,
                    uuid: null,
                    args: ["connect", mullvadId, country.code]
                }
            ];
        }
        return country.configs.map(config => ({
                    key: config.uuid,
                    name: config.name,
                    detail: config.name,
                    context: vendor.label + ", " + country.name,
                    uuid: config.uuid,
                    args: ["connect", config.uuid]
                }));
    }

    // The monitor ended, or could not be started (which Quickshell reports by no other signal).
    function monitorStopped(): void {
        if (monitorAlive && Date.now() - monitorStartedAt > monitorWaitedMs)
            retryMs = retryFirstMs;
        monitorAlive = false;
        console.error("nmcli monitor stopped: the VPN state is unknown until it runs again; next try in " + retryMs / 1000 + " s");
        monitorWaitedMs = retryMs;
        retry.interval = retryMs;
        retry.start();
        retryMs = Math.min(retryMs * 2, retryMaxMs);
    }

    StateFile {
        path: "/run/vekrona-vpn/state.json"
        onRefreshed: root.refresh()
    }

    Process {
        id: monitor
        command: ["stdbuf", "-oL", "nmcli", "monitor"]
        running: true
        stdout: SplitParser {
            onRead: root.refresh()
        }
        // What happened while it was not running is unknown, so the state is read again.
        onStarted: {
            root.monitorStartedAt = Date.now();
            root.monitorAlive = true;
            root.refresh();
        }
        onRunningChanged: if (!running)
            root.monitorStopped()
    }

    Timer {
        id: retry
        onTriggered: monitor.running = true
    }
}
