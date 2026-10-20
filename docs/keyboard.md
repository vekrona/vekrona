# Keyboard

Every key binding and remap vekrona sets up.

Caps Lock becomes Hyper (Ctrl+Alt+Super) when held, and a plain Caps Lock
when tapped alone within 300 ms. This comes from the `caps-hyper` modmap in
`config/xremap/config.yml`, run by xremap-wlroots as a system service (`xremap.service`) under its own user, `xremap`.
That user is in the `input` group and reads the keyboards and writes `/dev/uinput`; **your user is not in the `input`
group**, so no program you run can log raw key events, and `/dev/uinput` is closed to the seat's user as well
(`etc/udev/rules.d/70-vekrona-uinput.rules`). xremap's config is root's copy, `/etc/xremap/config.yml`, installed from
`config/xremap/config.yml` by `./install.sh 40`: edit the checkout, run the stage, and the service restarts. (A config the user
could write would run commands as the xremap user.) `~/.config/xremap/config.yml` stays a link to the checkout for
`vekrona-keybindings` and the validation.

`xremap.path` starts the service when a Wayland socket (`/run/user/UID/wayland-N`) appears. Before it starts, a root step
(`libexec/vekrona-xremap-access`) finds the socket Sway listens on, gives the xremap user an ACL on the socket and on the
runtime directory (both disappear with the session) and writes `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY` to
`/run/xremap/wayland.env`: the per-app remaps (terminals against everything else) ask the compositor which window has the
focus. `journalctl -u xremap` shows the service; `sudo systemctl restart xremap` restarts it.

There are two layers in Sway (`config/sway/config`): Cmd (Super) for the
everyday window keys, and Hyper for launching things, panels and moving
windows between workspaces. Hyper is Caps Lock held, so the keys you press all
day sit on Cmd and stay off Caps Lock.

Cmd (plain `Mod4`):

| Binding | Action |
|---|---|
| Cmd+Space | `qs -c vekrona-shell ipc call launcher toggle` (launcher) |
| Cmd+1..9, Cmd+0 | switch to workspace 1 through 10 |
| Cmd+arrow keys | focus left/down/up/right |
| Cmd+Shift+arrow keys | move the focused container left/down/up/right |
| Cmd+\\ | open the launcher; the app opens to the right of the focused window |
| Cmd+- | open the launcher; the app opens below the focused window |
| Cmd+Return | toggle fullscreen |
| Cmd+q | kill the focused window |
| Cmd+Ctrl+q | `vekrona-lock start` (the macOS shortcut for the same thing as Hyper+Escape) |
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
| Hyper+v | `qs -c vekrona-shell ipc call launcher toggleMode clip` (the launcher in its clipboard history mode) |
| Hyper+n | `qs -c vekrona-shell ipc call notifications toggle` |
| Hyper+Escape | `vekrona-lock start` |
| Hyper+BackSpace | `qs -c vekrona-shell ipc call launcher toggleMode power` (the launcher in its power mode) |
| Hyper+slash | show the keybindings help panel (`vekrona-keybindings menu`) |
| Hyper+a | open the coding agent (`vekrona-agent --pick`) |
| Hyper+Shift+a | `qs -c vekrona-shell ipc call launcher toggleMode agent` (toggle the robot's error list, the launcher in its `/agent` mode) |
| Hyper+Space | switch to the next keyboard layout and show it on screen (no backward key; the bar item's menu picks one directly) |
| Hyper+1..9, Hyper+0 | move the focused container to workspace 1 through 10 |
| Hyper+r | enter resize mode (h/j/k/l or arrows resize, Return or Escape exits) |
| Hyper+t | toggle floating |
| Hyper+e | toggle split layout |
| Hyper+= | go to a new workspace (the first empty one, `vekrona-workspace-new open`) |
| Hyper+Shift+= | move the focused window to a new workspace and follow it |
| Hyper+Print | `vekrona-screenshot area` |
| Hyper+Shift+Print | `vekrona-record toggle` |
| Hyper+Shift+c | `vekrona-caffeine toggle` (keep-awake: 1h, or off when on) |
| Hyper+Shift+n | `vekrona-night toggle` |
| Hyper+Shift+t | `vekrona-theme next` |
| XF86AudioRaiseVolume/LowerVolume/Mute, XF86MonBrightness* | `qs -c vekrona-shell ipc call audio ...` / `qs -c vekrona-shell ipc call brightness ...` |
| XF86AudioPlay/Pause/Next/Prev | `qs -c vekrona-shell ipc call mpris playPause` / `pause` / `next` / `previous` |

`qs -c vekrona-shell ipc show` lists every IPC target of the shell. Besides the
bound ones, `notifications close` and `notifications clearAll` (dismiss every
notification, which the e2e scenarios use) exist; the notification toasts and
centre always sit below the bar.

Moving a window to a workspace is Hyper+digit without Shift, because
Cmd+Shift+3/4/5 are the screenshot keys.

Shift is not folded into the Hyper mask itself: Hyper is exactly
Ctrl+Alt+Super, and Hyper+Shift is a separate binding on top of it. Putting
Shift inside the Hyper mask would make Hyper+Shift+X carry the same modifier
mask as some other Hyper+X binding and silently overwrite it.

## Launcher

Cmd+Space opens one launcher for applications, the calculator, settings,
power commands, web search, the coding agent and the clipboard history.
Typing `/` lists the modes; `/calc ` (keyword and a space) enters one, shown
as a badge before the query. The modes are `/apps`, `/calc`, `/search`,
`/agent`, `/settings`, `/power` and `/clip`. Hyper+v and Hyper+BackSpace open
it straight in `/clip` and `/power`, and pressing them again closes it.
Under the search field a row of mode tabs shows the mode you are in: `Apps`,
`Calculator`, `Search` and `Clipboard`, then `Settings` and `Power`. Each tab
is an icon with its name under it, and the lit one has the selection fill. A
click switches to that mode, and so does Enter or Space on a focused tab.
`Apps` is the default mode (`/apps` lights it too), so clicking a lit tab does
nothing, except inside a sub-view, where it returns to the mode's list. Typing
`/calc `, `/search `, `/clip `, `/settings ` or `/power ` lights the matching
tab. The tabs run no command: the toggles (theme, night light, caffeine, Wi-Fi,
Bluetooth, audio) are rows in `/settings`, and lock, sleep, log out, restart
and shut down are rows in `/power`. `/agent` has no tab because the bar's robot
button opens it.

| Key | Action |
|---|---|
| Up, Down, Ctrl+N, Ctrl+P | move the selection (PageUp and PageDown by a page) |
| Enter, Ctrl+Enter | run the first and the second action of the selected row |
| Ctrl+K | list every action of the selected row; Enter runs one, Escape closes the list |
| Tab, Shift+Tab | go to the mode tabs under the search field, which are one Tab stop (in a mode suggestion, Tab enters the mode) |
| Left, Right on a tab | move between the tabs |
| Enter or Space on a tab | switch to the focused one (when the key is released) |
| Tab, Shift+Tab, Escape on a tab | back to the search field |
| Backspace on an empty query | leave the mode (or the sub-view) |
| Escape | disarm a confirmation, then leave the sub-view, the mode, clear the query, close |

A destructive action (log out, restart, shut down; deleting a clipboard entry)
asks you to press Enter twice to confirm; Escape cancels. What you open often
moves up: results are ranked with a frecency score kept in
`$XDG_STATE_HOME/vekrona/launcher-frecency.json` that halves every seven days,
and the empty launcher lists the six most recent.

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
so `qs -c vekrona-app-switch` finds it. The overlay reads `config/tokens.json`
itself (the committed symlink `config/vekrona-app-switch/tokens.json`), in the
mode that `$XDG_STATE_HOME/vekrona/theme` names, and restyles when either
changes. Cmd+Tab and Cmd+Shift+Tab are plain
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
the files `/run/xremap/super-L` and `/run/xremap/super-R`: xremap runs `vekrona-super-state` on every Super press and
release (the `super-state` modmap in its config) and that writes 1 or 0 there, because your user cannot read the
keyboards. It watches the directory with inotify and, when no Super key is down, exits and the overlay commits.

`tests/e2e/app-switch-latency.sh` guards the speed with real key presses: the
overlay must be on screen within 200 ms of Cmd+Tab and focus must change within
75 ms of releasing Cmd.

xremap's Cmd layer must not remap Super+Tab: an earlier `Super-Tab: Alt-Tab`
entry made xremap send a fake Super release, which ended the switch at once,
and turned the next Super+Tab into an Alt+Tab Sway does not bind.

## Keybindings help panel

`vekrona-keybindings menu`, bound to Hyper+slash, is an Omarchy-style help
panel: it reads `~/.config/sway/config` and its `include`s directly (Sway
itself doesn't expand includes in `swaymsg -t get_config`), pairs every
`bindsym` with the `#: <description>` comment line placed directly above it
in the config, and renders them in a `rofi -dmenu` list styled from the
active Vekrona theme mode (generated into `~/.local/state/vekrona/active-theme.json`).
Alternative chords (`h` / `Left`) and the workspace 1..10 bindings (Cmd to switch, Hyper to move) are
collapsed into single rows; picking a Sway row runs its command through
`swaymsg`. It also lists the xremap Caps Lock and Cmd-layer remaps
(`config/xremap/config.yml`), informational only. `vekrona-keybindings --list` prints the same rows as
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
`shift:both_capslock_cancel` and drops any system layout-switch option the
installer chose (such as Alt+Shift or `grp:alts_toggle`). Hyper+Space
switches the layout instead (a Sway binding that runs `input type:keyboard
xkb_switch_layout next`). A system with no X11 keymap gets `us`, silently.
If the tool is missing or the file is unreadable or malformed, the session
still starts, with `us` and `shift:both_capslock_cancel`, and the cause is
logged at priority `err` (`journalctl -t vekrona-xkb-env`); the error watcher
(see [Errors](errors.md)) records it and lights the robot's dot once the session is
up, and `./install.sh 70` fails until the keymap is fixed.

To change layouts later, run `localectl set-x11-keymap us,ua` (variants and
options are further arguments) and log out and in again; `vekrona-keybindings`
and `./install.sh 70` read the same file.
