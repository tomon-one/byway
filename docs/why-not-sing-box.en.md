# Why byway runs on Xray-core only

The short answer: **sing-box is a good engine, but it gives byway nothing and
costs a lot.** Below are the numbers behind that decision, so the question does
not have to be asked again.

Decided on 7 September 2026. Not for good: the end of this page says what would
have to change for the analysis to be worth redoing.

---

## What would have been easy

byway's plumbing genuinely does not depend on the engine. Traffic interception,
address substitution and accepting the router's own traffic are defined by three
numbers: the interception port, the address of the built-in resolver and the
pool of placeholder addresses. Both engines provide all three.

In fact three things are neater in sing-box than in Xray-core: it has dedicated
inbound types where Xray uses one universal inbound with flags, and a ready-made
auto-pick between several servers instead of two mechanisms wired together.

So "impossible" is not the issue. The trade is.

---

## What sing-box cannot do

### The xhttp and kcp transports

sing-box's list of transports is closed: HTTP, WebSocket, QUIC, gRPC,
HTTPUpgrade. Its documentation names what is absent — mKCP is listed explicitly,
and xhttp never existed there at all.

byway parses six transports, and sing-box cannot carry two of them. Some keys
that work today would stop working on the second engine, and people would have
to know which key goes with which engine.

### Usage accounting

byway can show which sites from your list you actually use — that helps you
decide what to drop from it. The data comes from Xray-core's access log.

sing-box has no such log. Destination addresses only appear in the general log
at a verbose level, mixed in with everything else and in a different shape. So
the feature would either disappear on the second engine or require a separate
parser for a second format.

### Two incompatible config dialects

Over its recent releases sing-box removed a fair amount from its configuration:
legacy DNS server forms, some special outbound kinds, several inbound fields,
GeoIP and Geosite database support. A config written for the version shipped in
your firmware may be rejected by a newer one, and the other way round.

byway would have to detect the engine version and branch on it — on top of
branching on the engine itself.

### And a third dimension: how the package was built

OpenWrt firmware carries two package variants, the regular one and `-tiny`. The
`-tiny` build has no gRPC support. The regular one's feature set depends on the
options chosen when that firmware was built, and you cannot tell from the
version number — only by asking the binary itself.

byway would have to work out not just "which engine" and "which version" but
"how was it built". Three dimensions where today there are none.

---

## What sing-box offers in return

Protocols Xray-core does not have: TUIC, AnyTLS, ShadowTLS and others. Hysteria2
and WireGuard were on this list until autumn 2026: Xray-core added Hysteria2 in
26.1.13, it has had WireGuard for a long time, and byway parses both links
since release 0.2.4 (Hysteria2 — on engine 26.3.27 or newer: before it the
protocol settings changed from release to release). Of what remains, mostly TUIC gets asked for.

Like Hysteria2, it runs over QUIC, that is, over UDP. In Russia UDP is the first thing to be
throttled — long and widely documented, and matching what we see on a working
router. So the gain is smaller than the length of the list suggests: a protocol
that gets throttled first is a poor replacement for one that works.

---

## The argument that did not hold up

There was one more argument, and it looked like the strongest. Xray-core is
published for MIPS **only in a hardware floating point build**, and the common
cheap routers (24Kc, 1004Kc cores) have no FPU — such a file simply does not run
there. sing-box does publish softfloat builds.

Checking it cancelled the argument. What had to be counted was not the size of
the engine but the flash of those routers: devices with 8 MB of flash often have
under a megabyte for changes, and 16 MB ones three to eight. An unpacked engine
takes about thirty megabytes, **either of them**. byway will not install on such
hardware with any engine; the only route there is moving the system onto a USB
drive.

A softfloat build solves a problem that cannot be solved on that hardware
anyway: it produces a file with nowhere to go.

---

## Sizes, for completeness

Packages from OpenWrt 25.12.5 firmware, `mipsel_24kc` architecture:

| package | size |
|---|---|
| `sing-box` | 15.3 MB |
| `sing-box-tiny` | 10.8 MB |
| `xray-core` | 10.5 MB |

Two engines side by side will not fit on a router with modest flash, so it would
have been a choice of one at install time, not a switch.

---

## What would have to change for us to revisit

None of these on its own overturns the decision — the objections add up, and
removing one leaves the rest. But each removes an objection, and if two of them
come together the analysis is worth redoing:

1. **sing-box learns xhttp** — then it could be exercised on the same key as
   Xray-core rather than blind.
2. **Real demand appears for TUIC** from people for whom it genuinely works
   better — on their line, not in theory. (byway parses Hysteria2 since
   0.2.4.)
3. **sing-box configs stop drifting between versions** — then the branching
   becomes one-dimensional.

Until then byway stays on one engine. This is not about sing-box being worse; it
is about a second engine helping nobody here while being able to confuse.

If your experience differs, [tell us](https://github.com/tomon-one/byway/issues).
