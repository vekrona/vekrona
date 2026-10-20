import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.I3
import Quickshell.Io
import Quickshell.Wayland
import "../Vekrona"
import ".."
import "."
import "Ranker.js" as Ranker

// The one launcher: apps, commands, settings, calculator, clipboard history and the power commands,
// each a module (modules/*.qml). Opened by Super+Space and by `ipc call launcher toggleMode <mode>`.
PanelWindow {
    id: root

    readonly property int recentLimit: 6
    readonly property int sectionLimit: 5
    readonly property int toastMs: 3000

    property bool shown: false
    // The output the launcher is on: the focused one as it opened. Sway moves the focus with the pointer, so it is not
    // followed while the launcher is open.
    property var openScreen: null
    // The module whose mode is active (/calc), or null in root mode.
    property var modeModule: null
    // Pushed sub-views, innermost last: {title, viewId, module, savedQuery}.
    property var viewStack: []
    // {action, confirm} of the selected row while it waits for the confirming second Enter, else null.
    property var armed: null
    property bool actionsOpen: false
    // The row the Ctrl+K panel was opened on, whose actions it lists; null while the panel is closed.
    property var actionsEntry: null
    // Which Enter (0 primary, 1 Ctrl+Enter) came while no row was selectable and a module still had to answer, else -1.
    property int pendingActivation: -1
    property string toastText: ""
    // The list entries: {type: "header" | "empty", title} or {type: "row", module, result, synthetic}.
    property var rows: []
    property int selected: -1
    property int requestId: 0
    // By moduleId: the modules asked for the current request, those that have not answered it yet, and their
    // latest results. A module that has not answered keeps the results of the request before until it does, if that request
    // asked the same question (a module that announces a change of its static results).
    property var queried: ({})
    property var awaiting: ({})
    property var collected: ({})
    // What `collected` answers: the kind of request (the mode and the sub-view) and the query text. Results are kept for a module
    // that has not answered yet only while both are the same, since a row that answered another question must not be activated.
    property string collectedContext: ""
    property string collectedText: ""

    readonly property string activeSlash: modeModule === null ? "" : modeModule.slash
    readonly property var moduleList: modules.all
    // The selected result row, or null while nothing is selected (headers and the "No matches" line cannot be).
    readonly property var selectedEntry: selected >= 0 && selected < rows.length && rows[selected].type === "row" ? rows[selected] : null
    readonly property string selectedId: selectedEntry === null ? "" : selectedEntry.result.id
    readonly property var selectedActions: selectedEntry === null ? [] : selectedEntry.result.actions ?? []
    readonly property var panelActions: actionsEntry === null ? [] : actionsEntry.result.actions ?? []
    readonly property string escapeStep: armed !== null ? "disarm" : viewStack.length > 0 ? "back" : modeModule !== null ? "leaveMode" : search.text !== "" ? "clear" : "close"
    readonly property string escapeLabel: selectedEntry !== null ? "" : ({
            "disarm": "",
            "back": "Back",
            "leaveMode": "Leave mode",
            "clear": "Clear",
            "close": "Close"
        })[escapeStep]
    readonly property var footerModule: selectedEntry !== null ? selectedEntry.module : viewStack.length > 0 ? viewStack[viewStack.length - 1].module : modeModule
    readonly property string breadcrumb: viewStack.length === 0 ? "" : [viewStack[0].module.title].concat(viewStack.map(frame => frame.title)).join(" › ")
    readonly property real listContentHeight: rows.reduce((sum, entry) => sum + LauncherMetrics.heightOf(entry), 0)
    // The search field's middle sits on the screen's middle; the list takes the room below it.
    readonly property real screenWidth: openScreen?.width ?? 0
    readonly property real screenHeight: openScreen?.height ?? 0
    readonly property real panelTop: Math.round(screenHeight / 2 - VekronaTheme.borderHair - LauncherMetrics.searchHeight / 2)
    // The compositor centres the window across the output, so this is where its left edge lands.
    readonly property real panelLeft: Math.round((screenWidth - width) / 2)
    readonly property real chromeHeight: LauncherMetrics.searchHeight + strip.implicitHeight + crumb.implicitHeight + LauncherMetrics.footerHeight + 2 * VekronaTheme.borderHair
    readonly property real listLimit: Math.max(LauncherMetrics.minRows * LauncherMetrics.rowHeight, Math.min(LauncherMetrics.maxRows * LauncherMetrics.rowHeight, screenHeight - panelTop - chromeHeight - VekronaTheme.space6))

    function toggle(): void {
        if (shown)
            closeLauncher();
        else
            openMode("");
    }

    // Opens the launcher in settings mode and pushes the settings subview `viewId`. The bar and the IPC both come through here.
    function openSettings(viewId: string): void {
        const settingsModule = moduleList.find(candidate => candidate.moduleId === "settings");
        if (settingsModule === undefined) {
            console.error("launcher: settings module not found");
            return;
        }
        if (!Object.prototype.hasOwnProperty.call(settingsModule.views, viewId)) {
            console.error("launcher: unknown settings view '" + viewId + "'");
            return;
        }
        openMode("settings");
        pushView(settingsModule, settingsModule.views[viewId]);
    }

    // Closes when the mode of the slash keyword `slash` ("" is the root search) is already open, else opens in it. A key
    // binding and a click on a bar button both reach the closing branch: the click catcher starts below the bar, so the
    // bar stays clickable and the click reaches its button, not the catcher.
    function toggleMode(slash: string): void {
        if (shown && activeSlash === slash)
            closeLauncher();
        else
            openMode(slash);
    }

    // The output Sway has focused, else the first one.
    function focusedScreen(): var {
        const name = I3.focusedMonitor?.name;
        return Quickshell.screens.find(output => output.name === name) ?? Quickshell.screens[0] ?? null;
    }

    // Opens in root mode, or in the mode of the slash keyword `slash`.
    function openMode(slash: string): void {
        if (!shown)
            openScreen = focusedScreen();
        modeModule = null;
        viewStack = [];
        armed = null;
        actionsOpen = false;
        dismissToast();
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

    function dismissToast(): void {
        toastText = "";
        toastTimer.stop();
    }

    // The module whose mode is the slash keyword `slash`, or null.
    function moduleBySlash(slash: string): var {
        return moduleList.find(module => module.slash === slash) ?? null;
    }

    function moduleOf(resultId: string): var {
        const owner = resultId.slice(0, resultId.indexOf(":"));
        return moduleList.find(module => module.moduleId === owner) ?? null;
    }

    // Types text into the search field at the cursor, for the parts of the launcher that do not hold the focus.
    function typeText(text: string): void {
        search.insert(search.cursorPosition, text);
    }

    // Sets the search field; its change handler then queries.
    function applyQuery(value: string): void {
        if (search.text === value) {
            armed = null;
            refresh(false);
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
        const module = moduleBySlash(slash);
        if (module === null) {
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
        refresh(false);
    }

    // Enters the sub-view `push` ({title, viewId}) of the module, on top of whatever is open.
    function pushView(module: var, push: var): void {
        viewStack = viewStack.concat([
            {
                title: push.title,
                viewId: push.viewId,
                module: module,
                savedQuery: search.text
            }
        ]);
        armed = null;
        actionsOpen = false;
        search.forceActiveFocus();
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
            const module = typed === null ? null : moduleBySlash(typed[1]);
            if (module !== null) {
                enterModule(module, typed[2]);
                return;
            }
        }
        refresh(false);
    }

    // The modules whose slash keyword starts with what follows the "/" being typed.
    function modeSuggestions(): var {
        if (modeModule !== null || viewStack.length > 0 || !search.text.startsWith("/") || /\s/.test(search.text))
            return [];
        const typed = search.text.slice(1).toLowerCase();
        return moduleList.filter(module => module.slash !== "" && module.slash.startsWith(typed));
    }

    // The global modules that own a frecent result.
    function recentOwners(): var {
        const owners = Object.keys(frecency.entries).map(id => moduleOf(id));
        return moduleList.filter(module => module.global && owners.includes(module));
    }

    // The modules a new request asks.
    function targets(): var {
        if (viewStack.length > 0)
            return [viewStack[viewStack.length - 1].module];
        if (modeModule !== null)
            return [modeModule];
        if (modeSuggestions().length > 0)
            return [];
        if (search.text.trim() === "")
            return recentOwners();
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

    function notifyOpened(): void {
        for (const module of moduleList) {
            try {
                module.opened();
            } catch (e) {
                reportModuleFailure(module, e);
            }
        }
    }

    function notifyClosed(): void {
        for (const module of moduleList) {
            try {
                module.closed();
            } catch (e) {
                reportModuleFailure(module, e);
            }
        }
    }

    function reportModuleFailure(module: var, error: var): void {
        console.error("launcher: module " + module.moduleId + " failed:", error);
        showToast(module.title + " failed: " + error);
    }

    function contextKey(): string {
        const frame = viewStack.length > 0 ? viewStack[viewStack.length - 1] : null;
        return (modeModule === null ? "" : modeModule.moduleId) + "|" + (frame === null ? "" : frame.module.moduleId + ":" + frame.viewId);
    }

    // Asks the modules again. A new query (not keepSelection) selects the first row and forgets a waiting Enter.
    function refresh(keepSelection: bool): void {
        const reqId = ++requestId;
        const context = contextKey();
        const previous = context === collectedContext && search.text === collectedText ? collected : {};
        queried = {};
        awaiting = {};
        collected = {};
        collectedContext = context;
        collectedText = search.text;
        if (!keepSelection)
            pendingActivation = -1;
        for (const module of targets()) {
            const id = module.moduleId;
            queried[id] = true;
            const results = ask(module, reqId);
            if (results !== null) {
                collected[id] = results;
            } else {
                awaiting[id] = true;
                if (previous[id] !== undefined)
                    collected[id] = previous[id];
            }
        }
        rebuild(keepSelection);
    }

    function isAwaited(module: var, reqId: int): bool {
        return reqId === requestId && queried[module.moduleId] === true;
    }

    // A module delivered its results; those for an older request are dropped.
    function deliver(module: var, reqId: int, results: var): void {
        if (!isAwaited(module, reqId))
            return;
        if (Array.isArray(results))
            store(module, results);
        else
            deliverFailure(module, reqId, new Error("expected an array of results, got " + typeof results));
    }

    // A module could not answer: the failure is reported and the request counts as answered, with no results.
    function deliverFailure(module: var, reqId: int, error: var): void {
        if (!isAwaited(module, reqId))
            return;
        reportModuleFailure(module, error);
        store(module, []);
    }

    function store(module: var, results: var): void {
        collected[module.moduleId] = results;
        delete awaiting[module.moduleId];
        rebuild(true);
        runPendingActivation();
    }

    // Runs the Enter that came before any row could take it, once a delivery made a row selectable.
    function runPendingActivation(): void {
        if (pendingActivation < 0)
            return;
        if (selectedEntry !== null) {
            const which = pendingActivation;
            pendingActivation = -1;
            activateSelected(which);
        } else if (!isWaiting()) {
            pendingActivation = -1;
        }
    }

    function isWaiting(): bool {
        return Object.keys(awaiting).length > 0;
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

    // The most frecent of the results the modules list for an empty query.
    function recentRows(): var {
        const found = {};
        for (const module of moduleList) {
            for (const result of collected[module.moduleId] ?? [])
                found[result.id] = rowEntry(module, result);
        }
        const ids = Ranker.recentIds(frecency.entries, Date.now(), recentLimit, id => found[id] !== undefined);
        const rowsFound = ids.map(id => found[id]);
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
        const waiting = isWaiting();
        if (viewStack.length > 0)
            return singleRows(viewStack[viewStack.length - 1].module, text, waiting);
        if (modeModule !== null)
            return singleRows(modeModule, text, waiting);
        return text === "" ? recentRows() : rootRows(text, waiting);
    }

    // The index of the row nearest to `index`, or -1 when `entries` has none.
    function nearestRow(entries: var, index: int): int {
        if (entries.length === 0)
            return -1;
        const start = Math.max(0, Math.min(index, entries.length - 1));
        for (let distance = 0; distance < entries.length; distance++) {
            for (const candidate of [start - distance, start + distance]) {
                if (candidate >= 0 && candidate < entries.length && entries[candidate].type === "row")
                    return candidate;
            }
        }
        return -1;
    }

    // Replaces the list. With keepSelection the selected result stays selected if it is still there, else
    // the row nearest to where it was is; without, the first row is.
    function rebuild(keepSelection: bool): void {
        const next = buildRows();
        let index = -1;
        if (keepSelection && selectedId !== "")
            index = next.findIndex(entry => entry.type === "row" && entry.result.id === selectedId);
        if (index < 0)
            index = nearestRow(next, keepSelection ? selected : 0);
        showList(next, index);
        Qt.callLater(revealSelected);
    }

    // The one place that sets the list and the selection: choosing another result disarms and closes the panel.
    function showList(nextRows: var, nextSelected: int): void {
        const nextId = nextSelected >= 0 ? nextRows[nextSelected].result.id : "";
        if (nextId !== selectedId) {
            armed = null;
            actionsOpen = false;
        }
        rows = nextRows;
        selected = nextSelected;
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
        showList(rows, index);
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
        if (entry === null) {
            if (isWaiting())
                pendingActivation = which;
            return;
        }
        if (armed !== null) {
            const action = armed.action;
            armed = null;
            perform(entry, action);
            return;
        }
        if (which < selectedActions.length)
            requestAction(entry, selectedActions[which]);
    }

    // Runs the action, unless it is destructive: that only arms the row, and the next Enter runs it.
    function requestAction(entry: var, action: var): void {
        if (action.destructive !== true) {
            perform(entry, action);
            return;
        }
        actionsOpen = false;
        armed = {
            action: action,
            confirm: action.confirm ?? "Press Enter again to " + action.label.toLowerCase()
        };
    }

    // The action picked in the Ctrl+K panel, for the row the panel was opened on.
    function chooseAction(action: var): void {
        const entry = actionsEntry;
        actionsOpen = false;
        if (entry === null) {
            console.error("launcher: the actions panel chose '" + action.id + "' with no row open");
            showToast("Couldn’t run " + action.label + ": its row is gone");
            return;
        }
        requestAction(entry, action);
    }

    // Opens a web address in the default browser. Only http and https addresses: xdg-open would open a file, run a handler of
    // any scheme, or read an address that starts with "-" as an option, and the addresses come from the user's history.
    function openUrl(url: string): void {
        if (!/^https?:\/\//.test(url))
            throw new Error("only http and https addresses are opened, not " + JSON.stringify(url));
        Exec.detached(["xdg-open", url], Exec.home);
    }

    function perform(entry: var, action: var): void {
        if (!entry.synthetic)
            frecency.record(entry.result.id);
        try {
            if (action.exec !== undefined) {
                Exec.detached(action.exec, action.directory ?? Exec.home);
                closeLauncher();
            } else if (action.copy !== undefined) {
                Exec.copy(action.copy);
                closeLauncher();
            } else if (action.url !== undefined) {
                openUrl(action.url);
                closeLauncher();
            } else if (action.push !== undefined) {
                pushView(entry.module, action.push);
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
        switch (escapeStep) {
        case "disarm":
            armed = null;
            break;
        case "back":
            popView();
            break;
        case "leaveMode":
            exitMode();
            break;
        case "clear":
            applyQuery("");
            break;
        case "close":
            closeLauncher();
            break;
        }
    }

    function openActions(): void {
        if (selectedEntry === null || selectedActions.length === 0)
            return;
        armed = null;
        actionsEntry = selectedEntry;
        actionsOpen = true;
    }

    function handleTab(backwards: bool): void {
        if (!backwards && modeSuggestions().length > 0)
            activateSelected(0);
        else
            strip.enter();
    }

    function handleKey(event): void {
        pendingActivation = -1;
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
    // The window is the panel and nothing else: opaque, hung from the top edge at panelTop, and centred across by the
    // compositor because it has no left or right anchor. A click elsewhere is caught by the Catcher below, which closes
    // the launcher; Escape and the toggle shortcut close it too.
    screen: openScreen
    color: VekronaTheme.c.surface1
    anchors.top: true
    margins.top: panelTop
    implicitWidth: LauncherMetrics.panelWidth
    implicitHeight: column.implicitHeight + 2 * VekronaTheme.borderHair
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
            KeyboardSurface.claim(root);
            search.forceActiveFocus();
            notifyOpened();
        } else {
            requestId++;
            armed = null;
            actionsOpen = false;
            pendingActivation = -1;
            collected = {};
            collectedContext = "";
            collectedText = "";
            notifyClosed();
        }
    }
    onActionsOpenChanged: {
        if (actionsOpen) {
            Qt.callLater(actionsPanel.start);
        } else {
            actionsEntry = null;
            search.forceActiveFocus();
        }
    }

    IpcHandler {
        target: "launcher"

        function toggle(): void {
            root.toggle();
        }

        // Opens in the mode of the slash keyword `mode` ("" is the root search); asked again while that mode is open, it closes.
        function toggleMode(mode: string): void {
            root.toggleMode(mode);
        }

        // Opens the launcher in settings mode and pushes the settings subview with the given viewId.
        function settings(viewId: string): void {
            root.openSettings(viewId);
        }

        // The launcher's state as compact JSON. This is a seam for the tests (tests/lib.sh reads it), and it hands the typed
        // query to any process of the user that asks over IPC: {open, mode, query, view, selectedId, armed, actionsOpen, rows, empty,
        // tabs}. A tab is {slash, active, x, y}: its mode, whether it is lit, and the centre of its square in screen pixels.
        // The window is only the panel, so the tabs' window coordinates are moved by where the panel sits on the output.
        function state(): string {
            return JSON.stringify({
                open: root.shown,
                mode: root.activeSlash,
                query: search.text,
                view: root.breadcrumb,
                selectedId: root.selectedId,
                armed: root.armed !== null,
                actionsOpen: root.actionsOpen,
                rows: root.rows.filter(entry => entry.type === "row").length,
                empty: root.rows.some(entry => entry.type === "empty"),
                tabs: strip.placement().map(tab => Object.assign({}, tab, {
                    x: tab.x + root.panelLeft,
                    y: tab.y + root.panelTop
                }))
            });
        }
    }

    QtObject {
        id: api

        function pushView(moduleId: string, push: var): void {
            const module = root.moduleList.find(candidate => candidate.moduleId === moduleId);
            if (module === undefined)
                throw new Error("no module has the id " + moduleId);
            root.pushView(module, push);
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

            function onFailed(reqId: int, error: var): void {
                root.deliverFailure(modelData, reqId, error);
            }

            function onChanged(): void {
                if (root.shown)
                    root.refresh(true);
            }
        }
    }

    Timer {
        id: toastTimer
        interval: root.toastMs
        onTriggered: root.dismissToast()
    }

    // Closes the launcher on a click anywhere below the bar, which stays clickable.
    Catcher {
        targetScreen: root.openScreen
        active: root.shown
        onDismissed: root.closeLauncher()
    }

    // Another surface that grabs the keyboard, the notification centre or a popout, would fight with this one over it.
    Connections {
        target: KeyboardSurface

        function onClaimed(owner: var): void {
            if (owner !== root)
                root.closeLauncher();
        }
    }

    // The window takes a new size only after a round trip to the compositor, and the list changes the size with every
    // keystroke. Everything inside is therefore sized from the implicit size, not from the window: a layout that filled
    // the old window would recenter its shrunken content in it.
    Rectangle {
        width: root.implicitWidth
        height: root.implicitHeight
        color: "transparent"
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.line

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

                ModeTabs {
                    id: strip
                    Layout.fillWidth: true
                    launcher: root
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
                        armedText: root.armed !== null && index === root.selected ? root.armed.confirm : ""
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
                    glyph: root.footerModule === null ? "" : root.footerModule.glyph
                    title: root.footerModule === null ? "" : root.footerModule.title
                    escapeLabel: root.escapeLabel
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
            actions: root.panelActions
            onChosen: action => root.chooseAction(action)
            onDismissed: root.actionsOpen = false
        }
    }
}
