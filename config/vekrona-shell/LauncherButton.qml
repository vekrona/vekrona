import "Vekrona"

BarPill {
    required property var launcher

    icon: "apps"
    ariaName: "Applications"
    onClicked: launcher.toggle()
}
