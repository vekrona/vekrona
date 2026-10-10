import QtQuick
import "Vekrona"
import "."

// The current player: track art, title, "artist · player" and the transport buttons.
// Clicking the art or the text (not a button) shows the player's window.
Item {
    id: root

    readonly property real textX: VekronaTheme.space2 + VekronaTheme.iconXl + VekronaTheme.space3

    signal raised

    implicitHeight: VekronaTheme.iconXl

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: "Show " + (Audio.player?.identity ?? "")
        Keys.onReturnPressed: root.show()
        Keys.onSpacePressed: root.show()
        onClicked: root.show()

        Rectangle {
            anchors.fill: parent
            color: area.pressed ? VekronaTheme.c.surface3
                 : area.containsMouse ? VekronaTheme.c.surface2 : "transparent"
        }

        FocusRing {
            shown: area.activeFocus
        }
    }

    Rectangle {
        x: VekronaTheme.space2
        width: VekronaTheme.iconXl
        height: VekronaTheme.iconXl
        color: VekronaTheme.c.surface3
        visible: art.status !== Image.Ready

        Pictogram {
            anchors.centerIn: parent
            name: "music_note"
            px: VekronaTheme.iconL
            color: VekronaTheme.c.inkMuted
        }
    }

    Image {
        id: art
        x: VekronaTheme.space2
        width: VekronaTheme.iconXl
        height: VekronaTheme.iconXl
        source: Audio.player?.trackArtUrl ?? ""
        sourceSize.width: width
        sourceSize.height: height
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        onStatusChanged: {
            if (status === Image.Error)
                console.error("cannot load the track art " + source);
        }
    }

    Column {
        x: root.textX
        width: parent.width - root.textX - VekronaTheme.space2
        anchors.verticalCenter: parent.verticalCenter

        Label {
            width: parent.width
            style: VekronaTheme.type.bodyStrong
            elide: Text.ElideRight
            text: Audio.player?.trackTitle ?? ""
        }

        Label {
            width: parent.width
            style: VekronaTheme.type.caption
            color: VekronaTheme.c.inkMuted
            elide: Text.ElideRight
            text: [Audio.player?.trackArtist, Audio.player?.identity].filter(s => s).join(" · ")
        }

        // The pills' icons sit space2 inside them, so shifting the row left lines the icons up with the text.
        Row {
            x: -VekronaTheme.space2

            BarPill {
                icon: "skip_previous"
                enabled: Audio.player?.canGoPrevious ?? false
                ariaName: "Previous track"
                onClicked: Audio.player.previous()
            }

            BarPill {
                icon: Audio.player?.isPlaying ? "pause" : "play_arrow"
                enabled: Audio.player?.canTogglePlaying ?? false
                ariaName: "Play or pause"
                onClicked: Audio.player.togglePlaying()
            }

            BarPill {
                icon: "skip_next"
                enabled: Audio.player?.canGoNext ?? false
                ariaName: "Next track"
                onClicked: Audio.player.next()
            }
        }
    }

    function show(): void {
        Audio.raisePlayer(Audio.player);
        raised();
    }
}
