# The Xray-core engine

How byway finds the Xray-core engine, which version to install, how to replace
or roll it back, and what to do when the config stops building after an engine
update or the engine does not fit in memory or on flash.

Xray-core carries the traffic; byway builds its config and sets up the
interception. The engine version decides which keys can be used at all and in
what form byway writes the config. The short version of this document is the
[Engine version](../README.en.md#engine-version) section of the README.

---

## Where byway gets the engine

The path to the engine is in the `byway.main.xray_bin` option. There are
usually two sources:

| source | path | installed and updated by |
|---|---|---|
| XTLS release on GitHub | `/usr/local/bin/xray-VERSION` | the byway installer, then `byway engine` |
| OpenWrt packages (`xray-core`) | `/usr/bin/xray` | `apk` or `opkg` |

The version number in the file name lets two engines sit side by side and
lets you switch between them with one option.

The path comes from the settings, and the web UI edits those too, so byway
does not run just anything from it. The file must be in `/usr/bin`,
`/usr/sbin`, `/usr/local/bin`, `/bin` or `/sbin`, the path must not contain
`..`, the file name must start with `xray`, the file must be a regular
executable with an ELF header, and the first line of its `version` output
must start with the word `Xray`. The name and the header are checked before
anything is run: otherwise `xray_bin=/sbin/reboot` would reboot the router on
every byway call. If a check fails, byway prints
`the core path was rejected: …` and falls back to the default engine. A path
such as `/mnt/sda1/xray` is therefore not accepted, but a symlink
`/usr/local/bin/xray-…` to that file is; for USB, see "Flash".

If `xray_bin` is empty, both the `byway` command and the service look for
`xray` in `PATH`, then in `/usr/bin/xray`.
`/usr/local/bin` is not in `PATH` on OpenWrt, so an engine from GitHub is
always set explicitly — the installer writes the path itself. `byway status`
shows the engine in use on its `engine` line.

---

## Which version to install

The installer asks for a version only when there is no engine on the system
yet. A number can be typed by hand, or one of these picked:

- **the one verified with byway** — the default. byway is verified on it end
  to end, with the tunnel up and real traffic. Currently `26.9.30`;
  `byway engine tested` installs the same.
- **the newest one, pre-releases included** — the first release in the XTLS
  list (`byway engine newest`).
- **the newest stable one** — what GitHub returns as `releases/latest`
  (`byway engine stable`).
- **none** — the path to your own engine is set later.

**"Stable" lags behind for Xray-core.** XTLS marks everything newer than
`26.3.27` as a pre-release, and `releases/latest` skips pre-releases. So
"stable" is currently `26.3.27`, and the version verified with byway is
formally a pre-release. The difference is practical: some keys
(`obfs=salamander` on hysteria2, see the table below) do not build on
`26.3.27`.

The installer picks the source itself: GitHub first, the OpenWrt packages if
that fails. With less than 25 MB free on flash, GitHub is not tried. In the
packages, the version is decided by the firmware branch:

| OpenWrt | Xray-core in packages |
|---|---|
| 22.03 | 1.8.3 |
| 23.05 | 24.12.31 |
| 24.10 | 25.1.30 |
| 25.12 | 26.3.27 |

1.8.3 has no `xhttp` transport and no `host` field for `ws` (see the table
below). An engine from GitHub installs on any branch.

### MIPS without a floating-point unit

XTLS builds MIPS binaries only for processors with a floating-point unit
(FPU). Most inexpensive MIPS routers do not have one, and the GitHub build
does not run there. The sign is a `mips*` architecture with no word `fpu` in
`/proc/cpuinfo`. The installer checks this before downloading and offers only
the engine from the OpenWrt packages. On such a CPU `byway engine` refuses at
once and prints the command `apk update && apk add xray-core` (`opkg update && opkg install xray-core` on opkg). The
engine version there is whatever your branch packages.

---

## `byway engine`: checking and replacing

```sh
byway engine              # is there an update; below it — file, XTLS versions, space and memory
byway engine --check      # only the answer: is there an update
byway engine 26.9.9       # install this version (newer or older than the current one)
byway engine tested       # the one verified with byway
byway engine newest       # the newest one, pre-releases included
byway engine stable       # the newest stable one
byway engine restore      # no engine: version from xray_bin or tested
```

Without an argument and with `--check`, nothing changes. The first line says
whether a newer version than the installed one exists; if the installed one
is not the verified one, the next line names the verified one. Without
`--check` it goes on with the file path, the newest and stable versions at
XTLS, free flash and available memory. The "Check for a core update" button
on the "Maintenance" tab of the web UI calls `byway engine --check`, the
"Install the tested core" button runs `byway engine tested` in the background
(`byway job engine`), with progress on the page. Another version — the
"Another version" field there (or the console); your own engine as a file —
console only.

The version number is digits and dots, without a `v`.

### Before the swap

The replacement does not start and touches nothing if: there is no `unzip` or
`sha256sum`; the CPU is MIPS without an FPU; available memory
(`MemAvailable`) is below 40 MB; another replacement is already running. If
the current engine is not found or does not run, there is no swap — the
engine is simply installed (see [No engine](#no-engine)).

The release archive (about 14 MB) is downloaded to `/tmp`, that is, into
memory, and checked against the SHA2-256 sum from the `.dgst` file of the same
release. If it did not download, there is no `.dgst`, the sum does not match,
or the archive has no `xray` file, the archive is discarded and nothing is
touched. The check guards against a broken download; through the mirror
`.dgst` comes from the same mirror. The tested version is also checked against
a sum built into the signed byway. XTLS publishes no signatures.

The version number and the archive are fetched through byway's local proxy
inbound first (`local_proxy_port`, 1603 by default), then directly. If GitHub
is on your list and the tunnel is down, neither works: the resolver returns a
substitute address for GitHub. The third attempt goes directly to GitHub
addresses obtained over DoH, with the query sent to an address rather than a
name (`https://8.8.8.8`, then `https://1.1.1.1`); there is no need to take the
interception down before a swap.

What happens next depends on free flash.

### Side-by-side swap

If the partition holding `/usr/local/bin` has at least the uncompressed size
of the new engine plus 5 MB free (about 40 MB):

1. The new engine is unpacked to `/usr/local/bin/xray-VERSION`. If it does not
   run on this hardware, it is removed.
2. The config is built for the new engine and checked by it
   (`xray run -test`). If rejected, the new engine is removed and the current
   one keeps running with the current config.
3. `xray_bin` is switched and the service restarts: the tunnel drops for a few
   seconds.
4. byway waits up to 2.5 minutes for the tunnel to come up.
5. If it is up, the previous engine is removed when it is a
   `/usr/local/bin/xray-*` file. An engine from a package stays: removing it
   behind the package manager's back would leave the package with a hole.
   Remove it with `apk del xray-core` or `opkg remove xray-core`.
6. If it is not up, `xray_bin` and the config go back to the previous engine,
   the service restarts, and the new engine is removed.

### Swap through memory

No room for a second engine — the new one cannot go on flash while the old
one is there:

1. The previous engine must be a `/usr/local/bin/xray-*` file. If it comes
   from a package, the replacement does not start (see "Rolling back and
   switching by hand").
2. While the tunnel is still up, the archive of the previous version is
   downloaded — the way back. After the service stops, GitHub may become
   unreachable. If it does not download, the replacement does not start.
3. The service stops: the tunnel drops for about a minute. With "Block" the
   block goes up for that time and holds until interception comes up.
4. Memory is checked: the engine size plus 20 MB (about 55 MB). Too little —
   the service starts with the previous engine.
5. The new engine is unpacked to `/tmp` and checked there: does it run, does
   it accept the config. If not, the service starts with the previous engine.
6. The previous engine is deleted from flash and the new one is written under
   its own name. From this step on, the way back is only through the archive.
7. The service starts, and byway waits up to 2.5 minutes for the tunnel.
8. If the tunnel is not up, or the new engine did not fit on flash, the
   previous one is unpacked from the archive from step 2 and started.

If flash accepted neither the new nor the previous engine, there is no
tunnel. byway prints the path to the previous engine's archive in `/tmp` and
the command to install it by hand. The archive lives until reboot.

### What "the tunnel came up" means

The check is the same as for byway's own update rollback: the Xray process is
running, the interception nft table is in place, and the router's resolver
returns a substitute address from the fakeip pool for the first domain on the
lists. With empty domain lists the third sign is not checked. The fourth is
the connection through the server: a request through the proxy inbound
(`local_proxy_port`, 1603) to `example.com`, any HTTP answer will do. byway
checks it only if it passed before the swap: an unreachable server is not the
new engine's fault, and the engine must not be rolled back for it.

### Without a key

The service is off (`enabled 0`) or there is no key (no `node_url`, no
`node_urls`, no custom config) — there is nothing to check on the new engine.
In a side-by-side swap byway makes sure the new engine runs on this hardware,
switches `xray_bin`, deletes the previous `/usr/local/bin/xray-*` and prints
`the service is not running (disabled or no key) — the core was replaced
without a tunnel check`; the service is not restarted. A swap through memory
without a key, or with the service off, does the same: no config is built for
the new engine (there is nothing to check), the tunnel is not awaited, and the
engine is replaced without a check.

### No engine

This happens after a firmware upgrade (the engine is not on the keep list)
and after the `xray-core` package is removed. `byway engine VERSION` (and
`tested`, `newest`, `stable`) then installs rather than replaces: there is
nothing to roll back to, so there is no archive of the previous version and
no wait for the tunnel. It needs 25 MB free on flash, as the installer does. The
engine is unpacked to `/usr/local/bin/xray-VERSION`, checked by running it,
its path goes into `xray_bin`, and an enabled service is restarted.

`byway engine restore` picks the version itself: the number from the file
name in `xray_bin` if it is `/usr/local/bin/xray-VERSION` (settings survive a
firmware upgrade), otherwise the tested one. With the engine in place it does
nothing.

By hand this is rarely needed. When the service finds neither the engine nor
a runnable `/usr/local/bin/xray-*` next to it at start, it runs `byway engine
restore` in the background, once the default route is up (waiting up to two
minutes), 10 seconds after it, once per boot (the marker
`/tmp/byway-engine-restore`). If a runnable file is there, it names the
command to point at it instead of installing. If the install fails,
`byway watch` retries every 15 minutes. Progress is
in `logread -e byway`.

`byway update` and byway's auto-update do not touch the engine, and
`byway watch` does so only when there is none. The outcome of each swap goes
to the system log (`logread -e byway`).

---

## Rolling back and switching by hand

A rollback is the same replacement with an older number:
`byway engine 26.3.27`. After a successful swap the previous GitHub engine is
deleted, so going back to it means downloading it again.

If the engine you want is already there (`/usr/local/bin/xray-26.3.27`, and it
runs), `byway engine 26.3.27` switches to it without a download: the config is
checked with the new binary, the service restarts, the tunnel is awaited for up
to two and a half minutes, and if it does not come up the previous engine is
put back. Both files stay.

A fallback, with no tunnel check and no rollback:

```sh
uci set byway.main.xray_bin=/usr/local/bin/xray-26.3.27 && uci commit byway
byway gen && /etc/init.d/byway restart
```

`restart` is needed because `uci commit` from the console does not touch the
service. "Save & Apply" in the web UI calls `reload`, which compares the running
engine file with the one set in `xray_bin` and restarts the service if they
differ.

If the engine comes from a package and there is no room for a second one:
remove the package (`apk del xray-core` or `opkg remove xray-core`) and
install an engine with `byway engine VERSION` or `tested` (see [No
engine](#no-engine)). While there is no engine there is no tunnel either: the
interception is taken down; with `on_failure=closed` what went through the VPN
is closed, with `open` it goes to the internet directly.

---

## Engine built with Go 1.27

Xray-core releases 26.9.8 through 26.9.30 are built with Go 1.27. Its HTTP/2
client stopped coalescing dials, so XHTTP opens a TCP connection for every
waiting request, and `xmux.maxConnections` does not limit them. While the
server answers, this means a few extra connections. When the handshake with
the server hangs (the server is down, the address is being blocked), it
becomes hundreds of connections: the router runs out of memory, and a burst
of connections to one address is a reason to block it. Details:
[XTLS/Xray-core#6797](https://github.com/XTLS/Xray-core/issues/6797); the Go
fix: [golang/go#81646](https://github.com/golang/go/issues/81646).

Only xhttp keys are affected. With such an engine `byway doctor` warns
"xmux does not limit connections", and `byway status` prints an `xmux` line.
The sign is `go1.27` in `xray version` and a build without the
`http2legacy` tag.

The `-tags http2legacy` tag brings back the previous HTTP/2 client. It is set
at build time, so the ready-made engine from GitHub cannot be fixed with it:
the same version has to be built by hand. You need a computer with Linux,
macOS or WSL, `git` and Go 1.27 (an older Go works too: `GOTOOLCHAIN`
downloads the right version itself).

```sh
git clone --depth 1 --branch v26.9.30 https://github.com/XTLS/Xray-core.git
cd Xray-core
export GOTOOLCHAIN=go1.27.1 CGO_ENABLED=0 GOOS=linux GOARCH=arm64
go build -o xray -trimpath -buildvcs=false -gcflags="all=-l=4" \
  -ldflags="-X github.com/xtls/xray-core/core.build=$(git rev-parse --short HEAD)+http2legacy -s -w -buildid=" \
  -tags http2legacy ./main
gzip -9 xray
scp -O xray.gz root@192.168.1.1:/tmp/
```

`GOARCH` follows the router's `uname -m`: `aarch64` → `arm64`, `armv7l` →
`arm` with `GOARM=7`, `x86_64` → `amd64`, `mips` → `mips`, `mipsel` →
`mipsle`; for MIPS without an FPU add `GOMIPS=softfloat`. The Go version is
the one `xray version` shows for the release engine. The flags are the same as
in the XTLS release build (`.github/workflows/release.yml`): without
`-tags http2legacy` this command produces a file byte-identical to the release
engine, so the build is easy to verify.

On the router:

```sh
byway engine /tmp/xray.gz
```

byway prints the engine's sha256 (compare it with `sha256sum xray` on the
computer before `gzip`) and swaps the engine the same way as a GitHub
download: side by side or through memory, with a tunnel check and rollback.
The file in `/tmp` is deleted after the swap; when installing onto an empty
spot, or after a refusal before the swap starts, it stays. The custom build is saved as
`/usr/local/bin/xray-local-DATE`.

What to know about a custom build:

- `byway engine VERSION` and `tested` install the XTLS release engine, that is,
  the bug comes back; the same command returns you to the official engine of
  the same version.
- After a firmware upgrade byway restores the tested version from GitHub; the
  custom build has to be installed again.
- Once Xray ships a build with a fixed Go, the custom build is no longer
  needed.

---

## What depends on the engine version

An old engine drops an unknown field silently, and `xray run -test` accepts
such a config: checking with the engine catches nothing here. So byway asks
the engine itself for its version (`xray version`) and in these places writes
the config differently or refuses up front:

| engine version | what byway does |
|---|---|
| below 1.8.24 | `ws`: Host goes into `headers`, not into `wsSettings.host` — 1.8.3 has no such field, and without this branch a CDN would answer 404 |
| below 1.8.24 | `httpupgrade`: a warning that the engine may not know the transport; the config builds |
| below 1.8.24 | `xhttp`: refused |
| below 25.8.29 | VLESS encryption (`encryption=mlkem768x25519plus`): refused |
| below 26.3.27 | `hysteria2`: refused |
| below 26.3.27 | certificate check by fingerprint or name (`pcs=`, `pinSHA256=`, `vcn=`): refused |
| below 26.3.27 | `allowInsecure=1` (or `insecure=1`) without a fingerprint: refused; with `allow_insecure 1` in the settings, written to the config with a warning that the connection can be spoofed |
| 26.3.27 and newer | `allowInsecure=1` without a fingerprint: refused, the engine does not allow turning off certificate checks. With a fingerprint, only the fingerprint is written |
| below 26.7.11 | `obfs=salamander` on hysteria2: refused |
| below 26.7.11 | vless and trojan without TLS or reality to a public address: refused, as by the engine from 26.7.11; `allow_insecure 1` lifts it. Private IPv4 addresses pass |
| 26.9.8 and newer | for the direct outbound, name resolution (`UseIP`) goes into `sockopt`, not `settings`: the engine declared the old field deprecated |

A refusal is a message naming the required version and suggesting
`byway engine tested`; the working config is not changed. The refusals over
`allowInsecure` and over a key without TLS name a command for your own server
with a self-signed certificate instead:

```sh
uci set byway.main.allow_insecure=1 && uci commit byway && /etc/init.d/byway reload
```

The option is console only. It does not override an engine from 26.3.27 on
(from 26.7.11 on for a key without TLS).

If the version cannot be determined (the second word of `xray version` output
has no digits), byway treats the engine as the newest and writes the config in
the current form. An old build with a non-standard `version` output gets
fields it will silently drop.

A few more engine changes byway does not tell apart by version. The engine
itself catches them in `xray run -test`, and byway explains the reason:

- vless and trojan without TLS or reality to a public address are refused by
  the engine since 26.7.11; a private address is the exception. This is fixed
  on the server: the key needs `security=tls` or `reality`. On an engine below
  26.7.11 byway refuses itself (see the table above).
- `h2` (`http`) and `quic` are removed from the engine. byway warns and hands
  the config to the engine, which rejects it and names the replacement —
  `xhttp`.
- `header` and `seed` on `kcp` were removed in Xray-core `26.1.31`; the
  transport itself stays. On such an engine byway does not write these fields
  and warns: a server with mKCP masking will not answer, the replacement is
  finalmask (`mkcp-original`, `mkcp-aes128gcm`) on the server and in the key.
  On an older engine the fields are written as in the link.
- byway always runs wireguard inside the engine process (`noKernelTun`).
  Recent versions bring up a network interface through `/dev/net/tun` by
  default and reject the config without `kmod-tun`. Older versions do not know
  the field and skip it.

Engine deprecation warnings (`deprecated`, `will be removed`) are printed
during the build as `engine: …` lines: this is how the engine announces a
removal a version or two ahead. To check a key against the current engine
without touching the working config: `byway check 'LINK'`.

---

## The config stopped building after an engine update

byway writes every build to a temporary file first and checks it with the
engine. If the engine rejects it, the working `/etc/byway/config.json` is not
changed. `byway gen` then prints `the engine rejected the config, the draft is
left in /tmp/byway-config.new.json:`, the last lines of the engine's answer
and, when the reason is known, what to do about it. After "Save & Apply" in
the web UI or `/etc/init.d/byway reload`, the system log shows the same: the config
did not build, the previous one keeps working. `byway engine` does not keep
such an engine: the new one is removed, the previous one stays.

A running Xray is not restarted by a failed build and keeps working on the
previous config. It is worse when the engine was updated around
`byway engine`, for example with `apk upgrade xray-core`. On the next service
start (router reboot, `restart`) the new engine checks the previous config.
If it accepts it, the service comes up on it. If not, the service does not
start and the interception is taken down. With `on_failure=closed` (the
default) what went through the VPN stays closed; with `open` it
goes to the internet directly.

`byway gen` shows the reason in its last lines — the engine's answer. If it
is the key (no TLS, `allowInsecure`, a removed transport), rolling back the
engine only buys time: the key has to change on the server. If the engine
changed what byway generates, go back to the version that worked:
`byway engine NUMBER`. For an engine from a package, roll back the package or
remove it and install the engine with the installer.

And [report it](https://github.com/tomon-one/byway/issues): this is fixed in
byway rather than worked around by every user separately. Attach the output
of `byway report` (it contains no key) and the last lines of `byway gen`.

---

## Flash

The engine is a single file of about 34–35 MB. On flash with ubifs, which
compresses files, it takes about 18 MB. During installation and replacement
the release archive sits in memory, not on flash.

The installer needs 25 MB free on `/overlay`, otherwise the engine comes from
the OpenWrt packages. An install with no previous engine
(`byway engine` after a firmware upgrade, `restore`) needs the same 25 MB. A
side-by-side swap needs the uncompressed engine size plus 5 MB, about 40 MB:
how much ubifs will compress cannot be known in advance, so byway counts
uncompressed. A swap through
memory uses the space the previous engine frees.

On a router with about 40 MB for your own files, one engine takes almost half
of it, and a second one does not fit next to it. There every replacement goes
through memory, with a minute without the tunnel. If the engine does not
install from the packages either and less than 15 MB is free, the installer
says so: no setting fixes this, it takes a router with more flash or extroot.

With extroot (the root filesystem on a USB drive) `/usr/local/bin` ends up on
the drive, there is room for two engines, and the swap goes side by side.
Putting the engine on a separately mounted USB stick and pointing at it
directly does not work: byway does not accept a path outside the system
directories. A symlink named `xray*` in a system directory does work:
`ln -s /mnt/sda1/xray /usr/local/bin/xray-usb` and
`uci set byway.main.xray_bin=/usr/local/bin/xray-usb`. The stick has to be
mounted by the time the service starts, or there is no engine.

A firmware upgrade (sysupgrade) keeps byway's files but not the engine: 35 MB
are not added to the keep list, because sysupgrade packs it in memory. After
the upgrade the service installs the engine itself (see [No
engine](#no-engine)). With less than 25 MB free on flash that fails, and the
engine is installed with the install line.

`byway-uninstall --purge` removes every `/usr/local/bin/xray-*` file. An
engine from the OpenWrt packages and an engine at any other path stay.

---

## Memory

Xray is written in Go. Without a limit, the Go garbage collector lets the
heap grow to about twice the live data. On a router with 256 MB of memory Xray
reached ~100 MB, and the Linux kernel killed it for lack of memory (OOM). The
service brought it back, but every time all connections dropped — from the
outside it looked like "the tunnel drops now and then".

So the service starts Xray with the `GOMEMLIMIT` variable. It is a soft
limit: near it, Go collects garbage more often and returns memory to the
system. It does not cut live data; if there is more than the limit, Go simply
collects more often (using at most half the CPU time). It will not be worse
than OOM.

The value comes from the `byway.main.xray_memlimit` option:

| value | effect |
|---|---|
| not set | 40 % of `MemTotal`, but no less than 32 MiB |
| `0`, `off` or `no` | no limit is set |
| Go form: `B`, `KiB`, `MiB`, `GiB`, `TiB` | passed as is: `96MiB`, `128MiB` |
| `MB` or `M`, `GB` or `G` | converted to `MiB` and `GiB`: `128MB` → `128MiB` |
| a bare number | megabytes: `96` → `96MiB` |
| anything else | a line in the system log, `memory limit "…" not understood -- using auto`; the limit is as when unset |

On a router with 256 MB (`MemTotal` about 234 MB) the automatic value is
`93MiB`; Xray normally uses 30–50 MB. Without the conversion Go would refuse
`128MB`, and the engine would crash on every start.

```sh
uci set byway.main.xray_memlimit=128MiB && uci commit byway
/etc/init.d/byway reload
```

The limit is set when the process starts. `reload` compares it with the
running engine's environment and restarts the engine if they differ. `byway status`
reads it from the running process's environment, not from the settings: the
`memory … MB, limit …` line shows what is actually in effect.

Replacing the engine needs memory of its own, beyond the limit: 40 MB
available before it starts, and in a swap through memory, the engine size
plus 20 MB after the service stops. `byway engine` without an argument shows
how much is available now.
