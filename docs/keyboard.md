# Keyboard

Every key binding and remap vekrona sets up.

Caps Lock becomes Hyper (Ctrl+Alt+Super) when held, and a plain Caps Lock
when tapped alone within 300 ms. This comes from the `caps-hyper` modmap in
`config/xremap/config.yml`, run by xremap-wlroots as a user systemd service
(`config/systemd-user/xremap.service`). It requires the user to be in the
`input` group so xremap-wlroots can read raw keyboard events (see [Known issues](known-issues.md)).

There are two layers in Sway (`config/sway/config`): Cmd (Super) for the
everyday window keys, and Hyper for launching things, panels and moving
windows between workspaces. Hyper is Caps Lock held, so the keys you press all
day sit on Cmd and stay off Caps Lock.

Cmd (plain `Mod4`):

| Binding | Action |
|---|---|
| Cmd+Space | `dms ipc call spotlight toggle` (launcher) |
| Cmd+1..9, Cmd+0 | switch to workspace 1 through 10 |
| Cmd+arrow keys | focus left/down/up/right |
| Cmd+Shift+arrow keys | move the focused container left/down/up/right |
| Cmd+\\ | split vertically: the next window opens to the right of the focused one |
| Cmd+- | split horizontally: the next window opens below the focused one |
| Cmd+Return | toggle fullscreen |
| Cmd+q | kill the focused window |
| Cmd+Tab, Cmd+Shift+Tab | app switcher (see below) |
| Cmd+Shift+3 | `vekrona-screenshot screen` |
| Cmd+Shift+4 | `vekrona-screenshot area` |
| Cmd+Shift+5 | `vekrona-screenshot window` |
| Cmd+Ctrl+Shift+3 | `vekrona-screenshot --clipboard screen` |
| Cmd+Ctrl+Shift+4 | `vekrona-screenshot --clipboard area` |
| Cmd+Ctrl+Shift+5 | `vekrona-screenshot --clipboard window` |

Sway defines `$hyper` as `Mod4+Ctrl+Mod1` and binds the rest on it:

| Binding | Action |
|---|---|
| Hyper+Return | launch ghostty |
| Hyper+v | `dms ipc call clipboard toggle` |
| Hyper+n | `dms ipc call notifications toggle` |
| Hyper+comma | `dms ipc call control-center toggle` |
| Hyper+Escape | `dms ipc call lock lock` |
| Hyper+BackSpace | `dms ipc call powermenu toggle` |
| Hyper+slash | show the keybindings help panel (`vekrona-keybindings`) |
| Hyper+a | open the coding agent (`vekrona-agent --pick`) |
| Hyper+Shift+a | pick a recorded error and open the agent on it (`vekrona-error pick`) |
| Hyper+1..9, Hyper+0 | move the focused container to workspace 1 through 10 |
| Hyper+r | enter resize mode (h/j/k/l or arrows resize, Return or Escape exits) |
| Hyper+t | toggle floating |
| Hyper+e | toggle split layout |
| Hyper+= | go to a new workspace (the first empty one, `vekrona-workspace-new`) |
| Hyper+Shift+= | move the focused window to a new workspace and follow it |
| Hyper+Print | `vekrona-screenshot` |
| Hyper+Shift+Print | `vekrona-record` |
| Hyper+Shift+c | `vekrona-caffeine` |
| Hyper+Shift+n | `dms ipc call night toggle` |
| Hyper+Shift+t | `vekrona-theme next` |
| XF86AudioRaiseVolume/LowerVolume/Mute, XF86MonBrightness* | `dms ipc call audio ...` / `dms ipc call brightness ...` |
| XF86AudioPlay/Pause/Next/Prev | `dms ipc call mpris playPause` / `pause` / `next` / `previous` |

Moving a window to a workspace is Hyper+digit without Shift, because
Cmd+Shift+3/4/5 are the screenshot keys.

Shift is not folded into the Hyper mask itself: Hyper is exactly
Ctrl+Alt+Super, and Hyper+Shift is a separate binding on top of it. Putting
Shift inside the Hyper mask would make Hyper+Shift+X carry the same modifier
mask as some other Hyper+X binding and silently overwrite it.

## App switcher

Super+Tab works like Cmd+Tab on macOS: hold Super and press Tab to open a row
of app icons, one per app across all workspaces, most recently used first.
More Tab presses move right, Shift+Tab moves left, and releasing Super focuses
the most recent window of the highlighted app, switching workspace if needed.
A quick tap goes straight back to the previous app; Escape cancels and Return
or a click picks.

The overlay is a resident Quickshell instance, `config/vekrona-app-switch/shell.qml`,
started once per session by `vekrona-app-switch.service` (wanted by
`sway-session.target`, restarted by systemd if it dies) and hidden until
needed. Stage 50 links the config to `~/.config/quickshell/vekrona-app-switch`
so `qs -c vekrona-app-switch` finds it. Cmd+Tab and Cmd+Shift+Tab are plain
Sway bindings that run `qs -c vekrona-app-switch ipc call appswitch next|prev`:
the first call shows the overlay, later ones step it. A cold Quickshell start
per switch (QML compile, desktop entry scan, icon lookup) used to cost ~250 ms
in the VM and over a second on real hardware, which is why the overlay stays
resident with its desktop entries and icons warm.

The overlay tracks windows itself: it reads Sway's tree once at startup, then
follows `window` events (new, close, focus), so the most-recently-used order
needs no daemon or state file and opening it runs no query. Committing hides
the overlay and focuses the window with `I3.dispatch("[con_id=N] focus")`.
Quickshell's foreign-toplevel `activate()` is not usable here: Sway accepts the
request but does not move focus. The overlay takes exclusive keyboard focus
while shown, but Sway bindings still run first, so Tab presses keep reaching
the overlay's IPC.

Neither Sway nor the overlay sees Super go up reliably: a `bindsym --release
Super_L` in a mode never fires after Super+Tab, and Qt gets no key event for
it. So opening the overlay also starts `wait-super-release.py`, which asks the
kernel for the key state (`EVIOCGKEY`) of every `/dev/input/event*` device,
xremap's virtual keyboard included (the `input` group membership already
allows it), and re-checks whenever any device reports an event. When no Super
key is down it exits and the overlay commits.

`tests/e2e/app-switch-latency.sh` guards the speed with real key presses: the
overlay must be on screen within 200 ms of Cmd+Tab and focus must change within
75 ms of releasing Cmd.

xremap's Cmd layer must not remap Super+Tab: an earlier `Super-Tab: Alt-Tab`
entry made xremap send a fake Super release, which ended the switch at once,
and turned the next Super+Tab into an Alt+Tab Sway does not bind.

## Keybindings help panel

`bin/vekrona-keybindings`, bound to Hyper+slash, is an Omarchy-style help
panel: it reads `~/.config/sway/config` and its `include`s directly (Sway
itself doesn't expand includes in `swaymsg -t get_config`), pairs every
`bindsym` with the `#: <description>` comment line placed directly above it
in the config, and renders them in a `rofi -dmenu` list styled from the
active Vekrona theme mode (generated into `~/.local/state/vekrona/active-theme.json`).
Alternative chords (`h` / `Left`) and the workspace 1..10 bindings (Cmd to switch, Hyper to move) are
collapsed into single rows; picking a Sway row runs its command through
`swaymsg`. It also lists the xremap Caps Lock and Cmd-layer remaps
(`config/xremap/config.yml`) and the `Alt+Alt` layout toggle, both
informational only. `vekrona-keybindings --list` prints the same rows as
plain text and `--check` fails if any `bindsym` in the Sway config is
missing its `#:` description, or if a `cmd-layer` remap shadows a Sway
`Mod4` or `Mod4+Shift` binding (xremap sees keys before Sway, so that binding
could never fire); `stages/70-verify.sh` runs `--check` and
greps `--list` for the workspace-10 and help rows. Every `bindsym` in
`config/sway/config`, including the `mode "resize"` block and the XF86
media keys, must carry a `#:` description line directly above it, or the
panel refuses to run.

## The Cmd layer (xremap)

Outside the terminal app_ids (`com.mitchellh.ghostty`, `foot`,
`org.wezfurlong.wezterm` and `vekrona.agent`, defined once in the config), the `cmd-layer` keymap in
`config/xremap/config.yml` turns Super into a macOS-style Cmd modifier. Every
letter, Cmd+a through Cmd+z, sends the same letter under Ctrl instead, except Cmd+q: that is Sway's kill-window binding, not
Ctrl+q. Cmd+arrows are Sway's too (focus and move), so the layer no longer
remaps them:

| Cmd shortcut | Sends | Cmd shortcut | Sends |
|---|---|---|---|
| Cmd+Shift+z | Ctrl+Shift+z | Cmd+Shift+t | Ctrl+Shift+t |
| Cmd+Shift+n | Ctrl+Shift+n | Cmd+Shift+p | Ctrl+Shift+p |
| Cmd+Shift+f | Ctrl+Shift+f | Cmd+Shift+g | Ctrl+Shift+g |
| Cmd+Shift+r | Ctrl+Shift+r | Cmd+Shift+w | Ctrl+Shift+w |
| Cmd+Backspace | Shift+Home, then Backspace | Alt+Backspace | Ctrl+Backspace |
| Alt+Left | Ctrl+Left | Alt+Right | Ctrl+Right |
| Alt+Shift+Left | Ctrl+Shift+Left | Alt+Shift+Right | Ctrl+Shift+Right |
| Cmd+Shift+[ | Ctrl+PageUp | Cmd+Shift+] | Ctrl+PageDown |
| Cmd+comma | Ctrl+comma | | |

Inside the terminals, the `cmd-layer` is off so Ctrl still reaches the shell
for things like Ctrl+C, and the `terminal` keymap applies instead. It maps
Cmd+C and Cmd+V to Ctrl+Shift+C and Ctrl+Shift+V, the default copy and paste
of Ghostty, foot and wezterm, so Ctrl+C stays SIGINT. It also remaps
Alt+Left/Right to Ctrl+Left/Right, which readline (`backward-word`/`forward-word`)
already understands. Alt+Backspace is left unmapped in the terminal: Ghostty
sends it as ESC DEL (`\e\x7f`), which bash's readline already binds to
`backward-kill-word`, deleting the previous word. Remapping it to
Ctrl+Backspace like the Cmd layer does for GUI apps does not work here:
Ghostty encodes Ctrl+Backspace as a bare Ctrl-H byte (`^H`, 0x08), and
readline binds plain Ctrl-H to `backward-delete-char`, so it would delete one
character instead of a word.

Keyboard layouts are not hardcoded in `config/sway/config`: they follow the
system X11 keymap, the layouts chosen in the installer (Anaconda writes
`/etc/X11/xorg.conf.d/00-keyboard.conf`, which `localectl status` shows as
"X11 Layout"). `config/sway/environment`, which Fedora's `start-sway` sources
at every login, runs `bin/vekrona-xkb-env`; that script turns the file into
`XKB_DEFAULT_LAYOUT`, `_VARIANT`, `_MODEL` and `_OPTIONS`, which Sway uses
because the config sets no `xkb_layout`. It always adds
`shift:both_capslock_cancel`. With more than one layout it replaces any
layout-switch option the installer chose (such as Alt+Shift) with
`grp:alts_toggle`, so Left Alt and Right Alt pressed together cycle the
layouts; with one layout there is no switch. A system with no X11 keymap gets
`us`, silently. If the tool is missing or the file is unreadable or
malformed, the session still starts, with `us` and
`shift:both_capslock_cancel`, and the cause is logged at priority `err`
(`journalctl -t vekrona-xkb-env`); the error watcher (see [Errors](errors.md))
records it and shows a toast once the session is up, and `./install.sh 70`
fails until the keymap is fixed.

To change layouts later, run `localectl set-x11-keymap us,ua` (variants and
options are further arguments) and log out and in again; `vekrona-keybindings`
and `./install.sh 70` read the same file.
