# Agents

## No sensitive data on disk

Private keys, WireGuard preshared keys, account numbers and session or refresh tokens live only in the Secret Service (the gnome-keyring login collection) or in tmpfs, for the length of one operation. Never in NetworkManager keyfiles, `~/.config`, `~/.cache`, `/etc`, `/var`, logs, the journal or tracebacks. /etc and /home are in btrfs snapshots, so a secret written there once outlives its deletion.

Only user-side code talks to the keyring; root helpers never do. Commands the shell runs on its own (`vekrona-vpn status`, `list`) never touch the keyring, so a locked keyring prompts only when the person acts.

## Nomenclature

- **VPN**: the WireGuard tunnel `vvpn0` that vekrona-vpn connects.
- **kill switch**: the nftables table `inet vekrona-vpn`, armed from the moment a connect starts until the VPN is turned off.
- **tor**: the second egress: the system tor (Fedora's user `toranon`) that bypasses the VPN and the kill switch. Clients reach it only through the socket `/run/vekrona-tor/socks`, open to the group `vekrona-tor`. vekrona's own tor pieces are named `vekrona-tor…` like `vekrona-vpn…`; `/run/tor` (vekrona keeps it 0700) and `toranon` are Fedora's and stay private to tor.
