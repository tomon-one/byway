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
> | verified on a test bench | install and removal on 22.03–25.12, with opkg and with apk; install on aarch64 and mipsel |
> | never verified at all | IPv6 (written, but has never seen live traffic), behaviour under load, everyday use on any CPU other than MT7981 |
>
> **The code was written by an AI** — Claude, to a human's tasks and with a
> human's corrections. That is said up front rather than in a footnote:
> [how the code was checked](#written-with-an-ai).
>
> **A report that it did not work for you is worth more than any code review** —
> more even than a success report:
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
scripts plus a LuCI panel. Xray-core carries the traffic, while byway decides
what goes where, builds the engine's config, installs the firewall rules and
makes sure they stay in place. byway itself encrypts nothing and carries
nothing.

---

## Requirements

| | |
|---|---|
| **OpenWrt 22.03 or newer** | a hard boundary, see below |
| **`kmod-nft-tproxy`, `kmod-nft-socket`** | the installer fetches them |
| **`curl`** | the installer fetches it |
| **`unzip`** | the installer fetches it when the engine comes from GitHub |
| **Flash space** | byway itself is under a megabyte; the Xray-core engine takes ~18 MB, and a GitHub download needs 25 MB free |

**Why 22.03 is a boundary and not a preference.** From 22.03 the firewall is
firewall4 on nftables, and byway stands entirely on it. On 21.02 and older it is
firewall3 with iptables — a different mechanism, a mark-based rule will not go
in, and neither guests nor zones with an `input REJECT` policy would get the
tunnel. On such a system the installer **refuses to run** and explains why: a
byway that half works is worse than an honest refusal.

The lower bound comes from the firewall, not the engine: Xray-core is in the
OpenWrt packages from 22.03 on, and byway installs it from GitHub on any
release. For [podkop](https://github.com/itdoginfo/podkop) the bound is one
release higher only because sing-box appears in the packages from 23.05.

The package manager is detected automatically: `apk` from 25.12, `opkg` on 24.10
and older.

**Why a GitHub download needs 25 MB.** Eighteen for the engine itself, the rest
is room to unpack; the archive stays in memory, not on flash. With less free
space the chosen version is not downloaded: the installer says so and installs
Xray-core from the OpenWrt packages.

---

## What byway does not do

Worth knowing before installing, not after.

- **IPv6 — experimental, off by default.** Turn it on with
  `uci set byway.main.ipv6=1 && uci commit byway`; the web UI has no switch for
  it. Both families are intercepted: their own nft sets, their own fake pool
  (`fc00::/18`), their own routing rule.

  > **IPv6 has never been verified with real traffic.** The rules are accepted
  > by the Linux kernel in OpenWrt 25.12.5 and 22.03.7 and were read line by
  > line — that is all. The ISP byway was written on does not provide IPv6.
  > Rules written blind are **worse than no rules** in an interception path —
  > they quietly send part of the traffic the wrong way, and it can take weeks
  > to notice. If you have IPv6 and are willing to test on your own router,
  > [say so](https://github.com/tomon-one/byway/issues) — a report is needed
  > exactly here.

- **No `hysteria2`, `tuic` or `wireguard` keys.** The first two are not in
  Xray-core, and byway does not parse `wireguard://` links.
- **One engine — Xray-core, and no second one is planned.** byway itself
  really does not depend on the engine, but sing-box supports neither the
  `xhttp` nor the `kcp` transport, keeps no access log for byway to count usage
  from, and splits its configs into two incompatible dialects. In return it
  offers QUIC-based protocols, which are the first thing throttled in Russia.
  The trade does not pay off; decided 2026-09-07. In detail, with numbers and
  with what would change the decision:
  [why Xray-core only](docs/why-not-sing-box.en.md).
- **A device with its own DNS goes around byway.** The route is chosen by DNS.
  A device with Private DNS or DoH (encrypted address lookups straight from
  the browser, past the router) asks someone other than the router and gets the
  real address. But byway recognises the traffic to take precisely by the
  placeholder — a made-up address it hands out itself (see [How it
  works](#how-it-works)). The router cannot tell such devices apart, so
  `byway doctor` always reminds you of this. Any one of three things helps:
  turn encrypted DNS off on the device, intercept port 53 in the firewall, or
  add the service's **subnets** alongside its domains. A subnet works by
  address, and so works for a device that asked someone else for it; subnets
  complement domains rather than replace them. They cover IPv4 only.
- **On many cheaper routers the engine can only come from the OpenWrt
  packages.** That means models with a MIPS processor — a sizeable share of
  inexpensive hardware. Their processor cannot do fractional arithmetic on its
  own, and the ready-made Xray-core builds on GitHub count on it, so they do not
  start at all. The installer recognises such hardware and installs Xray-core
  from the OpenWrt packages: it is built differently there and works. Nothing
  for you to do — but there the OpenWrt release picks the engine version, not
  you (see [Compatibility](#compatibility)).

  To check your own (the same test the installer makes):

  ```sh
  if uname -m | grep -q mips && ! grep -qi fpu /proc/cpuinfo
  then echo "engine from OpenWrt packages only"; else echo "GitHub is fine"; fi
  ```

---

## Installing

**Way 1 — one line:**

```sh
sh -c "$(wget -O - https://raw.githubusercontent.com/tomon-one/byway/v0.2.3/install.sh)"
```

**Way 2 — through a mirror,** if `raw.githubusercontent.com` is unreachable.
**The mirror is someone else's** — the public `gh-proxy`, the same one
[Zapret-Manager](https://github.com/StressOzz/Zapret-Manager) uses. byway's
author neither runs it nor checks what it serves. If you would rather not trust
a third party inside a root install, take the archive the third way and read it
first.

```sh
wget -T 10 -O /tmp/byway-install.sh \
  "https://v4.gh-proxy.org/raw.githubusercontent.com/tomon-one/byway/v0.2.3/install.sh" \
  && sh /tmp/byway-install.sh
```

The installer also switches to this mirror by itself when GitHub cannot be
reached either directly or at addresses obtained over DoH — and warns you when
it does. To forbid it: `NO_MIRROR=1 sh install.sh` — the install then stops.

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
  version, not what the author published a minute ago;
- it is one readable file: `wget -O - …` without `| sh` shows all of it;
- it names every step it takes and does nothing silently.

**The first two ways download twice.** The one-liner puts only `install.sh` on
the router; it downloads the rest of byway's files with a second request — the
same version (tag) that is written into it. If that tag does not exist, it says
it took the `main` branch, rather than pretending it installed a tagged version.
The third way fetches byway once, entirely in front of you.

**The installer asks up to four questions.** Mandatory pieces are installed
without asking.

1. **Language** — first, before any checks. Only the chosen language's
   dictionary is installed; the other can be added later with `byway lang`.
2. **Xray-core version:** the one verified with byway (default), the newest
   with pre-releases, the newest stable, a number of your own, or none. Where to
   get it from, the installer decides for you — details in [Engine
   version](#engine-version). If an engine is already installed, there is no
   question.
3. **`base64`** — needed only for `vmess://` and `ss://` keys; not installed by
   default.
4. **The LuCI web UI** — last, yes by default. If the router has no LuCI, there
   is no question and no panel: you manage byway from the console, `byway menu`.

If it has no one to ask — run from a script, say — it takes the defaults and
warns you that it did.

**The installer does not touch your key or lists;** in the settings it writes
only the chosen language and the engine path, if none was set. That is why
running it again is safe, and why updates install the same way. If byway is
already configured, the engine config is rebuilt and the service restarted —
the tunnel drops for a few seconds.

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
entry per line; an entry covers subdomains too. If everything should go through
the VPN, pick the "Everything through the VPN" mode.

**3. Start** (the installer has already enabled autostart):

```sh
/etc/init.d/byway start
```

**4. Check** — `byway health`. The engine takes about fifteen seconds to come
up; for the first 25 seconds the check answers "starting", and that is not a
failure.

**5. Ready-made lists** — on the same "Routes" tab, the "Ready-made lists"
field; they are downloaded with the "Download now" button. Better to do this
once the tunnel is up: the lists are downloaded through it.

If something is wrong — `byway doctor`: it checks the environment and names a
cure for every fault.

---

## What it can do

### Routing

- **By domains and subnets.** Lists are plain files, one entry per line; an
  ordinary entry covers subdomains. For finer control byway understands
  Xray-core's entry forms: `full:` (that name only), `keyword:` (a match on a
  fragment), `regexp:`. `geosite:` and `ext:` are **not yet** accepted: they
  need a geodata file of a dozen megabytes, and the router's flash is only
  about forty. If it matters to you more than the free space —
  [say so](https://github.com/tomon-one/byway/issues), it is not hard to add.
  Non-Latin domains go in punycode. A line that cannot be parsed is shown at
  build time and left out of the list.
- **Both address families.** IPv4 and IPv6: their own rule sets, their own
  fake pool, their own routing rule — all in one firewall table, not a second
  one beside it. The "no traffic outside the VPN" block covers both as well.
  ⚠️ **Experimental and off by default** — see [What byway does not
  do](#what-byway-does-not-do).
- **Two modes.** "By lists" — only what is listed goes through the VPN.
  "Everything through the VPN" — all traffic, with a separate checkbox that
  keeps `.ru`, `.su` and `.рф` domains direct.
- **Several exits.** A separate list can be sent to a separate VPN: "these
  domains go there, everything else to the main one".
- **Ready-made lists** are chosen in the web UI and refreshed with a button or
  on a schedule — the interval is written as `12h`, `2h37m`, `1d`. Besides
  domains they carry subnets, for services that work by address rather than by
  name. They do not conflict with your own lists: entries are merged.

  **If the subnets cover more than a million addresses** or include a `/12`
  block or wider, byway names the number when downloading, when building and in
  `byway doctor`: whole hosting ranges pull other people's traffic into the
  tunnel, and it is better to know that as a number in advance than as lost
  speed later.
- **DNS queries** go direct or through the VPN. Domains from the list are not
  affected: a built-in resolver answers those locally.

### Connection

- **Keys:** `vless`, `vmess`, `trojan`, `shadowsocks`, `socks`.
  **Transports:** `tcp/raw`, `ws` (WebSocket), `grpc`, `httpupgrade`, `xhttp`,
  `kcp` (recent Xray-core versions dropped the `header` and `seed` parameters
  from `kcp`; byway puts them into the config only if your link has them, and
  warns you about it).
  **Security:** `tls`, `reality`.
- **Several keys at once:** pick one by hand or let Xray-core do it — it measures
  latency and routes through the fastest live one.
- **Subscription:** fetch a list of keys by URL and pick one.
- **Your own outbound config** — for what byway does not parse from a link.
- **Multiplexing** — several client streams inside one connection to the VPN.
  On by default (eight streams) on every transport except those that multiplex
  themselves: `xhttp` has its own `xmux` for that, `grpc` has `multiMode`, and
  a second layer on top only gets in the way. With `xtls-rprx-vision` byway
  leaves it off too: Vision splits the stream itself. byway tells you about
  every such case.

  Measured on the author's VPN (the `ws` transport, 60 simultaneous
  connections), without multiplexing and with it: median session setup
  **588 → 149 ms**, and connections to the server dropped from about fifty to
  exactly eight.

### When something goes wrong

- **An interception watchdog.** Every five minutes it checks that the rules are
  in place while the engine is running, and puts them back if something outside
  removed them — someone else's `nft flush ruleset`, a firewall4 update, a
  neighbouring service. Rules removed on purpose are left alone.
- **Failure behaviour** is a choice — see [How it works](#how-it-works).
- **Checks:** `byway doctor` for the environment, `byway health` for whether it
  works right now, `byway probe` to test a key in isolation without touching the
  working tunnel.
- **A state log** — what changed and when: connection drops, restarts,
  interception removed. Written every five minutes and only when there is
  something to write.
- **A report for a bug thread** — `byway report`: state, environment and
  diagnostics as one piece of text, **without the VPN key**.

### Control

- **The LuCI web UI:** key, mode, lists, diagnostics, updates. The console is
  needed only for experimental IPv6.
- **A console menu** — `byway menu`, the same actions.
- **Export and import.** All settings and lists as one piece of text:
  `byway export` and `byway import`. The export comes with or without the key
  (`--no-key`).
- **Usage statistics** (off by default): which list entries are actually used.
  Useful when deciding what to remove from a list. Everything stays on the
  router; not collected in "Everything through the VPN" mode.

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
| the web UI (installed if LuCI is present and you agreed in the installer) | `/www/luci-static/resources/byway/` and `.../view/byway/` |
| the English dictionary, only if English is chosen | `/etc/byway/lang/en.tsv` and the panel's `lang.js` |

**If Xray-core did not come up, interception is not enabled either.** The house is
left with the internet and without the tunnel, rather than without DNS — that is
a deliberate choice.

This is easy to get wrong, so plainly: **without the tunnel the list does not
stop working — it starts working AROUND the VPN.** The domains resolve to real
addresses, connections open as usual, and from your home address. Sites open,
everything looks intact, there is no protection — and nothing tells you so.

That does not happen with the second failure behaviour — **"do not let it
through"**. What exactly it closes depends on the list mode, and the difference
is large:

| mode | what stays closed until the VPN returns |
|---|---|
| by lists | the list only; the rest of the internet works |
| everything through the VPN | the whole way out — this is the full kill switch |

Access to the router itself (LuCI, ssh) stays open in both modes. The switch is
on the "Overview" tab.

---

## The web UI

*Services → Byway*, five tabs:

| tab | what is there |
|---|---|
| **Overview** | whether it works, through what, and how to change that: state, key, connection mode, failure behaviour |
| **Routes** | what goes through the VPN: mode, your lists, ready-made lists, directions |
| **Network** | whose traffic to divert, DNS, interception ports and addresses, VPN for programs on the router |
| **Maintenance** | full state, state log, byway and Xray core updates, settings transfer, statistics |
| **Advanced** | language and values you change once in a lifetime |

> ⚠️ **Clear the browser cache after updating byway.** LuCI appends the version
> of **LuCI itself** to a module's URL, not the file's, so after a byway update
> the browser does not know the file changed and keeps showing the old tab, and
> there is no way to tell by looking. Ctrl+F5 helps, but only re-fetches **the
> modules of the open page** — you would have to do it on every tab of the web
> UI. More reliable: F12 → Network → "Disable cache" → F5, without closing the
> tools.

---

## Commands

| command | what it does |
|---|---|
| `byway` | state and the list of commands |
| `byway menu` | console menu |
| `byway status [--short]` | what is working right now |
| `byway health` | service, VPN link, traffic, DNS |
| `byway doctor` | environment: modules, tools, space, conflicts; updates |
| `byway gen` | rebuild the config from settings and lists |
| `byway plumb on\|off` | raise or remove interception |
| `byway check [LINK]` | parse a key and verify the config, no connections |
| `byway probe [LINK]` | test a VPN in isolation without touching the working tunnel |
| `byway sub URL` | fetch a subscription and show the keys |
| `byway presets` | refresh the ready-made lists |
| `byway top [N]` | which list entries are actually used |
| `byway stat` | collect statistics now, without waiting for the schedule |
| `byway update [--check\|--force]` | whether a new byway version exists, and installing it; `--force` reinstalls the same one |
| `byway engine [VERSION\|tested\|newest\|stable]` | whether an Xray-core update exists, and replacing the engine |
| `byway lang ru\|en` | output and web UI language |
| `byway report [file]` | a report for a bug thread: state and diagnostics, no key |
| `byway export [file]` | export settings; `--no-key` leaves the VPN key out |
| `byway import FILE` | apply settings from an export; `--no-key` keeps the current key |
| `byway clear log\|stat\|all` | clear the state log, the statistics, or both |
| `byway show` | a summary of the built config: size, domain and subnet counts, addresses — without the key |
| `byway nft` | show the interception rules without applying anything |
| `byway version` | version |

**Language.** `byway lang en` downloads the English dictionary for the
installed version; `byway lang ru` removes it. In the web UI it is the same
thing — "Advanced → Language".

---

## Updating

```sh
byway update --check     # see whether a new version exists
byway update             # install it
byway update --force     # reinstall the same version
```

An update does not touch settings or lists. The installer asks about the
language and the web UI again, offering your previous answers as defaults. At
the end the service restarts and the tunnel drops for a few seconds. Clear the
browser cache afterwards — see the warning in [The web UI](#the-web-ui).

⚠️ **Update this way, not with the install one-liner.** On a running router the
install line may fail — the reason is below; `byway update` works whatever your
settings are.

**If the "VPN for programs on the router" setting is off** ("Network" tab,
`router_via_vpn`), the router itself cannot reach the listed sites, and that is
not a fault: interception catches traffic from your home devices, while the
router's own traffic goes past it. `wget` on the router answers `Operation not
permitted` — the resolver handed out a placeholder address and there is no road
to it. Since 0.2.2 the setting is on by default, but older installs may still
have it off.

`byway update` goes through byway's own proxy and does not depend on this
setting. If you need the install line on a running router, take the same
route, and use `curl` rather than `wget` (busybox's wget cannot do proxies):

```sh
sh -c "$(curl -fsSL --proxy http://127.0.0.1:1603 \
  https://raw.githubusercontent.com/tomon-one/byway/v0.2.3/install.sh)"
```

**Checking for a version and installing one are different things, and they
are set up separately.**

| | default | what it does |
|---|---|---|
| `update_check` | **on** | asks GitHub once a day whether a newer release exists |
| `auto_update` | off | installs what it found on its own, at a set hour |
| `auto_update_hour` | `04` | that hour, by the router's clock |

The version check goes to GitHub at regular intervals, and noticing that
regularity is enough for the ISP to conclude that byway is installed here — no
traffic inspection needed. It is turned off with a checkbox on the
"Maintenance" tab or `option update_check '0'`.

**The same is true of refreshing the ready-made lists** (`lists_update`) — it
also goes to GitHub on a schedule. The difference is the default: the version
check is on, the list refresh is **off**, and you set the interval yourself. Both
first try to go through the tunnel and only fall back to going direct — so the
trace is left exactly when the VPN is down.

**Auto-update** (`auto_update`) is off deliberately: it restarts the service,
which leaves the whole house without the tunnel for a while. By turning it on
you accept that this happens overnight, at a set hour — 04:00 by default, **by
the router's clock**. The hour is set with the `auto_update_hour` option (0–23);
there is a field on the "Maintenance" tab too.

⚠️ **The router's time zone may not be yours.** Stock firmware keeps time in
UTC, and then 04:00 on the router is 07:00 in Moscow and 14:00 in Vladivostok —
a service restart in the middle of the day. The router's time zone is shown in
LuCI: *System → System Properties*. Once auto-update is on, `byway doctor`
warns in its "Updates" section if the clock runs on UTC.

Auto-update installs a release no sooner than three days after it appears
(important ones immediately) and only if the first two numbers of the version
match: `0.1.1` to `0.1.4` yes, `0.1.4` to `0.2.1` no. If the tunnel does not
come up within two and a half minutes, byway puts the previous program file
back and will not install that release by itself again; you can install it by
hand with `byway update --force`.

---

## Engine version

byway is not tied to a version of Xray-core. The installer asks which
**version** you want and picks the source for you: GitHub first, the OpenWrt
packages if that fails; with less than 25 MB free on flash, straight to the
packages. The choices:

- **the one verified with byway** — the default; byway is fully verified on it;
- **the newest one, pre-releases included** — whatever XTLS (the team that
  makes Xray-core) released last;
- **the newest stable one** — the last one without the pre-release mark;
- **none** — if you will point at an engine path yourself later.

A version number can also be typed by hand instead of picking from the list.

⚠️ **"Newest" and "stable" are different things for Xray-core, and the gap is wider
than it looks.** XTLS marks everything newer than `26.3.27` as a pre-release —
so "the newest stable one" is months behind, and what runs on the developer's
router is a pre-release.

⚠️ **On MIPS without a floating-point unit there is no GitHub engine at all** —
and that is almost every inexpensive MIPS router. XTLS publishes `mips32le` and
`mips64le` builds only for processors with such a unit. The common router
processors (24Kc on ath79, 1004Kc on mt7621) do not have one, and such a build
dies at once with `Illegal instruction`. Picking another version does not
help: the release has no builds without this requirement (soft-float). The
OpenWrt packages have the same Xray-core built soft-float, and it works. The
installer recognises such a CPU **before** downloading and takes the engine
from there straight away, without spending 35 MB of traffic and flash.
Verified on `mipsel_24kc`. `byway engine` refuses on such a CPU; the engine is
updated as a package — `apk upgrade xray-core` or `opkg upgrade xray-core`.

**It is worth keeping the engine fresh.** Xray-core moves fast: transports get
fixed and added. The version is changed with one command:

```sh
byway engine              # is there an engine update; below it — file, XTLS versions, space
byway engine --check      # only the answer: is there an update
byway engine 26.9.9       # install this version
byway engine tested       # the version byway is fully verified on
byway engine newest       # the newest one, pre-releases included
byway engine stable       # the newest stable one
```

The archive is checked against the SHA2-256 sum from the release. If there is
room for a second engine, the new one goes next to it, and the previous one is
removed only after the tunnel is up on the new one. If there is not (routine
on a router with 40 MB for your own files), the replacement goes through
memory: the tunnel drops for about a minute, and an archive of the previous
version is downloaded in advance for the way back. If the tunnel does not come
up on the new engine, the previous one comes back by itself. Any replacement
needs at least 40 MB of free RAM.

A previous engine from the OpenWrt packages is not removed — uninstall it with
the package manager. If there is no room for a second engine and the previous
one comes from a package, the replacement does not start: remove the package
first.

`byway update` does not touch the engine: it updates byway only.

In the web UI, the "Xray core" block on the "Maintenance" tab has a "Check for
a core update" button: it answers whether a newer version than the installed
one exists and names the command to replace it. The engine is replaced from
the console, since the swap takes longer than the web UI is willing to wait.

**If the config stopped building after an engine update.** byway verifies every
build with the engine itself, so an incompatibility does not pass silently. The
new config does not replace the previous one, the tunnel keeps running on the
old one, and `byway engine` keeps the previous engine. That already happened
with the `h2` and `quic` transports: the engine no longer accepts them and says
they were "removed and migrated to XHTTP". Since 26.7.11 Xray-core also refuses
vless or trojan connections to a public address without TLS or reality —
byway says so plainly. If the engine was updated around `byway engine` (as a
package, for example), go back to the version that worked with
`byway engine NUMBER`.

And [report it](https://github.com/tomon-one/byway/issues): if the engine
changed what byway generates, that is fixed in byway rather than worked around
by every user separately.

---

## Removal

The installer puts an uninstall script in place along with the program, so
there is nothing to download:

```sh
byway-uninstall              # settings and lists stay
byway-uninstall --purge      # remove everything, including the key and the engine downloaded from GitHub
DRY_RUN=1 byway-uninstall    # show what would be done, change nothing
```

⚠️ **Installed a version before 0.1.4?** Then you do not have that file: only
installers from 0.1.4 on put it in place. Download it separately:

```sh
wget -O /tmp/byway-uninstall \
  https://raw.githubusercontent.com/tomon-one/byway/v0.2.3/uninstall.sh
sh /tmp/byway-uninstall
```

The script returns the network to its original state on its own: DNS goes back
to what it was before byway, rules are removed, the service is unregistered.
The network settings are not touched. The engine stays unless the removal is
run with `--purge`: then the engine downloaded from GitHub
(`/usr/local/bin/xray-*`) is removed. An engine from the OpenWrt packages and
an engine at a path you entered by hand always stay.

---

## Compatibility

**On real hardware:** Cudy WR3000S v1 (MediaTek MT7981, aarch64), OpenWrt
25.12.5. Developed and used daily: 1500 domains and 300 subnets, transports ws,
xhttp, httpupgrade and tcp+reality. This is the only combination where byway is
verified end to end — with a live tunnel, real traffic and real flash limits.

**On a test bench** (qemu, x86-64, `generic-ext4-combined` images):

| version | what was verified |
|---|---|
| 22.03.7 | full install with opkg; engine 26.9.9 from GitHub |
| 23.05.6 | install; removal, dry run and `--purge` |
| 24.10.8 | install, engine from GitHub, with opkg; removal and `--purge` |
| 25.12.5 | install with apk; settings import, clearing, list downloads |

**The engine in the OpenWrt packages depends on the release:** 22.03 — 1.8.3,
23.05 — 24.12.31, 24.10 — 25.1.30, 25.12 — 26.3.27. From GitHub any version
installs on any release; the packaged engine is used only on MIPS without a
floating-point unit and on routers with little flash. On 22.03 that engine has
no `xhttp` transport.

**Architectures** (qemu, initramfs, OpenWrt 25.12.5; for non-x86 the virtual
machine runs under full emulation):

| target | what was verified |
|---|---|
| `armsr/armv8` (`aarch64_generic`) | full install from GitHub; the GitHub engine downloaded and ran |
| `malta/le` (`mipsel_24kc`) | full install; the GitHub engine does not run, the one from the OpenWrt packages is taken |

That is installation and environment, not operation under load: no tunnel was
brought up on these virtual machines — a test bench has no key and should not
have one.

"Removal verified" here is meant literally: a snapshot of the system is taken
BEFORE the install and AFTER `uninstall.sh --purge`, and they match byte for
byte — including dnsmasq and firewall settings, cron jobs, nft tables, routing
rules and the list of files kept across firmware upgrades. The dry run is
separately verified to change not a single byte.

**What the bench does not verify, and it matters.** It is x86-64, so the choice
of engine build for your architecture is never executed there — and that is
exactly where a bug already lived (on MIPS the build with the wrong byte order
was downloaded). Flash space in a virtual machine is not limited, so running
out of space at 43.7 MB cannot be reproduced there. The tunnel does not come up
on the bench at all: install and removal are verified, not operation.

There was no other hardware. The list of devices byway has been run on lives in
the [compatibility
reports](https://github.com/tomon-one/byway/issues?q=label%3Acompatibility).
If you ran it, add yours: that is the single most useful thing you can report
right now — and a failure report is worth more than a success one.

---

## Written with an AI

byway's code was written by Claude, to a human's tasks and with a human's
corrections: the link parser, the nft rules and the web UI alike. That proves
nothing by itself — so here is how the generated was told apart from the
verified.

**Code checks by independent AI agents, each with its own topic.** The topics:
data from outside, permissions and secrets, shell mistakes, failure behaviour,
cleaning up after itself, two processes touching one file at once, living
alongside other programs on the router, limits and volumes, clocks and time
zones, whether the README matches what the code actually does. Every finding
was then checked by another agent given the **opposite** task: to refute it,
not to confirm it.

There have been several such checks: of the code, of the web UI, and a second
pass over the code that ran in four rounds. Everything they found is closed.

**What reading does not catch — and what was done about it.** Two bugs were
missed by every reading pass; both were caught by the `nft -c` syntax check.

First: a rule chain was named `fwd`, which is a reserved word in nft — so the
Linux kernel rejected the **whole** table along with it, and the subnet side of
the kill switch had never loaded since the day it was written. The error was
muffled by `2>/dev/null || true`, so nothing showed up in the log either.
Second: the check compared the new rules against the previous table while it
was still loaded, and so found an error in a correct set of rules.

Three passes read those lines and saw neither. Hence three test benches —
automated checks that run **every** variant of what byway hands to other
programs: firewall rules through `nft -c`; the engine config through Xray-core
itself, the dnsmasq settings snippet through `dnsmasq --test`; UCI edits and
cron jobs against a stand-in configuration.

**Every config build is verified by the engine itself** — `xray run -test`. If
it is not accepted, the working config is not replaced and the tunnel keeps
running on the previous one.

**It runs every day on a live router** — the one this README starts with.

**What none of this means.** byway has seen one router model and one OpenWrt
version, IPv6 was never tested at all, and full removal has been verified on a
live router exactly once.

---

## License

[GPL-2.0](LICENSE) — the same one OpenWrt itself lives under.
