import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../Vekrona"
import ".."
import "."
import "Ranker.js" as Ranker

// The one launcher: apps, commands, settings, calculator, clipboard history and the power commands,
// each a module (modules/*.qml). Opened by Super+Space and by `ipc call launcher open <mode>`.
PanelWindow {
    id: root

    readonly property int recentLimit: 6
    readonly property int sectionLimit: 5
    readonly property int toastMs: 3000

    property bool shown: false
    // The module whose mode is active (/calc), or null in root mode.
    property var modeModule: null
    // Pushed sub-views, innermost last: {title, viewId, module, savedQuery}.
    property var viewStack: []
    // {action} of the selected row while it waits for the confirming second Enter, else null.
    property var armed: null
    property bool actionsOpen: false
    property string toastText: ""
    // The list entries: {type: "header" | "empty", title} or {type: "row", module, result, synthetic}.
    property var rows: []
    property int selected: -1
    property int requestId: 0
    // The modules asked for the current request, and the results that came back, by moduleId.
    property var queried: ({})
    property var collected: ({})

    readonly property string activeSlash: modeModule === null ? "" : modeModule.slash
    readonly property var moduleList: modules.all
    readonly property var selectedEntry: selected >= 0 && selected < rows.length ? rows[selected] : null
    readonly property var selectedActions: selectedEntry === null ? [] : selectedEntry.result.actions ?? []
    readonly property string breadcrumb: viewStack.length === 0 ? "" : [viewStack[0].module.title].concat(viewStack.map(frame => frame.title)).join(" › ")
    readonly property real listContentHeight: rows.reduce((sum, entry) => sum + LauncherMetrics.heightOf(entry), 0)
    // The search field's middle sits on the screen's middle; the list takes the room below it.
    readonly property real panelTop: Math.round(height / 2 - VekronaTheme.borderHair - LauncherMetrics.searchHeight / 2)
    readonly property real chromeHeight: LauncherMetrics.searchHeight + strip.implicitHeight + crumb.implicitHeight + LauncherMetrics.footerHeight + 2 * VekronaTheme.borderHair
    readonly property real listLimit: Math.max(LauncherMetrics.minRows * LauncherMetrics.rowHeight, Math.min(LauncherMetrics.maxRows * LauncherMetrics.rowHeight, height - panelTop - chromeHeight - VekronaTheme.space6))

    function toggle(): void {
        if (shown)
            closeLauncher();
        else
            openMode("");
    }

    // Opens in root mode, or in the mode of the slash keyword `slash`.
    function openMode(slash: string): void {
        modeModule = null;
        viewStack = [];
        armed = null;
        actionsOpen = false;
        toastText = "";
        shown = true;
        if (slash === "" || !enterMode(slash))
            applyQuery("");
    }

    function closeLauncher(): void {
        shown = false;
    }

    function showToast(text: string): void {
        toastText = text;
        toastTimer.restart();
    }

    function moduleOf(resultId: string): var {
        const owner = resultId.slice(0, resultId.indexOf(":"));
        return moduleList.find(module => module.moduleId === owner) ?? null;
    }

    // Sets the search field; its change handler then queries.
    function applyQuery(value: string): void {
        if (search.text === value) {
            armed = null;
            refresh();
        } else {
            search.text = value;
        }
    }

    // The root query, with a leading /keyword entering a mode: the launcher API's setQuery.
    function setRootQuery(value: string): void {
        modeModule = null;
        viewStack = [];
        actionsOpen = false;
        search.forceActiveFocus();
        applyQuery(value);
    }

    function enterMode(slash: string): bool {
        const module = moduleList.find(candidate => candidate.slash === slash);
        if (module === undefined) {
            console.error("launcher: no module has the mode /" + slash);
            showToast("There is no /" + slash + " mode");
            return false;
        }
        search.forceActiveFocus();
        enterModule(module, "");
        return true;
    }

    function enterModule(module: var, text: string): void {
        modeModule = module;
        viewStack = [];
        actionsOpen = false;
        applyQuery(text);
    }

    function exitMode(): void {
        modeModule = null;
        armed = null;
        refresh();
    }

    function pushView(entry: var, push: var): void {
        viewStack = viewStack.concat([
            {
                title: push.title,
                viewId: push.viewId,
                module: entry.module,
                savedQuery: search.text
            }
        ]);
        applyQuery("");
    }

    function popView(): void {
        const frame = viewStack[viewStack.length - 1];
        viewStack = viewStack.slice(0, -1);
        applyQuery(frame.savedQuery);
    }

    // The text changed: a "/keyword " (or any /keyword followed by text) enters its mode, anything else queries.
    function queryEdited(): void {
        armed = null;
        if (modeModule === null && viewStack.length === 0) {
            const typed = /^\/(\S+)\s([\s\S]*)$/.exec(search.text);
            const module = typed === null ? undefined : moduleList.find(candidate => candidate.slash === typed[1]);
            if (module !== undefined) {
                enterModule(module, typed[2]);
                return;
            }
        }
        refresh();
    }

    // The modules whose slash keyword starts with what follows the "/" being typed.
    function modeSuggestions(): var {
        if (modeModule !== null || viewStack.length > 0 || !search.text.startsWith("/") || /\s/.test(search.text))
            return [];
        const typed = search.text.slice(1).toLowerCase();
        return moduleList.filter(module => module.slash !== "" && module.slash.startsWith(typed));
    }

    function isRecentCandidate(id: string): bool {
        const module = moduleOf(id);
        return module !== null && module.global;
    }

    // The modules a new request asks.
    function targets(): var {
        if (viewStack.length > 0)
            return [viewStack[viewStack.length - 1].module];
        if (modeModule !== null)
            return [modeModule];
        if (modeSuggestions().length > 0)
            return [];
        if (search.text.trim() === "") {
            const owners = Ranker.recentIds(frecency.entries, Date.now(), recentLimit, isRecentCandidate).map(id => moduleOf(id));
            return moduleList.filter(module => owners.includes(module));
        }
        return moduleList.filter(module => module.global);
    }

    function ask(module: var, reqId: int): var {
        try {
            const frame = viewStack.length > 0 ? viewStack[viewStack.length - 1] : null;
            const results = frame === null ? module.query(search.text, reqId) : module.view(frame.viewId, search.text, reqId);
            if (results === null || results === undefined)
                return null;
            if (!Array.isArray(results))
                throw new Error("expected an array of results or null, got " + typeof results);
            return results;
        } catch (e) {
            reportModuleFailure(module, e);
            return [];
        }
    }

    function reportModuleFailure(module: var, error: var): void {
        console.error("launcher: module " + module.moduleId + " failed:", error);
        showToast(module.title + " failed: " + error);
    }

    function refresh(): void {
        const reqId = ++requestId;
        queried = {};
        collected = {};
        for (const module of targets()) {
            queried[module.moduleId] = true;
            const results = ask(module, reqId);
            if (results !== null)
                collected[module.moduleId] = results;
        }
        rebuild(false);
    }

    // An asynchronous module delivered; results for an older request are dropped.
    function deliver(module: var, reqId: int, results: var): void {
        if (reqId !== requestId || !queried[module.moduleId])
            return;
        collected[module.moduleId] = results;
        rebuild(true);
    }

    function rowEntry(module: var, result: var): var {
        return {
            type: "row",
            module: module,
            result: result,
            synthetic: false
        };
    }

    function suggestionRows(modules: var): var {
        return modules.map(module => ({
                    type: "row",
                    module: module,
                    synthetic: true,
                    result: {
                        id: "mode:" + module.slash,
                        title: "/" + module.slash,
                        subtitle: module.title,
                        glyph: module.glyph,
                        kind: "Mode",
                        actions: [
                            {
                                id: "enter",
                                label: "Enter mode",
                                setQuery: "/" + module.slash + " "
                            }
                        ]
                    }
                }));
    }

    function fallbackRows(): var {
        const out = [];
        for (const module of moduleList) {
            try {
                for (const result of module.fallbacks(search.text))
                    out.push(rowEntry(module, result));
            } catch (e) {
                reportModuleFailure(module, e);
            }
        }
        return out;
    }

    function recentRows(): var {
        const found = {};
        for (const module of moduleList) {
            for (const result of collected[module.moduleId] ?? [])
                found[result.id] = rowEntry(module, result);
        }
        const ids = Ranker.recentIds(frecency.entries, Date.now(), recentLimit, isRecentCandidate);
        const rowsFound = ids.filter(id => found[id] !== undefined).map(id => found[id]);
        return rowsFound.length === 0 ? [] : [{ type: "header", title: "Recent" }].concat(rowsFound);
    }

    function rootRows(text: string, waiting: bool): var {
        const now = Date.now();
        const groups = moduleList.filter(module => module.global).map(module => ({
                    owner: module,
                    title: module.title,
                    items: Ranker.rank(collected[module.moduleId] ?? [], text, module.weight, frecency.entries, now)
                }));
        const out = [];
        for (const section of Ranker.sections(groups, sectionLimit)) {
            out.push({ type: "header", title: section.title });
            for (const item of section.items)
                out.push(rowEntry(section.owner, item.result));
        }
        if (out.length === 0 && !waiting)
            out.push({ type: "empty", title: "No matches" });
        const fallbacks = fallbackRows();
        if (fallbacks.length > 0)
            out.push({ type: "header", title: "Use “" + text + "” with" });
        return out.concat(fallbacks);
    }

    function singleRows(module: var, text: string, waiting: bool): var {
        const ranked = Ranker.rank(collected[module.moduleId] ?? [], text, module.weight, frecency.entries, Date.now());
        const out = ranked.map(item => rowEntry(module, item.result));
        if (out.length === 0 && !waiting)
            out.push({ type: "empty", title: text === "" ? "Nothing to show" : "No matches" });
        return out;
    }

    function buildRows(): var {
        const text = search.text.trim();
        const suggestions = modeSuggestions();
        if (suggestions.length > 0)
            return suggestionRows(suggestions);
        const waiting = Object.keys(queried).some(id => collected[id] === undefined);
        if (viewStack.length > 0)
            return singleRows(viewStack[viewStack.length - 1].module, text, waiting);
        if (modeModule !== null)
            return singleRows(modeModule, text, waiting);
        return text === "" ? recentRows() : rootRows(text, waiting);
    }

    function firstSelectable(): int {
        return rows.findIndex(entry => entry.type === "row");
    }

    // Replaces the list. With keepSelection the selected result stays selected if it is still there.
    function rebuild(keepSelection: bool): void {
        const keptId = keepSelection && selectedEntry !== null ? selectedEntry.result.id : null;
        rows = buildRows();
        const kept = keptId === null ? -1 : rows.findIndex(entry => entry.type === "row" && entry.result.id === keptId);
        selected = kept >= 0 ? kept : firstSelectable();
        if (kept < 0)
            armed = null;
        Qt.callLater(revealSelected);
    }

    function revealSelected(): void {
        if (selected < 0)
            return;
        if (selected > 0 && rows[selected - 1].type === "header")
            list.positionViewAtIndex(selected - 1, ListView.Contain);
        list.positionViewAtIndex(selected, ListView.Contain);
    }

    function selectIndex(index: int): void {
        if (index === selected)
            return;
        armed = null;
        selected = index;
        revealSelected();
    }

    function moveSelection(delta: int): void {
        const step = delta < 0 ? -1 : 1;
        let index = selected;
        for (let left = Math.abs(delta); left > 0; left--) {
            let next = index + step;
            while (next >= 0 && next < rows.length && rows[next].type !== "row")
                next += step;
            if (next < 0 || next >= rows.length)
                break;
            index = next;
        }
        selectIndex(index);
    }

    // Enter (which = 0, the primary action) or Ctrl+Enter (which = 1). While a row is armed, either runs the armed action.
    function activateSelected(which: int): void {
        const entry = selectedEntry;
        if (entry === null)
            return;
        if (armed !== null) {
            const action = armed.action;
            armed = null;
            perform(entry, action);
            return;
        }
        if (which < selectedActions.length)
            requestAction(entry, selectedActions[which]);
    }

    // Runs the action, unless it needs a confirming second Enter first.
    function requestAction(entry: var, action: var): void {
        if (action.confirm === undefined) {
            perform(entry, action);
            return;
        }
        actionsOpen = false;
        armed = { action: action };
    }

    function perform(entry: var, action: var): void {
        if (!entry.synthetic)
            frecency.record(entry.result.id);
        try {
            if (action.exec !== undefined) {
                Exec.detached(action.exec);
                closeLauncher();
            } else if (action.copy !== undefined) {
                Exec.detached(["wl-copy", "--", action.copy]);
                closeLauncher();
            } else if (action.url !== undefined) {
                Exec.detached(["xdg-open", action.url]);
                closeLauncher();
            } else if (action.push !== undefined) {
                pushView(entry, action.push);
            } else if (action.setQuery !== undefined) {
                setRootQuery(action.setQuery);
            } else if (action.run !== undefined) {
                if (action.run() !== false)
                    closeLauncher();
            } else {
                throw new Error("the action '" + action.id + "' has no exec, copy, url, push, setQuery or run");
            }
        } catch (e) {
            reportModuleFailure(entry.module, e);
        }
    }

    function handleEscape(): void {
        if (armed !== null)
            armed = null;
        else if (viewStack.length > 0)
            popView();
        else if (modeModule !== null)
            exitMode();
        else if (search.text !== "")
            applyQuery("");
        else
            closeLauncher();
    }

    function openActions(): void {
        if (selectedActions.length === 0)
            return;
        armed = null;
        actionsOpen = true;
    }

    function handleTab(backwards: bool): void {
        if (!backwards && modeSuggestions().length > 0)
            activateSelected(0);
        else if (strip.populated)
            strip.enter(backwards);
    }

    function handleKey(event): void {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        switch (event.key) {
        case Qt.Key_Escape:
            handleEscape();
            break;
        case Qt.Key_Up:
            moveSelection(-1);
            break;
        case Qt.Key_Down:
            moveSelection(1);
            break;
        case Qt.Key_N:
            if (!ctrl)
                return;
            moveSelection(1);
            break;
        case Qt.Key_P:
            if (!ctrl)
                return;
            moveSelection(-1);
            break;
        case Qt.Key_PageUp:
            moveSelection(-pageRows());
            break;
        case Qt.Key_PageDown:
            moveSelection(pageRows());
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            activateSelected(ctrl ? 1 : 0);
            break;
        case Qt.Key_K:
            if (!ctrl)
                return;
            openActions();
            break;
        case Qt.Key_Tab:
            handleTab(false);
            break;
        case Qt.Key_Backtab:
            handleTab(true);
            break;
        case Qt.Key_Space:
            if (modeSuggestions().length === 0)
                return;
            activateSelected(0);
            break;
        case Qt.Key_Backspace:
            if (search.text !== "" || (modeModule === null && viewStack.length === 0))
                return;
            if (viewStack.length > 0)
                popView();
            else
                exitMode();
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    function pageRows(): int {
        return Math.max(1, Math.floor(list.height / LauncherMetrics.rowHeight));
    }

    visible: shown
    color: "transparent"
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "vekrona-launcher"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    onModeModuleChanged: {
        for (const module of moduleList)
            module.inMode = module === modeModule;
    }
    onShownChanged: {
        if (shown) {
            search.forceActiveFocus();
        } else {
            requestId++;
            armed = null;
            actionsOpen = false;
        }
    }
    onActionsOpenChanged: {
        if (actionsOpen)
            Qt.callLater(actionsPanel.start);
        else
            search.forceActiveFocus();
    }

    IpcHandler {
        target: "launcher"

        function toggle(): void {
            root.toggle();
        }

        // Opens in the mode of the slash keyword `mode` ("" is the root search); asked again while that mode is open, it closes.
        function open(mode: string): void {
            if (root.shown && root.activeSlash === mode)
                root.closeLauncher();
            else
                root.openMode(mode);
        }
    }

    QtObject {
        id: api

        function close(): void {
            root.closeLauncher();
        }

        function setQuery(text: string): void {
            root.setRootQuery(text);
        }

        function enterMode(slash: string): void {
            root.enterMode(slash);
        }

        function toast(text: string): void {
            root.showToast(text);
        }
    }

    Frecency {
        id: frecency
    }

    Modules {
        id: modules
        launcher: api
    }

    Instantiator {
        model: root.moduleList

        delegate: Connections {
            required property var modelData

            target: modelData

            function onResultsReady(reqId: int, results: var): void {
                root.deliver(modelData, reqId, results);
            }

            function onChanged(): void {
                if (root.shown)
                    root.refresh();
            }
        }
    }

    Timer {
        id: toastTimer
        interval: root.toastMs
        onTriggered: root.toastText = ""
    }

    Rectangle {
        anchors.fill: parent
        color: VekronaTheme.c.scrim
        opacity: VekronaTheme.scrimOpacity
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.closeLauncher()
    }

    Rectangle {
        id: panel
        x: Math.round((root.width - width) / 2)
        y: root.panelTop
        width: LauncherMetrics.panelWidth
        height: column.implicitHeight + 2 * VekronaTheme.borderHair
        color: VekronaTheme.c.surface1
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.line

        MouseArea {
            anchors.fill: parent
        }

        FocusScope {
            id: scope
            anchors.fill: parent
            anchors.margins: VekronaTheme.borderHair
            focus: true

            ColumnLayout {
                id: column
                anchors.fill: parent
                spacing: 0

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: LauncherMetrics.searchHeight

                    Pictogram {
                        id: searchGlyph
                        x: VekronaTheme.space4
                        anchors.verticalCenter: parent.verticalCenter
                        px: VekronaTheme.iconM
                        name: root.modeModule === null ? "search" : root.modeModule.glyph
                        color: VekronaTheme.c.inkMuted
                    }

                    ModeBadge {
                        id: badge
                        visible: root.modeModule !== null
                        anchors.left: searchGlyph.right
                        anchors.leftMargin: VekronaTheme.space2
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.modeModule === null ? "" : root.modeModule.title
                    }

                    TextInput {
                        id: search
                        anchors.left: badge.visible ? badge.right : searchGlyph.right
                        anchors.leftMargin: VekronaTheme.space2
                        anchors.right: parent.right
                        anchors.rightMargin: VekronaTheme.space4
                        anchors.verticalCenter: parent.verticalCenter
                        focus: true
                        color: VekronaTheme.c.ink
                        font.family: VekronaTheme.fontSans
                        font.pixelSize: VekronaTheme.type.title.size
                        Accessible.name: "Search"
                        Keys.onPressed: event => root.handleKey(event)
                        onTextChanged: root.queryEdited()
                    }

                    Label {
                        visible: search.text === ""
                        anchors.fill: search
                        verticalAlignment: Text.AlignVCenter
                        style: VekronaTheme.type.title
                        color: VekronaTheme.c.inkMuted
                        text: "Search"
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: VekronaTheme.borderHair
                        color: VekronaTheme.c.line
                    }

                    FocusRing {
                        shown: search.activeFocus
                    }
                }

                WidgetStrip {
                    id: strip
                    Layout.fillWidth: true
                    launcher: api
                    modules: root.moduleList
                    onLeave: search.forceActiveFocus()
                }

                Item {
                    id: crumb
                    visible: root.viewStack.length > 0
                    Layout.fillWidth: true
                    implicitHeight: visible ? LauncherMetrics.headerHeight : 0

                    Label {
                        x: VekronaTheme.space4
                        width: parent.width - 2 * VekronaTheme.space4
                        anchors.verticalCenter: parent.verticalCenter
                        style: VekronaTheme.type.label
                        elide: Text.ElideRight
                        text: root.breadcrumb
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.popView()
                    }
                }

                ListView {
                    id: list
                    visible: root.rows.length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(root.listContentHeight, root.listLimit)
                    clip: true
                    interactive: false
                    model: root.rows

                    delegate: ResultRow {
                        required property var modelData
                        required property int index

                        width: ListView.view.width
                        entry: modelData
                        current: index === root.selected
                        armedText: root.armed !== null && index === root.selected ? root.armed.action.confirm : ""
                        onMoved: root.selectIndex(index)
                        onClicked: {
                            root.selectIndex(index);
                            root.activateSelected(0);
                        }
                    }

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse
                        onWheel: event => root.moveSelection(event.angleDelta.y > 0 ? -1 : 1)
                    }
                }

                Footer {
                    Layout.fillWidth: true
                    glyph: root.selectedEntry === null ? "" : root.selectedEntry.module.glyph
                    title: root.selectedEntry === null ? "" : root.selectedEntry.module.title
                    toastText: root.toastText
                    primaryLabel: root.selectedActions.length > 0 ? root.selectedActions[0].label : ""
                    armedLabel: root.armed === null ? "" : root.armed.action.label
                    hasActions: root.selectedActions.length > 0
                    onPrimaryClicked: root.activateSelected(0)
                    onActionsClicked: root.openActions()
                }
            }
        }

        ActionsPanel {
            id: actionsPanel
            visible: root.actionsOpen
            anchors.right: parent.right
            anchors.rightMargin: VekronaTheme.space2
            anchors.bottom: parent.bottom
            anchors.bottomMargin: LauncherMetrics.footerHeight + VekronaTheme.borderHair + VekronaTheme.space1
            actions: root.selectedActions
            onChosen: action => {
                root.actionsOpen = false;
                root.requestAction(root.selectedEntry, action);
            }
            onDismissed: root.actionsOpen = false
        }
    }
}
