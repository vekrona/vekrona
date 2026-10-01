import json
import sys

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib

INTROSPECTION = """
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
      <arg type="u" direction="out"/>
    </method>
  </interface>
</node>
"""

log_path = sys.argv[1]
next_id = [1]


def on_method_call(connection, sender, path, interface, method, params, invocation):
    app, _replaces, _icon, summary, body, actions, _hints, _timeout = params.unpack()
    with open(log_path, "a") as f:
        f.write(json.dumps({"app": app, "summary": summary, "body": body, "actions": actions}) + "\n")
    notification_id = next_id[0]
    next_id[0] += 1
    invocation.return_value(GLib.Variant("(u)", (notification_id,)))


def on_bus_acquired(connection, name):
    node = Gio.DBusNodeInfo.new_for_xml(INTROSPECTION)
    connection.register_object(
        "/org/freedesktop/Notifications", node.interfaces[0], on_method_call, None, None)


def on_name_acquired(connection, name):
    print("ready", flush=True)


def on_name_lost(connection, name):
    sys.exit(f"could not own {name}")


Gio.bus_own_name(Gio.BusType.SESSION, "org.freedesktop.Notifications", Gio.BusNameOwnerFlags.NONE,
                 on_bus_acquired, on_name_acquired, on_name_lost)
GLib.MainLoop().run()
