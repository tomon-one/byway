# How byway works

Read this if you are fixing or extending byway, or trying to work out why
traffic goes where it shouldn't. It covers the packet path, the interception
rules, the service, the periodic jobs and the files, using the function, UCI
option, port and path names exactly as they appear in the code.

Numbers below are the shipped defaults from `/etc/config/byway`; all of them
can be changed. Where a value is fixed in code rather than in UCI, that is
stated.

## Components

| part | role |
|---|---|
| `/usr/local/bin/byway` | one file: a POSIX sh wrapper ([busybox ash](https://busybox.net/)) — locks, signal traps, paths — followed by the [ucode](https://ucode-lang.org/) program; builds the Xray-core config, installs and removes the interception rules, checks state, updates itself |
| `/etc/init.d/byway` | [procd](https://openwrt.org/docs/techref/procd) service: runs Xray-core and calls `byway plumb on/off` |
| Xray-core | DNS inbound with fake addresses, tproxy inbound, routing, outbounds |
| [nft](https://wiki.nftables.org/) table `inet byway` | intercepts traffic from the trusted bridges |
| `ip rule` + routing table 100 | delivers marked packets to a local socket |
| [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) | forwards every query to the Xray-core DNS inbound |
| cron | `byway watch` every 5 minutes, `byway stat` hourly, `byway pulse` every minute |

"Interception rules" below means everything `byway plumb on` sets up: the nft
table, the `ip rule`, the route in table 100 and the dnsmasq redirection.

## Packet path

```
device on br-lan
  │ DNS query
  ▼
dnsmasq (byway-dns.conf: server=127.0.0.42, no-resolv)
  ▼
Xray-core: dns-in 127.0.0.42:53 → dns-out outbound → built-in DNS
  ├─ name on the list → address from pool 198.18.0.0/15 (fakedns)
  └─ anything else    → dns_upstream (DoH), real address
  │
  │ connection to 198.18.x.x:443
  ▼
nft: table inet byway, chain prerouting (priority mangle)
  0. iifname not in interface, source in privnets, ip daddr @fakeip
                                         → tproxy to :1604 ("direct" inbound), else drop
  1. iifname not in byway.main.interface → return
  2. ip daddr @privnets                  → return
  3. socket transparent 1                → mark, accept
  4. ip daddr @fakeip / @subnets         → tproxy to :1602, mark 0x100000
  5. not taken by tproxy                 → drop (pool always, subnets under closed)
  ▼
ip rule fwmark 0x100000/0x100000 lookup 100
table 100: local default dev lo          → delivered to a local socket
  ▼
Xray-core: tproxy-in 0.0.0.0:1602, sniffing fakedns/http/tls/quic
          (for networks outside interface: tproxy-direct :1604, sniffing fakedns only,
           routed straight to direct)
  ▼
routing → proxy | route-NAME | direct | block
```

### DNS and fake addresses

dnsmasq forwards everything to `dns_listen` (127.0.0.42). A [`dokodemo-door`](https://xtls.github.io/en/config/inbounds/tunnel.html)
tagged `dns-in` listens there; the first routing rule hands it to the
`dns-out` outbound, which passes queries to the built-in DNS. Its servers:

- [`fakedns`](https://xtls.github.io/en/config/fakedns.html) for names in the merged list (your own `domains.lst`, the
  ready-made lists in `list preset`, the per-route lists) and for
  `full:example.com`;
- `dns_upstream`, then `dns_upstream2` (`none` disables it) for everything
  else;
- `dns_bootstrap`, only to resolve the `dns_upstream*` hostnames themselves
  when they are given as names. If a resolver is given by name and
  `dns_bootstrap` is empty, `byway gen` warns and uses
  `https://8.8.8.8/dns-query` and `https://1.1.1.1/dns-query` instead.

For a listed name fakedns answers locally with an address from `fakeip_pool`.
Nobody looks up the real address at home: the VPN server does that when it
opens the connection.

`fakedns` is the last entry in `servers`, with `skipFallback`: a name that is
not on the list gets no pool address, even if both `dns_upstream*` return an
empty answer or no answer. For names under a listed domain fakedns answers
first and does not check that the name exists: with `example.com` on the list,
`nosuch.example.com` gets a pool address too.

The address-to-name table lives in Xray-core's memory. `poolSize` is the pool
size minus two (`pool_size`). If the list holds more names than that, `byway
gen` warns: an evicted address is handed to another name, and a device that
still has the old answer cached ends up at the wrong host.

Restarting the engine wipes the table, so the dnsmasq cache has to be flushed.
On service start `plumb on` does it (`pl_dns_up`): SIGHUP if the
`byway-dns.conf` file has not changed and the running dnsmasq has already read
it, otherwise a dnsmasq restart. If procd
brought the engine back on its own (`respawn`), the next `byway watch` run
flushes the cache when it sees the new PID, up to 5 minutes late. Until then
dnsmasq hands out addresses the new engine does not know. A connection to a
pool address the engine no longer knows, where sniffing could not recover a
name either, hits the `block` rule.

### Interception in nft

`byway nft` (`pl_ruleset` in `uc/plumb.uc`) prints the whole table without
applying anything. Sets: `fakeip` (the pool), `privnets` (`0/8`, `10/8`, `127/8`,
`169.254/16`, `172.16/12`, `192.168/16`, `100.64/10`, `224/4`, `240/4`) and
`subnets` (merged subnet list). The pool is not in `privnets`, so the private
cut-off can come before the [tproxy](https://docs.kernel.org/networking/tproxy.html) rules without eating anything needed.

Order in `prerouting` matters. Only packets arriving from bridges in `list
interface` are intercepted. The `privnets` return comes before the `socket
transparent` shortcut: the other way round, a packet addressed to the router
itself on the tproxy port would get the mark, the firewall rule that accepts
by mark would let it through, and a guest zone with `input REJECT` would stop
holding guests. The mark is applied with `or`, so other bits survive; `ip
rule` matches with a mask.

The last `prerouting` rules drop what tproxy did not take. With no listening
socket (the engine is down) tproxy lets the packet pass, and it would go out
to the WAN directly. A pool address is never needed outside, so it is always
dropped; the list's subnets (in `all`, all intercepted traffic) are dropped
under `on_failure closed`.

Chain `input` (priority `filter - 10`): `iif lo return`, the QUIC reject rule,
then `drop` for tcp/udp to `tproxy_port` and the `tproxy-direct` port (usually
1602 and 1604). It blocks direct connections to the
inbound from the network. Intercepted traffic is not affected: tproxy does not rewrite the destination
address or port, so such a packet reaches `input` with its original port.

The `engine_local` chain (`output` hook) stops the engine from opening new
connections to the router's own addresses (the public WAN address, the global
IPv6): otherwise a guest could reach the router's services through the
interception. Loopback and port 53 are excluded. The engine is recognised by
the process uid (not root), otherwise by the `self_mark` mark: it is set with
`router_via_vpn 1` and for an engine running as root (`xray_root 1`, no
`procd-ujail`, or the `byway` user could not be prepared); with nothing to
recognise it by, there is no chain.

Two more consequences of that. `tproxy-in` listens on `0.0.0.0`, not loopback,
because the packet arrives with destination `198.18.x.x`. And the firewall
needs the `firewall.bywaytproxy` rule (src `*`, proto `all`, `mark M/M`,
`ACCEPT`) that `install.sh` creates; without it a zone with `input REJECT`
drops intercepted packets. Before loading its own table, `byway plumb on`
creates the rule again if it is missing (the `bywaytproxy` block is appended as
text to `/etc/config/firewall`, then `/etc/init.d/firewall reload`) and rewrites it if `mark` changes. `byway doctor` warns when the rule
is missing.

The ruleset is applied as one transaction and starts with `table inet byway` +
`delete table inet byway`. `nft -f` adds to an existing table instead of
replacing it; without that prelude, narrowing the pool would fail with
"interval overlaps" on a perfectly valid ruleset. The text is checked with
`nft -c -f -` before it is loaded.

### Routing by mark

`pl_route_up` adds `ip rule add fwmark M/M lookup 100` and `ip route add
local default dev lo table 100`. Without them the kernel would forward the marked
packet and the tproxy socket would never see it. The table number is the
constant `PL_RT` in the code, not an option: busybox `ip` rejects table
numbers above 255. Foreign routes in table 100 are left alone, with a warning.
`pl_route_down` removes the route only if byway created it (marker
`/var/run/byway-route-mine`).

### Inside Xray-core

`tproxy-direct` on port `tproxy_port` plus 2 (usually 1604) takes what was meant
for networks outside `interface`: byway's dnsmasq is one for all bridges and hands
them placeholder addresses from the list, while they have no tunnel. An nft rule
(ahead of the "not from interface" return) sends packets from a private address
to the pool to this inbound, xray turns the name back (sniffing is `fakedns` only,
so a Host header cannot replace the destination) and sends the connection
direct; private addresses in the destination go to `block`. The port is closed in
`input`, like the `tproxy-in` port.

`tproxy-in` is a `dokodemo-door` with `followRedirect` and `sockopt.tproxy`.
Sniffing uses `destOverride` `fakedns`, `http`, `tls`, `quic` with `routeOnly:
false`: the destination is replaced by the recovered name, and routing works
with the name from then on. [Rules](https://xtls.github.io/en/config/routing.html), first match wins, `domainStrategy:
IPIfNonMatch` (`IPOnDemand` on cores before 26.5.9):

| # | rule | goes to |
|---|---|---|
| 1 | `inboundTag: dns-in` | `dns-out` |
| 2 | built-in DNS queries (`dns-query`) | `direct`, `proxy` with `dns_route tunnel` |
| 2a | `inboundTag: tproxy-direct` + private and the pool | `block` |
| 2b | `inboundTag: tproxy-direct` | `direct` |
| 3 | routes: `/etc/byway/routes/NAME.lst` | `route-NAME` |
| 4 | `lists`: listed domains and `full:example.com` | `proxy` |
| 5 | `lists`: listed subnets | `proxy` |
| 4′ | `all` + `ru_direct 1`: `domain:ru`, `domain:su`, `domain:xn--p1ai` | `direct` |
| 5′ | `all`: server addresses from the keys | `direct` |
| 6 | private, reserved and the pool itself | `block` |
| 7 | everything else, `tcp,udp` | `direct` in `lists`, `proxy` in `all` |

Rule 6 is required. Without it `tproxy-in` would be an open forwarder: a guest
connects to a pool address, writes `Host: 192.168.1.1` in the first packet,
sniffing rewrites the destination, and the router itself makes the connection,
bypassing the `forward` chain where the firewall stops guests. Having the pool
in the same rule closes the "inbound connects to itself" loop.

Rule 2 also sends into the tunnel the queries the engine uses to resolve the
server names from the keys, and without those addresses the tunnel cannot come
up. So with `dns_route tunnel`, `byway gen` resolves the server names itself
(the pin from `/etc/hosts`, then 8.8.8.8, then 1.1.1.1, then the local
resolver, then the address from the previous `config.json`) and puts them in
`dns.hosts`. If a server changes its address, `byway watch` notices once an
hour; by hand — `/etc/init.d/byway reload`.

`example.com` (constant `PROBE_DOMAIN`) always goes through the tunnel, so
`byway health` can test the whole chain regardless of what the lists contain.

With `conn_mode urltest` there are several outbounds (`proxy-0`, `proxy-1`,
…), and rules point to the `auto` balancer (`leastPing`). [`observatory`](https://xtls.github.io/en/config/observatory.html) probes
each key with a request to `https://www.google.com/generate_204` every
`probe_interval`: `3m` is the default in code, the shipped config does not
have this option. Each key is first parsed and built on its own (`ob_key` in
`uc/outbound.uc`): a refusal at either step gives
`key skipped: REASON`, and the key stays out of the balancer. A route's key is
checked the same way, and on refusal the route is skipped. If no auto-select
key is usable, the build fails.

### lists and all modes

`list_mode lists`: the pool and the listed subnets go through the tunnel,
everything else is `direct`.

`list_mode all`: nft intercepts everything from the listed bridges that is not
in `privnets`. The lists take no part in routing; the last rule points to
`proxy`. Exceptions:

- `ru_direct 1` sends `.ru`, `.su` and `.рф` around the tunnel. `.рф` is
  written in punycode, `xn--p1ai`, because that is what appears in DNS and
  SNI. The name here comes from sniffing.
- The server addresses of all keys (route servers included) go
  `direct`. Otherwise there is a loop: to connect to the server the engine
  resolves its name, and that query follows the catch-all rule into a tunnel
  that is not up yet.

For a key given as raw JSON (`conn_mode outbound`) byway takes the server
address from the `settings` of that config and exempts it; if none is found,
`byway gen` warns. In no mode
should the server address end up in the lists.

### Why a service needs both a domain and a subnet

DNS decides the route. A device that got its address somewhere other than the
router (DoH in the browser, Android Private DNS, a custom resolver) gets the
real address, and the pool never comes into play. The exception is Firefox
that turned DoH on by itself: the `use-application-dns.net` canary turns it
off (see "dnsmasq"). For that device only the
subnet works: `@subnets` intercepts by destination address.

Interception is not the same as tunnelling, though. Sniffing replaces the
address with the SNI name, and the decision is made by name. If the name is
not in the domain list, the subnet rule (`IPIfNonMatch`) checks the address
the engine itself gets for that name from its own resolver, not the address
the client was connecting to. A different CDN node, and the connection goes
`direct`. So a service gets both a domain (for the engine's decision) and a
subnet (for clients with their own DNS). To check: `grep NAME
/var/run/byway/access.log` should show `-> proxy`; the log is written with
`show_usage 1` (except in `list_mode all`) or `log_level` `info`/`debug`.

## The router's own traffic

`prerouting` never sees packets the router itself sends; those go through
`output`. Yet the router's resolver also points at the DNS inbound and returns
pool addresses for listed names. Without extra measures the router cannot
reach a single listed domain. There are two.

The first is the `local-in` inbound on `127.0.0.1:1603` (`local_proxy_port`),
an HTTP proxy in Xray-core. It works without any kernel rules. byway sends its
own downloads through it (`nt_get`): version check, `byway update`,
`byway core`, ready-made lists, the dictionary on `byway lang en`. If that
fails — directly, then directly with `curl --resolve` to GitHub addresses
from DoH (`nt_gh_resolve`, `nt_doh_a`: a query to `https://8.8.8.8`, then
`https://1.1.1.1`, by address, not by name). The third attempt is for a
broken tunnel with GitHub on the list: the router's resolver returns a fake
address for it. Subscriptions get no third attempt. `byway health` goes only
through this inbound and never retries directly, because what it tests is the
tunnel. By hand: `https_proxy=http://127.0.0.1:1603 curl …`.

The second is `router_via_vpn 1` (on by default), for programs that know
nothing about the proxy. The tproxy inbound can only be entered from
`prerouting`, so the router's packet is marked earlier, in the `output` chain
of byway's table:

```
chain output {
    type route hook output priority -150; policy accept;
    meta skuid UID return                    # engine not running as root
    meta mark & 0x400000 == 0x400000 return  # engine sockets
    ip daddr @privnets return
    ip daddr { SERVER ADDRESSES } return
    ip daddr @fakeip meta l4proto { tcp, udp } counter meta mark set meta mark or 0x100000
    ip daddr @subnets meta l4proto { tcp, udp } counter meta mark set meta mark or 0x100000
}
```

The `route` hook makes the kernel pick a route again after the mark changes,
and the `ip rule` on the mark sends the packet to table 100, onto `lo`. From
loopback it arrives in `prerouting`, where the same tproxy as for home traffic
takes it: the first rule of the chain lets only marked packets in from `lo`
(`iif lo meta mark & M != M return`). This covers TCP and UDP, the pool and
the subnets. The priority is written as a number: -150 is `mangle`.

The engine's own traffic is let through first. Otherwise there is a loop: when
it cannot recover a name for a fake address, the engine sends the packet
`direct` to that same address, and the chain sends it straight back. The loop
has no limit, eats the open-file limit within minutes, and Xray-core stops
accepting anything, interception for the whole home included. Address or port
cannot exclude it, since they are the same. The engine is recognised by its
process uid (when not running as root) and by the `self_mark` mark
(0x400000): with `router_via_vpn 1` every engine outbound gets it (`sockopt.mark`
on `proxy`, `route-*`, `direct`, `dns-out`). A raw-JSON key cannot get the
mark automatically; add `sockopt.mark` to it yourself.

Subnets are marked only when the engine is recognised by uid: an engine
running as root with a raw config may have no mark, and its server's address
may sit in the subnets. Server addresses from the built config (the address
in the key, in `dns.hosts`, or a pin in `/etc/hosts`; IPv4 only) always go
past: the server connectivity check stays honest even if the server's address
ended up in the subnet list. A server given by name with no pin, under
`dns_route direct`, is not covered by this exception, and its address must
not be in the subnets.

**The `self_mark` bit must differ from the `mark` bit.** `ip rule` matches any
mark with the `mark` bit set; on overlap, the engine's packets to the server
would go to table 100. `pl_self_mark` picks `0x400000` or `0x800000` on
overlap and warns.

## IPv6

`ipv6 0` is the default. The built-in DNS runs with `queryStrategy: UseIPv4`
and returns no AAAA. What leaks around the tunnel over IPv6 is traffic from
devices that got their addresses elsewhere, and anything that relies on
subnets only, since subnets are IPv4-only with this option off. If the router
has a default IPv6 route, `byway doctor` warns about it.

`ipv6 1` is experimental:

- the `inet byway` table gains the sets `fakeip6` (`fakeip6_pool`, default
  `fc00::/18`, Xray-core's built-in constant), `privnets6` (`::1`, `::`,
  `::ffff:0:0/96`, `fe80::/10`, `ff00::/8`, `fc00::/7`) and `subnets6` (IPv6
  lines from the same `subnets.lst`);
- in `prerouting` the `@fakeip6` rule sits above `@privnets6`, because the
  pool lies inside `fc00::/7`; then two `fib` cut-offs: the router's own
  addresses and anything routed back into the bridges (the global prefix comes
  from the ISP and cannot be put in a set);
- `lists` intercepts `@fakeip6` and `@subnets6`, `all` intercepts all IPv6;
- `ip -6 rule` to the same table 100 and `local ::/0 dev lo table 100`;
- Xray-core: a second fakedns pool, `queryStrategy: UseIP`, `tproxy-in`
  listens on `::`, the v6 pool is added to the `block` rule (`::/128`,
  `::1/128`, `fc00::/7` and `fe80::/10` are there even with IPv6 off);
- the `output` chain marks `@fakeip6` and, with the engine not running as
  root, `@subnets6`; the fail-closed block adds a `blocked6` set.

## Rejecting QUIC

`block_quic 1` is the default. Keys that run over TCP (vless, trojan, vmess
and others) carry the client's UDP inside TCP, and QUIC stalls there silently:
the application waits tens of seconds before falling back to TCP on its own.
An immediate reject makes it switch to HTTP/2 straight away. The rule sits in
the `input` chain:

```
meta mark & 0x100000 == 0x100000 udp dport 443 \
    @th,64,8 & 0xc0 == 0xc0 @th,72,32 { 0x00000001, 0x6b3343cf } counter reject
```

It lives in `input` because the kernel does not accept `reject` in prerouting,
and tproxy delivers the intercepted packet here with port 443 intact. It
matches the interception mark rather than an address, so one rule covers the
pool, subnets, `all` mode and IPv6, and leaves non-intercepted traffic alone.
It hits only the first QUIC packet: long header and version v1 or v2. OpenVPN
and WireGuard on udp/443, DTLS, STUN and packets of established sessions pass.
In `all` mode everything is intercepted, so QUIC to `.ru` under `ru_direct` is
rejected too. With hysteria2, wireguard and kcp keys the tunnel itself runs
over UDP and the option can be turned off. `block_quic` exists only in the nft
rules, which is why it is part of `byway nftsig` (see reload).

## When the engine does not come up

`byway plumb on` checks the engine before changing anything: `nslookup` of the
first listed name against `dns_listen` must return a pool address (with an
empty list, `example.com`, also a pool address). It makes 15 attempts one second apart, but
`nslookup` can hang on its own in each of them, so the wait can run past 15
seconds; it gives up earlier if there is no Xray-core process for five checks
in a row. If the probe fails, no rules are installed, `pl_block_on` runs, then
dnsmasq goes back to the ISP resolvers (`pl_dns_down`): the block is in place
before the listed sites could open around the VPN. The same failure path runs
when the kernel rejects the rules (`nft -c`) or fails to load them (`nft -f`);
on a load failure the route in table 100 and the previous `inet byway` table
are removed as well. What happens next depends on `on_failure`.

`open`: `pl_block_on` only lifts a block left over from `closed`. The home has internet and no
tunnel. **The list does not stop working, it works around the VPN:** names
resolve to real addresses, connections leave from your home address, and from
the outside everything looks fine.

`closed`, "no traffic outside the VPN" (the "Block" setting in the panel),
the default (in the shipped config and in the code: anything but `open`
counts as `closed`; installs with `open` written in their config keep it).
What gets closed depends on `list_mode`:

| mode | what `pl_block_on` sets up |
|---|---|
| `lists` | `byway-block.conf` in dnsmasq's `conf-dir`: `address=/NAME/` for plain names on the list, NXDOMAIN to a query of any type, A, AAAA and HTTPS (after `dnsmasq --test`); table `inet byway_block`, chain `forward`: from the listed bridges to `@blocked` / `@blocked6` (subnets), `reject` |
| `all` | table `inet byway_block`, chain `forward`: everything from the listed bridges except traffic between them and to `privnets`, `reject` |

The block hooks `forward`. The router's own traffic stays open, so the engine
can still reach the server and come up; LuCI and ssh go through `input` and
are unaffected; bridges outside `list interface` are not blocked. `keyword:`
and `regexp:` entries cannot be blocked by name (dnsmasq matches by suffix),
and byway reports how many there are. The outcome goes to
`/var/run/byway-blocked`: `lists`, `all` or `none` (nothing to block, or the
kernel rejected the rule), and next to it `/var/run/byway-blocked.sig` holds the
md5 of the mode, the bridges, IPv6 and the merged lists. Another `pl_block_on`
with the same signature and the block still in place does nothing (the
`inet byway_block` table and the dnsmasq file are checked against the parts
list in `/var/run/byway-blocked.parts`: whatever is gone is put back); with a
different one it rebuilds the
block in place, without lifting it: the table is replaced in one transaction
(a `table`/`delete table` prelude), the dnsmasq file after `dnsmasq --test`
and only if it changed. In `all` mode the names file is removed.

With `closed`, the service calls `byway plumb close` before starting the
engine: after a reboot dnsmasq comes up with the ISP resolvers before byway
does, and the list would leak directly during the wait.

A stop followed by a start (restart, reload with a new config, an update,
`BYWAY_KEEP_DNS`) and an engine replacement (`BYWAY_KEEP_BLOCK` from
`byway core`, through RAM included) first call `plumb close` under `closed`
and remove interception with `--keep-block`: there is no window in which the
list's subnets go direct.

The block is lifted by a successful `plumb on`, by `byway plumb off` and by
a real stop of the service. On failure paths the service and `byway watch`
call `plumb off --keep-block`, which leaves the block in place.

A pin in `/etc/hosts` overrides fakedns: dnsmasq answers it directly, so the
name neither goes through the tunnel nor gets blocked. `byway doctor` counts
such pins.

## Building the config

`byway gen` (`cmd_gen`) builds `/etc/byway/config.json` from UCI and the lists:

1. Lock `/var/run/byway-gen.lock`.
2. Merge the lists: your own file, ready-made lists, routes. Cached in
   `/var/run/byway-domains-all.lst` and `/var/run/byway-subnets-all.lst`, rebuilt when
   the set of sources changes or any file is newer than the cache.
3. Every UCI value that goes into JSON or into the nft rules is matched
   against a pattern (`g_val_or`); on mismatch the default is used and a warning
   printed. Values come from the panel and from other people's exports (`byway
   import`), hence the checks.
4. The draft `/var/run/byway-config.new.json` (640 root:byway, 600 without a
   `byway` group) is checked with `xray run -test -c`. Rejected: the draft stays, the error and a hint are printed, the
   working config is untouched, exit code 1. Accepted: the engine's
   deprecation warnings are shown.
5. List lines that look like neither a name nor a subnet are dropped
   (`/var/run/byway-bad-entries`); for an accepted config the count and the first
   ten are printed before the comparison with the working one, so also when
   the config did not change.
6. Identical to the working config (`cmp`): nothing changes. Otherwise free
   space is checked, the draft is copied to `/etc/byway/config.json.new`, the size
   is verified and it is renamed over the working config, mode 640
   root:byway (600 with a root engine or without a `byway` group).

The service runs `byway gen` on every start. If the build fails but the
previous config still passes `xray run -test`, the engine starts on the
previous one.

Memory. The init script passes [`GOMEMLIMIT`](https://go.dev/doc/gc-guide#Memory_limit) to the engine via `procd_set_param
env` (function `xray_memlimit`): with `xray_memlimit` unset, 40 % of
`MemTotal`, at least 32 MiB; `0`/`off`/`no`, not set; Go format (`B`, `KiB`,
`MiB`, `GiB`, `TiB`), passed as is; `MB`/`M` → `MiB`, `GB`/`G` → `GiB`; a bare
number means megabytes (`96` → `96MiB`); anything else, a line in the system
log, `memory limit "…" not understood -- using auto`, and 40 %. Without the conversion Go
would refuse `128MB`, the engine would crash on start, and procd would keep
restarting it. Without a limit Go lets the heap grow to twice
the live data, and on a router with little memory the kernel OOM-kills the
engine. The limit is soft: live data is never cut, Go just collects garbage
more often. uci drops empty options, so the default lives in code. `byway
status` shows the effective value.

Engine path: `xray_bin`. It is accepted only if it lies in `/usr/bin`,
`/usr/sbin`, `/usr/local/bin`, `/bin` or `/sbin`, contains no `..`, the file
name starts with `xray`, the file is executable, begins with an ELF header,
and its `version` starts with `Xray `. The name and the ELF header are checked
before anything is run: otherwise `xray_bin=/sbin/reboot` would reboot the
router on every byway call. A symlink named `xray*` in one of these
directories passes wherever it points. Otherwise both byway and the init
script fall back to `xray` from `PATH`, then `/usr/bin/xray`. byway checks the
path (`x_ok`, `xray_bin` in `uc/core.uc`) only in commands that need the
engine: running `xray version` costs ~0.05 s on a router.

## The procd service

`START=21` — right after the network (20), dnsmasq and the firewall (19);
`STOP=10`. With the former `START=90`, tens of seconds passed between dnsmasq
coming up and the block under `closed`, and clients got real addresses and
kept them until the TTL ran out. The installer calls `disable` before
`enable` to remove the old `S90byway`, and drops it from
`/etc/sysupgrade.conf`. Instance: `$XRAY run -c /etc/byway/config.json`,
`stdout` and `stderr` to syslog (Xray-core logs to stdout), pidfile
`/var/run/byway.pid`, `respawn 3600 5 0`. The engine runs as the `byway` system
user in a [`procd-ujail`](https://openwrt.org/docs/guide-developer/procd-init-scripts) cage (`procd_add_jail byway`, capabilities from
`/var/run/byway-caps.json`: `CAP_NET_RAW`, or `CAP_NET_ADMIN` on kernels before
5.17, plus `CAP_NET_BIND_SERVICE`, `no_new_privs`); the pid file holds the
wrapper, the engine is its child. The config is read by the group (`640
root:byway`), the access log lives in `/var/run/byway/` (root 755). Without
`/sbin/ujail`, or with `xray_root 1`, the engine runs as root. `reload` notices
a change of `xray_root` and of the engine: it checks who the process runs as
and restarts it.

Parameters: threshold 3600 s, 5 s pause before restarting, 0 retries meaning
unlimited. procd's threshold is not "this many crashes per hour": the counter
resets only after the process has run longer than the threshold. With a finite
retry count, a handful of crashes half an hour apart stops the service for
good, and `stop_service` is not called, so dnsmasq would keep pointing at a
port nobody listens on.

`start`: if `enabled` is not `1`, run `byway plumb off --service` and exit.
With `closed`, run `byway plumb close`. No engine binary: print a hint and
exit; if a runnable `/usr/local/bin/xray-*` sits next to it, the hint names
it, otherwise the service sets the marker `/var/run/byway-engine-restore` and
in the background, once the default route is up (waiting up to two minutes), 10 s after it runs `byway core restore` (output to syslog),
once per boot. Then `byway gen`, the procd instance, and in `service_started`
up to three `byway plumb on` attempts 10 s apart. That loop runs in the
background, because with waiting it takes up to a minute and the panel drops
the request after about 20 seconds. The loop's PID goes to
`/var/run/byway-plumb.pid`. A snapshot of what was applied goes to
`/var/run/byway.applied`: md5 of `config.json` and md5 of `byway nftsig`
output.

Interception rules go in after the engine, never before: `byway-dns.conf`
points the router's entire resolver at the DNS inbound, and with a dead engine the home
would have no DNS.

`stop`: first kill the background loop and its children (if the PID still
belongs to byway), then `byway plumb off --service`. `--service` does not set
the "removed by hand" marker (`/var/run/byway-plumb-down`); otherwise `byway
watch` would not restore the rules after a failed start.

`restart`, and the reload branch for "config changed", pass `--keep-dns`: the
resolver stays on the DNS inbound and only its cache is flushed. Switching to
the ISP and back would mean two windows without DNS. If the engine does not
answer, `plumb on` hands dnsmasq back to the ISP on its failure path. Under
`closed` the block goes up before interception is removed and stays until a
successful `plumb on` (see [When the engine does not come
up](#when-the-engine-does-not-come-up)).

`reload`. `service_triggers` registers `procd_add_reload_trigger byway byway_key` (the second
package holds the keys), so
procd calls reload on `reload_config`, that is, on every "Save & Apply" in
LuCI, panel language changes included; byway itself calls it after updating
the ready-made lists. A bare `uci commit byway` from the console does not
touch the service; run `/etc/init.d/byway reload` after it. Reload is called
often, so `reload_service` restarts only what changed:

1. `enabled 1` and the engine not running: `start`; `enabled 0`: `stop` (also
   with the engine down: that is how the `closed` block and the interception are
   lifted), then `start`, which with `enabled 0` does not start the engine but
   registers the service again with its config-change trigger.
2. The running engine is not the binary the engine path now points to (checked
   via `/proc/PID/exe`), or it runs with a different memory limit
   (`GOMEMLIMIT` in `/proc/PID/environ` against `xray_memlimit`): `stop` +
   `start` with `--keep-dns`.
3. `byway gen`. If it fails, the old config keeps running.
4. md5 of `config.json` ≠ first snapshot line: `stop` + `start` with
   `--keep-dns`.
5. md5 of `byway nftsig` ≠ second line: only `byway plumb on`, the engine is
   left alone.
6. Otherwise nothing.

`byway nftsig` (`cmd_nftsig`) is a signature of the rules without building them: `fakeip_pool`,
`mark`, `tproxy_port`, `interface`, `list_mode`, `block_quic`, `on_failure` and the md5 of
`subnets.lst` and the ready-made `.sub` files. Everything else changes
`config.json` and is caught in step 4. **A new option that lives only in the
nft rules must be added to `cmd_nftsig`**, or reload will not notice it.

## Periodic jobs

`install.sh` adds to crontab:

```
*/5 * * * * /usr/local/bin/byway watch >/dev/null 2>&1
7 * * * *   /usr/local/bin/byway stat  >/dev/null 2>&1
* * * * *   /usr/local/bin/byway pulse >/dev/null 2>&1
```

`byway pulse` does one thing: it looks whether the engine is alive and calls
the same `wt_engine_gone` and `wt_engine_back` as `watch`. It stays silent on minutes
divisible by five — `watch` runs then. So the engine's fall and return are
noticed within one or two minutes rather than five. With `on_failure open` it
also puts back the interception that was lifted when the engine fell.

List updates and version checks have no jobs of their own; `byway watch` does
them.

### byway watch

Every 5 minutes it records the state (engine PID, nft table, `ip rule`, route,
where dnsmasq points, whether the resolver returns a fake address) and then,
in order:

1. With `enabled 1`, the engine file fails `x_ok`, there is no runnable
   `/usr/local/bin/xray-*` next to it, and the marker
   `/var/run/byway-engine-restore` is over 15 minutes old or missing: the marker
   is refreshed, `byway core restore` runs in the background, output to
   syslog. Flash needs 25 MB free; with less it refuses before downloading.
2. No engine while `enabled 1` and no "removed by hand" marker: `pl_block_on`
   (only acts with `closed`). Misses are counted in `/var/run/byway-nopid`. On the
   second miss in a row, if dnsmasq points at the DNS inbound, `plumb off
   --service --keep-block`: resolver back to the ISP, block stays. Logged as
   `(nodns)`.
3. Engine is back and a block is in place: `plumb on` regardless of `guard`;
   a successful one lifts the block (`(healed)`), a failed one leaves it
   (`(failed)`). With `enabled` other than `1`, just `pl_block_off`.
4. Engine running, `enabled 1`, `guard` not `0`, no "removed by hand" marker
   (`/var/run/byway-plumb-down`), but the table, rule, route or byway's address in
   `byway-dns.conf` is missing: `plumb on`, logged as `(healed)` or
   `(failed)`. The address is checked in the file, not in the running dnsmasq.
   This repairs a foreign `nft flush ruleset` or a firewall reload.
5. Ready-made lists, version check, auto-update (below), and hourly
   `wt_hosts`: with `dns_route tunnel` the server addresses in `dns.hosts`
   are compared with DNS; if an address changed (the old one is not among the
   answers), `byway gen` and `reload` (marker `/var/run/byway-hostcheck`).
6. `/var/run/byway/access.log` over 4 MB: truncated to zero, which means `byway
   stat` is not running.
7. A state line is appended to `/etc/byway/health.log` (last 200 lines) only
   when something changed or was repaired. Engine PID changed and the
   resolver already returns a pool address: `killall -HUP dnsmasq`.

`byway plumb off` without `--service` creates `/var/run/byway-plumb-down`, and
`byway watch` leaves the rules alone until the next `plumb on` or reboot.

### byway stat

cron runs `byway stat` every hour at :07, whatever the settings. It always
extends the address map (below), but there is something to count only if the
access log is being written (`show_usage 1` with `list_mode lists`, or
`log_level` `info`/`debug`; otherwise the config has `"access": "none"`). In
`all` mode collection is off even with `show_usage 1`: the log would record
the address of every connection in the home.

Xray-core logs a line when it accepts a connection, before sniffing, so the
line holds the pool address, not the name. `byway stat` therefore builds a
reverse address-to-name table (`/var/run/byway/fakemap`) by asking the DNS inbound
about listed names, at most 200 per run, with the resume point in `.pos`. The
table is tied to the engine PID. From the log it takes `tproxy-in -> proxy`
and `-> route-NAME` lines newer than the cut-off (`/var/run/byway/statmark`)
and adds the counts to `/etc/byway/usage.tsv`; addresses outside the pool
(subnets) are counted as `(подсети)`, a pool address without a name as
`(поддомены)` (`(по IP)` until the map is complete). Only the router's own traffic is not
counted. The file is written to flash only when it changes. The log is
trimmed to its last 50 lines by writing over it, not with `mv`: the engine
keeps the file open with `O_APPEND`, and a replaced file would send writes
into a deleted one. To view: `byway top [N]`.

### Scheduled list updates

`lists_update`: `90m`, `12h`, `2h37m`, `1d`; a bare number is minutes; empty
or `0` means never; anything below 30 minutes becomes 30. At least one
`preset` must be enabled. The time of the last attempt is the mtime of
`/etc/byway/presets`: it is updated before the download, so a failed attempt
also pushes the next one back by the full interval. When it is due: `byway
presets`, errors to syslog, `/etc/init.d/byway reload`. It fires on the first
`byway watch` run after the interval expires.

### Version check and auto-update

`update_check 1` (default): a request to the GitHub API `releases/latest`
every random 12–36 hours. `/var/run/byway-upcheck` holds the interval until the
next check in minutes (720–2160, randomness from
`/proc/sys/kernel/random/uuid`); the file's mtime is the time of the last
one. If newer: the version goes to
`/var/run/byway-newver`, the first line of the release notes to
`/var/run/byway-relnote`, the time it was first seen to `/etc/byway/.newver-seen`,
and a line to syslog. Nothing is downloaded.

`auto_update 1` installs what was found; without `update_check` there is
nothing to install. All of these must hold:

- the clock is synchronised (the year is 2020 or later);
- the router's local hour equals `auto_update_hour` (`04`; stock firmware runs
  in UTC, and `byway doctor` tells you what hour that is for you);
- same minor branch (`X.Y` matches);
- three days have passed since it was first seen, unless the release notes
  start with `ВАЖНО`, `CRITICAL` or `!`;
- the md5 of `/usr/local/bin/byway` equals `/etc/byway/.binmd5` written by the
  installer, so a hand-edited script is never updated, and without
  `.binmd5` no update is installed at all;
- this version has not been rolled back before (`/etc/byway/.au-failed`), and
  there was no attempt in the last 24 hours (`/etc/byway/.au-try`).

Sequence: `byway update` downloads the tag archive from GitHub and checks the
signature, then copies the whole previous version to `/etc/byway/prev.tgz` (if
that fails, abort) and runs the archive's `install.sh`; after it, up to
150 seconds of `up_alive_ok` checks: engine process, `inet byway` table, fake
address from the resolver (skipped when the list is empty). If `up_tunnel_ok`
passed before the update — a `curl` request through the proxy inbound
(`local_proxy_port`, 1603) to `example.com`, any HTTP answer will do — it has
to pass after it too. If it does not come up, `prev.tgz` is unpacked back
(`byway update --rollback` does the same), the service restarts, and the version
is recorded in `.au-failed`. **Rollback restores the whole version:** program,
init script, panel and dictionaries. The outcome goes to
`/var/run/byway-autoupdate` and syslog.

### Replacing the engine

`byway core VERSION|tested|newest|stable|restore`; without an argument it
shows what is installed and what is available. `tested` is the constant
`XRAY_TESTED` (also in `install.sh`), `restore` is the number from the file
name in `xray_bin` (`/usr/local/bin/xray-VERSION`), otherwise `XRAY_TESTED`;
with a live engine `restore` does nothing. The archive and its `.dgst` come
from the XTLS releases, and the SHA2-256 is verified. On MIPS without an FPU
the GitHub builds do not run, so the engine there is updated from the OpenWrt
packages. With less than 40 MB of `MemAvailable` the swap does not start.

If free flash is at least the size of the uncompressed binary plus 5 MB, the
new binary goes next to the old one (`/usr/local/bin/xray-VERSION`), is
checked with `byway gen`, written to `xray_bin`, and the service restarts.
After success the old `/usr/local/bin/xray-*` is deleted; a packaged
`/usr/bin/xray` stays. With less space the swap goes through RAM, and only if
the old binary is in `/usr/local/bin/xray-*`; with a packaged one byway
refuses. The old version's archive is downloaded first for rollback, then the
service stops for about a minute, and for that time `/var/run/byway-plumb-down`
is set so that `byway watch` stays out of the way; the stop runs with
`BYWAY_KEEP_BLOCK=1`, so under `closed` the block holds for the whole minute.
Either way `up_alive_ok` checks the result and, if the connection through the
server worked before the replacement, `up_tunnel_ok` too; on failure the old
engine is put back. With the service off or without a key the tunnel check and
the config check are skipped, and on the side-by-side path the service restart
too; without a key the engine is replaced through RAM as well. Lock:
`/var/run/byway-engine.lock`.

`byway core VERSION` when `/usr/local/bin/xray-VERSION` is already there and
runs is a switch without a download: the config is checked with the new
binary, `xray_bin` changes, the service restarts, and the tunnel is awaited for
up to two and a half minutes; if it does not come up, back to the old one. Both
files stay.

`byway core /tmp/FILE` installs your own binary: a `.gz` with the binary or
the release `.zip`, from `/tmp` only, `unzip` required. The file is placed as
`/usr/local/bin/xray-local-DATE`, the `.dgst` is not checked (the sha256 is
printed), then the same choice between side-by-side and through RAM, with
rollback. `byway core --check` only reports whether an engine update exists
and changes nothing.

No previous engine (not found or does not run) — `en_fresh`: 25 MB free flash
(as for the installer), unpacking to `/usr/local/bin/xray-VERSION`, a
run check, `xray_bin`, a service restart with `enabled 1`. No rollback archive
and no wait for the tunnel: there is nothing to roll back to.

### Background jobs for the panel

A panel request lives for seconds, an update or an engine swap for minutes,
so the "Install the update" and "Install the tested core" buttons call
`byway job update` and `byway job engine tested`; `job gen`, `job presets`,
`job restart`, `job reload` and `job import [--no-key]` (accepting an export from
the panel; the file is `/var/run/byway-import.txt`) go the same way. `job` detaches
`byway job run …` (through `setsid` if present), writes the PID to
`/var/run/byway-job.pid` and answers at once. `job run` writes output straight
to `/var/run/byway-job.log`, without a pipe, so progress shows as it goes, and
ends with the line `== done` (`== конец` in Russian). One job at a time: with
a live PID it refuses. `byway job log` returns the log without colours and,
while the job is alive, the line `… in progress` with exit code 3, and after it
ends 0 or 1 by outcome (the outcome code is kept in `/var/run/byway-job.rc`); the
panel polls it every 3 s. The job lock is `/var/run/byway-job.lock` with a PID:
a dead owner does not hold it. `byway doctor` and `byway report` the panel calls
directly — they finish in seconds.

## dnsmasq

`pl_dns_up` puts a `byway-dns.conf` file into the drop-in directory of the
first dnsmasq instance — `conf-dir` from `/var/etc/dnsmasq.conf.<section>`
(`/tmp/dnsmasq.cfg01411c.d` on 25.12, `/tmp/dnsmasq.d` on 22.03):

```
server=127.0.0.42
no-resolv
server=/use-application-dns.net/
```

- Without `no-resolv` dnsmasq would also ask the ISP, take the first answer,
  and some listed names would get real addresses.
- `server=/use-application-dns.net/` is an entry without an address, "local
  only": dnsmasq answers NXDOMAIN. This is the Firefox [canary](https://support.mozilla.org/en-US/kb/canary-domain-use-application-dnsnet): Firefox turns
  off DoH it enabled by itself (the default on desktop in Russia since 2022) on this
  answer and asks the router. DoH turned on by hand, Android Private DNS and
  iOS DNS profiles ignore it.
- `/domain/address` entries in the dnsmasq settings keep working: they are
  split DNS for the local network.
- General servers set in the dnsmasq settings (`dhcp.@dnsmasq[0].server`
  without `/domain/`) cannot be switched off from a file: dnsmasq sends part
  of the queries to them, and listed sites open only some of the time.
  `plumb on` and `byway doctor` warn about them.

dnsmasq reads drop-in files only at startup: a new or changed file means a
`restart`; an unchanged file the running dnsmasq has already read means a
SIGHUP, a cache flush. If there is no drop-in directory, home DNS is not
redirected, byway warns, and interception by subnet still works. With less than
256 KB free in `/tmp`, dnsmasq is not restarted when DNS is switched to byway
or when the block is written, and its files are left alone: without space it
will not come up. byway warns, the guard retries later, and the block is not
lifted until space is freed. Handing the resolver back to the ISP (stop, engine
failure) works even with `/tmp` full: removing the file needs no space.

**byway does not change the dnsmasq settings.** The file lives in RAM and is
gone after a reboot: the router comes up with the ISP's DNS and no tunnel
until the service brings interception up. The UCI change used by versions 0.3
and earlier got committed to flash by "Save" on the DHCP page in LuCI, and with a
dead engine the home was left with a resolver pointing nowhere. The old change
(byway's address in `dhcp.@dnsmasq[0].server`, the `/etc/byway/dns-saved`
snapshot) is removed once by the first `plumb on` or `plumb off` of the new
version (`pl_dns_legacy`), and the resolvers from the snapshot are restored.

`pl_dns_down` deletes the file and restarts dnsmasq; if there was no file,
only SIGHUP.

## Locks

A lock is a directory (`mkdir` is atomic) holding the files `pid` and `byway`.
Without `byway` it is foreign and is removed at once. With a dead PID it is
left over from an interrupted run and is removed. With a live PID, wait up to
30 seconds.

| lock | taken by | if busy |
|---|---|---|
| `/var/run/byway-gen.lock` | `byway gen` | exit with error |
| `/var/run/byway-plumb.lock` | `byway plumb on/off/close` | `return 1`, so `byway watch` carries on |
| `/var/run/byway-engine.lock` | `byway core` | exit with error |

Locks live in `/var/run`, not `/tmp`: on OpenWrt that is `/tmp/run`, owned by
root with mode 755. In `/tmp` (1777) any process, dnsmasq under its own user
included, could create the lock directory and lock out the config build and
the interception rules.

## Files

| path | contents |
|---|---|
| `/usr/local/bin/byway` | the program; symlink `/usr/bin/byway`, because `/usr/local/bin` is not in OpenWrt's `PATH` |
| `/var/run/byway.uc`, `byway.ucc` | the ucode part cut out of `byway` and its bytecode: rebuilt when the file itself changes |
| `/usr/local/bin/byway-uninstall` | uninstaller (symlink `/usr/bin/byway-uninstall`) |
| `/usr/local/bin/xray-VERSION` | engine, if installed from GitHub |
| `/etc/init.d/byway` | service |
| `/etc/config/byway` | UCI: section `main`, `route` sections for per-route outbounds |
| `/etc/config/byway_key` | UCI, mode 600: `node_url`, `node_urls`, `sub_url`, `outbound_json` (keys kept apart so the panel's read-only role does not get them) |
| `/etc/byway/domains.lst`, `subnets.lst` | your lists; domains accept `full:`, `keyword:`, `regexp:` |
| `/etc/byway/presets/NAME.lst`, `NAME.sub` | downloaded ready-made lists: domains and subnets |
| `/etc/byway/routes/NAME.lst` | per-route list |
| `/etc/byway/config.json` | built Xray-core config, mode 640 root:byway (600 with a root engine) |
| `/etc/byway/lang/en.tsv` | "key⇥translation" dictionary, English only |
| `/etc/byway/health.log`, `usage.tsv` | `byway watch` log, `byway stat` counts |
| `/etc/byway/prev.tgz`, `.binmd5`, `.au-try`, `.au-failed`, `.newver-seen` | auto-update; `prev.tgz` is the whole previous version for rollback |
| `/var/run/byway/access.log` | Xray-core access log |
| `/var/run/byway-config.new.json` | draft config; kept if the engine rejected it |
| `/var/run/byway-domains-all.lst`, `byway-subnets-all.lst` (+ `.sig`) | merged lists |
| `/var/run/byway-bad-entries` | dropped list lines |
| `/var/run/byway-blocked`, `.sig`, `.parts` | active block: `lists`, `all`, `none`; the signature it is rebuilt by; the block's parts (table, dnsmasq file) for the check |
| `/var/run/byway-plumb-down` | rules removed by hand |
| `/var/run/byway-route-mine`, `byway-route-mine6` | the route in table 100 was created by byway |
| `/var/run/byway-watch.last`, `byway-nopid` | previous state and miss counter of `byway watch` |
| `/var/run/byway/fakemap`, `fakemap.pos`, `statmark` | `byway stat` accounting |
| `/var/run/byway-upcheck`, `-newver`, `-relnote`, `-autoupdate` | version check, auto-update outcome |
| `/var/run/byway-upcheck-ok`, `-fail` | time of the last check that reached GitHub, and the response code of a failed one; `byway doctor` uses them to see whether the check gets through |
| `/etc/byway/.github-noexec` | marker: the GitHub engine build does not run on this CPU |
| `/etc/byway/before-import/` | copy of settings and lists from before `byway import` (mode 700, with the key) |
| `/var/run/byway-dialbug` | result of the Go 1.27 dial-bug check for the engine file |
| `/var/run/byway-engine-restore` | marker of an attempt to install a missing engine: the service once per boot, `byway watch` when it is over 15 minutes old |
| `/var/run/byway-job.log`, `byway-job.pid`, `byway-job.rc`, `byway-job.lock` | progress, PID, outcome code and lock of the panel's background job (`byway job`) |
| `/var/run/byway-import.txt` | an export accepted by the panel; deleted after accepting (it holds the key) |
| `/var/run/byway-mark` | the applied interception mark (hex only, not 0) |
| `/var/run/byway.pid`, `byway.applied` | PID of the ujail wrapper (the engine is its child); applied-state snapshot for reload |
| `/var/run/byway-caps.json` | engine capabilities for procd-ujail |
| `/var/run/byway-hostcheck` | marker of the hourly server-address check (`wt_hosts`) |
| `/var/run/byway-plumb.pid`, `byway-nostart` | background start loop; "start failed, skip the loop" |
| `<dnsmasq conf-dir>/byway-dns.conf` | dnsmasq pointed at the DNS inbound while interception is up |
| `<dnsmasq conf-dir>/byway-block.conf` | name block under `closed` |
| `/www/luci-static/resources/view/byway/`, `.../resources/byway/` | panel; the installer writes the version number into `ui.js` (`BUILT`), and if it differs from `byway version` the panel warns that the browser shows it from cache |
| `/usr/share/luci/menu.d/`, `/usr/share/rpcd/acl.d/luci-app-byway.json` | panel menu and ACL |

Everything under `/tmp` and `/var/run` lives in RAM and is gone after a
reboot. `install.sh` adds `/etc/byway/`, the init script, the
`/etc/rc.d/S21byway` and `K10byway` links, the byway files and the panel
files to `/etc/sysupgrade.conf`. The engine is not on that list (35 MB): after
a sysupgrade the service installs it itself with `byway core restore` (see
[The procd service](#the-procd-service)).

## Where to look

| question | command |
|---|---|
| what is up right now | `byway status` |
| what is wrong with the environment | `byway doctor` |
| does traffic get through the tunnel | `byway health` |
| which nft rules would be / are installed | `byway nft` / `nft list table inet byway` |
| rule and route | `ip rule`, `ip route show table 100` |
| where dnsmasq points | `cat /tmp/dnsmasq*.d/byway-dns.conf` |
| does the resolver return a fake address | `nslookup NAME 127.0.0.42` |
| where a connection went | `grep NAME /var/run/byway/access.log` |
| what the service and `byway watch` did | `logread -e byway`, `/etc/byway/health.log` |
| what the engine logs | `logread -e xray` |
| what is in the built config: domain and subnet counts, tags, protocols, addresses (no uuid) | `byway show` |
