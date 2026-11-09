Product: Fedora   Component: selinux-policy   Version: 44

Summary: virtqemud_t is denied execute on libvirt qemu hooks (virt_hook_t); allowed only because the domain is permissive

Description:
With the modular libvirt daemons, virtqemud runs the qemu hook scripts in
/etc/libvirt/hooks/qemu.d/. Every domain start logs execute and
execute_no_trans denials on a hook correctly labelled virt_hook_t:

  avc: denied { execute } for comm="rpc-virtqemud" name="50-yolobox-passt"
    scontext=system_u:system_r:virtqemud_t:s0
    tcontext=system_u:object_r:virt_hook_t:s0 tclass=file permissive=1
  avc: denied { execute_no_trans } for comm="rpc-virtqemud"
    path="/etc/libvirt/hooks/qemu.d/50-yolobox-passt"
    scontext=system_u:system_r:virtqemud_t:s0
    tcontext=system_u:object_r:virt_hook_t:s0 tclass=file permissive=1

The hook runs today only because virtqemud_t is a builtin permissive type
(`semanage permissive -l`). Once virtqemud_t is enforcing, every qemu hook
stops running. Bug 2276917 fixed the same denial for virtnetworkd_t and the
network hook (selinux-policy-40.24-1.fc40); virtqemud_t and the qemu hook
appear to need the same rule.

Versions: selinux-policy-44.11-1.fc44, libvirt-daemon-driver-qemu-12.9.0-1.fc44
Label: -rwxr-xr-x. root root system_u:object_r:virt_hook_t:s0 /etc/libvirt/hooks/qemu.d/50-yolobox-passt

Steps to reproduce:
1. Install any executable hook in /etc/libvirt/hooks/qemu.d/ and run restorecon on it (virt_hook_t).
2. Restart virtqemud and start a domain.
3. ausearch -m avc -c rpc-virtqemud

Expected: virtqemud_t may execute virt_hook_t (or transitions into a hook domain), with no AVC.
