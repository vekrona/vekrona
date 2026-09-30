#!/usr/bin/env python3
import sys
import threading

import libvirt


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 4:
        print(
            f"usage: {sys.argv[0]} <domain> <reboot-timeout-seconds> <agent-timeout-seconds>",
            file=sys.stderr,
        )
        return 2
    domain_name = sys.argv[1]
    reboot_timeout = float(sys.argv[2])
    agent_timeout = float(sys.argv[3])

    libvirt.registerErrorHandler(lambda ctx, err: None, None)
    libvirt.virEventRegisterDefaultImpl()

    def event_loop():
        while True:
            libvirt.virEventRunDefaultImpl()

    threading.Thread(target=event_loop, daemon=True).start()

    try:
        conn = libvirt.open("qemu:///system")
        domain = conn.lookupByName(domain_name)
    except libvirt.libvirtError as exc:
        fail(f"could not reach domain '{domain_name}': {exc}")

    rebooted = threading.Event()
    connected = threading.Event()

    def on_reboot(_conn, _dom, _opaque):
        rebooted.set()

    def on_agent_lifecycle(_conn, _dom, state, _reason, _opaque):
        if state == libvirt.VIR_CONNECT_DOMAIN_EVENT_AGENT_LIFECYCLE_STATE_CONNECTED:
            connected.set()

    try:
        conn.domainEventRegisterAny(
            domain, libvirt.VIR_DOMAIN_EVENT_ID_REBOOT, on_reboot, None
        )
        conn.domainEventRegisterAny(
            domain,
            libvirt.VIR_DOMAIN_EVENT_ID_AGENT_LIFECYCLE,
            on_agent_lifecycle,
            None,
        )
        domain.reboot(0)
    except libvirt.libvirtError as exc:
        fail(f"could not request a reboot of '{domain_name}': {exc}")

    if not rebooted.wait(timeout=reboot_timeout):
        fail(
            f"guest '{domain_name}' did not emit a libvirt 'reboot' event within "
            f"{reboot_timeout:g}s of requesting a reboot"
        )

    if not connected.wait(timeout=agent_timeout):
        fail(
            f"qemu-guest-agent on '{domain_name}' did not report state 'connected' "
            f"within {agent_timeout:g}s after the reboot"
        )

    print(f"guest '{domain_name}' rebooted and qemu-guest-agent reconnected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
