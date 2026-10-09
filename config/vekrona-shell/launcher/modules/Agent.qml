import QtCore
import QtQuick
import Quickshell.Io
import ".."

LauncherModule {
    id: root

    readonly property string unreadPath: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/vekrona/errors/unread"
    readonly property var listLine: /^(\d{8}T\d{6}-[0-9a-f]{8})\s+(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(.*)$/
    property string defaultTool: ""
    property var latestError: null
    property bool toolInFlight: false
    property bool errorsInFlight: false

    function capture(argv: list<string>, onDone): void {
        job.createObject(root, {
            argv: argv,
            onDone: onDone
        }).running = true;
    }

    function refreshTool(): void {
        if (toolInFlight)
            return;
        toolInFlight = true;
        capture(["vekrona-agent", "get"], (code, stdout, stderr) => {
            toolInFlight = false;
            if (code !== 0)
                console.warn("agent: vekrona-agent get exited " + code + ": " + stderr.trim());
            const next = code === 0 ? stdout.trim() : "";
            if (next === defaultTool)
                return;
            defaultTool = next;
            changed();
        });
    }

    // `vekrona-error list` prints "no errors recorded", or a header and one fixed-width line per error, newest first:
    //   ID  SOURCE  STATUS  COUNT  AGE  TITLE
    function parseErrors(stdout: string): var {
        const lines = stdout.split("\n").filter(line => line.trim() !== "");
        if (lines.length === 0 || lines[0].trim() === "no errors recorded")
            return [];
        if (!lines[0].startsWith("ID "))
            console.error("agent: unexpected vekrona-error list header: " + lines[0]);
        const records = [];
        for (const line of lines.slice(1)) {
            const match = listLine.exec(line);
            if (!match) {
                console.error("agent: unrecognised vekrona-error list line: " + line);
                continue;
            }
            records.push({
                id: match[1],
                status: match[3],
                count: parseInt(match[4], 10),
                age: match[5],
                title: match[6].trim()
            });
        }
        return records;
    }

    function describeError(record: var): string {
        const count = record.count > 1 ? " ×" + record.count : "";
        const age = record.age === "?" ? "" : " — " + record.age + " ago";
        return record.title + count + age;
    }

    function refreshErrors(): void {
        if (errorsInFlight)
            return;
        errorsInFlight = true;
        capture(["vekrona-error", "list"], (code, stdout, stderr) => {
            errorsInFlight = false;
            let next = null;
            if (code !== 0)
                console.error("agent: vekrona-error list exited " + code + ": " + stderr.trim());
            else
                next = parseErrors(stdout).find(record => record.status === "new") ?? null;
            if (JSON.stringify(next) === JSON.stringify(latestError))
                return;
            latestError = next;
            changed();
        });
    }

    function askRow(text: string): var {
        return {
            id: "agent:ask",
            title: "Ask agent “" + text + "”",
            subtitle: defaultTool !== "" ? defaultTool : "no default agent, you will choose one",
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

    function commandRows(): var {
        const rows = [];
        if (latestError) {
            rows.push({
                id: "agent:fix-error",
                title: "Fix latest error",
                subtitle: describeError(latestError),
                glyph: "build",
                kind: "Command",
                keywords: ["agent", "error", "diagnose", "fix"],
                actions: [
                    {
                        id: "fix",
                        label: "Fix with agent",
                        exec: ["vekrona-agent", "--pick", "--error", latestError.id]
                    },
                    {
                        id: "fix-choose",
                        label: "Choose agent and fix",
                        exec: ["vekrona-agent", "--choose", "--error", latestError.id]
                    }
                ]
            });
        }
        rows.push({
            id: "agent:error-list",
            title: "Open error list",
            glyph: "error",
            kind: "Command",
            keywords: ["agent", "errors", "vekrona-error"],
            actions: [
                {
                    id: "open",
                    label: "Open",
                    exec: ["vekrona-error", "pick"]
                }
            ]
        }, {
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
        });
        return rows;
    }

    function refreshIfOpening(text: string): void {
        if (text !== "")
            return;
        refreshTool();
        refreshErrors();
    }

    function query(text: string, reqId: int): var {
        refreshIfOpening(text);
        return commandRows();
    }

    function fallbacks(text: string): var {
        return [askRow(text)];
    }

    function view(viewId: string, text: string, reqId: int): var {
        refreshIfOpening(text);
        return text === "" ? commandRows() : [askRow(text)].concat(commandRows());
    }

    moduleId: "agent"
    title: "Agent"
    glyph: "smart_toy"
    slash: "agent"
    global: true
    weight: 0.7
    Component.onCompleted: refreshTool()

    FileView {
        path: root.unreadPath
        watchChanges: true
        onLoaded: root.refreshErrors()
        onLoadFailed: root.refreshErrors()
        onFileChanged: reload()
    }

    Component {
        id: job

        Process {
            id: process

            required property list<string> argv
            required property var onDone
            property bool started: false
            property int exitCode: -1
            property int pending: 3

            function settle(): void {
                if (--pending > 0)
                    return;
                onDone(exitCode, output.text, errors.text);
                destroy();
            }

            command: argv
            stdout: StdioCollector {
                id: output
                onStreamFinished: process.settle()
            }
            stderr: StdioCollector {
                id: errors
                onStreamFinished: process.settle()
            }
            onStarted: started = true
            onExited: code => {
                exitCode = code;
                settle();
            }
            // Quickshell emits no exited signal when the binary cannot be started.
            onRunningChanged: {
                if (running || started)
                    return;
                onDone(-1, "", "failed to start " + argv[0]);
                destroy();
            }
        }
    }
}
