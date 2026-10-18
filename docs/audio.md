# Audio

How sound devices that come and go (a USB interface behind a KVM, a hot-plugged headset) are handled, and what
catches the one failure WirePlumber has no defence against.

## Which device plays

The default sink and source follow the best device that is present: Scarlett > other USB audio > onboard
analog > HDMI > network (AirPlay). WirePlumber ranks by `priority.session`; its own values already give
USB 1100, analog 1009, HDMI at most 744 and a node without one 0, so only the Scarlett has a rule
(`config/wireplumber/wireplumber.conf.d/50-vekrona-audio.conf`, priority 3000). Streams follow the default.

Two settings keep that true over time:

- `node.restore-default-targets = false`. Otherwise WirePlumber remembers every default ever chosen by hand
  (`wpctl set-default`, a mixer) and a remembered device outranks every priority while it is present, so a
  remembered AirPlay sink would keep winning over a Scarlett that returns. A choice made at runtime is still
  respected; it is just not stored.
- `session.dont-restore-off-profile = true` on every `alsa_card.*`. A card that comes back is given its best
  profile even if "off" was stored for it. (`wpctl set-profile ID 0` stores off.)
- `device.disabled = true` on `alsa_card.usb-MACROSILICON.*`, the MS2109 HDMI capture card: its audio (it offers only
  `pro-audio`) is not wanted, so WirePlumber does not create the device at all.

## The wedge, and the watchdog

WirePlumber runs its policy as a queue of events, and an event whose hook is asynchronous holds back every
event behind it until the hook completes. There is no timeout (checked in 0.5.18 and in master, 2026-10-16).
When one completion is lost, WirePlumber stays alive and answers `wpctl`, but ignores devices from then on:
cards stay on profile `off`, `default.audio.sink` names a sink that is gone, `wpctl set-default` changes
`default.configured.*` and nothing follows, and the shell has no default sink.

Reproduced in the vekrona-dev VM with the `vivid` V4L2 test driver loaded and unloaded in a loop next to
emulated USB audio plugs and streams starting and stopping: the last hook dispatched is
`monitor/v4l2/create-device`, a `SpaDevice` activation for a camera that vanished mid-activation, and it
never completes. With `hardware.video-capture = disabled` the same load did not wedge. Related upstream
reports, all closed and none covering this: wireplumber#1004 (a Lua step that raises, fixed by 1222c2f2 for
steps only, not for errors inside callbacks), #1009 and #1010 (a V4L2 hook that did not advance).

`vekrona-audio-watchdog.service` follows `pw-dump --monitor`, so it wakes on graph changes and never on a
timer except the grace period. Only a change of a device, a node or the metadata wakes it: its own snapshots make
clients come and go in PipeWire, and waking on those would make it run in a loop. A burst of changes is read in
one go and answered with one snapshot. When either of these outlasts 5 seconds while WirePlumber is running, it
restarts WirePlumber and records an error through `vekrona-error`:

- a default sink or source that names no node while nodes of that kind exist;
- an ALSA card on profile `off` that offers a profile WirePlumber would have picked (not `pro-audio`, not
  `available = no`, so HDMI outputs without a monitor and the capture card stay off without complaint), unless
  the profile WirePlumber has stored for the card (`~/.local/state/wireplumber/default-profile`) is `off`: a card
  somebody turned off is a choice, not a wedge.

If the problem survives the restart it records that once and does not restart again until the graph is
healthy. The unit is part of `pipewire.service`: a PipeWire restart (stage 50 does one) stops the watchdog and
starts it again, instead of ending it with an error.

## AirPlay

`pipewire-config-raop` loads `libpipewire-module-raop-discover` without arguments, and the sinks then buffer
250 ms, which is not a whole number of 352-frame packets, so PipeWire logs `sess.latency.msec 250.000000 should
be an integer multiple of rtp.ptime 7.981859` (module-rtp `stream.c`) and rounds down itself.
`config/pipewire/pipewire.conf.d/50-vekrona-raop.conf` switches the packaged entry off with its own condition
(`module.raop = false`) and loads one with `stream.props = { sess.latency.msec = 247.45 }` (10912 frames, 31
packets). The receiver's control and timing packets arrive on UDP 6001-6010 and mDNS replies on ports above 1024,
which the FedoraWorkstation zone accepted. vekrona's default zone is `public` (see "Default firewall zone" in
[Daily use](daily-use.md)); `ensure_airplay_ports` (`lib/firewall.sh`, called by stage 40) opens UDP 6001-6010 there, and stage 70 checks it.
