pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire

Singleton {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property var sinks: Pipewire.nodes.values.filter(node => node.type === PwNodeType.AudioSink)
    readonly property real volume: sink?.audio?.volume ?? 0
    readonly property bool muted: sink?.audio?.muted ?? true
    readonly property int percent: Math.round(100 * volume)
    readonly property string glyph: muted || percent === 0 ? "volume_off" : percent <= 33 ? "volume_down" : "volume_up"
    readonly property MprisPlayer player: Mpris.players.values.find(candidate => candidate.isPlaying) ?? Mpris.players.values[0] ?? null

    function setVolume(fraction: real): void {
        if (!sink?.audio) {
            console.error("cannot set the volume: there is no default audio sink");
            return;
        }
        sink.audio.volume = Math.max(0, Math.min(1, fraction));
    }

    function selectSink(node: PwNode): void {
        Pipewire.preferredDefaultAudioSink = node;
    }

    // Focuses the window of player. The helper finds the window by process, which works for every player
    // on Sway. MPRIS Raise is the fallback: it needs a window activation token that some players lack.
    function raisePlayer(player: MprisPlayer): void {
        const argv = ["vekrona-media-raise", player.dbusName];
        Exec.run(argv, (code, stdout, stderr) => {
            if (code === 0)
                return;
            if (player.canRaise)
                player.raise();
            else
                Exec.failure(argv, code, stderr);
        });
    }

    function toggleMute(): void {
        if (!sink?.audio) {
            console.error("cannot mute: there is no default audio sink");
            return;
        }
        sink.audio.muted = !sink.audio.muted;
    }

    PwObjectTracker {
        objects: [root.sink]
    }
}
