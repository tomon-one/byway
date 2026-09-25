<img src="logo-wide.svg" alt="byway" width="220">

<sub>A cairn — the stack of stones that marks a path where none is visible.</sub>

# byway

**Split tunnelling for an OpenWrt router.** Part of your traffic goes through
your VPN, the rest goes direct. The engine is
[Xray-core](https://github.com/XTLS/Xray-core).

![OpenWrt 22.03+](https://img.shields.io/badge/OpenWrt-22.03%2B-00B5E2)
![engine Xray-core](https://img.shields.io/badge/engine-Xray--core-333)
![IPv6 experimental](https://img.shields.io/badge/IPv6-experimental-orange)
![GPL-2.0](https://img.shields.io/badge/license-GPL--2.0-blue)

*[Русская версия](README.md)*

---

> ### ⚠️ Read this before installing
>
> **Version 0.2.3.** byway runs every day on one
> router: 1500 domains, 300 subnets, and a family that notices breakage
> immediately. But still just **one** — the author had no other hardware.
>
> | | |
> |---|---|
> | fully verified | Cudy WR3000S v1 (MT7981, aarch64), OpenWrt 25.12.5 |
> | verified on a test bench | install and removal on 22.03–25.12, both package managers; install on aarch64 and mipsel |
> | never verified at all | IPv6 (written, but has never seen live traffic), behaviour under load, daily life on anything but MT7981 |
>
> **The code was written by an AI** — Claude, to a human's brief and
> corrections. That is said up front rather than in a footnote:
> [what was done about it](#written-with-an-ai).
>
> **A report that it did not work for you is worth more than any review.** A
> failure report beats a success one:
> [issues](https://github.com/tomon-one/byway/issues).

---

## Contents

[Why this exists](#why-this-exists) · [Requirements](#requirements) · [What
byway does not do](#what-byway-does-not-do) · [Installing](#installing) ·
[First run](#first-run) · [What it can do](#what-it-can-do) · [How it
works](#how-it-works) · [The web UI](#the-web-ui) · [Commands](#commands) ·
[Updating](#updating) · [Engine version](#engine-version) ·
[Removal](#removal) · [Compatibility](#compatibility) · [Written with an
AI](#written-with-an-ai)

---

## Why this exists

byway gives you access to nothing on its own: the VPN is yours, and what opens
through it depends on the VPN, not on byway. byway's job is different — to
**decide what goes through the VPN and what goes around it**, and to do it on
the router, so you don't have to run a client on every device in the house.

What usually has to bypass the tunnel is local services: banks, government
portals and marketplaces often refuse foreign addresses and simply stop working
over a VPN.

byway solves **one** problem and does not try to grow into anything more. There
is no traffic-graph screen, no private vocabulary, no subscription to someone
else's rule sets you have to learn separately. There are lists as plain files, a
key as a link, and five tabs in the web UI.

If you want the full toolbox, there are
[PassWall](https://github.com/xiaorouji/openwrt-passwall) and
[OpenClash](https://github.com/vernesong/OpenClash): they do more and weigh
accordingly.

**What it is, technically.** Neither a package nor a binary: a set of POSIX sh
scripts plus a LuCI panel. Xray-core carries the traffic — byway decides what goes
where, builds the engine's config, installs the kernel rules and watches that
none of it falls apart. Plumbing, in other words.

---

## Requirements

| | |
|---|---|
| **OpenWrt 22.03 or newer** | a hard boundary, see below |
| **`kmod-nft-tproxy`, `kmod-nft-socket`** | the installer fetches them |
| **`curl`** | the installer fetches it |
| **Flash space** | byway itself is under a megabyte; the Xray-core engine needs ~18 MB |

**Why 22.03 is a boundary and not a preference.** From 22.03 the firewall is
firewall4 on nftables, and byway stands entirely on it. On 21.02 and older it is
firewall3 with iptables — a different mechanism, a mark-based rule will not go
in, and neither guests nor zones with an `input REJECT` policy would get the
tunnel. On such a system the installer **refuses to run** and says why: half a
working byway is worse than an honest refusal.

The lower bound comes from the engine: Xray-core is already in the feed in 22.03, and
byway can fetch it from GitHub itself. For
[podkop](https://github.com/itdoginfo/podkop) that bound is one OpenWrt release higher
only because sing-box appears in the feeds from 23.05.

The package manager is detected automatically: `apk` from 25.12, `opkg` on 24.10
and older.

**About the 25 MB for a GitHub install.** Eighteen for the engine itself plus
room to unpack; the archive stays in memory, not on flash. With less, the
installer does not ask — it takes the firmware feed's version and says so out
loud.

---

## What byway does not do

Worth knowing before installing, not after.

- **IPv6 — experimental, off by default.** Turn it on with
  `uci set byway.main.ipv6=1`. Both families are intercepted: their own nft
  sets, their own fake pool (`fc00::/18`), their own routing rule.

  > **IPv6 has never been verified with real traffic.** The rules are accepted
  > by kernels 25.12.5 and 22.03.7 and were read line by line — that is all.
  > The ISP byway was written on does not provide IPv6. Rules written blind are
  > **worse than no rules** in an interception path — they quietly send part of
  > the traffic the wrong way, and it can take weeks to notice. If you have IPv6
  > and are willing to test on your own router,
  > [say so](https://github.com/tomon-one/byway/issues) — a report is needed
  > exactly here.

- **No `hysteria2`, `tuic`, `wireguard`** — they are not in Xray-core.
- **One engine — Xray-core, and no second one is planned.** byway's plumbing
  really does not depend on the engine, but sing-box supports neither the
  `xhttp` nor the `kcp` transport, keeps no access log for byway to count usage
  from, and splits its configs into two incompatible dialects. In return it
  offers QUIC-based protocols, which are the first thing throttled in Russia.
  The trade does not add up — decided 2026-09-07. In detail, with numbers and
  with what would change our mind:
  [why Xray-core only](docs/why-not-sing-box.en.md).
- **A client with its own DNS bypasses it.** DNS decides the route: a device
  with Private DNS or DoH in the browser asks someone other than the router and
  gets the real address instead of our placeholder — a made-up address by which
  byway recognises the traffic it should take (see [How it
  works](#how-it-works)). `byway doctor` says so. The
  cure is either to turn encrypted DNS off on the device, or to add the
  service's **subnets** alongside its domains: a subnet works by address, and so
  works for whoever asked someone else for it. One does not replace the other —
  subnets complement domains.
- **On many cheaper routers the engine can only come from the firmware.** That
  means models with a MIPS processor — a sizeable share of inexpensive
  hardware. Their processor cannot do fractional arithmetic on its own, and the
  ready-made Xray-core builds on GitHub count on it, so they do not start at all.
  The installer recognises such hardware and installs the version that ships
  with the firmware: it is built differently and works. Nothing for you to do —
  but there the firmware picks the engine version, not you.

  To check your own (the same test the installer makes):

  ```sh
  if uname -m | grep -q mips && ! grep -qi fpu /proc/cpuinfo
  then echo "engine from the firmware only"; else echo "GitHub is fine"; fi
  ```

---

## Installing

**Way 1 — one line:**

```sh
sh -c "$(wget -O - https://raw.githubusercontent.com/tomon-one/byway/v0.2.3/install.sh)"
```

**Way 2 — through a mirror,** if `raw.githubusercontent.com` is unreachable.
**The mirror is someone else's** — the public `gh-proxy`, the same one
[Zapret-Manager](https://github.com/StressOzz/Zapret-Manager) uses. We neither
run it nor check what it serves. If you would rather not trust a third party
inside a root install, take the archive the third way and read it first.

```sh
wget -T 10 -O /tmp/byway-install.sh \
  "https://v4.gh-proxy.org/raw.githubusercontent.com/tomon-one/byway/v0.2.3/install.sh" \
  && sh /tmp/byway-install.sh
```

**Way 3 — as an archive,** if you want to read it first:

```sh
cd /tmp
wget -O byway.tar.gz https://github.com/tomon-one/byway/archive/refs/tags/v0.2.3.tar.gz
tar xzf byway.tar.gz && cd byway-0.2.3
sh install.sh
```

**How to check the installer rather than trust it.** It runs as root — it could
not touch the network otherwise:

- the link points at a **tag**, not a branch: you install what is marked with a
  version, not what the author pushed a minute ago;
- it is one readable file: `wget -O - …` without `| sh` shows all of it;
- it names every step it takes out loud and does nothing silently.

**The first two ways download twice.** The one-liner puts only `install.sh` on
the router; it fetches the rest of the package with a second request, from the
same tag that is baked into it as a constant. If the tag does not exist it says
out loud that it took the `main` branch, rather than pretending it installed a
tagged version. The third way goes to the network once, entirely in front of you.

**It asks about what is optional:** where to get the Xray-core engine and which
version, and whether `base64` is needed (only for `vmess://` and `ss://` keys).
Mandatory pieces are installed without questions. If it has no one to ask — run
from a script, say — it takes the defaults and prints that it did.

**The installer does not touch your configuration or lists** — which is why
running it again is safe, and why updates install the same way.

---

## First run

**1. The key.** Web UI: *Services → Byway → Overview*, the "Key" field — the whole link
from your VPN: `vless://`, `vmess://`, `trojan://`, `ss://` or `socks://`. Or in
the console:

```sh
uci set byway.main.node_url='vless://…'   # or vmess://, trojan://, ss://, socks://
uci set byway.main.enabled=1
uci commit byway
```

**2. The list.** The "Routes" tab or the file `/etc/byway/domains.lst`, one
entry per line; an entry covers subdomains too. Ready-made lists are attached
next to it with a checkbox. Or the "Everything through the VPN" mode, if there
is nothing to split.

**3. Start:**

```sh
/etc/init.d/byway enable
/etc/init.d/byway start
```

**4. Check** — `byway health`. The engine takes about fifteen seconds to come
up; there is nothing to check before that.

If something is wrong — `byway doctor`: it checks the environment and names a
cure for every fault.

---

## What it can do

### Routing

- **By domains and subnets.** Lists are plain files, one entry per line; an
  ordinary entry covers subdomains. If you need to be more precise, byway
  accepts Xray-core's forms: `full:` (that name only), `keyword:` (a match on a
  fragment), `regexp:`. `geosite:` and `ext:` are **not yet** accepted: they need a
  geodata file of a dozen megabytes, and the router has forty in total. If it
  matters to you more than the free space —
  [say so](https://github.com/tomon-one/byway/issues), it is not hard to add. Non-Latin domains go in punycode. A line that does
  not parse is named out loud at build time and left out of the list.
- **Both address families.** IPv4 and IPv6: their own rule sets, their own
  fake pool, their own routing rule — all in one firewall table, not a second
  one beside it. The "no traffic outside the VPN" block covers both as well.
  ⚠️ **Experimental and off by default:** the rules are accepted by kernels
  22.03 and 25.12, but the author has no IPv6 and there was nowhere to verify
  them. Turn it on with `uci set byway.main.ipv6=1 && uci commit byway`; a
  report on how it behaved is [the most useful thing you can
  send](https://github.com/tomon-one/byway/issues).
- **Two modes.** "By lists" — only what is listed goes through the VPN.
  "Everything through the VPN" — all traffic, with a separate checkbox that
  keeps `.ru`, `.su` and `.рф` domains direct.
- **Several exits.** A separate list can be sent to a separate VPN: "these
  domains go there, everything else to the main one".
- **Ready-made lists** are attached with a checkbox and refresh either on a
  button or on their own — the interval is written in words: `12h`, `2h37m`,
  `1d`. Besides domains they bring subnets: services that work by address rather
  than by name need them. They do not argue with your own lists; entries are
  merged.

  **byway counts how many addresses a list covers and says it out loud:** whole
  hosting ranges pull other people's traffic into the tunnel, and it is better
  to know that as a number in advance than as lost speed later.
- **DNS** can stay direct or go through the VPN. Domains from the list are not
  affected: a built-in resolver answers those locally.

### Connection

- **Keys:** `vless`, `vmess`, `trojan`, `shadowsocks`, `socks`.
  **Transports:** `tcp/raw`, `ws`, `grpc`, `httpupgrade`, `xhttp`, `kcp`
  (recent Xray-core versions dropped `header` and `seed` from the last one — byway
  writes them only if your link has them, and says so).
  **Security:** `tls`, `reality`.
- **Several keys at once:** pick one by hand or let Xray-core do it — it measures
  latency and routes through the fastest live one.
- **Subscription:** fetch a list of keys by URL and pick one.
- **Your own outbound config** — for what byway does not parse from a link.
- **Multiplexing** — several client streams inside one connection to the VPN.
  It is a web-transport technique; byway has four of those: `ws`,
  `httpupgrade`, `xhttp` and `grpc`.

  It is enabled where the transport **does not multiplex itself** — that is, on
  `ws` and `httpupgrade`. `xhttp` has its own `xmux` for that, `grpc` has
  `multiMode`, and a second layer on top only gets in the way; with
  `xtls-rprx-vision` byway leaves it off too — Vision splits the stream itself.
  It says so out loud in every such case rather than staying quiet.

  Measured on `ws`: session setup went **588 → 149 ms**, and connections to the
  server dropped from about fifty to exactly eight.

### When something goes wrong

- **A plumbing watchdog.** Every five minutes it checks that the rules are in
  place while the engine is running, and puts them back if something outside
  removed them — someone else's `nft flush ruleset`, a firewall4 update, a
  neighbouring service. It leaves deliberately removed plumbing alone.
- **Failure behaviour** is a choice — see [How it works](#how-it-works).
- **Checks:** `byway doctor` for the environment, `byway health` for whether it
  works right now, `byway probe` to test a key in isolation without touching the
  working tunnel.
- **A state log** — what changed and when: drops, restarts, plumbing removed.
  Written every five minutes and only when there is something to write.
- **A report for a bug thread** — `byway report`: state, environment and
  diagnostics as one piece of text, **without the VPN key**.

### Control

- **The LuCI web UI**, from which everything is done: key, mode, lists,
  diagnostics. You never have to touch the console.
- **A console menu** — `byway menu`, the same actions.
- **Export and import.** All settings and lists as one piece of text:
  `byway export` and `byway import`. The export comes with or without the key
  (`--no-key`).
- **Usage statistics** (off by default): which list entries are actually used.
  Useful when deciding what to remove. Everything stays on the router.

---

## How it works

A domain from the list gets an address from byway that does not exist on the
internet (from the `198.18.0.0/15` range). After that it is simple: any packet
to such an address is by definition the traffic that has to be diverted, and
that is visible without looking inside.

```
dnsmasq → Xray-core DNS inbound → placeholder address for a listed domain
                                    ↓
                  nft rules divert that traffic
                                    ↓
              Xray-core restores the domain and decides where to send it
```

Where things go:

| | |
|---|---|
| `byway` — one script, all the logic | `/usr/local/bin/byway` |
| the procd service | `/etc/init.d/byway` |
| settings | `/etc/config/byway` |
| lists, engine config, logs | `/etc/byway/` |
| the panel | `/www/luci-static/resources/byway/` and `.../view/byway/` |

**If Xray-core did not come up, interception is not enabled either.** The house is
left with the internet and without the tunnel, rather than without DNS — that is
a deliberate choice.

This is easy to get wrong, so plainly: **without the tunnel the list does not
stop working — it starts working AROUND the VPN.** The domains resolve to real
addresses, connections open as usual, and from your home address. Sites open,
everything looks intact, there is no protection — and nothing tells you so.

That is exactly what the second failure model — **"do not let it through"** —
is there to prevent.
What exactly it closes depends on the list mode, and the difference is large:

| mode | what stays closed until the VPN returns |
|---|---|
| by lists | the list only; the rest of the internet works |
| everything through the VPN | the whole way out — this is the full kill switch |

Access to the router itself (LuCI, ssh) is untouched in either case. The switch
is on the "Overview" tab.

---

## The web UI

*Services → Byway*, five tabs:

| tab | what is there |
|---|---|
| **Main** | whether it works, through what, and how to change that: state, key, connection mode, failure behaviour |
| **Routes** | what goes through the VPN: mode, your lists, ready-made lists, directions |
| **Network** | whose traffic to divert, DNS, interception ports and addresses |
| **Maintenance** | statistics, state log, settings transfer, updates, full state |
| **Advanced** | values you change once in a lifetime |

> ⚠️ **Clear the browser cache after updating byway.** LuCI appends the version
> of **LuCI itself** to a module's URL, not the file's, so after a byway update
> the browser does not know the file changed and keeps showing the old tab, and
> there is no way
> to tell by looking. Ctrl+F5 helps, but only re-fetches **the modules of the
> open page** — you would have to do it on every tab. More reliable: F12 →
> Network → "Disable cache" → F5, without closing the tools.

---

## Commands

| command | what it does |
|---|---|
| `byway` | state and the list of commands |
| `byway menu` | console menu |
| `byway status` | what is working right now |
| `byway health` | service, VPN link, traffic, DNS |
| `byway doctor` | environment: modules, tools, space, conflicts |
| `byway gen` | rebuild the config from settings and lists |
| `byway plumb on\|off` | raise or remove interception |
| `byway check [LINK]` | parse a key and verify the config, no connections |
| `byway probe [LINK]` | test a VPN in isolation without touching the working tunnel |
| `byway sub URL` | fetch a subscription and show the keys |
| `byway presets` | refresh the ready-made lists |
| `byway top [N]` | what is actually used |
| `byway update [--check]` | see whether a new version exists, and install it |
| `byway engine [VERSION]` | the Xray-core engine version and its replacement |
| `byway report [file]` | a report for a bug thread: state and diagnostics, no key |
| `byway export [file]` | export settings; `--no-key` leaves the VPN key out |
| `byway import FILE` | apply settings from an export |
| `byway clear log\|stat\|all` | clear the state log, the statistics, or both |
| `byway show` | show the built config, without the key |
| `byway nft` | show the interception rules without applying anything |
| `byway version` | version |

---

## Updating

```sh
byway update --check     # see whether a new version exists
byway update             # install it
byway update --force     # reinstall the same version
```

⚠️ **Update this way, not with the install one-liner.** `byway update` knows
about the quirk below and works whatever your settings are; the install line
does not.

**The router itself cannot reach the listed sites**, and that is not a fault:
interception catches traffic from your home devices, while the router's own
traffic goes past it. `wget` on the router answers `Operation not permitted` —
the resolver handed out a placeholder address and there is no road to it.

`byway update` knows this and goes through byway's own proxy. If you need the
install line on a running router, take the same route, and use `curl` rather
than `wget` (busybox's wget cannot do proxies):

```sh
sh -c "$(curl -fsSL --proxy http://127.0.0.1:1603 \
  https://raw.githubusercontent.com/tomon-one/byway/v0.2.3/install.sh)"
```

An update does not touch settings or lists. Clear the browser cache afterwards —
see the warning above.

**Checking for a version and installing one are different things, and they leave
different traces.**

| | default | what it does |
|---|---|---|
| `update_check` | **on** | asks GitHub once a day whether a newer release exists |
| `auto_update` | off | installs what it found on its own, at a set hour |
| `auto_update_hour` | `04` | that hour, by the router’s clock |

A regular request from your home address is a steady "byway is installed here"
trace, readable at the ISP without any traffic inspection. It is turned off with
a checkbox on the "Maintenance" tab or `option update_check '0'`.

**The same is true of refreshing the ready-made lists** (`lists_update`) — it
also goes to GitHub on a schedule. The difference is the default: the version
check is on, the list refresh is **off**, and you set the interval yourself. Both
first try to go through the tunnel and only fall back to going direct — so the
trace is left exactly when the VPN is down.

**Auto-update** (`auto_update`) is off deliberately: it restarts the service,
which takes the tunnel away from the whole house. By turning it on you accept
that this happens overnight, at a set hour — 04:00 by default, **by the
router's clock**. The hour is yours to choose: `auto_update_hour`, a value of
0–23, with a field on the Maintenance tab too.

⚠️ **The router's clock is not yours.** Stock firmware keeps time in UTC, and
then 04:00 on the router is 07:00 in Moscow and 14:00 in Vladivostok — a
service restart in the middle of the day. `byway doctor` prints the router's
time zone and current time on a line of its own; read it before you turn this
on.

A release is installed no sooner than three days after it appears (important ones
immediately) and only to a release that keeps the same first two numbers:
`0.1.1` to `0.1.4` yes, `0.1.4` to `0.2.1` no. If the tunnel does not come
up within two and a half minutes, byway puts the previous version back on its
own.

---

## Engine version

byway is not tied to a version of Xray-core. The installer asks which **version**
you want; where to take it from is its own problem — GitHub first, the firmware
feed if that fails.

- **the one verified with byway** — the default; byway was run through on it;
- **the newest one, pre-releases included** — whatever XTLS released last;
- **the newest stable one** — the last one without the pre-release mark;
- **none** — if you will point at a path yourself later.

A version number can also be typed by hand instead of picking from the list.

⚠️ **"Newest" and "stable" are different things for Xray-core, and the gap is wider
than it looks.** XTLS (the team that makes Xray-core) marks everything newer than
`26.3.27` as a pre-release — so "the newest stable one" is months behind, and
what runs on the developer's router is a pre-release.

⚠️ **On MIPS without a floating-point unit there is no GitHub engine at all** —
and that is almost every inexpensive MIPS router. XTLS publishes
`mips32le` and `mips64le` hard-float only, while the common router processors — 24Kc
on ath79, 1004Kc on mt7621 — have no coprocessor, and the binary dies on its
first instruction with `Illegal instruction`. Picking another version does not
help: a soft-float build does not exist in the release. The feed ships the same
Xray-core built soft-float and it works — the installer recognises such a CPU
**before** downloading and takes the feed instead of spending 35 MB of your link
and flash. Verified on `mipsel_24kc`.

**It is worth keeping the engine fresh.** Xray-core moves fast: transports get
fixed and added. The version is changed with one command:

```sh
byway engine              # what is installed, what byway was tested with, what XTLS has
byway engine 26.9.9       # install this version
byway engine tested       # the version byway was fully tested on
byway engine newest       # the newest one, pre-releases included
```

The archive is checked against the SHA2-256 sum from the release. If there is
room for a second engine, the new one goes next to it, and the previous one is
removed only after the tunnel is up on the new one. If there is not (routine for
a router with 40 MB for changes), the replacement goes through memory: the
tunnel drops for about a minute, and the way back is an archive of the previous
version downloaded in advance. If the tunnel does not come up on the new
engine, the previous one comes back by itself.

`byway update` does not touch the engine: it updates byway only.

In the panel, the same versions are shown by the «Xray core» block on the
«Maintenance» tab; the engine is replaced from the console, since the swap takes
longer than the panel is willing to wait.

**On MIPS without an FPU** `byway engine` refuses: XTLS builds do not run
there. The engine is updated with the package — `apk upgrade xray-core` or
`opkg upgrade xray-core`.

**If the config stopped building after an engine update** — byway verifies every
build with the engine itself, so an incompatibility does not pass silently: the
config is not replaced, the previous one keeps working, and `byway engine`
keeps the previous engine in that case. That already happened with the `h2` and
`quic` transports: the engine no longer accepts them and says they were
"removed and migrated to XHTTP". Since 26.7.11 Xray-core also refuses vless or
trojan without TLS or reality to a public address — byway says so plainly. To
go back to the version that worked: `byway engine 26.7.28`.

And [tell us about it](https://github.com/tomon-one/byway/issues): if the engine
changed what byway generates, that is fixed in byway rather than worked around
by every user separately.

---

## Removal

The installer puts the uninstaller next to the program, nothing to download:

```sh
byway-uninstall              # settings and lists stay
byway-uninstall --purge      # remove everything, including the key
DRY_RUN=1 byway-uninstall    # show what would be done, change nothing
```

⚠️ **Installed a version before 0.1.4?** Then you do not have that file -- it
only appears at install time. Take it from the archive of the same tag:

```sh
wget -O /tmp/byway-uninstall   https://raw.githubusercontent.com/tomon-one/byway/v0.2.3/uninstall.sh
sh /tmp/byway-uninstall
```

The script returns the network to its original state on its own: DNS goes back
to the ISP, rules are removed, the service is unregistered. It does not touch
the Xray-core engine or the network settings.

---

## Compatibility

**On real hardware:** Cudy WR3000S v1 (MediaTek MT7981, aarch64), OpenWrt
25.12.5. Developed and used daily: 1500 domains and 300 subnets, transports ws,
xhttp, httpupgrade and tcp+reality. This is the only combination where byway is
verified end to end — with a live tunnel, real traffic and real flash limits.

**On a test bench** (qemu, x86-64, `generic-ext4-combined` images):

| version | what was verified |
|---|---|
| 22.03.7 | full install, opkg branch |
| 23.05.6 | install; removal, dry run and `--purge` |
| 24.10.8 | install, engine from GitHub, opkg branch; removal and `--purge` |
| 25.12.5 | install, apk branch; settings import, clearing, list downloads |

**Architectures** (qemu, initramfs, OpenWrt 25.12.5; there is no acceleration
for non-x86, so the guest runs emulated):

| target | what was verified |
|---|---|
| `armsr/armv8` (`aarch64_generic`) | full install from GitHub; the GitHub engine downloaded and ran |
| `malta/le` (`mipsel_24kc`) | full install; the GitHub engine does not run, the feed one is taken |

That is installation and environment, not life under load: no tunnel was
brought up on these guests — a test bench has no key and should not have one.

"Removal verified" here is meant literally: a snapshot of the system is taken
BEFORE the install and AFTER `uninstall.sh --purge`, and they match byte for
byte — including dnsmasq and firewall settings, cron jobs, nft tables, routing
rules and the firmware keep list. The dry run is separately verified to change
not a single byte.

**What the bench does not verify, and it matters.** It is x86-64, so the choice
of engine build for your architecture is never executed there — and that is
exactly where a bug already lived (on MIPS the build with the wrong byte order
was downloaded). Flash in a VM is elastic, so the 43.7 MB ceiling is not
reproduced. The tunnel does not come up on the bench at all: install and cleanup
are verified, not operation.

There was no other hardware. The list of devices byway has been run on lives in
the [compatibility
reports](https://github.com/tomon-one/byway/issues?q=label%3Acompatibility).
If you ran it, add yours: that is the single most useful thing you can report
right now — and a failure report beats a success one.

---

## Written with an AI

byway's code was written by Claude, to a human's brief and corrections: the link
parser, the nft rules and the web UI alike. That proves nothing by itself — so
here is how the generated was told apart from the verified.

**Reviews by independent agents, angle by angle.** Each agent got its own angle —
data from outside, permissions and secrets, shell mistakes, failure behaviour,
cleaning up after itself, two processes touching one file at once, living
alongside other people's programs on the router, limits and volumes, clocks and
time zones, whether the README matches what the code actually does. Every finding was then
checked by a separate sceptic given the **opposite** task: to refute it, not to
confirm it.

There have been several such reviews: of the code, of the web UI, and a second
pass over the code that ran in four rounds. Everything they found is closed.

**What reading does not catch — and what was done about it.** Two things were
missed by every pass; both were caught by a parser, `nft -c`.

First: a rule chain was named `fwd`, which is a reserved word in nft — so the
kernel rejected the **whole** table along with it, and the subnet side of the
kill switch had never loaded since the day it was written. The error was
muffled by `2>/dev/null || true`, so nothing showed up in the log either.
Second: the check itself ran against the previous table while it was still
loaded, and so complained about a perfectly good set of rules.

Three passes read those lines and saw neither. Hence three benches that run
**every** branch of what byway hands to other programs: firewall rules through
`nft -c`; the engine config and the blocking snippet through Xray-core itself and
`dnsmasq --test`; UCI edits and cron jobs against a stand-in configuration.

**Every config build is verified by the engine itself** — `xray run -test`. If
it is not accepted, the working config is not replaced and the tunnel keeps
running on the previous one.

**It runs every day on a live router.** Fifteen hundred domains, three hundred
subnets, and a family that notices immediately when something breaks.

**What none of this means.** byway has seen one router model and one OpenWrt
version, IPv6 was never tested at all, and full removal has been verified on a
live router exactly once.

---

## License

[GPL-2.0](LICENSE) — the same one OpenWrt itself lives under.
