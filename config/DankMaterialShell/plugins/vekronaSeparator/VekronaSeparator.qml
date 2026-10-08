import QtQuick
import qs.Common
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property real breathingRoom: Math.max(0, (barConfig?.pillPadding ?? 0) - (barConfig?.widgetPadding ?? 0)) / 2

    horizontalBarPill: Component {
        Item {
            implicitWidth: 1 + 2 * root.breathingRoom
            implicitHeight: root.widgetThickness

            Rectangle {
                width: 1
                height: root.barThickness * 0.6
                anchors.centerIn: parent
                color: Theme.outlineVariant
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: root.widgetThickness
            implicitHeight: 1

            Rectangle {
                width: root.barThickness * 0.6
                height: 1
                anchors.centerIn: parent
                color: Theme.outlineVariant
            }
        }
    }
}
