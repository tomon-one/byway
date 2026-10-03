# When byway does not work

A page for when something is broken: five commands that show where the
fault is, and common symptoms with what to check and what to do.

The commands run on the router, in an ssh console. Most of this is in the
web UI too, but the console shows more. Output is quoted as it appears with
the English dictionary installed (`byway lang en`).

---

## Where to start

### `byway status`

Plain `byway` prints the same, plus the list of commands. A snapshot of what
is built, what is running and what is in the kernel.

| line | meaning |
|---|---|
| `config` | size of the built engine config; `NO` means no config has been built |
| `transport`, `key` | transport and security from the config, key name (the part after `#` in the link) |
| `connection`, `now` | in auto-select mode, instead of the two lines above: how many keys there are and which one is in use |
| `engine`, `xray` | Xray-core version and path, PID or `not running` |
| `memory` | how much the engine uses and the memory limit it runs under |
| `nft table`, `ip rule`, `route` | the three parts of the interception rules; all `yes` while byway works |
| `dnsmasq ->` | where dnsmasq forwards queries; while byway works, the byway resolver, `127.0.0.42` by default |
| `routes with their own exit` | how many routes have their own exit; absent when there are none |
| `fakeip` | the first domain on the list and the placeholder address it got; `NOT issued` means the resolver did not answer with a pool address |
| `in tproxy` | packets intercepted so far; grows while devices open sites on the list |
| `overnight` | how the automatic update ended |
| `update` | a new byway version is out; its description and the install command follow |

`WARNING` lines matter more than the rest. "Config was built for another mode"
is fixed by `/etc/init.d/byway reload` (it rebuilds the config itself and
restarts the service if it changed); the lines about blocked access are covered in
["Block" shut off the internet](#block-shut-off-the-internet). The web UI
shows them on the Overview tab; the full output is under Maintenance → Full
status. `byway status --short` prints only the top part, up to the `engine`
line.

### `byway health`

Four checks in a few seconds, one line each:
`name<TAB>ok|warn|fail<TAB>detail`. In the web UI this is the Check block on
the Overview tab.

| line | what it checks | `fail` means |
|---|---|---|
| `service` | whether the engine runs | no engine; the other lines then say `nothing to check` |
| `vpn` | TCP connect time to the server, directly from the router; over 400 ms is `slow` | the server does not accept connections on that address and port |
| `tunnel` | a request to `example.com` through the router's proxy inbound and the VPN | the server is reachable, but traffic does not pass through it |
| `dns` | whether `example.com` gets an address from the placeholder pool | the byway resolver does not answer |

byway always sends `example.com` through the VPN, whatever the lists say;
the checks rely on it. In auto-select mode `vpn` measures all keys at once: how many answer and the
best latency, `warn` means not all answer; for UDP keys (hysteria2, wireguard,
mKCP) latency is not measured; in
custom config mode byway does not know the server address and `vpn` shows
`warn`.

**`starting` is not an error.** Xray-core takes about 15 seconds to come up.
While the process is younger than 25 seconds and the service was started
less than a minute ago, `service` shows `warn starting` and failed checks
show `still starting`. Ask again in half a minute. If the engine keeps
crashing, `health` shows the real failure a minute after the service start.

`tunnel` goes through the router's proxy inbound, not through the
interception rules. Four `ok` lines mean the engine, the key and the server
work, not that devices at home reach the tunnel. That shows in the
`nft table`, `ip rule` and `route` lines and the `in tproxy` counter of
`byway status`.

### `byway doctor`

An environment check: from autostart, cron jobs and kernel modules to the
key, lists, IPv6, the router's networks and neighbouring services.

`[ ok ]` is fine, `[ ?? ]` is worth knowing, `[ !! ]` is a fault. Under each
`[ ?? ]` and `[ !! ]` line there is what to do, often as a ready command.
With faults the command exits with code 1. In the web UI —
"Maintenance → Check the environment".

### `byway report`

A report for a bug thread as one text: hardware and firmware, the output of
`doctor`, `status` and `health`, the connection shape (protocol, transport,
security, port), settings, list sizes, interception rules, the last lines of
the logs. It contains no key, server address, subscription address or custom
outbound config: settings are printed from an allow-list, everything else is
`<hidden>`, and only errors are taken from the engine log, without
connection lines and with addresses and names replaced by `x.x.x.x`, `x::x`
and `NAME`.

`byway report FILE` creates the file with mode 600 from the start. Paths like
`/tmp/byway-…` are refused, byway keeps its working files there.
`/tmp/report.txt` works. In the web UI — "Maintenance → Collect a report",
the text appears on the page.

### `logread -e byway` and `logread -e xray`

The OpenWrt system log with a filter. `logread -e byway` holds byway's own
messages: interception rules did not load, the 5-minute check restored
removed rules, the engine restarted, the config did not build, how the
automatic update ended. `logread -e xray` holds the engine's messages; at the
default log level these are errors and warnings only.

### State log

The file `/etc/byway/health.log`. The 5-minute check writes it, and only
when something changed. In the web UI: Maintenance → State log.

```
2026-10-01 03:15  pid=2817 nft=1 rule=1 route=1 dns=127.0.0.42 fakeip=yes  (restart)
```

`pid` is the engine process, a new one means a restart. `nft`, `rule`,
`route` are the parts of the interception rules, `dns` is where dnsmasq
points, `fakeip` is whether the resolver hands out placeholder addresses.
Marks: `(start)` the first entry after a reboot or `byway clear log`,
`(restart)` the engine restarted, `(healed)` someone removed the
rules and they were put back, `(failed)` putting them back failed, `(nodns)`
there was no engine on two checks in a row (one to two minutes) and
interception was removed; if `byway pulse` removed it, the log has a line with
`pid=none` and no mark.

---

## Nothing goes through the VPN

Run `byway health` and follow the first `fail` line.

`service fail`: start with `byway doctor`, it names a byway switched off in
the settings and a missing autostart right away. Then `/etc/init.d/byway
restart`: on failure the service prints the reason. With no engine it names a
file found next to it, `/usr/local/bin/xray-*`, and if there is none, installs
the engine itself in the background (`byway engine restore`). That is what the
first minutes after a firmware upgrade look like; progress is in `logread -e
byway`, the line `no core — installing Xray …`. If it fails, the watchdog
retries every 15 minutes; by hand — `byway engine restore`. If the config did not
build, `byway gen` shows the engine's answer and, for known causes, what to
do; the draft stays in `/tmp/byway-config.new.json`. If the new config fails
but the engine accepts the previous one, the service starts on the previous
one, and the latest settings changes do not take effect. The engine runs as the
`byway` user in a `procd-ujail` cage; if it fails to start only there
(`doctor`: the engine runs not as root and crashes in a loop), return to root:
`uci set byway.main.xray_root=1 && uci commit byway && /etc/init.d/byway
restart`.

`vpn fail`: the router cannot open a connection to the server. The server
is down, changed its address or port, or the address is unreachable from
your line. The key can be checked on its own, without the running tunnel:

```sh
byway check              # parse the key, no connections: ACCEPTED or REJECTED
byway probe              # one connection through the key: WORKS or DOES NOT WORK
byway probe 'vless://…'  # the same for any other key
byway probe --all        # every auto-select key in turn, then "N of M work"
```

In auto-select mode there is no key in `node_url`: use `byway probe --all`, or
pass the link as an argument. A key that byway refuses during the build does
not enter auto-select: `byway gen` prints `key skipped: REASON`, and the other
keys keep working.

`tunnel fail` with `vpn ok`: the server is reachable, but it did not accept
the key or does not let traffic out. Engine errors:
`logread -e xray | tail -30`. If `probe` works and `tunnel` does not, run
`/etc/init.d/byway restart` and `byway health` again.

`dns fail`: the byway resolver does not answer. The `dnsmasq ->` line of
`byway status` should show `127.0.0.42` (or your `dns_listen`). Another
address or `ISP` while the engine runs means the interception rules are gone:
`byway plumb on`.

All four `ok`, yet devices bypass the VPN: look at `byway status`. `NO` in
the `nft table`, `ip rule` or `route` line is fixed with `byway plumb on`: it
re-lays the table in one transaction, restores the rule and the route, and
lifts the block only after success.

If everything is in place but `in tproxy` does not grow while a device opens
a site on the list, its traffic does not reach interception: the device has
its own DNS, or its network is not in byway's interface list. Both cases are
below.

---

## One site does not open

Whether a domain is on the list shows on the router with
`nslookup DOMAIN 127.0.0.1`. An address from `198.18.0.0/15` (unless the pool
was changed) means it is on the list and goes through the VPN. A real address
means it is not on the list, or a pin in `/etc/hosts` overrides it
(`byway doctor` counts them), or `byway gen` dropped the line as unsuitable,
naming the count and examples even when the config did not change because of
it; the count is also in `byway report`, the `lines dropped` line. A plain
entry covers subdomains too, `full:`
covers only the name itself.

After editing `/etc/byway/domains.lst` or `subnets.lst` in the console, run
`/etc/init.d/byway reload` (in the web UI, Save & Apply). The service
rebuilds the config and restarts only if it changed; the tunnel drops for a
few seconds. A device may have cached the old address: restart the browser
or wait.

The page opens partly, login fails, video does not load: the site pulls data
from other domains. They show in the browser developer tools (the Network
tab) and need adding too. Which list entries are actually used is shown by
`byway top`; it needs Statistics collection on the Maintenance tab, and
`byway stat` collects the data right away.

A service listed by subnets needs its domains as well. A subnet is
intercepted by address and brings the connection to the engine, but the
engine decides "VPN or direct" by the name inside the connection (SNI or
Host). If the name is not on the list, the engine resolves it again and
compares the result with the subnets. The DNS answer may differ from the
address the device used, and then the connection goes direct.

Where the engine sent a connection is written to `/var/run/byway/access.log` when
Statistics collection is on or Advanced → Log detail is set to "every
connection":

```sh
grep 'tproxy-in -> ' /var/run/byway/access.log | tail -20
```

`-> proxy` went into the VPN, `-> direct` was intercepted and let out
directly. For list domains the line holds the placeholder address, not the
name: get it with `nslookup` first, then search for it. The detailed log
keeps the address of everything opened on the network; set the level back
afterwards.

Whether the server itself reaches the site is checked past the router's
rules: `PROBE_URL=https://DOMAIN/ byway probe`. `WORKS` means the server
reaches it and the problem is routing on the router (any response code,
403 and 302 included, counts as success). `DOES NOT WORK` means the site is
unreachable from the server, and no list will help.

A site broken only by the ISP faking DNS answers needs no tunnel. byway's
resolver asks a DoH server (`dns_upstream`, `https://8.8.8.8/dns-query` by
default) about everything not on the list, so a faked answer never reaches
the device. If the site opens with byway running and without a list entry,
leave it off the list: on the list it would go out from the VPN server's
address for no reason.

---

## One device bypasses the VPN

DNS decides the route. byway recognises the traffic to send by the
placeholder address it hands out itself. A device with its own DNS asks
somebody other than the router, gets the real address and goes direct. The
router cannot see this.

Check from the device, if it has a console: `nslookup example.com`. An
address from `198.18.0.0/15` means the device uses the router's resolver; a
real one means it has its own DNS. Where to look: Android, "Private DNS"
(the name varies by vendor), set it to Off or Automatic; browsers, DNS over
HTTPS (Firefox "DNS over HTTPS", Chrome "Use secure DNS"); iOS and macOS, DNS
profiles and apps that set their own resolver.

Firefox that turned DoH on by itself rather than by the user's setting (the
default in Russia since 2022) goes through byway: while interception is up,
dnsmasq answers NXDOMAIN for `use-application-dns.net`, and Firefox takes this
signal to turn DoH off. Check from a PC: `nslookup use-application-dns.net`
answers `NXDOMAIN`. DoH turned on in Firefox by hand, Android Private DNS and
iOS DNS profiles ignore the signal.

If encrypted DNS cannot be turned off on the device, two ways remain.
Intercepting port 53 in the firewall catches plain queries to other
resolvers, not encrypted ones; byway does not set it up, that is the network
owner's call. The service's subnets in `subnets.lst` are intercepted by
address, so they work for such a device too: IPv4 only, and together with the
domains (see above).

In list mode `byway doctor` always reminds of this with
`[ ?? ] a client with its own DNS bypasses the tunnel`. It is a warning, not
a detected fault. In "Everything through the VPN" mode the device's DNS does
not matter: all traffic of the listed networks is intercepted.

---

## Guest network without the tunnel

A network gets the tunnel only with both: the network in byway's interface
list (Network tab → Interfaces, `byway.main.interface`, only `br-lan` by
default), and the router as its clients' DNS.

| in the interface list | clients' DNS | result |
|---|---|---|
| yes | router | the tunnel works |
| no | router | list sites do not open: clients get a placeholder address, and their network has no interception |
| no | own (`dhcp_option '6,…'`) | the network bypasses the VPN entirely, nothing breaks |
| yes | own | only the list's subnets go through the VPN |

`byway doctor` names the second row: `networks using the byway resolver but
not intercepted`. In "Everything through the VPN" mode a network outside the
interface list bypasses both the tunnel and the "Block" setting, and doctor
reports it as a fault.

To add a network (the device name is in `uci get network.NETWORK.device`,
for example `br-guest`):

```sh
uci add_list byway.main.interface=br-guest && uci commit byway && /etc/init.d/byway reload
```

The installer adds the firewall rule `byway-tproxy`, which accepts
intercepted packets from any zone, so a guest zone with closed input does not
block the tunnel. If the rule was deleted, `byway doctor` reports `there is
no firewall rule for marked traffic`, and bringing interception up
(`/etc/init.d/byway restart`) creates it again. Guests' DNS queries to the
router must be allowed.

---

## Sites through the VPN load with pauses, messages leave half a minute late

Most keys (vless, trojan, vmess and others over TCP) carry traffic inside
TCP. QUIC (HTTP/3 over UDP 443) stalls silently in such a tunnel: the app
waits tens of seconds before falling back to TCP. From the outside these are
pauses when opening pages and a messenger that sends with a delay.

The setting "Reject QUIC for sites through the VPN" (Network tab,
`block_quic`) is on by default. The first QUIC packet to an intercepted site
is rejected at once, and the app moves to TCP without waiting. Other UDP on
port 443 (OpenVPN, WireGuard on devices) and traffic byway does not intercept
are untouched. To check:

```sh
uci get byway.main.block_quic      # 1 or empty means on
nft list chain inet byway input
```

The chain should have a line with `udp dport 443`, `counter packets N` and
`reject`; a growing `N` means the rejection fires. No such line, turn it on:

```sh
uci set byway.main.block_quic=1 && uci commit byway && /etc/init.d/byway reload
```

The line is there, the counter grows, and the pauses stay: the cause is
elsewhere, see the next section. With hysteria2 and wireguard keys the tunnel
itself runs over UDP, and the setting can be turned off.

---

## The tunnel drops now and then

Start with the state log: what changed and when.

Memory. The kernel kills a process that ran out of memory, procd brings the
engine back after 5 seconds, and from the outside it is a drop of a few
seconds. Traces: `dmesg | grep -i killed`; current use: the `memory` line of
`byway status`. The engine runs under a soft memory limit (`GOMEMLIMIT`): 40 %
of the router's memory by default, at least 32 MiB. Your own limit:

```sh
uci set byway.main.xray_memlimit=64MiB && uci commit byway && /etc/init.d/byway reload
```

`0` means no limit. A bare number means megabytes; `MB` and `M` become `MiB`,
`GB` and `G` become `GiB`. A value that does not parse is noted in the system
log (`logread -e byway`: `memory limit "…" not understood`) and the automatic limit is used. reload compares the
limit of the running engine and restarts it when the limit has changed.

Restarts. The state log shows `(restart)` and a new `pid`; `logread -e byway`
has the line `the core restarted — dnsmasq cache flushed`. The `(healed)`
mark is something else: someone outside removed the interception rules (a
firewall reload, a neighbouring service, `nft flush ruleset`) and the 5-minute
check put them back. Frequent `(healed)` means finding who removes them.

Server. Engine errors with an unchanged `pid` mean the engine is alive but
connections to the server break:

```sh
logread -e xray | grep -iE 'fail|error|EOF|timeout' | tail -20
```

`failed to dial`, `EOF`, timeouts point at the path to the server or the
server itself. Several `byway probe` runs in a row and the `vpn` line of
`byway health` show whether it is constant. It is fixed on the server side
or with another key.

The line. If the connection to the ISP drops, the tunnel drops with it:
`logread -e netifd | tail -20`, `ifstatus wan | grep uptime`.

---

## Stopped working after an update

`byway update` leaves settings and lists alone, rebuilds the config and
restarts the service. If the web UI behaves oddly afterwards, clear the
browser cache: LuCI does not tell the browser that the UI files changed. The
web UI warns about it with the line "The byway panel was updated to …, but the
browser shows the previous one (…) from its cache", but only until its shared
module is re-fetched. Ctrl+Shift+R (Ctrl+F5) on each tab of the UI, or F12 →
Network → "Disable cache" → F5. A manual `byway update` makes a copy of the whole previous
version (`/etc/byway/prev.tgz`), waits up to two and a half minutes for the
tunnel and rolls back by itself on failure; to go back by hand —
`byway update --rollback`. The release signature (`SHA256SUMS.sig`) is checked
with `usign`: no `usign` or no signature is a refusal, a signature that does
not match is a refusal with no bypass suggested; when there is nothing to
check with, the bypass is `byway update --no-verify`.

Automatic updates are off by default. When on, they install only releases
with the same first two version numbers, at the set hour by the router's
clock; a regular release no earlier than three days after the router first
saw it, an important one at once. The whole current version is copied to
`/etc/byway/prev.tgz` first. Then byway waits up to two and a half minutes
for the engine to run, the interception rules to be in place, the resolver
to hand out placeholder addresses and, if the connection through the server
worked before the update, for it to work after. If that does not happen, it
restores the previous version and never installs that release on its own
again.

The result shows in the `overnight` line of `byway status` (`updated to …`
or `ROLLBACK from … to …`) and in `logread -e byway`; `byway doctor` reminds
of a release that did not come up. Once the cause is fixed, `byway update`
installs it. If the rollback itself failed (`ROLLBACK FAILED`), restore by
hand with one command:

```sh
byway update --rollback
```

It unpacks `/etc/byway/prev.tgz`, recomputes the sum in `.binmd5` (otherwise
automatic updates would take the file for a hand-edited one) and restarts the
service.


Automatic updates leave alone a file edited by hand or not placed by the
installer, and `byway doctor` says so.

The Xray-core engine. byway checks every built config with the engine itself,
so an incompatibility does not pass silently: `byway gen` shows the refusal,
and the previously built config is not replaced. If the new engine accepts
it, the service runs on it. For known refusals byway names the cause: for
example, new Xray-core versions refuse vless and trojan without TLS to a
public address and do not allow turning off server certificate checks; on
older versions byway refuses the same itself. A key without TLS is fixed on
the server. Instead of a disabled check the key needs the certificate
fingerprint (`pcs=` or `pinSHA256=`), or the server needs a real certificate.
For your own server with a self-signed certificate on an engine below 26.3.27
(without TLS, below 26.7.11), `uci set byway.main.allow_insecure=1 && uci
commit byway && /etc/init.d/byway reload` lifts byway's refusal; the option
does not override a recent engine.

`byway engine` checks the archive against the release checksum, tests the
config with the new engine and waits up to two and a half minutes for the
tunnel, and, if the connection through the server worked before the
replacement, for that too; if it does not come up, the previous engine is
restored automatically. With the service off or without a key the tunnel
check and the config check are skipped — the swap goes without them, side by
side and through memory (see [engine](engine.en.md#without-a-key)). If a package manager updated the
engine, go back to the version that worked:

```sh
byway engine              # what is installed and what XTLS has
byway engine 26.9.9       # a specific version; tested: the one tested with byway
```

If the flash has no room for a second engine and the current one came from a
package, `byway engine` refuses: remove the package with the package manager
first, after which `byway engine tested` installs the engine as onto empty
space.

A replacement needs at least 40 MB of free memory. On MIPS without a
floating-point unit GitHub builds do not run, and `byway engine` refuses:
there the engine changes only through the OpenWrt package.

---

## Programs on the router itself hang on list sites

Interception catches traffic of devices at home, while the resolver hands
placeholder addresses to everyone, the router included. Without a separate
redirect a program on the router waits for a timeout: `curl` hangs, busybox
`wget` answers `Operation not permitted`. Updates of other services and your
own scripts break this way if their sites are on the list.

The redirect is the setting "VPN for programs on the router" (Network tab,
`router_via_vpn`). It is on in new installs and may be off in older ones;
`byway doctor` then shows `the router itself cannot reach the sites on the
list`. To turn it on:

```sh
uci set byway.main.router_via_vpn=1 && uci commit byway && /etc/init.d/byway reload
```

Reloading the rules is not enough here: the setting adds an inbound for the
router's traffic to the engine config, and reload rebuilds it and restarts
the service.

Only TCP to placeholder addresses is redirected, that is, to list domains;
subnets do not apply to programs on the router. byway downloads through its
proxy inbound `127.0.0.1:1603` and does not depend on the setting. A one-off
download can go the same way: `curl --proxy http://127.0.0.1:1603 …`.

---

## IPv6 bypasses the tunnel

IPv6 interception is off by default (`byway.main.ipv6=0`): domains and
subnets work for IPv4 only. If the router has IPv6 from the ISP, a device
that got an IPv6 address for a site usually prefers it and goes direct.

`byway doctor` sees the default IPv6 route and shows `IPv6 is up,
interception is IPv4 only`. There are two ways out. Turn IPv6 off on the
WAN: there will be no IPv6 route out, so nothing can leave around the
tunnel. Or turn on experimental IPv6 interception, which has not been tested
with real IPv6 traffic (see [What byway does not
do](../README.en.md#what-byway-does-not-do)):

```sh
uci set byway.main.ipv6=1 && uci commit byway && /etc/init.d/byway restart
```

If IPv6 is on but the kernel has no rule for it, doctor suggests
`byway plumb on`.

---

## Another interceptor next to byway

byway takes the nft table `inet byway` (plus `inet byway_block` while "Block"
is in effect), the mark `0x100000` (`mark`), the engine's own connection
mark `0x400000` (`self_mark`), routing table 100, ports 1602–1604 and the
pool `198.18.0.0/15`. It points dnsmasq at its own resolver and removes the
other upstream servers. A service of the same kind (podkop, passwall,
OpenClash and the like) does the same with its own values. Two of them side
by side do not mean slowness, they mean traffic going the wrong way.

`byway doctor` knows podkop, passwall, passwall2, openclash, nikki,
homeproxy and shadowsocks-libev by name. For an installed one it checks
whether it runs, whether it is in autostart and whether it leaves a trace in
the kernel: an nft table with its name, or a rule for table 100 while byway
is stopped. A running one is reported as a fault, with the command to stop
and disable it. doctor also checks for extra firewall rules with byway's
mark, taken ports, whether dnsmasq points at byway, the `local default`
route in table 100 and extra `ip rule` entries for it.

doctor names pbr when it is enabled; zapret and your own scripts it does not. Check by
hand: `nft list tables`, `ip rule show`, `ip route show table 100`,
`uci get dhcp.@dnsmasq[0].server`, `uci show firewall | grep mark`.

While byway runs, table 100 should hold only `local default dev lo`; byway
warns about foreign routes there when it loads its rules. The mark, ports
and pool can be changed on the Network tab, the table number cannot.

If zapret runs alongside, one domain must not sit on both lists: the session
splits across two exits. `byway presets` compares the zapret hostlist at
`/opt/zapret/ipset/zapret-hosts-user.txt` with the ready-made and your own
lists and names the overlaps. byway does not check zapret2 hostlists
(`/opt/zapret2/ipset/`); compare those by hand.

---

## "Block" shut off the internet

The setting "If the VPN does not come up" (Overview tab, `on_failure`) set to
"Block" closes what should go through the VPN while there is no tunnel;
it is the default for new installs. In list mode that is the
list's domains (dnsmasq answers NXDOMAIN to a query of any type for them) and
subnets; in "Everything through the VPN" mode, all outbound traffic from the
listed networks. Access to the router (LuCI, ssh) stays.

`byway status` then shows `WARNING … the list is CLOSED` or `WARNING …
Traffic of the listed networks outside the VPN is BLOCKED`, and the web UI shows it on the Overview
tab. A third variant, `WARNING … there was nothing to block — traffic goes
DIRECT`, means the block is on but the lists are empty. The block goes up on
every service start, before interception is in place, and stays if the engine
did not start or the interception rules did not load. In the second case the
engine is alive, and `service`, `vpn`, `tunnel` in `byway health` may be `ok`:
the tunnel check goes around interception. A restart, an update or an engine
replacement does not lift the block; a change of lists, mode or networks
rebuilds it. `byway watch` picks up an engine that came back by itself, even
with the watchdog off: it brings interception up, and a successful start lifts
the block. A service stopped by hand (`/etc/init.d/byway stop`) is not counted
as an engine failure: the list is not closed. Switching to "Go direct" lifts a
standing block even while the engine is down; with that setting an engine that
comes back gets interception through `byway pulse` within a minute.

To open access until the tunnel is fixed:

```sh
byway plumb off
```

The command removes the block and interception and returns dnsmasq to its
previous servers: the list then goes direct. No need to change the setting —
the block comes back on the next service start. If you did set
`on_failure=open` (`uci set byway.main.on_failure=open && uci commit byway`),
restore the default once fixed: `uci set byway.main.on_failure=closed && uci
commit byway && /etc/init.d/byway restart`.

If the `byway` command itself does not work, remove the block by hand (the
directory is in the `conf-dir=` line of `/var/etc/dnsmasq.conf.*`):

```sh
nft delete table inet byway_block
rm -f DIRECTORY/byway-block.conf /tmp/byway-blocked
/etc/init.d/dnsmasq restart
```

The block does not close `keyword:` and `regexp:` entries, and byway warns
about that when it goes up. Domains pinned in `/etc/hosts` stay open too;
`byway doctor` says how many.

---

## How to report a problem

Start with `byway doctor`: some questions end with the hint under a fault.
If not, open an issue: <https://github.com/tomon-one/byway/issues>. The Bug
template asks for the version (`byway version`), the router model and
OpenWrt version, what you did and what you got, and the output of
`byway report`:

```sh
byway report /tmp/report.txt
```

Read the file before sending. It has no key and no server address, but it
does have the key name (the `key` line), the first list domain (the `fakeip`
line) and the router's network names. Do not attach: `byway export
--with-key`, `/etc/config/byway` and `/etc/byway/config.json`, which hold the
key; the output of `byway gen`, `byway check`, `byway probe`, which holds the
server address; the access log and a detailed `logread -e xray`, which hold
the address of everything opened on the network.

Vulnerabilities go through [SECURITY.md](../SECURITY.md), not a public
issue.
