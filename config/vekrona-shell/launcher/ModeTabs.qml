import QtQuick
import "../Vekrona"
import "."

// The launcher's modes as a row of tabs under the search field, the active one filled. A tab opens its
// mode; the lit tab of an open mode does nothing, unless a sub-view is pushed: then it returns to the mode's
// list. The row is one keyboard stop: Tab and Escape hand focus back to the search field, Left and Right move
// between the tabs, Enter and Space open the focused one when released, so a held key opens it once.
FocusScope {
    id: root

    // The Launcher: its activeSlash marks the lit tab and its openMode(slash) is what a tab does.
    required property var launcher
    // The tabs by mode slash, left to right, in groups with a gap between them: "" is the root mode (Apps).
    // This is the one place that says which modes have a tab.
    readonly property var groups: [["", "calc", "search", "clip"], ["settings", "power"]]
    readonly property var tabs: buildTabs()
    // The mode whose tab is lit: Apps ("") for both of its modes, the root search and /apps.
    readonly property string litSlash: launcher.activeSlash === "apps" ? "" : launcher.activeSlash
    property int current: 0

    signal leave

    function describe(slash: string, startsGroup: bool): var {
        if (slash === "")
            return {
                slash: slash,
                glyph: "apps",
                label: "Apps",
                startsGroup: startsGroup
            };
        const module = launcher.moduleBySlash(slash);
        if (module === null)
            throw new Error("launcher: the tab /" + slash + " has no module");
        return {
            slash: slash,
            glyph: module.glyph,
            label: module.title,
            startsGroup: startsGroup
        };
    }

    function buildTabs(): var {
        const built = [];
        groups.forEach((group, groupIndex) => group.forEach((slash, position) => built.push(describe(slash, groupIndex > 0 && position === 0))));
        return built;
    }

    // Whether the key event types a character: it has text that is not a control character, and no shortcut modifier.
    function isTyped(event): bool {
        const shortcut = Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier;
        return event.text.length > 0 && event.text.charCodeAt(0) >= 0x20 && event.text.charCodeAt(0) !== 0x7f && (event.modifiers & shortcut) === 0;
    }

    function activate(slash: string): void {
        if (slash !== litSlash || launcher.viewStack.length > 0)
            launcher.openMode(slash);
        leave();
    }

    // Takes focus with the lit tab current, or the first one for a mode without a tab.
    function enter(): void {
        current = Math.max(0, tabs.findIndex(tab => tab.slash === litSlash));
        forceActiveFocus();
    }

    // The tabs as the launcher's test state reports them: {slash, active, x, y}, the centre of each square in the window.
    function placement(): var {
        return tabs.map((tab, index) => {
            const square = repeater.itemAt(index).square;
            const centre = square.mapToItem(null, square.width / 2, square.height / 2);
            return {
                slash: tab.slash,
                active: tab.slash === litSlash,
                x: Math.round(centre.x),
                y: Math.round(centre.y)
            };
        });
    }

    implicitHeight: row.implicitHeight + 2 * VekronaTheme.space2 + VekronaTheme.borderHair
    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Tab:
        case Qt.Key_Backtab:
        case Qt.Key_Escape:
            leave();
            break;
        case Qt.Key_Left:
            current = Math.max(0, current - 1);
            break;
        case Qt.Key_Right:
            current = Math.min(tabs.length - 1, current + 1);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            break;
        default:
            // A character is meant for the search field, whichever stop has the focus.
            if (!isTyped(event))
                return;
            launcher.typeText(event.text);
            leave();
            break;
        }
        event.accepted = true;
    }
    Keys.onReleased: event => {
        if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Space)
            return;
        if (!event.isAutoRepeat)
            activate(tabs[current].slash);
        event.accepted = true;
    }

    Row {
        id: row
        x: VekronaTheme.space4
        y: VekronaTheme.space2
        spacing: VekronaTheme.space2

        Repeater {
            id: repeater
            model: root.tabs

            delegate: Item {
                id: cell

                required property int index
                required property var modelData
                readonly property bool active: modelData.slash === root.litSlash
                readonly property real lead: modelData.startsGroup ? VekronaTheme.space6 : 0
                property alias square: square

                width: lead + LauncherMetrics.tabWidth
                height: tab.height

                Item {
                    id: tab

                    x: cell.lead
                    width: LauncherMetrics.tabWidth
                    height: VekronaTheme.sizeTarget + VekronaTheme.space1 + caption.implicitHeight

                    Accessible.role: Accessible.PageTab
                    Accessible.name: cell.modelData.label
                    Accessible.selected: cell.active

                    Rectangle {
                        id: square

                        anchors.horizontalCenter: parent.horizontalCenter
                        width: VekronaTheme.sizeTarget
                        height: VekronaTheme.sizeTarget
                        color: mouse.pressed ? VekronaTheme.c.surface3 : mouse.containsMouse ? VekronaTheme.c.surface2 : "transparent"
                        border.width: VekronaTheme.borderControl
                        border.color: VekronaTheme.c.line

                        Selection {
                            shown: cell.active
                        }

                        Pictogram {
                            anchors.centerIn: parent
                            name: cell.modelData.glyph
                            filled: cell.active
                        }

                        FocusRing {
                            shown: root.activeFocus && root.current === cell.index
                        }
                    }

                    Label {
                        id: caption

                        anchors.top: square.bottom
                        anchors.topMargin: VekronaTheme.space1
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        style: VekronaTheme.type.caption
                        text: cell.modelData.label
                    }

                    MouseArea {
                        id: mouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.current = cell.index;
                            root.activate(cell.modelData.slash);
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: VekronaTheme.borderHair
        color: VekronaTheme.c.line
    }
}
