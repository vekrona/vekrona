import QtQuick
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
        // The Path key of the .desktop file, for the application and for its actions.
        const directory = entry.workingDirectory || Shell.Exec.home;
        const desktopActions = Array.from(entry.actions).map(action => ({
                    id: "action:" + action.id,
                    label: action.name,
                    exec: launch(Array.from(action.command)),
                    directory: directory
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
                    exec: command,
                    directory: directory
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

    // Built by the first query after the application list changed or the launcher opened, not while it is closed: the list is
    // rescanned whenever a .desktop file changes, which an installer or a browser profile does by the hundred.
    property var rows: null

    function opened() {
        rows = null;
    }

    function query(text: string, reqId: int): var {
        if (rows === null)
            rows = DesktopEntries.applications.values.filter(entry => !entry.noDisplay).map(row);
        return rows;
    }

    moduleId: "apps"
    title: "Applications"
    glyph: "apps"
    slash: "apps"

    // The launcher asks again only if it is open; it rebuilds the rows then.
    Connections {
        target: DesktopEntries.applications

        function onValuesChanged(): void {
            root.rows = null;
            root.changed();
        }
    }
}
