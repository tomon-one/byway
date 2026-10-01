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
`..`, the file must be a regular executable, and the first line of its
`version` output must start with the word `Xray`. Otherwise byway prints
`the core path was rejected: …` and falls back to the default engine. An
engine on a USB stick such as `/mnt/sda1/xray` is therefore not accepted; for
USB, see "Flash".

If `xray_bin` is empty, the `byway` command looks for `xray` in `PATH`, then
`/usr/bin/xray`; the service goes straight to `/usr/bin/xray`.
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
once and suggests `apk upgrade xray-core` or `opkg upgrade xray-core`. The
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
```

Without an argument and with `--check`, nothing changes. The first line says
whether a newer version than the installed one exists; if the installed one
is not the verified one, the next line names the verified one. Without
`--check` it goes on with the file path, the newest and stable versions at
XTLS, free flash and available memory. The "Check for a core update" button
on the "Maintenance" tab of the web UI calls `byway engine --check`. The
engine is replaced only from the console: the swap takes longer than the web
UI is willing to wait.

The version number is digits and dots, without a `v`.

### Before the swap

The replacement does not start and touches nothing if: there is no `unzip` or
`sha256sum`; the CPU is MIPS without an FPU; the current engine is not found
or does not run (then install with the byway installer — there is nothing to
roll back to); available memory (`MemAvailable`) is below 40 MB; another
replacement is already running.

The release archive (about 14 MB) is downloaded to `/tmp`, that is, into
memory, and checked against the SHA2-256 sum from the `.dgst` file of the same
release. If it did not download, there is no `.dgst`, the sum does not match,
or the archive has no `xray` file, the archive is discarded and nothing is
touched. The check guards against a broken download and tampering on the way,
but it is not a signature: `.dgst` sits next to the archive on the same
GitHub.

The version number and the archive are fetched through byway's local proxy
inbound first (`local_proxy_port`, 1603 by default), then directly. If GitHub
is on your list and the tunnel is down, neither works: the resolver returns a
substitute address for GitHub. byway then suggests taking the interception
down (`byway plumb off`) and trying again. The replacement brings the
interception back by itself when it restarts the service; if you give up on
it, bring it back with `byway plumb on`.

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
3. The service stops: the tunnel drops for about a minute.
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
lists. With empty domain lists the third sign is not checked. **This check
does not test a connection through the server.** An engine that started and
accepted the config but cannot talk to the server will not be caught by the
rollback. After a swap, open a site from your list or run `byway health`.

### Without a key

Without a key (or your own config) the config does not build for any engine.
The replacement still starts, but stops at the config build with
`the new engine rejected the config`; the reason is one line above:
`no key is set`. In a swap through memory the service has already been
stopped by then and is started again. Set the key before replacing the engine.

`byway update`, the five-minute check (`byway watch`) and byway's auto-update do not touch the
engine. The outcome of each swap goes to the system log (`logread -e byway`).

---

## Rolling back and switching by hand

A rollback is the same replacement with an older number:
`byway engine 26.3.27`. After a successful swap the previous GitHub engine is
deleted, so going back to it means downloading it again.

If two engines already sit side by side, you can switch without a download:

```sh
uci set byway.main.xray_bin=/usr/local/bin/xray-26.3.27 && uci commit byway
byway gen && /etc/init.d/byway restart
```

`restart` is needed because `uci commit` from the console does not touch the
service. "Save & Apply" in the web UI calls `reload`, which compares the running
engine file with the one set in `xray_bin` and restarts the service if they
differ.

If the engine comes from a package and there is no room for a second one:
remove the package (`apk del xray-core` or `opkg remove xray-core`) and run
the byway installer again (see "Installing" in the README). With no engine on
the system, the installer asks for a version. While there is no engine there
is no tunnel either: the interception is taken down and the router goes to
the internet directly. `byway engine` does not help here — it needs a working
current engine.

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
| below 26.3.27 | `allowInsecure=1` (or `insecure=1`): written to the config, with a warning that the connection can be spoofed |
| 26.3.27 and newer | `allowInsecure=1` without a fingerprint: refused, the engine does not allow turning off certificate checks. With a fingerprint, only the fingerprint is written |
| below 26.7.11 | `obfs=salamander` on hysteria2: refused |
| 26.9.8 and newer | for the direct outbound, name resolution (`UseIP`) goes into `sockopt`, not `settings`: the engine declared the old field deprecated |

A refusal is a message naming the required version and suggesting
`byway engine tested`; the working config is not changed.

If the version cannot be determined (the second word of `xray version` output
has no digits), byway treats the engine as the newest and writes the config in
the current form. An old build with a non-standard `version` output gets
fields it will silently drop.

A few more engine changes byway does not tell apart by version. The engine
itself catches them in `xray run -test`, and byway explains the reason:

- vless and trojan without TLS or reality to a public address are refused by
  the engine since 26.7.11; a private address is the exception. This is fixed
  on the server: the key needs `security=tls` or `reality`.
- `h2` (`http`) and `quic` are removed from the engine. byway warns and hands
  the config to the engine, which rejects it and names the replacement —
  `xhttp`.
- `header` and `seed` on `kcp` were removed in recent versions; the transport
  itself stays. byway writes these fields only if the key has them, and warns.
  On `26.3.27` they still work; on newer engines the config is rejected.
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
the web UI or `uci commit byway`, the system log shows the same: the config
did not build, the previous one keeps working. `byway engine` does not keep
such an engine: the new one is removed, the previous one stays.

A running Xray is not restarted by a failed build and keeps working on the
previous config. It is worse when the engine was updated around
`byway engine`, for example with `apk upgrade xray-core`. On the next service
start (router reboot, `restart`) the new engine checks the previous config.
If it accepts it, the service comes up on it. If not, the service does not
start, the interception is taken down, and the router goes to the internet
directly. With `on_failure=closed`, the domains on the list stay blocked.

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
the OpenWrt packages. A side-by-side swap needs the uncompressed engine size
plus 5 MB, about 40 MB: how much ubifs will compress cannot be known in
advance, so byway counts uncompressed. A swap through memory uses the space
the previous engine frees.

On a router with about 40 MB for your own files, one engine takes almost half
of it, and a second one does not fit next to it. There every replacement goes
through memory, with a minute without the tunnel. If the engine does not
install from the packages either and less than 15 MB is free, the installer
says so: no setting fixes this, it takes a router with more flash or extroot.

With extroot (the root filesystem on a USB drive) `/usr/local/bin` ends up on
the drive, there is room for two engines, and the swap goes side by side.
Putting the engine on a separately mounted USB stick and pointing at it does
not work: byway does not accept a path outside the system directories.

A firmware upgrade (sysupgrade) keeps byway's files but not the engine: 35 MB
are not added to the keep list, because sysupgrade packs it in memory. After
the upgrade the service reports that the engine is not found and says how to
install it.

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
| anything else | passed as is, in Go form: `96MiB`, `128MiB` |

On a router with 256 MB (`MemTotal` about 234 MB) the automatic value is
`93MiB`; Xray normally uses 30–50 MB. byway does not validate the value:
whatever is written goes into `GOMEMLIMIT`.

```sh
uci set byway.main.xray_memlimit=128MiB && uci commit byway
/etc/init.d/byway restart
```

The limit is set when the process starts, hence the `restart`. `byway status`
reads it from the running process's environment, not from the settings: the
`memory … MB, limit …` line shows what is actually in effect.

Replacing the engine needs memory of its own, beyond the limit: 40 MB
available before it starts, and in a swap through memory, the engine size
plus 20 MB after the service stops. `byway engine` without an argument shows
how much is available now.
