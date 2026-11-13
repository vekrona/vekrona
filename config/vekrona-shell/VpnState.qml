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

    // The layout of `vekrona-vpn status` and `list` that this file reads. The backend keeps its own copy of the number (OUTPUT_SCHEMA in
    // lib/vekrona_vpn.py): raise both together. The scenarios of tests/e2e read the backend's number for their stand-in's answers,
    // so one that finds the two apart fails.
    readonly property int schemaVersion: 2
    // The country code that the backend (bin/vekrona-vpn, `import`) gives a configuration whose country it could not tell.
    readonly property string unknownCountry: "??"
    // The country that the backend gives a connection to a Proton free server: the connection's name is then the server.
    readonly property string freeCountry: "FREE"
    // The vendors whose countries come from a catalog, need a login and have no configurations of their own.
    readonly property string mullvadId: "mullvad"
    readonly property string protonId: "proton"
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
            },
            proton: {
                logged_in: false,
                netshield: 0,
                error: ""
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
    // The shape of `status` and `list`, from vpn-output.json; null until it is loaded. Until then no command runs: the first read of each
    // comes on the load (or, for the list, when it is first asked for after the load), so no output is read twice.
    property var outputShape: null
    // Why the shape file cannot be loaded, "" while it can (or has not been tried yet); the state is unknown then.
    property string shapeFailure: ""
    // Whether the list was asked for before the shape loaded: it is read once the shape has loaded.
    property bool listWanted: false
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
    readonly property string unknownReason: shapeFailure !== "" ? shapeFailure : statusFailure !== "" ? statusFailure : monitorAlive ? "" : "nmcli monitor is not running: changes of the network go unseen"
    readonly property string phase: unknownReason !== "" || !statusSettled ? "unknown"
        : status.tunnel === "up" ? (status.armed ? "on" : "exposed")
        : status.tunnel === "activating" ? "activating"
        : status.armed ? "blocked" : "off"
    // The icon, text and detail of the phase.
    readonly property var look: phases[phase]
    readonly property bool mullvadLoggedIn: status.mullvad.logged_in
    readonly property bool protonLoggedIn: status.proton.logged_in
    // The NetShield level the next Proton connect uses: 0 off, 1 malware, 2 malware, ads and trackers.
    // Null when the NetShield setting cannot be read: then the level is not shown, and the error is (protonNetshieldError).
    readonly property var protonNetshield: status.proton.netshield
    readonly property string protonNetshieldError: status.proton.error
    // "Vendor, country, name, IPv4 only" of the connection in use, "" without one.
    readonly property string connectionLabel: {
        const connection = status.connection;
        if (connection === null)
            return "";
        const vendorLabel = catalog.find(candidate => candidate.id === connection.vendor)?.label ?? connection.vendor;
        return [vendorLabel, connection.country === unknownCountry || connection.country === freeCountry ? "" : connection.country, connection.name, ipv4Only(connection.ipv6)].filter(part => part !== "").join(", ");
    }
    // The label of a tunnel without IPv6 (IPv6 sites do not work through it). The one place the label is made: the popout, the bar and
    // the launcher show it through this function, and it is "" for a tunnel that has IPv6.
    readonly property string ipv4OnlyText: "IPv4 only"
    function ipv4Only(ipv6: bool): string {
        return ipv6 ? "" : ipv4OnlyText;
    }
    // The trailing text of a row: the label of a tunnel without IPv6 wins over the load of its server, which wins over `fallback`.
    function trailingOf(ipv6: bool, load, fallback: string): string {
        if (!ipv6)
            return ipv4OnlyText;
        return load !== null ? load + "%" : fallback;
    }

    // Turns the text of `vekrona-vpn status` into the status; throws on text that is not valid.
    function parseStatus(text: string): var {
        const next = JSON.parse(text);
        checkSchema(next);
        checkShape("status", next);
        return next;
    }

    // Turns the text of `vekrona-vpn list` into the vendors; throws on text that is not valid.
    function parseList(text: string): var {
        const next = JSON.parse(text);
        checkSchema(next);
        checkShape("list", next);
        for (const entry of next.vendors) {
            for (const place of entry.countries) {
                if (!isCatalogVendor(entry.id) && place.configs.length === 0)
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

    // Throws when the parsed output of `vekrona-vpn` (which is "status" or "list") does not have the shape that vpn-output.json describes.
    // The backend's tests check its real output against that same file.
    function checkShape(which: string, parsed: var): void {
        if (outputShape === null)
            throw new Error("the output shape is not loaded yet");
        const problem = shapeProblem(outputShape[which], parsed, "$");
        if (problem !== "")
            throw new Error("unexpected " + which + " output: " + problem);
    }

    // The first way `value` does not have `shape`, or "" when it has it. The shape language: a type name ("boolean", "string" or
    // "integer"), {"enum": [...]}, {"nullable": shape}, {"list": shape} and {"object": {key: shape}}, where an object has exactly those keys.
    function shapeProblem(shape: var, value: var, path: string): string {
        if (typeof shape === "string") {
            const ok = shape === "integer" ? Number.isInteger(value) : typeof value === shape;
            return ok ? "" : path + " is not a " + shape;
        }
        if (shape.enum !== undefined)
            return shape.enum.includes(value) ? "" : path + " is not one of " + JSON.stringify(shape.enum);
        if (shape.nullable !== undefined)
            return value === null ? "" : shapeProblem(shape.nullable, value, path);
        if (shape.list !== undefined) {
            if (!Array.isArray(value))
                return path + " is not a list";
            for (let index = 0; index < value.length; index++) {
                const problem = shapeProblem(shape.list, value[index], path + "[" + index + "]");
                if (problem !== "")
                    return problem;
            }
            return "";
        }
        if (value === null || typeof value !== "object" || Array.isArray(value))
            return path + " is not an object";
        const keys = Object.keys(shape.object).sort();
        const actual = Object.keys(value).sort();
        if (JSON.stringify(keys) !== JSON.stringify(actual))
            return path + " has the keys " + actual.join(", ") + ", not " + keys.join(", ");
        for (const key of keys) {
            const problem = shapeProblem(shape.object[key], value[key], path + "." + key);
            if (problem !== "")
                return problem;
        }
        return "";
    }

    // Asks for the state again; a change that comes while the answer is awaited asks once more when it arrives, so a burst of
    // changes costs at most two runs.
    function refresh(): void {
        if (outputShape === null)
            return;
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
        if (outputShape === null) {
            listWanted = true;
            return;
        }
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

    // Whether the vendor takes its countries from a catalog (and so has no configurations of its own).
    function isCatalogVendor(vendorId: string): bool {
        return vendorId === mullvadId || vendorId === protonId;
    }

    // Whether the vendor lists nothing until the account is logged in.
    function needsLogin(vendorId: string): bool {
        return vendorId === mullvadId ? !mullvadLoggedIn : vendorId === protonId && !protonLoggedIn;
    }

    // The ways to connect to `country` of `vendor`, the one place that knows them: Mullvad and Proton connect by the country's
    // code, one choice; any other vendor has a configuration per choice. A choice is {key, name, ipv6, detail (what a row of the country
    // shows when it is the only one), context (where a flat list places it), uuid (null for a catalog vendor: nothing to forget),
    // args (the arguments of the `vekrona-vpn` call that connects)}.
    function connectChoices(vendor: var, country: var): var {
        if (isCatalogVendor(vendor.id)) {
            return [
                {
                    key: country.code,
                    name: country.name,
                    ipv6: country.ipv6,
                    detail: trailingOf(country.ipv6, country.load, country.code),
                    context: vendor.label,
                    uuid: null,
                    args: ["connect", vendor.id, country.code]
                }
            ];
        }
        return country.configs.map(config => ({
                    key: config.uuid,
                    name: config.name,
                    ipv6: config.ipv6,
                    detail: trailingOf(config.ipv6, null, config.name),
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

    // The shape of the output (vpn-output.json, next to this file). Until it is loaded no command runs and the state is unknown; the
    // status is read once it is loaded, and the list when it was asked for.
    FileView {
        path: Qt.resolvedUrl("vpn-output.json")
        onLoaded: {
            root.outputShape = JSON.parse(text());
            root.refresh();
            if (root.listWanted) {
                root.listWanted = false;
                root.loadList();
            }
        }
        onLoadFailed: root.shapeFailure = "the output shape vpn-output.json next to VpnState.qml cannot be read"
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
