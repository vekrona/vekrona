import QtQuick
import QtQuick.Layouts
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    readonly property real menuWidth: 280 - 2 * VekronaTheme.space4

    icon: "keyboard"
    value: Keyboard.available && Keyboard.current ? Keyboard.current.code : "--"
    ariaName: "Keyboard layout: " + (Keyboard.current?.name ?? "unknown")
    visible: Keyboard.layouts.length > 1
    valueMinWidth: widestCode.advanceWidth

    // Right click is the one-handed switch; the wheel does nothing, so a trackpad brushing the bar never changes what you type.
    onClicked: bar.togglePopout(popout)
    onRightClicked: Keyboard.next()

    TextMetrics {
        id: widestCode
        font.family: VekronaTheme.fontSans
        font.pixelSize: VekronaTheme.type.label.size
        font.weight: VekronaTheme.type.label.weight
        font.letterSpacing: VekronaTheme.type.label.tracking * VekronaTheme.type.label.size
        text: Keyboard.layouts.reduce((widest, layout) => layout.code.length > widest.length ? layout.code : widest, "--")
    }

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null

        Repeater {
            model: Keyboard.layouts

            LayoutRow {
                required property var modelData
                required property int index

                Layout.minimumWidth: root.menuWidth
                layout: modelData
                current: index === Keyboard.activeIndex
                onClicked: {
                    Keyboard.select(index);
                    root.bar.openPopout = null;
                }
            }
        }

        RowLayout {
            visible: Keyboard.error !== ""
            Layout.fillWidth: true
            Layout.maximumWidth: root.menuWidth
            Layout.leftMargin: VekronaTheme.space2
            spacing: VekronaTheme.space1

            Pictogram {
                Layout.alignment: Qt.AlignTop
                name: "error"
                color: VekronaTheme.c.dangerInk
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                style: VekronaTheme.type.caption
                color: VekronaTheme.c.dangerInk
                text: "Could not read or switch the layout. Try again, or sign out and back in."
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: VekronaTheme.space2
            Layout.bottomMargin: VekronaTheme.space2
            implicitHeight: VekronaTheme.borderHair
            color: VekronaTheme.c.line
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: VekronaTheme.space2
            Layout.rightMargin: VekronaTheme.space2

            Label {
                Layout.fillWidth: true
                style: VekronaTheme.type.caption
                color: VekronaTheme.c.inkMuted
                text: "Next layout"
            }

            Label {
                style: VekronaTheme.type.mono
                font.family: VekronaTheme.fontMono
                text: "Hyper+Space"
            }
        }

        BarPill {
            Layout.fillWidth: true
            icon: "settings"
            value: "Change keyboard layouts"
            ariaName: "Change keyboard layouts, opens settings"
            onClicked: {
                root.bar.openPopout = null;
                Exec.detached(["qs", "-c", "vekrona-shell", "ipc", "call", "launcher", "settings", "keyboard"]);
            }
        }
    }
}
