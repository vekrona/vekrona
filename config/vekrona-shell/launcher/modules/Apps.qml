import Quickshell
import ".."
import "../.." as Shell

LauncherModule {
    id: root

    function shellQuote(word: string): string {
        return /^[A-Za-z0-9_\/.:=@%+,-]+$/.test(word) ? word : "'" + word.replace(/'/g, "'\\''") + "'";
    }

    function row(entry): var {
        const launch = argv => entry.runInTerminal ? Shell.Exec.inTerminal(argv) : argv;
        const command = launch(Array.from(entry.command));
        const desktopActions = Array.from(entry.actions).map(action => ({
                    id: "action:" + action.id,
                    label: action.name,
                    exec: launch(Array.from(action.command))
                }));
        return {
            id: "apps:" + entry.id,
            title: entry.name,
            subtitle: entry.genericName,
            iconPath: Quickshell.iconPath(entry.icon, "application-x-executable"),
            kind: "Application",
            keywords: Array.from(entry.keywords).concat([entry.genericName, entry.id]).filter(word => word !== ""),
            actions: [
                {
                    id: "open",
                    label: "Open",
                    exec: command
                }
            ].concat(desktopActions, [
                {
                    id: "copy-command",
                    label: "Copy command",
                    copy: command.map(shellQuote).join(" ")
                }
            ])
        };
    }

    // Rebuilt whenever the application list or a property read by row() changes.
    readonly property var rows: DesktopEntries.applications.values.filter(entry => !entry.noDisplay).map(row)

    function query(text: string, reqId: int): var {
        return rows;
    }

    moduleId: "apps"
    title: "Applications"
    glyph: "apps"
    slash: "apps"
    onRowsChanged: changed()
}
