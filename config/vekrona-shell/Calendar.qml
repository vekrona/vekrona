import QtCore
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Vekrona"

Row {
    id: root

    required property var bar
    readonly property string calendarPath: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/vekrona/calendar.json"
    readonly property int labelMaxChars: 24
    readonly property int agendaMaxHeight: VekronaTheme.sizeTarget * 8
    property var calendar: null
    property int monthOffset: 0
    readonly property var events: calendar?.events ?? []
    readonly property date today: new Date(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate())
    readonly property date shownMonth: new Date(today.getFullYear(), today.getMonth() + monthOffset, 1)
    readonly property int leadingBlanks: (shownMonth.getDay() + 6) % 7
    readonly property int daysInMonth: new Date(shownMonth.getFullYear(), shownMonth.getMonth() + 1, 0).getDate()
    readonly property var upcoming: nextEvent(events, clock.date)

    function parse(stamp: string): date {
        const [year, month, day] = stamp.slice(0, 10).split("-").map(Number);
        const [hour, minute] = stamp.length > 10 ? stamp.slice(11).split(":").map(Number) : [0, 0];
        return new Date(year, month - 1, day, hour, minute);
    }

    function nextEvent(list, now: date) {
        const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
        return list.find(event => !event.allDay && parse(event.end) > now && parse(event.start) < midnight) ?? null;
    }

    function elide(text: string): string {
        return text.length > labelMaxChars ? text.slice(0, labelMaxChars - 1) + "…" : text;
    }

    function byDay(list) {
        const days = [];
        for (const event of list) {
            const day = event.start.slice(0, 10);
            if (days.length === 0 || days[days.length - 1].day !== day)
                days.push({ day: day, events: [] });
            days[days.length - 1].events.push(event);
        }
        return days;
    }

    function isToday(day: int): bool {
        return monthOffset === 0 && day === today.getDate();
    }

    BarPill {
        visible: root.upcoming !== null
        value: root.upcoming ? root.elide(root.upcoming.start.slice(11) + " " + root.upcoming.title) : ""
        ariaName: "Next event"
        onClicked: root.bar.togglePopout(popout)
    }

    BarPill {
        id: dateTime
        value: Qt.formatDateTime(clock.date, "ddd d MMM HH:mm")
        ariaName: "Calendar"
        onClicked: root.bar.togglePopout(popout)
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    FileView {
        path: root.calendarPath
        watchChanges: true
        onLoaded: root.calendar = JSON.parse(text())
        onLoadFailed: error => {
            root.calendar = null;
            if (error !== FileViewError.FileNotFound)
                console.error("cannot read " + root.calendarPath + ": " + error);
        }
        onFileChanged: reload()
    }

    Popout {
        id: popout
        anchorItem: dateTime
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null
        onOpenChanged: if (!open)
            root.monthOffset = 0

        RowLayout {
            Layout.preferredWidth: VekronaTheme.sizeTarget * 10
            spacing: VekronaTheme.space2

            BarPill {
                icon: "chevron_left"
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
                    required property int index
                    readonly property int day: index - root.leadingBlanks + 1

                    Layout.preferredWidth: VekronaTheme.sizeTarget
                    Layout.preferredHeight: VekronaTheme.sizeTarget

                    Selection {
                        shown: root.isToday(parent.day)
                    }

                    Label {
                        anchors.centerIn: parent
                        visible: parent.day >= 1
                        style: root.isToday(parent.day) ? VekronaTheme.type.bodyStrong : VekronaTheme.type.body
                        text: parent.day
                    }
                }
            }
        }

        Label {
            visible: root.calendar?.configured === false
            Layout.maximumWidth: VekronaTheme.sizeTarget * 10
            wrapMode: Text.Wrap
            color: VekronaTheme.c.inkMuted
            style: VekronaTheme.type.body
            text: "No calendars yet. See docs/calendar.md."
        }

        Label {
            visible: root.calendar?.configured === true && root.events.length === 0
            color: VekronaTheme.c.inkMuted
            style: VekronaTheme.type.body
            text: "No events in the next 31 days."
        }

        Flickable {
            visible: root.events.length > 0
            Layout.preferredWidth: VekronaTheme.sizeTarget * 10
            Layout.preferredHeight: Math.min(agenda.implicitHeight, root.agendaMaxHeight)
            contentWidth: width
            contentHeight: agenda.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            ColumnLayout {
                id: agenda
                width: parent.width
                spacing: VekronaTheme.space2

                Repeater {
                    model: root.byDay(root.events)

                    ColumnLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 0

                        Label {
                            style: VekronaTheme.type.bodyStrong
                            text: Qt.formatDate(root.parse(modelData.day), "ddd d MMM")
                        }

                        Repeater {
                            model: modelData.events

                            RowLayout {
                                required property var modelData

                                Layout.fillWidth: true
                                spacing: VekronaTheme.space2

                                Label {
                                    Layout.preferredWidth: VekronaTheme.sizeTarget * 2
                                    color: VekronaTheme.c.inkMuted
                                    style: VekronaTheme.type.body
                                    text: modelData.allDay ? "All day" : modelData.start.slice(11)
                                }

                                Label {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    style: VekronaTheme.type.body
                                    text: modelData.title
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
