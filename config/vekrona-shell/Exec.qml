pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string terminal: "ghostty"

    function inTerminal(argv: list<string>): list<string> {
        return [terminal, "-e"].concat(argv);
    }

    // Like inTerminal, in a window with its own app id, which Sway rules and a toggle can tell from the other terminals.
    function inTerminalAs(appId: string, argv: list<string>): list<string> {
        return [terminal, "--class=" + appId, "-e"].concat(argv);
    }

    // Where a transient user unit starts when the command names no directory: the one systemd gives a user unit anyway.
    readonly property string home: Quickshell.env("HOME")

    // The command that runs argv in `directory` as a transient user unit, which outlives the shell. `options` are more
    // arguments of systemd-run.
    function systemdRun(options: list<string>, argv: list<string>, directory: string): list<string> {
        return ["systemd-run", "--user", "--collect", "--quiet", "--property=ExitType=cgroup", "--working-directory=" + directory].concat(options, ["--"], argv);
    }

    // Starts argv in `directory` as a unit that outlives the shell. A start that fails is logged, which records it.
    function detached(argv: list<string>, directory: string): void {
        check(systemdRun([], argv, directory));
    }

    // Starts argv in `directory` as the unit `name`, or stops that unit, and the argv with it, when it runs: one command that
    // a button opens and the next press closes. Stopping needs no confirmation of the program, which a window's close would.
    function toggleDetached(name: string, argv: list<string>, directory: string): void {
        const service = name + ".service";
        run(["systemctl", "--user", "is-active", "--quiet", service], (code, stdout, stderr) => {
            if (code === 0)
                check(["systemctl", "--user", "stop", service]);
            else
                check(systemdRun(["--unit=" + name], argv, directory));
        });
    }

    // When this shell last started each service of `refreshService`, in epoch milliseconds, by service name.
    readonly property var refreshed: ({})

    // Starts the oneshot `service` of the user manager without waiting for it, unless this shell started it less than `maxAgeMs`
    // ago. For data that a timer keeps fresh slowly and that the user is about to look at. A failure to start is logged.
    function refreshService(service: string, maxAgeMs: int): void {
        const now = Date.now();
        if (now - (refreshed[service] ?? 0) < maxAgeMs)
            return;
        refreshed[service] = now;
        check(["systemctl", "--user", "start", "--no-block", service]);
    }

    // Puts text on the clipboard, then calls onCopied if one is given. wl-copy reads the text from its stdin, so that
    // it shows up in no command line, unit or journal line, and has no length limit. It forks to serve the selection,
    // so the process the caller waits for exits as soon as it has the text. A scope moves that process into a transient
    // unit of its own while it keeps the caller's stdin and stdout, so the server outlives a restart of the shell.
    function copy(text: string, onCopied): void {
        const argv = ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--", "wl-copy"];
        runWithInput(argv, text, (code, stdout, stderr) => {
            if (code !== 0)
                failure(argv, code, stderr);
            else
                onCopied?.();
        });
    }

    // Logs a failed command and returns what to tell the user: the first line of its stderr, else its exit code.
    function failure(argv: list<string>, code: int, stderr: string): string {
        console.error(JSON.stringify(argv) + " exited " + code + ": " + stderr.trim());
        return stderr.trim().split("\n")[0] || "exited " + code;
    }

    // Runs argv and calls onOk(stdout) when it succeeded. A failure is logged (which records it, and puts the robot's dot
    // up) and passed to onFail(reason) with what to tell the user. Returns the handle of the run.
    function runOr(argv: list<string>, onOk, onFail): var {
        return run(argv, (code, stdout, stderr) => {
            if (code !== 0)
                onFail(failure(argv, code, stderr));
            else
                onOk(stdout);
        });
    }

    // Like runOr for a caller with nothing to show for a failure: the log is all of it.
    function runChecked(argv: list<string>, onOk): var {
        return runOr(argv, onOk, reason => {});
    }

    // Runs argv for its effect alone; only a failure is logged.
    function check(argv: list<string>): void {
        runChecked(argv, stdout => {});
    }

    // The one process runner: runs argv and calls onDone(code, stdout, stderr) once it ended. The code is
    // non-zero (-1 without an exit status) also when the binary could not be started. The returned
    // handle's kill() stops the process; onDone is not called after that.
    function run(argv: list<string>, onDone): var {
        return runWithin(argv, 0, onDone);
    }

    // Like run, and a process still alive after timeoutMs milliseconds (0: no limit) is stopped and ends as code -1 with
    // "timed out" as its stderr, so a query that hangs fails instead of holding its caller for good.
    function runWithin(argv: list<string>, timeoutMs: int, onDone): var {
        return startJob(argv, "", timeoutMs, onDone);
    }

    // Like run, and the process gets input on its stdin, which is then closed.
    function runWithInput(argv: list<string>, input: string, onDone): var {
        return startJob(argv, input, 0, onDone);
    }

    function startJob(argv: list<string>, input: string, timeoutMs: int, onDone): var {
        let alive = true;
        const runner = job.createObject(root, {
            argv: argv,
            input: input,
            timeoutMs: timeoutMs,
            onDone: (code, stdout, stderr) => {
                alive = false;
                onDone(code, stdout, stderr);
            }
        });
        if (timeoutMs > 0)
            limit.createObject(runner, { target: runner, interval: timeoutMs, running: true });
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

    // Stops the process that owns it, which then ends as a timeout. It dies with the process.
    Component {
        id: limit

        Timer {
            required property var target

            onTriggered: {
                target.timedOut = true;
                target.running = false;
            }
        }
    }

    Component {
        id: job

        Process {
            id: process

            required property list<string> argv
            required property var onDone
            property string input: ""
            property int timeoutMs: 0
            property bool timedOut: false
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
                if (timedOut)
                    finish(-1, output.text, "timed out after " + timeoutMs + " ms");
                else
                    finish(exitCode, output.text, errors.text);
            }

            command: argv
            stdinEnabled: input !== ""
            stdout: StdioCollector {
                id: output
                onStreamFinished: process.settle()
            }
            stderr: StdioCollector {
                id: errors
                onStreamFinished: process.settle()
            }
            onStarted: {
                started = true;
                if (input !== "") {
                    write(input);
                    stdinEnabled = false;
                }
            }
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
