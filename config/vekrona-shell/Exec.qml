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

    // The command that runs argv as a transient user unit, which outlives the shell. With `wait`, the
    // command returns when the unit finishes and exits with the unit's status.
    function unit(argv: list<string>, wait: bool): list<string> {
        return ["systemd-run", "--user", "--collect", "--quiet", "--property=ExitType=cgroup"].concat(wait ? ["--wait"] : [], ["--"], argv);
    }

    function detached(argv: list<string>): void {
        run(unit(argv, false), (code, stdout, stderr) => {
            if (code !== 0)
                failure(argv, code, stderr);
        });
    }

    // Logs a failed command and returns what to tell the user: the first line of its stderr, else its exit code.
    function failure(argv: list<string>, code: int, stderr: string): string {
        console.error(JSON.stringify(argv) + " exited " + code + ": " + stderr.trim());
        return stderr.trim().split("\n")[0] || "exited " + code;
    }

    // The one process runner: runs argv and calls onDone(code, stdout, stderr) once it ended. The code is
    // non-zero (-1 without an exit status) also when the binary could not be started. The returned
    // handle's kill() stops the process; onDone is not called after that.
    function run(argv: list<string>, onDone): var {
        let alive = true;
        const runner = job.createObject(root, {
            argv: argv,
            onDone: (code, stdout, stderr) => {
                alive = false;
                onDone(code, stdout, stderr);
            }
        });
        runner.running = true;
        return {
            kill: () => {
                if (!alive)
                    return;
                alive = false;
                runner.cancel();
            }
        };
    }

    Component {
        id: job

        Process {
            id: process

            required property list<string> argv
            required property var onDone
            property bool cancelled: false
            property bool started: false
            property bool finished: false
            property int exitCode: -1
            property int pending: 3

            function cancel(): void {
                cancelled = true;
                running = false;
            }

            function finish(code: int, out: string, err: string): void {
                if (finished)
                    return;
                finished = true;
                try {
                    if (!cancelled)
                        onDone(code, out, err);
                } finally {
                    destroy();
                }
            }

            function settle(): void {
                if (--pending > 0)
                    return;
                finish(exitCode, output.text, errors.text);
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
            // Quickshell emits no exited signal when the binary cannot be started, only this.
            onRunningChanged: {
                if (!running && !started)
                    finish(-1, "", "failed to start " + argv[0]);
            }
        }
    }
}
