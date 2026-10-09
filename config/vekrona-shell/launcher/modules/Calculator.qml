import QtQuick
import Quickshell.Io
import ".."

LauncherModule {
    id: root

    readonly property var expressionStart: /^[\s(]*[-+]?[\d.,]/
    readonly property var expressionWord: /[-+*\/^%=×÷(]|\b(to|in|of|as|mod)\b/i
    property var current: null

    function looksLikeExpression(text: string): bool {
        return /\d/.test(text) && (expressionStart.test(text) || expressionWord.test(text));
    }

    function squash(text: string): string {
        return text.replace(/\s+/g, "").toLowerCase();
    }

    function cancel(): void {
        if (!current)
            return;
        current.cancelled = true;
        current.running = false;
        current = null;
    }

    // "--" ends qalc's options, so an expression like "-5+3" is not read as one.
    // Outside /calc, "unknowns off" makes plain words ("firefox") an error instead of a symbolic answer.
    function run(text: string, reqId: int, strict: bool): var {
        cancel();
        if (!strict && !looksLikeExpression(text))
            return [];
        const options = strict ? ["-t"] : ["-t", "-s", "unknowns off"];
        current = job.createObject(root, {
            argv: ["qalc"].concat(options, ["--", text]),
            reqId: reqId,
            strict: strict,
            question: text
        });
        current.running = true;
        return null;
    }

    function failureRow(message: string): var {
        return {
            id: "calc:error",
            title: "Can’t evaluate",
            subtitle: message,
            glyph: "calculate",
            kind: "Calculator",
            score: 1,
            actions: [
                {
                    id: "copy-message",
                    label: "Copy message",
                    copy: message
                }
            ]
        };
    }

    function answerRow(question: string, answer: string): var {
        const bare = answer.replace(/^[≈=]\s*/, "");
        return {
            id: "calc:result",
            card: "calc",
            title: question,
            subtitle: answer,
            glyph: "calculate",
            kind: "Calculator",
            score: 1,
            actions: [
                {
                    id: "copy-answer",
                    label: "Copy answer",
                    copy: bare
                },
                {
                    id: "copy-equation",
                    label: "Copy “" + question + " = " + bare + "”",
                    copy: question + " = " + bare
                }
            ]
        };
    }

    // qalc prints "error: ..." and "warning: ..." lines on stdout, before the result.
    function finish(reqId: int, strict: bool, question: string, exitCode: int, stdout: string, stderr: string): void {
        if (exitCode !== 0) {
            const message = stderr.trim() || stdout.trim() || ("qalc exited " + exitCode);
            console.error("calculator: qalc exited " + exitCode + ": " + message);
            resultsReady(reqId, strict ? [failureRow(message)] : []);
            return;
        }
        const lines = stdout.split("\n").map(line => line.trim()).filter(line => line !== "");
        const problems = lines.filter(line => line.startsWith("error: ")).map(line => line.slice("error: ".length));
        const answers = lines.filter(line => !line.startsWith("error: ") && !line.startsWith("warning: "));
        if (problems.length > 0 || answers.length === 0) {
            resultsReady(reqId, strict ? [failureRow(problems.length > 0 ? problems.join("; ") : "qalc printed no result")] : []);
            return;
        }
        const answer = answers.join(", ");
        if (!strict && squash(answer) === squash(question)) {
            resultsReady(reqId, []);
            return;
        }
        resultsReady(reqId, [answerRow(question, answer)]);
    }

    function query(text: string, reqId: int): var {
        return run(text.trim(), reqId, false);
    }

    function view(viewId: string, text: string, reqId: int): var {
        if (text.trim() === "") {
            cancel();
            return [];
        }
        return run(text.trim(), reqId, true);
    }

    moduleId: "calc"
    title: "Calculator"
    glyph: "calculate"
    slash: "calc"
    global: true
    weight: 1.0

    Component {
        id: job

        Process {
            id: process

            required property list<string> argv
            required property int reqId
            required property bool strict
            required property string question
            property bool cancelled: false
            property bool started: false
            property int exitCode: -1
            property int pending: 3

            function settle(): void {
                if (--pending > 0)
                    return;
                if (!cancelled) {
                    if (root.current === process)
                        root.current = null;
                    root.finish(reqId, strict, question, exitCode, output.text, errors.text);
                }
                destroy();
            }

            command: argv
            environment: ({
                    LC_ALL: "C.UTF-8"
                })
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
                if (root.current === process)
                    root.current = null;
                if (!cancelled)
                    root.finish(reqId, strict, question, -1, "", "failed to start " + argv[0] + " (is the qalculate package installed?)");
                destroy();
            }
        }
    }
}
