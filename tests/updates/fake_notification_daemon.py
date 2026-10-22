"""A notification daemon on the session bus, driven from stdin so a test can answer, forge and restart.

stdout, one JSON object per line: {"event": "ready"}, {"event": "notify", "id", "summary", "body", "actions"},
{"event": "close", "id"} (CloseNotification was called), and {"event": "done", "command"} once a stdin
command has taken effect on the bus.

stdin commands:
  action ID KEY      the daemon emits ActionInvoked
  closed ID REASON   the daemon emits NotificationClosed
  forge-action ID KEY / forge-closed ID REASON
                     the same signals from another connection, which is not the daemon
  release            the daemon gives up org.freedesktop.Notifications
  fail-close         CloseNotification fails from now on
"""
import json
import sys

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib

NAME = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"

INTROSPECTION = """
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
      <arg type="u" direction="out"/>
    </method>
    <method name="CloseNotification"><arg type="u" direction="in"/></method>
    <signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
    <signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
  </interface>
</node>
"""

next_id = [1]
daemon_connection = [None]
owner_id = [None]
released = [False]
close_fails = [False]


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}), flush=True)


def on_method_call(connection, sender, path, interface, method, params, invocation):
    if method == "CloseNotification":
        emit("close", id=params.unpack()[0])
        if close_fails[0]:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.Failed", "refusing to close")
        else:
            invocation.return_value(None)
    else:
        _app, _replaces, _icon, summary, body, actions, _hints, _timeout = params.unpack()
        notification_id = next_id[0]
        next_id[0] += 1
        emit("notify", id=notification_id, summary=summary, body=body, actions=actions)
        invocation.return_value(GLib.Variant("(u)", (notification_id,)))


def on_bus_acquired(connection, name):
    daemon_connection[0] = connection
    connection.register_object(
        PATH, Gio.DBusNodeInfo.new_for_xml(INTROSPECTION).interfaces[0], on_method_call, None, None)


def signal_from(connection, member, signature, values):
    connection.emit_signal(None, PATH, NAME, member, GLib.Variant(signature, values))


def forger_connection():
    return Gio.DBusConnection.new_for_address_sync(
        Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None),
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)


def forge(member, signature, values):
    connection = forger_connection()
    signal_from(connection, member, signature, values)
    # The bus handles one connection's messages in order, so once this reply is back the forged signal has been
    # routed to every subscriber and the next signal sent by anyone else cannot overtake it.
    connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId",
                         None, GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE, 5000, None)
    connection.close_sync(None)


def run_command(line):
    command, *args = line.split()
    if command == "action":
        signal_from(daemon_connection[0], "ActionInvoked", "(us)", (int(args[0]), args[1]))
        daemon_connection[0].flush_sync(None)
    elif command == "closed":
        signal_from(daemon_connection[0], "NotificationClosed", "(uu)", (int(args[0]), int(args[1])))
        daemon_connection[0].flush_sync(None)
    elif command == "forge-action":
        forge("ActionInvoked", "(us)", (int(args[0]), args[1]))
    elif command == "forge-closed":
        forge("NotificationClosed", "(uu)", (int(args[0]), int(args[1])))
    elif command == "fail-close":
        close_fails[0] = True
    elif command == "release":
        released[0] = True
        Gio.bus_unown_name(owner_id[0])
    else:
        sys.exit(f"unknown command: {line}")
    emit("done", command=command)


def on_name_lost(connection, name):
    if not released[0]:
        sys.exit(f"could not own {name}")


def on_stdin(channel, condition):
    line = channel.readline().strip()
    if not line:
        loop.quit()
        return False
    run_command(line)
    return True


owner_id[0] = Gio.bus_own_name(
    Gio.BusType.SESSION, NAME, Gio.BusNameOwnerFlags.NONE, on_bus_acquired,
    lambda connection, name: emit("ready"), on_name_lost)
loop = GLib.MainLoop()
GLib.io_add_watch(GLib.IOChannel.unix_new(sys.stdin.fileno()), GLib.PRIORITY_DEFAULT,
                  GLib.IOCondition.IN | GLib.IOCondition.HUP, on_stdin)
loop.run()
