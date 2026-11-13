# VPN

`vekrona-vpn` runs WireGuard connections of NetworkManager behind an nftables kill switch. The bar's VPN icon and the launcher's
Settings, VPN view are its UI; `bin/vekrona-vpn` is the command behind both. Proton's own VPN app is gone (stage `00-repos`
removes its dnf repo and key): it sent IPv6 to a dummy device that dropped it silently, and that stalled Tor Browser Launcher
([the kill switch](#the-kill-switch) says why that matters). `wireguard-tools` (`wg`, for Mullvad's key pair) is the only package the
VPN adds, and `libsecret` (`secret-tool`) the one for the keyring it keeps the keys in.

## How it works

There is no VPN daemon of our own. Each configuration is a NetworkManager connection of type `wireguard`, named
`vekrona-vpn/<vendor>/<country>/<name>`, with autoconnect off. NetworkManager keeps no key: the keys live in the login keyring
(gnome-keyring, the Secret Service), and a connect gives them to NetworkManager on stdin, for that one `nmcli connection up`
([Keys](#keys)). A connection brings up the interface `vvpn0` (one tunnel at a time) and routes all traffic and all DNS
(`dns-priority -1`, search domain `~.`) through it. The tunnel's own encrypted packets carry the fixed fwmark `0xca6c`, so the kill
switch can recognize them before the tunnel exists.

Nothing starts at boot: after a reboot the VPN is off and no kill switch is loaded until you connect.

The shell does not poll. It runs `vekrona-vpn status` again when `/run/vekrona-vpn/state.json` changes (the kill switch armed or
removed) or when `nmcli monitor` reports a change (the tunnel came up or dropped).

## Vendors

A vendor is a way to get configurations. The popout is a tree: vendor, country, configuration.

**Mullvad.** Enter the account number in the popout (or run `vekrona-vpn mullvad login`, which asks on the terminal without echo).
The number goes to Mullvad over stdin and is kept in the keyring, with the device's key. vekrona generates a WireGuard key pair,
registers it as a device of the account and keeps the key in the keyring. The list shows Mullvad's countries from its relay list (refreshed when it is older than
a day and you are logged in, and `connect` and `login` use the cache too while it is younger than that, so a connect does not
download the whole list, a megabyte, over a network that is not the VPN yet; a cache that cannot be used is asked for again); you
connect to a country, never to a relay. Each connect picks a random active relay of that country,
makes a connection for it, brings it up and then deletes the older connection of that country. If the account already has the
maximum number of devices, login stops and says so; it removes nothing. If the root step or the keyring fails after the device was
registered, the device is removed again: its key is kept nowhere else, so it would be of no use. Once the new device works, the
device the keyring held before is removed from the account too (by its id, or for a key from before ids were kept, by its public
key). That is how an old key stops working at Mullvad (see [Keys](#keys)).

**Proton and other.** Import `.conf` files with Import Proton… or Import other… in the popout (the popout closes first, because
the file chooser, a portal dialog, would be under it, and the keyring may prompt), or `vekrona-vpn import --vendor proton|other [FILE...]`. The vendor is the
button you pressed. The country is the first two-letter token in the file name that is an ISO country (`NL-792.conf`,
`nl-ams-wg-001.conf` give NL; `wg0.conf` gives an unknown country, shown as `??`). The name is the file name without `.conf`.
Importing a file with an id that exists replaces the old connection after the new one is made. Up to 32 files at a time.

An import is refused, with the line or key named and never its value, when the file:

- is larger than 16 KiB, is not UTF-8 text, or does not have exactly one `[Interface]` and one `[Peer]`;
- repeats a key (only `Address`, `DNS` and `AllowedIPs` may repeat), or has a key vekrona does not render into the connection
  (`PostUp`, `Table`, `FwMark`, `ListenPort`, ... would be silently ignored or dangerous, so they are an error);
- has a `PrivateKey`, `PublicKey` or `PresharedKey` that is not a WireGuard key;
- has an `Endpoint` that is a host name: the kill switch lets the handshake through to one address, and a name cannot be resolved
  once the kill switch is armed;
- has no `DNS`, or a `DNS` that is a name: every name lookup would go unresolved (all DNS goes through the tunnel);
- has `AllowedIPs` without `0.0.0.0/0`: a split tunnel would send the rest outside it, and the kill switch only lets the tunnel
  carry traffic.

Autoconnect: `nmcli connection import` cannot be told to turn autoconnect off, and NetworkManager autoconnects a profile it has just
been given, which would bring a tunnel up before the kill switch exists. So the helper imports the configuration with `Table = off`
(NetworkManager's `wireguard.peer-routes=no`: a tunnel without routes carries nothing) and one `nmcli connection modify` then sets
the id, the interface `vvpn0`, autoconnect off, the routes back, the fwmark, the DNS, and the keys out of the profile, all together;
if NetworkManager had brought the profile up in between, the helper takes it down again. The import file holds a placeholder in place
of the private key and no preshared key, so the profile never holds a real key. (Passing the key to `nmcli connection add` instead would put it on a command
line any process can read.) The import runs under the name `vvpn-import`, not `vvpn0`: a profile that is born on the interface of
the tunnel in use could replace that tunnel when NetworkManager autoconnects it, so importing while connected must not touch it
(`tests/e2e/vpn-import-while-connected.sh`). A helper that was killed between the import and the change leaves a profile named
`vvpn-import` with the placeholder key; every import deletes such a profile first. A batch of files is checked as a whole before the first is
imported; if NetworkManager then fails on one, the error names its position and how many files were imported before it.

A file whose `Address` has no IPv6 address gets `ipv6.method disabled` on its connection, so IPv6 fails at once (see the next
section) instead of going into a tunnel that cannot carry it.

## Keys

Every key lives in one place: the login keyring, as an item of application `vekrona-vpn` (gnome-keyring, through `secret-tool`,
`lib/vekrona_secrets.py`). There are three kinds: the Mullvad account number, the Mullvad device (its private key and addresses, and
its id at Mullvad), and the key of each imported configuration (its private key and preshared key, under the connection's id).
NetworkManager keeps none of them: each `nmcli connection up` gets the private key on stdin (`passwd-file /dev/stdin`); a preshared
key is set on the live tunnel with `wg set` right after the activation (nmcli's passwd-file cannot name a peer's secret, see
[TODO-UPSTREAM](../TODO-UPSTREAM.md)), so the peer keeps flag 4 (not required) and NetworkManager neither stores nor asks for it. The helper's
request file holds them for that one operation, in tmpfs. `status` and `list` never touch the keyring. A locked keyring prompts the
first time a command needs a key, so an unlock prompt can come after a FIDO login; the popout and the launcher close before such a
command, so the prompt gets the keyboard. A dismissed or refused unlock looks like a missing item to secret-tool, so when it answers "nothing" the Secret Service is asked whether
the collection is locked: locked fails the command with "keyring locked", before the kill switch is armed.

`vekrona-vpn seal` moves the keys that an earlier vekrona left in NetworkManager's keyfiles into the keyring, and takes them out of
the keyfiles, and binds each to the tunnel's interface `vvpn0` (a profile imported outside vekrona-vpn may name another one,
which the kill switch would block; `connect` refuses such a profile before it arms anything). The helper writes the export to `/run/vekrona-vpn/served/<uid>.sealed`: in tmpfs, in the helper's own directory (the
receipts' directory, root's, which you can read but not write), as a file of yours with mode 0600. The client reads it, stores the
keys, and the strip that follows removes the file together with the keys from NetworkManager. The export lives from the export to the
strip, and a seal that dies in between leaves it until the next operation of yours, which removes it first. The
helper checks that no keyfile of WireGuard holds a key. `connect` runs the seal first when a key is still in a keyfile, and
`stages/50-user.sh` runs it once on install, through `systemd-run --user` (polkit accepts the request from your user manager only).
`stages/70-verify.sh` checks that no WireGuard keyfile holds a key.

Keys written before this change stay in the btrfs snapshots that were taken before it, until they are rotated. Mullvad's device
is replaced (and the old one removed from the account) at the next `vekrona-vpn mullvad login`. An imported configuration's key and
a Proton key must be revoked at the provider.

## The kill switch

The table `inet vekrona-vpn` has two chains, `output` (this machine's own packets) and `forward` (packets it routes for others),
both on priority -10 with policy accept, and each rejects whatever a rule below does not accept. The root helper loads it (there is
no unit for it: the table lives in the kernel, and `vekrona-vpn off` removes it).

**When.** `connect` arms it first, checks that the table is still in the kernel, and then brings the tunnel up. It stays until
`vekrona-vpn off`, which takes the tunnel down and then removes the table. Both run inside one operation of the helper, under its
lock, so an `off` cannot land between the arming and the tunnel coming up and leave the tunnel unprotected. A tunnel that drops, a connect that fails: traffic stays blocked and the bar
shows the blocked icon, until you connect again or turn the VPN off. Connecting to another configuration swaps the rules in one
nft transaction, so there is no moment with nothing blocked. The table lives in the kernel only; a reboot clears it.

**Reject, not drop.** The rule ends in `reject with icmpx admin-prohibited`, so a program that tries the network gets "refused" in
a millisecond instead of waiting for a timeout. This is deliberate. Under Proton's app, IPv6 went to a dummy device that dropped it
silently, and Tor Browser Launcher (Python `requests`, which tries each IPv6 address of a host with no timeout) sat at "Downloading
version check, 0%" for ever. A reject makes every such program fall back to IPv4 at once.

**What is let through**, first match wins:

1. Loopback.
2. Tailscale: on `tailscale0` only tailnet addresses (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`); the rest of `tailscale0` is rejected,
   so an exit node is no way around the VPN. `tailscaled`'s own packets (control, DERP and NAT traversal carry the mark `0x80000`
   under the mask `0xff0000`) leave by the physical interface, but only from uid 0 (since Linux 5.17 a program with `CAP_NET_RAW`
   may set the mark), and never to the local network, to multicast or to a DNS port (53, and 853 for DNS over TLS or QUIC), so
   MagicDNS forwarding cannot ask the network's resolver outside the tunnel. One leak is left: [Tailscale and DNS](#tailscale-and-dns).
3. Anything sent out through `vvpn0`.
4. The `toranon` user's packets, when that user exists as the kill switch is armed ([tor](#tor-and-the-vpn)).
5. Replies on connections that were opened to this machine, DHCP and DHCPv6, IPv6 neighbour discovery and MLD.
6. The handshake and the tunnel's encrypted packets: the mark `0xca6c` to the endpoint's address and port only.
7. The local network (RFC1918, link-local, `fe80::/10`, `fc00::/7`) except DNS: ports 53 and 853 are rejected there, so the
   network's resolver learns nothing.
8. Syncthing's local discovery: UDP 21027 to `255.255.255.255` and to `ff12::8384` (the subnet broadcast is in the local network
   already), so Sync's Nearby list keeps working with the VPN on.

**Forwarded traffic.** A VM on libvirt's NAT sends its packets through the `forward` chain, which has the same policy as the list
above where it applies: replies on connections that exist, anything out through `vvpn0`, tailnet addresses on `tailscale0`, and the
local network except DNS (items 3 and 7, and the tailscale0 part of item 2); everything else is rejected. The rules about this
machine's own packets (loopback, `tailscaled`, tor, DHCP, the handshake, Syncthing discovery) are not in it. The accept ends only
this chain, so firewalld's and libvirt's own forward rules still run after it.

### Tailscale and DNS

If the tailnet's admin turns on "Override local DNS", `tailscaled` gives `tailscale0` the routing domain `~.` in systemd-resolved.
`vvpn0` has `~.` as well, and resolved sends a lookup that matches the same domain on several links to all of them at once and
returns the first answer (`systemd-resolved(8)`), so every lookup also reaches `tailscaled`'s forwarder. What it does with it:

- upstream resolvers inside the tailnet: through `tailscale0`, which the kill switch allows (tailnet addresses only);
- plain DNS or DNS over TLS to any other resolver: sent from `tailscaled`'s own sockets (mark `0x80000`, uid 0), which the kill switch
  rejects on ports 53 and 853. The lookup fails there and resolved uses `vvpn0`'s answer;
- DNS over HTTPS (port 443) to a public resolver that `tailscaled` knows (Cloudflare, Google, Quad9 and a few more): **this leaves by
  the physical interface.** Port 443 from `tailscaled` is also the control plane and the DERP relays, which have to work, so the kill
  switch cannot tell the two apart. The network sees encrypted traffic to a public resolver, and that resolver sees the names.

The ways to close it are all worse: `tailscale set --accept-dns=false` drops MagicDNS names with it; editing `tailscale0`'s domains
in resolved is undone by `tailscaled` at its next network change; a list of resolver addresses is `tailscaled`'s list and grows; and
refusing its port 443 breaks the tailnet. If this matters to you, turn "Override local DNS" off in the admin console: MagicDNS names
resolve without it, and nothing is then asked on `tailscale0` but the tailnet's own names.

## Privilege

`bin/vekrona-vpn` runs as you. Everything that needs root runs as `vekrona-vpn-apply@<op>-<uid>.service`, a oneshot unit that runs
the root-owned copy of `libexec/vekrona-vpn-apply` (`ensure_system_copy`, under `/usr/local/lib/vekrona`). `op` is one of `import`,
`login`, `connect`, `off`, `forget`, `seal`. `off` takes the tunnel down and removes the kill switch.

- **Polkit** (`etc/polkit-1/rules.d/50-vekrona-vpn.rules`): a member of `wheel` who is at the machine (an active local session) or
  runs inside the user manager (`user@UID.service`, which is what the shell is) may start an apply unit whose name matches that
  exact pattern (the uid has no leading zero, as the helper parses it, so a job has one name), with no password. No other unit and
  no other verb matches. Starting and stopping `tor.service` for the same subjects is the rule of its own,
  `50-vekrona-tor.rules`: it has nothing to do with the VPN's operations.
- **The request.** The arguments (a configuration's text, a uuid and its keys, a Mullvad relay and device) go in
  `/run/user/<uid>/vekrona-vpn/request.json`, which only you and root can enter. The helper takes it only if it opens without
  following a link, is a regular file owned by the uid in the unit's name, is at most 1 MiB and is JSON of the schema it knows.
  The file is one for every operation, and the unit is named after the operation and the uid alone, so `bin/vekrona-vpn` holds a
  lock (`/run/user/<uid>/vekrona-vpn/lock`) from writing the request until it has taken it back: the popout, the launcher and a
  terminal queue behind each other instead of handing over each other's request or merging into one job. `status` and `list` do not
  take it, so the bar keeps updating while a connect waits for its tunnel.
- **The receipt.** The lock lives only as long as the client, and Ctrl-C leaves the job running in systemd. The next call for the same
  operation then runs `systemctl start` on a unit that is already starting, which joins that job: the helper never reads the new
  request, yet `systemctl` succeeds. So every request holds a random nonce, and the helper writes the nonce of the request it served to
  `/run/vekrona-vpn/served/<uid>` (root-owned, world-readable) once the operation ended, and when it failed, the one line it failed
  with. After `systemctl` returns, `bin/vekrona-vpn` compares the nonce with its own and, if they differ, fails with
  `another vekrona-vpn <op> was still running; try again`. When `systemctl` itself fails, the client reports the helper's line from
  the receipt of its own request; without a receipt for it (polkit refused the start, the unit ran into its timeout) it reports
  systemctl's error and says that the helper did not serve the request. It never reads the journal, whose last line may belong to
  an earlier run.
- **Nothing of your file reaches NetworkManager** except the checked fields, and no key of it: the helper parses the configuration
  again and writes it out in one fixed shape, with a placeholder for the key, through a file in a root-only directory (`/run/vekrona-vpn/import`, 0700) that is deleted right after the
  import. An error names a line or a key, never a value. A second lock (`/run/vekrona-vpn/lock`) serializes the helper's
  operations across users, the arming and the removal of the kill switch included.
- **State.** The helper publishes `/run/vekrona-vpn/state.json` (root-owned, world-readable: whether the kill switch is armed and
  for which connection). Nothing writes into your home, and no NetworkManager dispatcher script is involved. `off` publishes
  "disarmed" before it deletes the table. If the publish fails, nothing was deleted and the state still says armed. If `nft` then
  fails to delete the table, `off` publishes the armed state again before it reports the error, so `state.json` never says
  disarmed while the table blocks: the bar keeps showing Blocked and its Off button, and `off` can be run again. `status` reads
  `state.json`, not the kernel: a table that something else removed (a flush of the whole ruleset, `nft flush ruleset`) is not
  noticed, and the bar goes on showing the kill switch armed. Only `connect` looks (`nft list table`) and refuses to bring a tunnel
  up without the table. Nothing in vekrona enables `nftables.service` (the only firewall service it enables is `firewalld`), so
  nothing restores the table after a reboot.

A process of yours can therefore do what you can do with the popout: import a configuration, connect, turn the kill switch off.
[threat-model](threat-model.md#trust-boundaries) says what that means.

## Tor and the VPN

tor bypasses the VPN, on purpose, and the VPN does not break it. Tor Browser's circuits leave by the physical interface: your ISP
sees that you use Tor, and your VPN provider sees none of it. Two pieces do that, both only while tor runs
([Tor Browser](daily-use.md#tor-browser)):

- `vekrona-tor-route.service` (pulled in by `tor.service`) holds `ip rule uidrange <toranon>-<toranon> lookup main priority 100`
  (IPv4 and IPv6). It sits ahead of NetworkManager's WireGuard rules and Tailscale's (5210-5270), so tor's own packets use the
  main routing table, not the tunnel's.
- The kill switch accepts `meta skuid <toranon's uid>`. The uid is looked up when the kill switch is armed, and the rule is left out
  when the user does not exist (nft refuses an unknown user name and the whole table would fail to load). If tor is installed while
  the kill switch is armed, connect again to pick the user up.

Other programs reach tor the same way when they are members of the group `vekrona-tor`, through its socket:
`curl --proxy socks5h://localhost/run/vekrona-tor/socks https://check.torproject.org/api/ip`. torsocks cannot, since its `TorAddress`
takes only an IP address. tor opens no TCP port on purpose, so a program without the socket path cannot reach tor.

## The bar icon

One icon, six states, all in the bar button; a left click opens the popout and a second one closes it.

| Icon | Meaning |
|---|---|
| `vpn_key_off` | Off: no tunnel, no kill switch |
| `pending` | Connecting |
| `vpn_lock` | Connected: the tunnel is up and the kill switch is armed |
| `no_encryption` | Not protected: a tunnel is up and the kill switch is off, so traffic can leave around it (a tunnel brought up outside `vekrona-vpn`) |
| `gpp_bad` | Blocked: the kill switch is armed and there is no tunnel |
| `shield_question` | Status unknown (never shown as off): no `vekrona-vpn status` has answered yet, the last one failed, or `nmcli monitor` is not running, so changes of the network go unseen |

The popout shows the state, the connection in use, an Off button while the kill switch is armed or a tunnel exists, the tree of vendors, countries and
configurations, Import buttons, and the Mullvad account field while you are logged out. A country with one configuration connects
on a click; a Forget button asks first.

## Commands

All of them are for a terminal as well; a failure exits non-zero with one line on stderr.

```
vekrona-vpn status                    # JSON: kill switch armed, tunnel down|activating|up, the connection
vekrona-vpn list                      # JSON: vendors, countries, configurations
vekrona-vpn connect UUID              # arm the kill switch, bring that configuration up
vekrona-vpn connect mullvad NL        # the same for a random Mullvad relay of a country (a code, or a name; a name is echoed: "using Netherlands (NL)")
vekrona-vpn off                       # tunnel down, then the kill switch off
vekrona-vpn import --vendor proton [FILE...]   # no FILE: the file chooser; --vendor proton|other
vekrona-vpn forget UUID               # remove a configuration
vekrona-vpn mullvad login             # account number on stdin; the number and the device's key go to the keyring
vekrona-vpn mullvad logout            # remove this device from the Mullvad account, forget the Mullvad connections, clear the keyring of them
vekrona-vpn seal                      # move the keys of NetworkManager's keyfiles into the keyring (connect does it first when needed)
```

## Known gaps

- A tailnet that overrides local DNS can still send lookups out by DNS over HTTPS to a public resolver ([Tailscale and DNS](#tailscale-and-dns)).
- Stopping `vekrona-vpn` with Ctrl-C while it waits for the helper does not stop the helper: the job runs on in systemd, and it finds its request gone
  if it had not read it yet. A call for the same operation that starts meanwhile fails with "another vekrona-vpn <op> was still running"
  (see the receipt under [Privilege](#privilege)); try again once the job is done.
- One tunnel at a time, no VPN at boot, no IPv6 for a configuration without an IPv6 address.
