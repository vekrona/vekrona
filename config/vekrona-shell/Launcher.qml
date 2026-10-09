import QtQuick
import Quickshell
import "."

Picker {
    id: root

    function entries(applications, query: string): var {
        const needle = query.toLowerCase();
        const byName = (a, b) => a.name.localeCompare(b.name);
        const matches = applications.filter(app => !app.noDisplay && [app.name, app.genericName].concat(app.keywords).some(field => field.toLowerCase().includes(needle)));
        const startsWithQuery = app => app.name.toLowerCase().startsWith(needle);
        return matches.filter(startsWithQuery).sort(byName).concat(matches.filter(app => !startsWithQuery(app)).sort(byName)).map(app => ({
                    label: app.name,
                    iconPath: Quickshell.iconPath(app.icon, "application-x-executable"),
                    command: app.runInTerminal ? Exec.inTerminal(app.command) : app.command
                }));
    }

    ipcTarget: "launcher"
    namespace: "vekrona-launcher"
    placeholder: "Search applications"
    items: entries(DesktopEntries.applications.values, query)
    onChosen: item => Exec.detached(item.command)
}
