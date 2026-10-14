import QtCore
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "Vekrona"

BarPill {
    id: root

    required property var bar
    readonly property string weatherPath: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/vekrona/weather.json"
    property var report: null
    readonly property var current: report?.current ?? null
    readonly property var today: report?.daily?.[0] ?? null

    function glyph(code: int, isDay: bool): string {
        if (code === 0)
            return isDay ? "clear_day" : "clear_night";
        if (code <= 3)
            return isDay ? "partly_cloudy_day" : "partly_cloudy_night";
        if (code === 45 || code === 48)
            return "foggy";
        if (code >= 95)
            return "thunderstorm";
        if ((code >= 71 && code <= 77) || code === 85 || code === 86)
            return "weather_snowy";
        return "rainy";
    }

    function degrees(value: real): string {
        return Math.round(value) + " °C";
    }

    function range(day): string {
        return Math.round(day.max) + " / " + Math.round(day.min) + " °C";
    }

    function weekday(isoDate: string): string {
        const [year, month, day] = isoDate.split("-").map(Number);
        return Qt.locale().dayName(new Date(year, month - 1, day).getDay(), Locale.ShortFormat);
    }

    visible: report !== null
    icon: current && !report.error ? glyph(current.weather_code, current.is_day) : "cloud_off"
    value: current ? degrees(current.temperature) : ""
    widestValue: "-88 °C"
    ariaName: "Weather"
    onClicked: bar.togglePopout(popout)

    FileView {
        path: root.weatherPath
        watchChanges: true
        onLoaded: root.report = JSON.parse(text())
        onLoadFailed: error => {
            root.report = null;
            if (error !== FileViewError.FileNotFound)
                console.error("cannot read " + root.weatherPath + ": " + error);
        }
        onFileChanged: reload()
    }

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null

        Label {
            style: VekronaTheme.type.title
            text: root.report?.location?.name ?? ""
        }

        Label {
            visible: root.today !== null
            style: VekronaTheme.type.body
            text: root.today ? "Today " + root.range(root.today) : ""
        }

        Repeater {
            model: root.report?.daily ?? []

            RowLayout {
                required property var modelData

                spacing: VekronaTheme.space2

                Label {
                    Layout.preferredWidth: VekronaTheme.sizeTarget
                    style: VekronaTheme.type.body
                    text: root.weekday(modelData.date)
                }

                Pictogram {
                    name: root.glyph(modelData.weather_code, true)
                }

                Label {
                    style: VekronaTheme.type.body
                    text: root.range(modelData)
                }
            }
        }

        Label {
            visible: (root.report?.error ?? null) !== null
            Layout.maximumWidth: VekronaTheme.sizeTarget * 8
            wrapMode: Text.Wrap
            color: VekronaTheme.c.dangerInk
            style: VekronaTheme.type.body
            text: root.report?.error ?? ""
        }

        Label {
            style: VekronaTheme.type.caption
            color: VekronaTheme.c.inkMuted
            text: "Weather data by Open-Meteo.com"
        }
    }
}
