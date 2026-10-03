import QtQuick
import qs.Common
import qs.Services
import qs.Modules.DankBar.Widgets

// DMS styles (fontScale, outline, noBackground) only per bar, so the stock pill gets a derived barConfig.
Item {
    id: root

    property string kind: ""

    property var axis: null
    property string section: "center"
    property var parentScreen: null
    property real widgetThickness: 30
    property real barThickness: 48
    property real barSpacing: 4
    property var barConfig: null
    property var blurBarWindow: null
    property var widgetData: null
    property bool isFirst: false
    property bool isLast: false
    property bool isLeftBarEdge: false
    property bool isRightBarEdge: false
    property bool isTopBarEdge: false
    property bool isBottomBarEdge: false
    property real sectionSpacing: 0
    property real crossEdgeExtension: 0

    readonly property var kinds: ({
            "clock": {
                "component": clockPill,
                "tab": "overview"
            },
            "weather": {
                "component": weatherPill,
                "tab": "weather"
            }
        })
    readonly property var emphasizedBarConfig: Object.assign({}, barConfig, {
        "fontScale": 1.5,
        "noBackground": false,
        "widgetTransparency": 0,
        "widgetOutlineEnabled": true,
        "widgetOutlineThickness": 1,
        "widgetOutlineColor": "surfaceText",
        "widgetOutlineOpacity": 0.35
    })
    readonly property int barPosition: axis?.edge === "left" ? 2 : (axis?.edge === "right" ? 3 : (axis?.edge === "top" ? 0 : 1))

    // The section spaces widgets by 2px when the bar has no background, so outlined pills would touch.
    readonly property real edgeMargin: Math.max(0, ((barConfig?.spacing ?? 0) - sectionSpacing) / 2)

    width: pillLoader.item?.visible ? pillLoader.item.width + 2 * edgeMargin : 0
    height: pillLoader.item?.visible ? pillLoader.item.height : 0

    Component.onCompleted: {
        if (!kinds[kind])
            console.error("VekronaEmphasizedPill: unknown kind", JSON.stringify(kind));
    }

    function openDash() {
        const loader = PopoutService.dankDashPopoutLoader;
        if (!loader) {
            console.error("VekronaEmphasizedPill: PopoutService.dankDashPopoutLoader is missing, cannot open DankDash");
            return;
        }
        const open = () => root.finishOpenDash(loader.item);
        loader.active = true;
        if (loader.item) {
            open();
            return;
        }
        const onLoaded = () => {
            loader.loaded.disconnect(onLoaded);
            open();
        };
        loader.loaded.connect(onLoaded);
    }

    function finishOpenDash(popout) {
        const tab = kinds[kind].tab;
        const screen = parentScreen;
        if (popout.setBarContext)
            popout.setBarContext(barPosition, barConfig?.bottomGap ?? 0);
        popout.triggerScreen = screen;
        const globalPos = pillLoader.item.visualContent.mapToItem(null, 0, 0);
        const pos = SettingsData.getPopupTriggerPosition(globalPos, screen, barThickness, pillLoader.item.visualWidth, barSpacing, barPosition, barConfig);
        popout.setTriggerPosition(pos.x, pos.y, pos.width, section, screen, barPosition, barThickness, barSpacing, barConfig);
        popout.requestTab(tab);
        PopoutManager.requestPopout(popout, undefined, (barConfig?.id ?? "default") + "-" + section + "-" + tab);
    }

    Loader {
        id: pillLoader
        x: root.edgeMargin
        sourceComponent: root.kinds[root.kind]?.component
    }

    Component {
        id: clockPill

        Clock {
            axis: root.axis
            section: root.section
            parentScreen: root.parentScreen
            widgetThickness: root.widgetThickness
            barThickness: root.barThickness
            barSpacing: root.barSpacing
            barConfig: root.emphasizedBarConfig
            blurBarWindow: root.blurBarWindow
            widgetData: root.widgetData
            isFirst: root.isFirst
            isLast: root.isLast
            isLeftBarEdge: root.isLeftBarEdge
            isRightBarEdge: root.isRightBarEdge
            isTopBarEdge: root.isTopBarEdge
            isBottomBarEdge: root.isBottomBarEdge
            sectionSpacing: root.sectionSpacing
            crossEdgeExtension: root.crossEdgeExtension
            onClockClicked: root.openDash()
        }
    }

    Component {
        id: weatherPill

        Weather {
            axis: root.axis
            section: root.section
            parentScreen: root.parentScreen
            widgetThickness: root.widgetThickness
            barThickness: root.barThickness
            barSpacing: root.barSpacing
            barConfig: root.emphasizedBarConfig
            blurBarWindow: root.blurBarWindow
            isFirst: root.isFirst
            isLast: root.isLast
            isLeftBarEdge: root.isLeftBarEdge
            isRightBarEdge: root.isRightBarEdge
            isTopBarEdge: root.isTopBarEdge
            isBottomBarEdge: root.isBottomBarEdge
            sectionSpacing: root.sectionSpacing
            crossEdgeExtension: root.crossEdgeExtension
            onClicked: root.openDash()
        }
    }
}
