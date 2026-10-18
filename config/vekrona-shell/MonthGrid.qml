import QtQuick
import QtQuick.Layouts
import "Vekrona"

// A month with arrows to the months around it. Without `interactive` it only shows the month; with it, the days between
// `earliest` and `latest` can be clicked and the others are dimmed.
ColumnLayout {
    id: root

    // The midnight that `monthOffset` counts months from.
    required property date today
    // The day drawn as selected and in bold, as a Date or null for none.
    property var highlighted: null
    // The days that can be picked, as midnight Dates, or null for no limit.
    property var earliest: null
    property var latest: null
    property bool interactive: false
    property int monthOffset: 0
    readonly property date shownMonth: new Date(today.getFullYear(), today.getMonth() + monthOffset, 1)
    readonly property int leadingBlanks: (shownMonth.getDay() + 6) % 7
    readonly property int daysInMonth: new Date(shownMonth.getFullYear(), shownMonth.getMonth() + 1, 0).getDate()

    // Emitted with the midnight of a picked day.
    signal picked(date day)

    function monthsAfterToday(date: date): int {
        return (date.getFullYear() - today.getFullYear()) * 12 + date.getMonth() - today.getMonth();
    }

    // Shows the month that holds `date`.
    function showMonthOf(date: date): void {
        monthOffset = monthsAfterToday(date);
    }

    function dayAt(day: int): date {
        return new Date(shownMonth.getFullYear(), shownMonth.getMonth(), day);
    }

    function isPickable(day: date): bool {
        return (earliest === null || day >= earliest) && (latest === null || day <= latest);
    }

    function isHighlighted(day: date): bool {
        return highlighted !== null && day.getTime() === new Date(highlighted.getFullYear(), highlighted.getMonth(), highlighted.getDate()).getTime();
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: VekronaTheme.space2

        BarPill {
            icon: "chevron_left"
            enabled: root.earliest === null || root.monthOffset > root.monthsAfterToday(root.earliest)
            ariaName: "Previous month"
            onClicked: root.monthOffset--
        }

        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            style: VekronaTheme.type.title
            text: Qt.locale().monthName(root.shownMonth.getMonth(), Locale.LongFormat) + " " + root.shownMonth.getFullYear()
        }

        BarPill {
            icon: "chevron_right"
            enabled: root.latest === null || root.monthOffset < root.monthsAfterToday(root.latest)
            ariaName: "Next month"
            onClicked: root.monthOffset++
        }
    }

    GridLayout {
        Layout.alignment: Qt.AlignHCenter
        columns: 7
        columnSpacing: 0
        rowSpacing: 0

        Repeater {
            model: 7

            Label {
                required property int index

                Layout.preferredWidth: VekronaTheme.sizeTarget
                horizontalAlignment: Text.AlignHCenter
                color: VekronaTheme.c.inkMuted
                style: VekronaTheme.type.caption
                text: Qt.locale().dayName((index + 1) % 7, Locale.NarrowFormat)
            }
        }

        Repeater {
            model: root.leadingBlanks + root.daysInMonth

            Item {
                id: cell

                required property int index
                readonly property int day: index - root.leadingBlanks + 1
                readonly property bool blank: day < 1
                readonly property date date: root.dayAt(day)
                readonly property bool pickable: !blank && root.isPickable(date)
                readonly property bool current: !blank && root.isHighlighted(date)

                Layout.preferredWidth: VekronaTheme.sizeTarget
                Layout.preferredHeight: VekronaTheme.sizeTarget

                Rectangle {
                    anchors.fill: parent
                    visible: root.interactive && cell.pickable
                    color: mouse.pressed ? VekronaTheme.c.surface3 : mouse.containsMouse ? VekronaTheme.c.surface2 : "transparent"
                }

                Selection {
                    shown: cell.current
                }

                Label {
                    anchors.centerIn: parent
                    visible: !cell.blank
                    color: cell.pickable ? VekronaTheme.c.ink : VekronaTheme.c.inkDisabled
                    style: cell.current ? VekronaTheme.type.bodyStrong : VekronaTheme.type.body
                    text: cell.day
                }

                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    enabled: root.interactive && cell.pickable
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    Accessible.role: Accessible.Button
                    Accessible.name: Qt.formatDate(cell.date, "dddd d MMMM")
                    onClicked: root.picked(cell.date)
                }
            }
        }
    }
}
