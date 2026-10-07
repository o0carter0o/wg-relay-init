# wg-relay

A small, provider-agnostic kit that turns a fresh **Debian 13 VPS** into a
WireGuard relay for a home **OPNsense** firewall. Its job is to give a home
network a real public IPv4 address while it is failed over to a **CGNAT LTE
backup WAN**.

Everything runs natively: kernel WireGuard + `wg-quick`, nftables, Linux IP
forwarding, and systemd. No Docker, no provider-specific tooling.

```
            NORMAL                                    FAILOVER (primary WAN down)

  Internet                                  Internet
     │  example.com -> primary IP              │  example.com -> VPS IP (ddclient updates it)
     ▼                                         ▼
┌──────────────┐                     ┌──────────────────────────────┐
│ Primary WAN  │                     │ Debian 13 VPS (public IPv4)  │
│ (dynamic IP) │                     │  nft: DNAT inbound ports     │
└──────┬───────┘                     │       masquerade egress      │
       │                             │  wg0 10.250.0.1              │
       │                             └──────────────▲───────────────┘
       │                                            │ WireGuard UDP 51820
       │                                            │ (OPNsense initiates;
       │                             ┌──────────────┴───────────────┐  pinned to LTE)
       │                             │ LTE WAN (CGNAT)              │
       │                             └──────────────▲───────────────┘
┌──────▼────────────────────────────────────────────┴───────────────┐
│ OPNsense   gateway group: tier 1 primary WAN -> tier 2 WireGuard   │
│            wg 10.250.0.2                                            │
└─────────────────────────────────┬──────────────────────────────────┘
                                  │
                                 LAN
```

**How failover works.** OPNsense keeps the tunnel up over LTE at all times.
When the primary WAN fails, OPNsense's gateway group switches to the
WireGuard gateway, so all traffic, in and out, goes through the VPS. Because
outbound traffic now leaves from the VPS, ddclient's normal web-based IP check
sees the VPS address and updates DNS automatically. When the primary returns,
traffic and DNS move back. The VPS itself needs no knowledge of any of this.

---

## Contents

- [Quick start](#quick-start)
- [Installation types](#installation-types)
- [Keys](#keys)
- [Migrating to another VPS](#migrating-to-another-vps)
- [Changing settings later](#changing-settings-later)
- [Installer options](#installer-options)
- [Configuration reference](#configuration-reference)
- [OPNsense configuration](#opnsense-configuration-high-level)
- [Firewall model](#firewall-model)
- [Status and troubleshooting](#status-and-troubleshooting)
- [Removing wg-relay](#removing-wg-relay)
- [Security considerations](#security-considerations)
- [Files](#files)

---

## Quick start

Open UDP 51820 in your provider's firewall or security group first, if it has
one; the installer can't change provider-level firewalls.

```bash
tar xzf wg-relay.tar.gz      # or: git clone <your-repo-url> wg-relay
cd wg-relay
nano config.env              # forwarded ports, addressing, etc.
./install.sh                 # as root, or with sudo
```

`config.env` ships with working defaults. If you run the installer without
changing anything, it says so and asks `Continue anyway? [y/N]`.

The installer works in four phases:

1. **Check** (changes nothing): root, Debian 13, not a container, a valid
   `config.env`.
2. **Packages**: installs anything missing, showing apt's normal output and
   progress bar.
3. **Ask and confirm**: installation type, keys, then the plan and
   `Do you want to continue? [Y/n]`. Nothing is written before this point.
4. **Do**: writes config and keys, applies the firewall (with an SSH access
   check), WireGuard and kernel settings, checks the result, and prints the
   OPNsense settings.

Progress shows as `[3/5] Configuring firewall... done`. Every detail is written
to `/var/log/wg-relay-install.log`; `--verbose` shows it live.

---

## Installation types

```
Installation type:
  1. New tunnel     set up both ends from scratch
  2. Migration      move an existing tunnel to this VPS
  3. Reconfigure    re-apply config.env on this VPS (keys kept unless you change them)
Selection [1]:
```

The default is **3** when wg-relay is already installed on this VPS, otherwise **1**.

- **New tunnel** asks for all three keys (see [Keys](#keys)).
- **Migration** asks you to paste the block from `./install.sh --export` on the
  old VPS. Same as running `./install.sh --import`.
- **Reconfigure** re-applies `config.env`: firewall, WireGuard config, kernel
  settings. It asks `Keep the current keys? [Y/n]`; answer `n` to replace any of
  them.

A new tunnel looks like this:

```
wg-relay 0.9.0
[1/5] Installing packages... done

Installation type:
  1. New tunnel     set up both ends from scratch
  2. Migration      move an existing tunnel to this VPS
  3. Reconfigure    re-apply config.env on this VPS (keys kept unless you change them)
Selection [1]: 1

VPS private key
Generate a new private key? [Y/n]

OPNsense instance public key
  Copy from: OPNsense > VPN > WireGuard > Instances > (instance) > Public key
Public key (leave blank to skip): 1NvS...VA=

Use a pre-shared key? [y/N] y
Generate a new pre-shared key? [Y/n]

The following will be configured:
  Installation type  New tunnel
  WAN interface      eth0 (SSH port 22 stays open)
  Tunnel             10.250.0.1/24 <-> 10.250.0.2, UDP 51820, MTU 1380
  Relay egress       yes, masqueraded
  Inbound forwards   TCP 443, 8080; UDP none
  VPS private key    (hidden)                                      (generated)
  VPS public key     j/A2genx4Mq8byEEzFw6lpzeloyOAnpZ8wMeONs/RQk=  (derived)
  Instance key       1NvS9Rf5d70mXQHfUv1nHgpoegXY47oalnYuzfhWeVA=  (pasted)
  Pre-shared key     HuqNnin+sa0MulvMp2fkED4xRFcCG3oj6sHf7ljSToc=  (generated)
  Changes            firewall rules, WireGuard config, kernel settings, firewall service, key files, config.env
Firewall changes need an SSH access check; you will be asked.
Do you want to continue? [Y/n]

[2/5] Writing configuration and keys... done
[3/5] Configuring firewall...

Firewall rules applied. They roll back in 120 seconds unless kept.
Open a new SSH session to this server to check access.
Keep the new firewall rules? [y/N] y
[3/5] Configuring firewall... done
[4/5] Configuring WireGuard... done
[5/5] Checking installation... done

OPNsense settings (VPN > WireGuard):
  Instances > (instance)
    Public key      1NvS9Rf5d70mXQHfUv1nHgpoegXY47oalnYuzfhWeVA=  (pasted)
    Tunnel address  10.250.0.2/24
    MTU             1380
    Disable routes  checked
  Peers > (peer)
    Public key      j/A2genx4Mq8byEEzFw6lpzeloyOAnpZ8wMeONs/RQk=  (derived)
    Pre-shared key  HuqNnin+sa0MulvMp2fkED4xRFcCG3oj6sHf7ljSToc=  (generated)
    Endpoint        203.0.113.10 or your relay DNS name, port 51820
    Allowed IPs     0.0.0.0/0
    Keepalive       25
  System > Gateways
    Gateway         10.250.0.1

OPNsense must match every key above.
The pre-shared key is shown in full only now; later: cat /etc/wireguard/preshared.key

Tunnel is waiting for OPNsense to connect.
Export: ./install.sh --export    Status: wg-relay-status    Log: /var/log/wg-relay-install.log
```

Every key is shown the same way: value, then what happened to it this run:
`generated` (created on this VPS), `pasted` (entered or imported), `derived`
(the VPS public key, calculated from the private key) or `unchanged`. Secrets
are never shown in full, except a newly generated pre-shared key, which you
need to paste into OPNsense.

### The SSH safety net

When the firewall rules change, the installer:

1. arms a **systemd timer** that restores the previous rules after
   `ROLLBACK_TIMEOUT` seconds (120 by default). It runs under systemd, so it
   still fires if your SSH session dies;
2. loads the new rules;
3. asks `Keep the new firewall rules? [y/N]`. Open a **new** SSH session first;
   if it connects, answer `y`. Enter or no answer means *no*.

Existing sessions always survive (established connections are accepted), so
only a *new* connection proves you aren't locked out. If you don't confirm,
or the installer exits early, the rules are rolled back. The rules are only
saved for boot **after** confirmation, so a reboot also returns to the last
confirmed ruleset.

The installer also refuses to run if your current SSH session's port isn't in
the allowed SSH ports.

Use `--no-confirm` only for unattended runs where you have console access.

---

## Keys

A working tunnel uses four key values, plus an optional fifth. The installer
uses the names OPNsense shows:

| Key | Lives on | OPNsense name | On the VPS |
|---|---|---|---|
| VPS private key | VPS only | (never seen) | `/etc/wireguard/private.key` |
| VPS public key | derived from the private key | **Peer public key** | printed by the installer |
| OPNsense private key | OPNsense only | Instance private key | never touches the VPS |
| OPNsense public key | derived from OPNsense's private key | **Instance public key** | `WG_PEER_PUBLIC_KEY` in `config.env` |
| Pre-shared key (optional) | both, identical | **Peer pre-shared key** | `/etc/wireguard/preshared.key` |

- **Each side holds its own private key and the other side's public key.** A
  public key is always derived from its private key, so a new VPS private key
  means a new peer public key on OPNsense, and the same private key means no
  change.
- **Every key can be generated or entered.** Answer `n` to "Generate..." to
  paste an existing key instead. Secrets (private and pre-shared keys) are read
  with input hidden. The instance public key is shown as you paste it, because
  it isn't secret and you'll want to see it.
- **Secrets are confirmed without being shown.** The private key shows as
  `(hidden)` with its derived public key on the next line (the value you compare
  on OPNsense); a pasted or existing pre-shared key shows its first and last four
  characters.
- **Nothing is written until you confirm the plan.** New keys are generated in
  memory first.
- **The pre-shared key is optional.** It adds a second secret as a hedge against
  future quantum attacks on recorded traffic. Each new one means another value
  to paste into OPNsense, so the question defaults to no.

---

## Migrating to another VPS

```
old VPS:  ./install.sh --export      copy the block it prints
new VPS:  ./install.sh --import      paste the block, confirm
```

`--export` (also installed as `wg-relay-export`) prints every `config.env`
setting plus the keys:

```
-----BEGIN WG-RELAY MIGRATION-----
# wg-relay 0.9.0, exported from relay-old, 2026-10-07 20:26 UTC
WG_INTERFACE=wg0
WG_PORT=51820
...
FORWARD_TCP_PORTS=443 8080
...
WG_PRIVATE_KEY=...
WG_PRESHARED_KEY=...
-----END WG-RELAY MIGRATION-----
W: this block contains secret keys. Paste it only into the new VPS: ./install.sh --import
```

On the new VPS, `--import` (or choosing **Migration**) asks you to paste it.
Input is hidden. It then shows exactly what changes:

```
Changes to config.env:
  WG_PEER_PUBLIC_KEY: (empty) -> 1NvS...VA=
  FORWARD_TCP_PORTS: (empty) -> 443 8080
Keys in the block:
  VPS private key    public key e1JV...BC4=
  Instance key       1NvS...VA=
  Pre-shared key     GYgL...Vrg=
Write these settings to config.env? [Y/n]

Keep the old VPS identity (no key change on OPNsense)? [Y/n]
```

Keeping the old identity means OPNsense's keys need no change at all. The
normal plan and confirmation follow. Afterwards:

1. Point your relay DNS name at the new VPS.
2. Update the OPNsense static route that pins the tunnel to LTE.
3. Check `wg-relay-status` for a handshake, then destroy the old VPS.

The block is never written to a file. A WAN interface name from the old
provider that doesn't exist on the new VPS is switched to `auto`.

---

## Changing settings later

Edit `config.env` and run `./install.sh` again, choosing **Reconfigure** (the
default once installed). Only what changed is applied:

- **Firewall rules**: reloaded, with the SSH access check.
- **WireGuard peer changes**: applied live with `wg syncconf` (no tunnel drop).
- **Interface changes** (address, port, MTU): WireGuard restarts briefly.
- **Keys**: unchanged unless you answer `n` to `Keep the current keys?`.

The plan's **Changes** line says exactly which of these will happen, and reads
`none (already up to date)` when there's nothing to do. `./install.sh --dry-run`
shows the plan and the file diffs without asking or changing anything.

---

## Installer options

| Option | Effect |
|---|---|
| `--export` | Print a migration block (settings and keys) |
| `--import` | Migrate this VPS from a pasted migration block |
| `--dry-run` | Show the plan and file diffs; change nothing |
| `--config FILE` | Use FILE instead of `./config.env` |
| `--no-prompt` | Ask nothing: reconfigure with `config.env`, keep keys (generate any that are missing) |
| `--no-confirm` | Skip the SSH access check (and the automatic firewall rollback) |
| `--ignore-other-firewalls` | Continue even if ufw / firewalld / legacy iptables rules are active |
| `-v`, `--verbose` | Show every step on screen (always written to the log) |

---

## Configuration reference

`config.env` ships with working defaults and is **parsed, not executed**: plain `KEY=value` lines, optional
quotes, `#` comments. Unknown keys are rejected so typos are caught. After any
edit, re-run `sudo ./install.sh`.

| Variable | Default | Purpose |
|---|---|---|
| `WG_INTERFACE` | `wg0` | Tunnel interface name (`wg-quick@<name>`) |
| `WG_PORT` | `51820` | UDP listen port |
| `WG_SERVER_ADDRESS` | `10.250.0.1/24` | VPS tunnel address and subnet. Must not clash with home or WAN subnets |
| `WG_PEER_ADDRESS` | `10.250.0.2/32` | OPNsense tunnel address. Inbound forwards are sent here |
| `WG_MTU` | `1380` | Tunnel MTU. Conservative for LTE; set the same on OPNsense |
| `WG_PRIVATE_KEY_FILE` | `/etc/wireguard/private.key` | Where this VPS's private key is stored. Set by the installer's key questions |
| `WG_PRESHARED_KEY_FILE` | *(empty)* | Pre-shared key: empty = not decided, `none` = none, or a key file path. Set by the installer |
| `WG_PEER_PUBLIC_KEY` | *(empty)* | OPNsense instance public key. Set by the installer, or edit it here |
| `WG_PEER_ALLOWED_IPS` | `10.250.0.2/32` | Sources accepted from the peer. Add LAN subnets if OPNsense does not NAT onto the tunnel. `/0` is rejected |
| `WAN_INTERFACE` | `auto` | Detected from the route to the Internet; set a name only if detection is wrong |
| `SSH_PORTS` | `auto` | SSH ports to allow; or an explicit list like `22 2222` |
| `ENABLE_IPV4_FORWARDING` | `yes` | Required for egress and port forwards |
| `ENABLE_IPV6_FORWARDING` | `no` | Tunnel is IPv4-only. If `yes`, RAs keep working on the WAN (`accept_ra=2`) |
| `CONNTRACK_MAX` | *(empty)* | Optional conntrack table size (e.g. `131072`) |
| `RELAY_EGRESS` | `yes` | Allow the peer to use the VPS as its Internet gateway |
| `MASQUERADE_EGRESS` | `yes` | NAT egress traffic behind the VPS's public IP |
| `FORWARD_TCP_PORTS` | *(empty)* | Public TCP ports/ranges DNAT'd to the peer, e.g. `80 443` |
| `FORWARD_UDP_PORTS` | *(empty)* | Public UDP ports/ranges DNAT'd to the peer |
| `TUNNEL_INPUT_TCP_PORTS` | *(empty)* | TCP ports on the VPS reachable only from the peer |
| `ROLLBACK_TIMEOUT` | `120` | Seconds before unconfirmed firewall changes roll back |
| `ALLOW_UNSUPPORTED_OS` | `no` | Permit non-Debian-13 systems |
| `PUBLIC_IP_LOOKUP_URL` | `https://api.ipify.org` | Only used when the WAN has no public IP (1:1 NAT) and curl exists. Empty = never |

Validation catches the dangerous cases, including: a `/0` in
`WG_PEER_ALLOWED_IPS` (wg-quick would route the VPS's own traffic into the
tunnel), allowed IPs or the tunnel subnet overlapping the WAN network,
forwarding the VPS's SSH port, forwarding `WG_PORT`, and the current SSH
session's port missing from `SSH_PORTS`.

---

## OPNsense configuration (high level)

OPNsense menu names vary slightly between versions; the concepts below don't.

1. **WireGuard instance** (VPN → WireGuard → Instances): generate a keypair,
   tunnel address `10.250.0.2/24`, MTU `1380`, enable **Disable routes**, and
   set the gateway to `10.250.0.1`. Copy its public key into
   `WG_PEER_PUBLIC_KEY` on the VPS.
2. **Peer**: public key = the VPS's key (printed by the installer), endpoint =
   your relay DNS name (e.g. `relay.example.com`) or the VPS IP, port `51820`,
   allowed IPs `0.0.0.0/0`, keepalive `25` (use `15` if your carrier's NAT
   drops idle UDP quickly). Add the preshared key if you use one.
3. **Assign the interface** (e.g. `WG_RELAY`) and enable it. Assigning it
   gives you per-interface rules, NAT, and a gateway.
4. **Gateway**: a gateway on `WG_RELAY` with address `10.250.0.1` and a
   monitor IP that is reached **through** the tunnel (e.g. a public resolver),
   so monitoring tests the VPS's Internet path, not just the tunnel.
5. **Pin the tunnel to LTE**: a static route for the VPS's public IP `/32` via
   the LTE gateway. Otherwise, once the WireGuard gateway becomes the default,
   the tunnel would try to route through itself. (Update this route when you
   migrate VPS providers.)
6. **Gateway group**: primary WAN on tier 1, the WireGuard gateway on tier 2.
   Use it on your LAN rules (policy routing).
7. **OPNsense's own traffic** (ddclient, DNS, updates) follows the system
   default route, not LAN rules. Enable default gateway switching and give the
   WireGuard gateway a better priority than the LTE gateway, so that during an
   outage OPNsense defaults to the tunnel, never to raw CGNAT LTE.
8. **Outbound NAT**: NAT LAN traffic leaving `WG_RELAY` to the interface
   address (`10.250.0.2`). This matches the default `WG_PEER_ALLOWED_IPS`.
   If you'd rather not NAT, add your LAN subnets to `WG_PEER_ALLOWED_IPS`
   instead.
9. **Port forwards**: for every service you expose, add a port forward on
   `WG_RELAY` mirroring the one on your primary WAN, and list the same ports
   in `FORWARD_TCP_PORTS` / `FORWARD_UDP_PORTS`. Because `WG_RELAY` has a
   gateway, OPNsense applies reply-to, so replies return through the tunnel
   and clients' real source IPs are preserved.
10. **ddclient**: keep the normal **web-based** IP check over the default
    route. During failover it sees the VPS address and updates DNS; when the
    primary returns, it sees the primary address again.

IPv6 is not relayed. If home devices use IPv6 via the primary WAN, that
traffic stops during failover rather than flowing through the VPS.

---

## Firewall model

The kit owns exactly **one** nftables table, `inet wg_relay`, loaded by its own
unit, `wg-relay-firewall.service`. It never touches `/etc/nftables.conf` or
other tables. Debian's stock `nftables.service` flushes the *entire* ruleset on
stop and reload, so wg-relay keeps its rules separate and reloads its table
if `nftables.service` is restarted.

The `inet` family covers IPv4 and IPv6 in one table, so the host's own IPv6
is firewalled too.

**input** (traffic to the VPS), policy drop:
loopback; established/related; essential ICMP and ICMPv6 (PMTU errors,
neighbor discovery, router advertisements) plus rate-limited ping; DHCPv6
replies; UDP `WG_PORT`; TCP SSH ports; and from the peer only, any
`TUNNEL_INPUT_TCP_PORTS`. SSH and WireGuard are accepted on any interface, so a
renamed NIC can't lock you out.

**forward** (traffic through the VPS), policy drop:
MSS clamped to path MTU; established/related; Internet → tunnel only for
connections that were DNAT'd (`ct status dnat`); tunnel → Internet only from
`WG_PEER_ALLOWED_IPS`, and only if `RELAY_EGRESS=yes`.

**dstnat**: public `FORWARD_TCP_PORTS` / `FORWARD_UDP_PORTS` → `WG_PEER_ADDRESS`,
same port, source address preserved.

**srcnat**: masquerade egress from the peer behind the VPS's public IP
(`MASQUERADE_EGRESS`).

**Adding a port forward**: add it to `FORWARD_TCP_PORTS` or `FORWARD_UDP_PORTS`,
re-run `sudo ./install.sh`, and add the matching port forward on OPNsense's
`WG_RELAY` interface. Because the forward chain accepts anything DNAT'd, no
separate filter rule is needed.

**Other firewalls**: if ufw, firewalld, or legacy iptables rules are active, the
installer stops (override: `--ignore-other-firewalls`). With multiple
nftables tables, a packet must be accepted by *every* base chain on a hook.
This matters if you later add Docker for monitoring: Docker sets its own
`FORWARD` policy to drop, which would drop relayed traffic. Run such
containers with host networking, or allow the relay in Docker's `DOCKER-USER`
chain.

---

## Status and troubleshooting

```bash
wg-relay-status              # one-screen summary
wg-relay-diagnostics > diag.txt        # full dump; no private keys
less /var/log/wg-relay-install.log     # everything the installer did
wg show
ip addr show wg0
systemctl status wg-quick@wg0 wg-relay-firewall
```

`wg-relay-status` shows: OS, hostname, WAN interface, public IPv4, WireGuard
state, peer endpoint, latest handshake, RX/TX, forwarding state, firewall
state with drop counters, configured forwards, and routes.

| Symptom | Things to check |
|---|---|
| No handshake ever | Provider firewall/security group allows UDP `WG_PORT`; OPNsense endpoint and port; keys swapped correctly (each side holds the *other's* public key); `WG_PEER_PUBLIC_KEY` set and installer re-run; PSK identical on both sides |
| Handshake, but no traffic | Source addresses outside `WG_PEER_ALLOWED_IPS` (OPNsense not NATing onto 10.250.0.2?); `RELAY_EGRESS`; IPv4 forwarding; forward drop counter rising in `wg-relay-status` |
| Handshake goes stale on LTE | Lower OPNsense keepalive to 15; check the static route pins the tunnel to the LTE gateway |
| Inbound forwards fail | Port listed in `FORWARD_*_PORTS`; matching port forward and rule on OPNsense's `WG_RELAY` interface; `WG_RELAY` has a gateway (needed for reply-to) |
| Some sites or uploads hang | MTU: lower `WG_MTU` on both sides (e.g. 1360 or 1340) |
| `nf_conntrack: table full` in kernel log | Set `CONNTRACK_MAX` (e.g. `131072`) and re-run |
| Installer: "another firewall manager is active" | Disable ufw/firewalld, or use `--ignore-other-firewalls` if their rules allow the relay |

Useful packet capture (install `tcpdump` first):

```bash
sudo tcpdump -ni any udp port 51820                     # tunnel packets arriving?
sudo tcpdump -ni wg0                                     # traffic inside the tunnel
```

**Locked out of SSH?** Use your provider's web console, then:

```bash
nft delete table inet wg_relay          # VPS unfiltered until next boot / start
systemctl stop wg-relay-firewall        # same, via the unit
```

Fix `config.env` (e.g. set `SSH_PORTS`) and re-run the installer.

---

## Removing wg-relay

```bash
./uninstall.sh
```

No prompts. It stops WireGuard and removes the firewall table, configs,
**keys**, helper commands, sysctl settings and install log. It also turns IP
forwarding off and purges the packages the installer added
(`wireguard-tools nftables jq`). The repo folder and `config.env` are left alone.
Run `./install.sh --export` first if you might want the keys back.

---

## Security considerations

- **During failover, the VPS provider carries all your traffic.** It can see
  metadata and anything not encrypted end-to-end. Pick a provider you trust.
- **Forwarded ports are public.** Anything in `FORWARD_*_PORTS` is reachable
  from the whole Internet via the VPS. OPNsense still filters behind it, so
  keep its rules tight.
- **Key handling**: key files are 0600 root-only and never passed on a command
  line. Keys are not in `config.env` or `wg0.conf` (a `PostUp` line loads the
  private key from its file). Secrets are typed or pasted with input hidden, and
  confirmed without being shown: the private key by its public key, a pre-shared
  key by its first and last four characters.
- **The migration block contains secret keys.** `--export` only prints it, never
  saves it. Paste it straight into `--import` on the new VPS, and clear your
  terminal scrollback afterwards if that matters to you.
- **SSH is exposed** on the VPS's public IP (as on any VPS). Use key-only
  authentication (`PasswordAuthentication no`). fail2ban is optional and out
  of scope.
- **Minimal attack surface**: inbound is limited to SSH, WireGuard, essential
  ICMP, and the ports you explicitly forward. Nothing is forwarded by default,
  and there is no blanket "accept everything from wg0" rule.
- **Updates**: consider `unattended-upgrades` for security patches. This kit
  doesn't configure it.
- **Provider firewall**: if your provider offers one, it can add a second layer
  (allow only SSH, UDP 51820, and your forwarded ports).

---

## Files

Repository:

```
wg-relay/
├── install.sh                 installer: new tunnel, migration, reconfigure, export/import
├── uninstall.sh               removes everything install.sh added (no prompts)
├── config.env                 settings (ships with working defaults; no secrets)
├── README.md
├── .gitignore                 keeps key files out of git
├── lib/common.sh              shared parser, validation, detection, migration block
├── templates/
│   ├── wg0.conf               WireGuard interface (no secrets)
│   ├── wg-relay.nft           nftables table inet wg_relay
│   ├── wg-relay-firewall.service
│   └── sysctl.conf
└── scripts/
    ├── status.sh              -> /usr/local/sbin/wg-relay-status
    ├── diagnostics.sh         -> /usr/local/sbin/wg-relay-diagnostics
    └── export.sh              -> /usr/local/sbin/wg-relay-export
```

Installed on the VPS:

| Path | Purpose |
|---|---|
| `/etc/wg-relay/config.env` | Installed copy of the config |
| `/etc/wg-relay/wg-relay.nft` | Last *confirmed* firewall ruleset |
| `/etc/wireguard/wg0.conf` | WireGuard interface config (no secrets) |
| `/etc/wireguard/private.key` | VPS private key (0600) |
| `/etc/wireguard/preshared.key` | Pre-shared key, if used (0600) |
| `/etc/systemd/system/wg-relay-firewall.service` | Loads the firewall table at boot |
| `/etc/sysctl.d/99-wg-relay.conf` | Forwarding and conntrack settings |
| `/etc/modules-load.d/wg-relay.conf` | Only when `CONNTRACK_MAX` is set |
| `/usr/local/lib/wg-relay/` | Helper scripts behind the `wg-relay-*` commands |
| `/var/log/wg-relay-install.log` | Installer log |
