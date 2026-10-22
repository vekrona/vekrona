import QtQuick
import ".."
import "../.." as Shell

LauncherModule {
    id: root

    readonly property var listLine: /^(\d{8}T\d{6}-[0-9a-f]{8})\s+(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(.*)$/
    // "" when none is set, or when reading it failed (toolFailed): those are different states.
    property string defaultTool: ""
    property bool toolFailed: false
    // The recorded errors, newest first: null until the first `vekrona-error list` answers or when it failed (errorsFailure).
    property var errors: null
    property string errorsFailure: ""
    property bool toolInFlight: false
    property bool errorsInFlight: false
    // Something changed the errors while `vekrona-error list` was running, so its answer may be out of date.
    property bool errorsStale: false
    property bool launcherOpen: false
    // The error list is on screen: the launcher is open in /agent. It keeps its mode while closed.
    readonly property bool listShown: launcherOpen && inMode

    function refreshTool(): void {
        if (toolInFlight)
            return;
        toolInFlight = true;
        const argv = ["vekrona-agent", "get"];
        Shell.Exec.run(argv, (code, stdout, stderr) => {
            toolInFlight = false;
            const unreadable = code !== 0;
            if (unreadable)
                Shell.Exec.failure(argv, code, stderr);
            const next = unreadable ? "" : stdout.trim();
            if (next === defaultTool && unreadable === toolFailed)
                return;
            defaultTool = next;
            toolFailed = unreadable;
            changed();
        });
    }

    // `vekrona-error list` prints "no errors recorded", or a header and one fixed-width line per error, newest first:
    //   ID  SOURCE  STATUS  COUNT  AGE  TITLE (STATUS is "new" until the error is seen)
    // Throws on output it does not recognise, so the failure is shown instead of a list with rows missing.
    function parseErrors(stdout: string): var {
        const lines = stdout.split("\n").filter(line => line.trim() !== "");
        if (lines.length === 0 || lines[0].trim() === "no errors recorded")
            return [];
        if (!lines[0].startsWith("ID "))
            throw new Error("unexpected vekrona-error list header: " + lines[0]);
        return lines.slice(1).map(line => {
            const match = listLine.exec(line);
            if (!match)
                throw new Error("unrecognised vekrona-error list line: " + line);
            return {
                id: match[1],
                source: match[2],
                status: match[3],
                count: parseInt(match[4], 10),
                age: match[5],
                title: match[6].trim()
            };
        });
    }

    // Runs `vekrona-error ARGS`. A failure is toasted as "Couldn’t <what>: <reason>", a success calls onSuccess.
    function runErrorTool(args: var, what: string, onSuccess: var): void {
        Shell.Exec.runOr(["vekrona-error"].concat(args), stdout => onSuccess(), reason => launcher.toast("Couldn’t " + what + ": " + reason));
    }

    // Showing the error list sees the errors it shows, as opening the notification centre sees every notification: the
    // robot's dot clears. Exactly those ids, so an error recorded after the list was read stays unread until it is shown.
    function markSeen(ids: var): void {
        runErrorTool(["ack"].concat(ids), "mark the errors as seen", () => {});
    }

    // Mutes the error, then lists again. Returns false: the launcher stays open on the shorter list.
    function muteError(id: string): bool {
        runErrorTool(["mute", id], "mute", refreshErrors);
        return false;
    }

    function refreshErrors(): void {
        if (errorsInFlight) {
            errorsStale = true;
            return;
        }
        errorsInFlight = true;
        const argv = ["vekrona-error", "list"];
        Shell.Exec.run(argv, (code, stdout, stderr) => {
            errorsInFlight = false;
            if (errorsStale) {
                errorsStale = false;
                refreshErrors();
                return;
            }
            let next = null;
            let failure = "";
            if (code !== 0) {
                failure = Shell.Exec.failure(argv, code, stderr);
            } else {
                try {
                    next = parseErrors(stdout);
                } catch (e) {
                    console.error("agent: " + e.message);
                    failure = e.message;
                }
            }
            if (listShown && next !== null) {
                const unseen = next.filter(record => record.status === "new").map(record => record.id);
                if (unseen.length > 0)
                    markSeen(unseen);
            }
            if (failure === errorsFailure && JSON.stringify(next) === JSON.stringify(errors))
                return;
            errors = next;
            errorsFailure = failure;
            changed();
        });
    }

    function askRow(text: string): var {
        return {
            id: "agent:ask",
            title: "Ask agent “" + text + "”",
            subtitle: toolFailed ? "Couldn’t read the default agent" : defaultTool !== "" ? defaultTool : "no default agent, you will choose one",
            glyph: "smart_toy",
            kind: "Command",
            score: 1,
            actions: [
                {
                    id: "ask",
                    label: "Ask",
                    exec: ["vekrona-agent", "--pick", "--prompt", text]
                },
                {
                    id: "ask-choose",
                    label: "Choose agent and ask",
                    exec: ["vekrona-agent", "--choose", "--prompt", text]
                }
            ]
        };
    }

    function recordRow(record: var): var {
        return {
            id: "agent:error:" + record.id,
            title: record.title,
            subtitle: record.source + (record.count > 1 ? " ×" + record.count : ""),
            glyph: "error",
            kind: record.age === "?" ? "" : record.age + " ago",
            actions: [
                {
                    id: "fix",
                    label: "Fix with agent",
                    key: "↵",
                    exec: ["vekrona-agent", "--pick", "--error", record.id]
                },
                {
                    id: "fix-choose",
                    label: "Choose agent and fix",
                    key: "Ctrl ↵",
                    exec: ["vekrona-agent", "--choose", "--error", record.id]
                },
                {
                    id: "mute",
                    label: "Mute",
                    run: () => root.muteError(record.id)
                }
            ]
        };
    }

    // One row per recorded error, or the one row that says why there are none to show.
    function errorRows(): var {
        if (errorsFailure !== "")
            return [errorRow("list the recorded errors", errorsFailure)];
        if (errors === null)
            return [];
        if (errors.length === 0) {
            return [
                {
                    id: "agent:no-errors",
                    title: "No recorded errors",
                    glyph: "check",
                    kind: "Errors"
                }
            ];
        }
        return errors.map(recordRow);
    }

    function launchRow(): var {
        return {
            id: "agent:launch",
            title: "Launch agent",
            glyph: "smart_toy",
            kind: "Command",
            keywords: ["agent", "ai", "coding", "claude"],
            actions: [
                {
                    id: "launch",
                    label: "Launch",
                    exec: ["vekrona-agent", "--pick"]
                },
                {
                    id: "launch-choose",
                    label: "Choose agent",
                    exec: ["vekrona-agent", "--choose"]
                }
            ]
        };
    }

    function opened(): void {
        launcherOpen = true;
        refreshTool();
    }

    // The recorded errors are listed in /agent only. There what is typed is also a question for the agent, so asking it comes first.
    // Until the first listing has answered the list is awaited, not shown without errors: the launcher keeps a selected row
    // selected, so a Launch agent row shown first would stay selected, with the newest error scrolled out of sight above it.
    function query(text: string, reqId: int): var {
        if (!inMode)
            return [launchRow()];
        if (errors === null && errorsFailure === "")
            return null;
        const ask = text.trim() !== "" ? [askRow(text.trim())] : [];
        return ask.concat(errorRows(), [launchRow()]);
    }

    function closed(): void {
        launcherOpen = false;
    }

    function fallbacks(text: string): var {
        return [askRow(text.trim())];
    }

    moduleId: "agent"
    title: "Agent"
    glyph: "smart_toy"
    slash: "agent"
    global: true
    weight: 0.7

    // However the list comes on screen (the launcher opens on it, /agent is typed, a click or the keyboard opens it over
    // another mode), what it shows is read, and then seen. While it is not shown nothing is read: listing spawns a process.
    onListShownChanged: {
        if (listShown)
            refreshErrors();
    }

    Connections {
        target: Shell.Errors

        function onRefreshed(): void {
            if (root.listShown)
                root.refreshErrors();
        }
    }
}
