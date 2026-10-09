import ".."
import "../.." as Shell

LauncherModule {
    id: root

    readonly property var expressionStart: /^[\s(]*[-+]?[\d.,]/
    readonly property var expressionWord: /[-+*\/^%=×÷(]|\b(to|in|of|as|mod)\b/i
    // qalc's exit status for an expression it ran and could not evaluate ("5 apples + 3"): the user's input, not a failure.
    readonly property int exitRefused: 1
    // The handle of the running qalc, if any.
    property var current: null

    function looksLikeExpression(text: string): bool {
        return /\d/.test(text) && (expressionStart.test(text) || expressionWord.test(text));
    }

    // qalc reads "of" as a unit, so "12.5% of 1840" is meant as the product it stands for.
    function percentOf(text: string): string {
        return text.replace(/%\s*of\b/gi, "% *");
    }

    function squash(text: string): string {
        return text.replace(/\s+/g, "").toLowerCase();
    }

    function cancel(): void {
        if (current)
            current.kill();
        current = null;
    }

    // "--" ends qalc's options, so an expression like "-5+3" is not read as one. Outside /calc, "unknowns off"
    // makes plain words ("firefox") an error instead of a symbolic answer. LC_ALL pins the number format.
    function evaluate(text: string, reqId: int): var {
        cancel();
        if (text === "" || (!inMode && !looksLikeExpression(text)))
            return [];
        const strict = inMode;
        const options = strict ? ["-t"] : ["-t", "-s", "unknowns off"];
        const argv = ["env", "LC_ALL=C.UTF-8", "qalc"].concat(options, ["--", percentOf(text)]);
        current = answerFrom(reqId, argv, (code, stdout, stderr) => outcome(strict, text, argv, code, stdout, stderr));
        return null;
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

    // qalc prints "error: ..." and "warning: ..." lines on stdout, before the result. Outside /calc
    // (not strict), a failure or an answer that only repeats the question shows no row.
    function outcome(strict: bool, question: string, argv: list<string>, exitCode: int, stdout: string, stderr: string): var {
        if (exitCode !== 0 && exitCode !== exitRefused) {
            const message = Shell.Exec.failure(argv, exitCode, stderr);
            return strict ? [errorRow("evaluate", message)] : [];
        }
        const lines = stdout.split("\n").map(line => line.trim()).filter(line => line !== "");
        const problems = lines.filter(line => line.startsWith("error: ")).map(line => line.slice("error: ".length));
        if (exitCode === exitRefused && problems.length === 0)
            problems.push("qalc cannot evaluate it");
        const answers = lines.filter(line => !line.startsWith("error: ") && !line.startsWith("warning: "));
        if (problems.length > 0 || answers.length === 0)
            return strict ? [errorRow("evaluate", problems.length > 0 ? problems.join("; ") : "qalc printed no result")] : [];
        const answer = answers.join(", ");
        if (!strict && squash(answer) === squash(question))
            return [];
        return [answerRow(question, answer)];
    }

    function query(text: string, reqId: int): var {
        return evaluate(text.trim(), reqId);
    }

    moduleId: "calc"
    title: "Calculator"
    glyph: "calculate"
    slash: "calc"
    global: true
    weight: 1.0
}
