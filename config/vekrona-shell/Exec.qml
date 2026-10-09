pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property var terminal: ["ghostty", "-e"]

    function inTerminal(argv: list<string>): list<string> {
        return terminal.concat(argv);
    }

    readonly property var transientUnit: ["systemd-run", "--user", "--collect", "--quiet", "--property=ExitType=cgroup"]

    function detached(argv: list<string>): void {
        capture(transientUnit.concat(["--"], argv), null);
    }

    // Like detached(), but waits for the unit to finish and calls onSuccess if it exited 0.
    function detachedThen(argv: list<string>, onSuccess): void {
        capture(transientUnit.concat(["--wait", "--"], argv), onSuccess);
    }

    function capture(argv: list<string>, onSuccess): void {
        job.createObject(root, {
            argv: argv,
            onSuccess: onSuccess
        }).running = true;
    }

    Component {
        id: job

        Process {
            id: process

            required property list<string> argv
            required property var onSuccess
            property int exitCode: -1
            property int pending: 3

            function settle(): void {
                if (--pending > 0)
                    return;
                if (exitCode !== 0)
                    console.error(JSON.stringify(argv) + " exited " + exitCode + ": " + errors.text.trim());
                else if (onSuccess)
                    onSuccess(output.text);
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
            onExited: code => {
                exitCode = code;
                settle();
            }
        }
    }
}
