# Keys and connection

For anyone connecting their own server: whether byway can parse the link, what
ends up in the Xray-core config, and why a key may be rejected.

## How a key becomes a config

A key is the whole link from the server: `vless://…`, `hy2://…` and so on.
byway parses it itself, builds an Xray-core outbound from it and checks the
result with the engine's own `xray run -test`. Either side can refuse. byway
refuses when the link cannot be parsed, when it is unsafe, or when the engine
is too old for this kind of key, and names the reason right away. The engine
refuses when the built config does not suit it; byway prints the last line of
its error and adds an explanation for the common cases.

A rejected config never replaces the working one, so the tunnel keeps running
on the previous config. In the panel, "Save & Apply" on the Overview tab then
shows "Key not accepted — the previous setting is running" along with the build
output.

The name after the hash (`#Germany`) becomes the connection name and does not
go into the config. If the link has no port, 443 is used; vmess always takes
the port from its JSON.

The server address is IPv4 or a name. An IPv6 literal (`[2001:db8::1]` in the
link, an address with colons in the vmess `add` field) is refused: "IPv6
address in the key is not supported: … — an IPv4 address or a name is needed".

## Link types

| type | scheme | requires |
|---|---|---|
| VLESS | `vless://` | — |
| Trojan | `trojan://` | — |
| VMess | `vmess://` | — |
| Shadowsocks | `ss://` | — |
| SOCKS5 | `socks://` | — |
| Hysteria2 | `hysteria2://`, `hy2://` | Xray-core 26.3.27 or newer |
| WireGuard | `wireguard://`, `wg://` | — |

BusyBox on OpenWrt usually has no base64; byway decodes base64 itself, no
extra package is needed.

### VLESS and Trojan

```
vless://00000000-0000-0000-0000-000000000000@example.com:443?type=xhttp&security=tls&sni=example.com&path=/x#Name
vless://00000000-0000-0000-0000-000000000000@example.com:443?type=tcp&security=reality&sni=example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=01ab&flow=xtls-rprx-vision#Name
trojan://PASSWORD@example.com:443?type=ws&security=tls&sni=example.com&path=/t#Name
```

Before the `@`: the user ID for vless, the password for trojan (fully
percent-decoded). Parameters are listed under "Link parameters". `flow` and
`encryption` exist only for vless. A `flow` on a trojan link is dropped with the
warning "flow=… is not supported by Xray-core for trojan — dropped", and mux
stays on.

Without `security=` the security is `none` for vless and `tls` for trojan:
trojan is meant to run over TLS, and clients often leave the parameter out.
Engines from 26.7.11 on reject vless without TLS to a public address (see
"Security").

### VMess

```
vmess://eyJhZGQiOiJleGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLC4uLn0=
```

After `vmess://` comes base64-encoded JSON. byway reads `add` and `port` (server
address and port), `id`, `aid` (alterId, default 0; anything but a number is
refused with "vmess aid is not a number"), `net` (transport, default tcp),
`type` (`http` for tcp, header type for kcp; `none` means no header), `host`
(Host header, defaults to the address), `path` (default `/`), `tls` (the value
`tls` turns TLS on), `sni` (defaults to `host`, then to the address), `scy`
(VMess encryption: `auto`, `aes-128-gcm`, `chacha20-poly1305`, `none`, `zero`;
anything else is refused), `alpn` and `fp`. With `net=grpc` the service name is
taken from `path` — that is where clients put it; without `path` it is empty.

Other fields are not read, and there is no warning about them.

### Shadowsocks

```
ss://YWVzLTI1Ni1nY206UEFTU1dPUkQ@example.com:8388#Name
ss://aes-256-gcm:PASSWORD@example.com:8388#Name
```

The first form is base64 of `method:password`; base64url without `=` padding
is accepted. The second is the same in plain text, fully percent-decoded. The
old form, with the whole link wrapped in base64
(`ss://BASE64(method:password@address:port)#Name`), is parsed as well. The
address is split off at the last `@`, so an `@`
in the password is fine. The transport is always tcp, the security `none`.

Parameters after `?` other than `plugin` are not carried over, and there is no
warning about them.

Xray-core does not run plugins (`obfs-local`, `v2ray-plugin`). A link with
`plugin=` parses, the plugin is dropped, and byway warns: a server that expects
the plugin will not answer.

### SOCKS5

```
socks://user:pass@example.com:1080#Name
```

User name and password are plain text separated by a colon, and may be absent.
Some clients encode `user:pass` as base64 (`socks://dXNlcjpwYXNz@…`). byway
decodes this form.

### Hysteria2

```
hy2://PASSWORD@example.com:8443/?sni=example.com#Name
hy2://PASSWORD@example.com:8443/?sni=example.com&obfs=salamander&obfs-password=OBFSPASS#Name
hy2://PASSWORD@example.com:8443/?sni=example.com&insecure=1&pinSHA256=e3b0c442…b855#Name
```

Before the `@`: the password, fully percent-decoded. `sni` defaults to the
server address, `alpn` to `h3`. `obfs=salamander` turns on obfuscation and
requires `obfs-password`; any other `obfs` is rejected, since Xray-core has no
other. For `insecure` and `pinSHA256` see "Security".

Hysteria2 always runs over TLS, and `security` in the link is ignored. `fp` is
not written: QUIC has no TLS client fingerprint.

There is no port hopping. Neither `mport=` nor a range in the port
(`host:443,20000-30000`, `host:20000-30000`) is accepted by the hysteria
settings in Xray-core. byway warns and connects to the first port, so the
server has to listen on it as well.

### WireGuard

```
wireguard://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D@example.com:51820?publickey=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB%3D&address=10.7.0.2%2F32%2Cfd00%3A%3A2%2F128&mtu=1280&reserved=1%2C2%2C3#Name
wg://example.com:51820?pk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D&peer_pk=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB%3D&local_address=10.7.0.2%2F32&keepalive=25#Name
```

The first form (as v2rayN writes it) has the private key before the `@`. The
second (as Hiddify writes it) has everything in parameters. Both are parsed.

| field | names in the link | required | format |
|---|---|---|---|
| private key | before `@`, `privatekey`, `secretkey`, `pk` | yes | 44-character base64 or 64 hex |
| server key | `publickey`, `peer_pk` | yes | same |
| pre-shared key | `presharedkey`, `pre_shared_key`, `psk` | no | same |
| tunnel address | `address`, `local_address` | yes | IPv4/IPv6, comma-separated, prefix optional |
| MTU | `mtu` | no | 3–4 digits |
| reserved | `reserved` | no | three comma-separated numbers |
| keepalive | `keepalive` | no | up to 5 digits |

A link without `address` is rejected: the engine would substitute its own
address, and the server would not recognise the client. WireGuard runs inside
the Xray-core process (`noKernelTun`), so neither the tun module nor a separate
interface is needed. It has no transport and no TLS.

### What is not supported

`tuic://` and first-version `hysteria://` do not exist in Xray-core; byway
answers "is not in Xray-core; the closest thing there is hysteria2". HTTP(S)
proxies have no link format, and byway does not parse MASQUE or XDRIVE links:
all of these connect through "Custom config". Hysteria2 port hopping and
Shadowsocks plugins are not carried over (see above). Any other scheme gets
"unknown link type".

## Link parameters

Shared by vless, trojan and socks. The hysteria2 and wireguard additions are
described above.

| parameter | what it does | if absent |
|---|---|---|
| `type` | transport | `tcp` |
| `security` | `tls`, `reality`, `none` | `none` |
| `sni` | server name for TLS and Reality | server address |
| `fp` | TLS client fingerprint | `chrome` |
| `alpn` | comma-separated list | — |
| `path` | path for ws, httpupgrade, xhttp, tcp+http | `/` |
| `host` | Host header | server address |
| `headerType` | `http` for tcp; header type for kcp | — |
| `seed` | kcp | — |
| `serviceName` | grpc | empty |
| `mode` | grpc: `multi` turns on multiMode; xhttp: mode | — |
| `authority` | grpc | — |
| `extra` | xhttp, a JSON object | — |
| `pbk`, `sid`, `spx`, `pqv` | Reality | — |
| `flow` | vless | — |
| `encryption` | vless | `none` |
| `allowInsecure`, `insecure` | turn off certificate checks | — |
| `pcs`, `pinSHA256` | server certificate fingerprint | — |
| `vcn` | name to verify the certificate against | — |
| `quicSecurity`, `key` | the quic transport, removed from the engine | — |

A parameter not in this table does not reach the config, and byway warns:
`byway does not carry link parameter "…" into the config`. This is not a
refusal, but it is worth checking whether the server needs it.

Parameter values are fully percent-decoded: `path=%2F%3Fed%3D2048` (the way
v2rayN writes early data) goes into the config as `/?ed=2048`. A quote, a
backslash or a control character after decoding means a refusal (see
"Suspicious links"). The exception is `extra`: only `%2F %3A %2C %20 %3D %26`
and the braces and quotes `%7B %7D %22 %5B %5D` are decoded in it.

## Transports

| `type` | what goes into the config | engine below 1.8.24 |
|---|---|---|
| `tcp`, `raw` | `network: tcp`; with `headerType=http`, HTTP camouflage with `path` and `host` | — |
| `ws` | path and Host | Host written in the old form, in headers |
| `grpc` | `serviceName`, `multiMode` with `mode=multi`, `authority` | — |
| `httpupgrade` | path and Host | warning |
| `xhttp` | path, Host, `mode`, `extra` | refused |
| `kcp` | `header` and `seed`, only if present in the link | — |
| `hysteria` | version 2, password, salamander | — |

Any other `type` except h2, http and quic (see below) is rejected: "transport
… is not supported".

**`extra` for xhttp.** This is the only parameter that goes into the config as
a JSON object rather than a string. Braces and quotes are legitimate in it, so
the quote check does not apply. Instead byway requires exactly one object: the
value starts with `{`, ends with the matching `}`, and nothing follows. Without
this, `extra` could close `xhttpSettings` early and rewrite neighbouring
fields, up to the server address and the security, and `run -test` would
accept the result. The syntax inside the object is checked by the engine.

**kcp.** Recent Xray-core releases removed the `header` and `seed` fields from
kcp (the replacement is `finalmask`). byway writes them only if they are in the
link, and warns. If the engine rejects them, the config is not replaced.
Without these fields kcp builds on a recent engine too. byway also warns that
kcp runs over UDP.

**h2/http and quic** have been removed from Xray-core entirely. byway warns,
names the replacement (xhttp in stream-one mode) and builds the config as is,
and a recent engine rejects it. Such a key has to be changed on the server.

## Security

### tls

`sni` → `serverName`, `fp` → `fingerprint` (except hysteria2), `alpn` →
`alpn`. `pcs` or `pinSHA256` → `pinnedPeerCertSha256` (hex, `:` and `,`
allowed), `vcn` → `verifyPeerCertByName` (a host name).

Since 26.3.27 Xray-core does not allow turning off server certificate checks.
On an engine below 26.3.27 byway enforces the same rule itself, but lets you
lift it with the `allow_insecure` option (unset by default). `allowInsecure=1`
or `true` (the same for `insecure`) is handled as follows:

| engine | `pcs`/`pinSHA256` or `vcn` in the key | what byway does |
|---|---|---|
| below 26.3.27 | no, `allow_insecure` unset | refuses and says how to allow it |
| below 26.3.27 | no, `allow_insecure 1` | writes `allowInsecure` and warns that the connection can be spoofed |
| below 26.3.27 | yes | refuses: the engine understands the fingerprint and name only from 26.3.27 |
| 26.3.27 or newer | yes | drops the flag; the certificate is checked by fingerprint or name |
| 26.3.27 or newer | no | refuses: the key needs a fingerprint, or the server a real certificate |

`pcs`, `pinSHA256` and `vcn` themselves need engine 26.3.27 or newer.

`allow_insecure` is meant for your own server with a self-signed certificate.
The option is not in the panel, only in the console; `byway export` includes
it:

```sh
uci set byway.main.allow_insecure=1 && uci commit byway && /etc/init.d/byway reload
```

On engine 26.3.27 or newer the engine decides, and the option does not
override it.

### reality

`sni` → `serverName`, `fp` → `fingerprint` (default `chrome`), `pbk` →
`publicKey`, `sid` → `shortId`. `spx` → `spiderX` and `pqv` → `mldsa65Verify`
are written only if present in the link.

### none

Since 26.7.11 Xray-core rejects vless and trojan without TLS or Reality when
the server is on a public address. On an engine below 26.7.11 byway refuses
the same: "a vless or trojan key without TLS to a public address: the key and
the traffic are visible to anyone on the path". Private addresses (`10/8`,
`172.16/12`, `192.168/16`, `127/8`, `169.254/16`) pass; byway treats a server
name as a public address. `allow_insecure 1` lifts byway's refusal (see
"tls"), not the recent engine's.

The key is what the server issued, and it can only be fixed there. After the
engine refuses, byway explains that a key with `security=tls` or `reality` is
needed.

### VLESS encryption

`encryption=mlkem768x25519plus.…` is post-quantum VLESS encryption and needs
engine 25.8.29 or newer. byway checks only the shape: the
`mlkem768x25519plus.` prefix and allowed characters. The engine parses the
parts. Any other value except `none` is refused, and so is `encryption` on
anything other than vless.

### flow=xtls-rprx-vision

vless only. Vision works over plain TCP (`type=tcp` or `raw`) with TLS or
Reality. With other transports the engine accepts the config and the
connection breaks in use, so byway warns. byway does not check the security
here. Any `flow` turns multiplexing off.

## Engine versions

byway asks the engine itself for its version (`xray version`). If the version
cannot be parsed, the engine is treated as recent.

| what | threshold | on an engine below it |
|---|---|---|
| xhttp transport | 1.8.24 | refused |
| ws transport | 1.8.24 | Host in the old form |
| httpupgrade transport | 1.8.24 | warning |
| VLESS encryption | 25.8.29 | refused |
| Hysteria2 | 26.3.27 | refused |
| `pcs`, `pinSHA256`, `vcn` | 26.3.27 | refused |
| `allowInsecure`, `insecure` | 26.3.27 | refused without `allow_insecure 1`, written with it; from this version refused without `pcs`/`vcn` |
| `obfs=salamander` | 26.7.11 | refused |
| vless, trojan without TLS to a public address | 26.7.11 | byway refuses without `allow_insecure 1`; from this version the engine refuses |
| kcp `header`, `seed` | recent versions | written as in the link, the engine decides |
| h2/http, quic | removed | the engine refuses |

When it refuses, byway names the installed version. For VLESS encryption,
hysteria2, salamander and pcs/vcn it also prints the update command,
`byway engine tested`; for xhttp it suggests updating Xray-core or using a ws
key.

## Suspicious links

Values from the link go into the config inside JSON strings without escaping.
Keys often come from subscriptions and third-party channels that cannot be
trusted. A quote inside a value would close the string and append foreign
fields to the config: turn off certificate checks, for example, or swap the
server address.

So after parsing, byway checks every value that goes into the config and
refuses if it contains a quote `"`, a backslash `\` or a control character
(newline, tab). Control characters are caught separately: `%0A` becomes a real
newline, and some format checks look only at the first line. The refusal names
the field. An honest link never contains these characters.

Fields that go into the config without quotes, or have a fixed format, are
matched against a pattern: the port (1–65535), the vmess `aid`, wireguard keys
and numbers, the certificate fingerprint, `vcn`. `extra` is checked as a single
JSON object.

## Multiplexing

Mux folds many client connections into a few connections to the server. The
number of streams per connection is the "Mux" setting on the Network tab
(`mux_concurrency`). It ships as 8; `0` turns it off. Values from 0 to 999 are
accepted; an empty value means 0, an invalid one also means 0, with a warning.

Mux is used for tcp/raw, ws, httpupgrade and kcp. It is not used for xhttp (it
has its own xmux), grpc (its own multiMode), hysteria2 (its own QUIC streams),
keys with a `flow` (Vision splits the stream itself) or wireguard (it has no
stream). byway reports each of these cases during the build. A second layer on
top of a transport's own multiplexing only gets in the way: xhttp with mux
pushed all traffic into one connection and got slower. Mux is not added to a
custom config.

## Several keys

The method is the "Connection method" field on the Overview tab (`conn_mode`).

| in the panel | `conn_mode` | what is in use |
|---|---|---|
| One key | `key` | the "Key" field (`node_url`) |
| Loaded from a subscription | `sub` | the key picked from the subscription (`node_url`) |
| Several, manual | `selector` | the key marked under "Active key" (`node_url`) |
| Several, automatic | `urltest` | every key in the "Keys" list (`node_urls`) |
| Custom config | `outbound` | the JSON object in "Outbound config" (`outbound_json`) |

**Subscription.** The address is an `https://` URL where the service
publishes its list of keys, usually as base64. "Load the list of keys"
downloads it, and the panel decodes it and shows the keys. Types byway cannot
handle (`ssr`, `hysteria`, `tuic`, `warp`) are listed but cannot be picked;
lines with other schemes are not listed at all. All usable keys go into the
"Keys" list, so switching to "Several, …" later needs no second download. The
download goes through byway's local proxy inbound and, if that fails,
directly; an address pointing at the router itself or into a private network
is refused. A subscription over `http://` is not accepted: "a subscription
over http:// is not accepted: anyone on the path can replace the keys in it —
https:// is needed". byway does not refresh the subscription on its own: the
list is taken when the button is pressed. In the console, `byway sub ADDRESS`
prints the subscription response as is, without decoding.

**Several, manual.** Only the active key is in use; switching is done in the
panel. The other keys in the list do not go into the config unless a route
uses them.

**Several, automatic.** Each key becomes its own outbound (`proxy-0`,
`proxy-1`, …). The engine's `observatory` checks each one with a request to
`https://www.google.com/generate_204`, and a balancer with the `leastPing`
strategy sends traffic through the key with the lowest latency. The interval
is "Key check interval" on the Advanced tab (`probe_interval`), `3m` by
default; the format is a number followed by `s`, `m` or `h`. A key that byway
refuses while parsing it or while building the transport and security
(allowInsecure without a fingerprint, hysteria2 or pcs on an old engine, xhttp
on a 1.x engine) is skipped with the warning "key skipped: reason", and the
rest go into the config. If no key is usable, the build fails and the previous
config keeps running.

**Custom config.** For what byway cannot parse from a link: HTTP(S) proxies,
MASQUE, XDRIVE, non-standard settings. The field takes a whole Xray-core
outbound object: `protocol`, `settings`, and `streamSettings` if needed. byway
adds only `"tag": "proxy"` as the last field: with a repeated key the engine
takes the last one, so your own `tag` in the object breaks nothing. The name
shown in the "Connection" line is the "Connection name" field.

Nothing else is added to a custom config:

- The socket mark. byway adds `streamSettings.sockopt.mark` to all of its own
  outbounds when "VPN for programs on the router" is on (Network tab, on by
  default). The mark keeps the engine's own connections out of interception.
  In a custom config, write it yourself: `"sockopt": { "mark": 4194304 }`
  inside `streamSettings`. 4194304 is `0x400000`, the default `self_mark`.
- Multiplexing. If you want mux, put it in the object.
- Excluding the server address. In "everything through the VPN" mode the
  server address from a link bypasses the tunnel, otherwise the tunnel would
  loop into itself. In a custom config the address sits inside the JSON, byway
  does not know it and warns that the server address must not end up in the
  lists.

## Per-key routes

A route is a separate list of domains and subnets that goes through its own key
instead of the main one. Routes tab, "Per-key routes" block, "Add a route"
button.

The route name uses Latin letters, digits, `_` and `-`; it is also the file
name `/etc/byway/routes/NAME.lst`. The key is picked by the name after the
hash, so it has to be in the "Keys" list (`node_urls`) and have a name. The
"Keys" list is visible in the "Several, …" modes, and loading a subscription
fills it. The file holds domains and IPv4 subnets mixed, one per line, in the
same forms as the main lists (`full:`, `keyword:`, `regexp:`).

Route rules come before the general ones: a domain that is in both goes
through the route's key. The route's key follows the same parsing, transport
and multiplexing rules as the main one. A route is skipped with a warning if
its list is empty, if none of the added keys has that name, or if its key is
refused while parsing or building (`route "…": the key does not parse,
skipping`); the rest of the build carries on.

A route is switched off without deleting it with the "Enabled" flag in the
table or `uci set byway.NAME.enabled=0`. A disabled route is skipped without a
warning.

In the console a route is a UCI section of type `route`:

```sh
uci set byway.video=route
uci set byway.video.label='Germany'
uci commit byway
mkdir -p /etc/byway/routes
echo 'example.com' > /etc/byway/routes/video.lst
byway gen && /etc/init.d/byway restart
```

## Checking a key without touching the tunnel

Both commands work on a separate config in a temporary file and leave the
running tunnel alone. Without an argument they take the key from the settings
(`node_url`). Parser warnings are printed above the result line.

**`byway check LINK`** parses the link and runs `xray run -test` on the built
outbound. It makes no network connections.

```
  xhttp        tls        example.com:443  ACCEPTED
```

Transport, security, address and the verdict. If the engine refuses:
`REJECTED`, the last line of its error and, where known, an explanation. The
exit code is 0 or 1. In "Custom config" mode, `byway check` without an
argument checks the object from "Outbound config". The "Enter a key" item in
`byway menu` ("VPN connection") runs this check before saving the key and
switches the connection method to "One key".

**`byway probe LINK`** makes one real connection through the server. byway
starts a separate engine with this key and a SOCKS inbound on
`127.0.0.1:15080`, waits 3 seconds and fetches `https://api.ipify.org` through
it (up to 15 seconds).

```
  xhttp/tls    example.com:443        WORKS     exit 203.0.113.7      0.843210 s
```

On the right: the address the server uses to reach the internet, and the
request time. Any HTTP response, 302 or 403 included, means the server carried
the connection. No response gives `DOES NOT WORK (code …)` and up to two error
lines from the engine log. If the engine rejected the config, the output says
so and gives the reason. The port and the test URL can be changed with the
`PROBE_PORT` and `PROBE_URL` variables. Without an argument `byway probe`
takes the object from "Outbound config" in "Custom config" mode, otherwise
`node_url`.

**`byway probe --all`** checks every key in the "Keys" list (`node_urls`) in
turn: a `key N NAME` line before each, and `N of M work` at the end. This is
how to find a dead key in "Several, automatic" mode, where `node_url` is not in
use.
