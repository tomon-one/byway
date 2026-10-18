# Glossary

*[Русская версия](glossary.md)*

Words from the byway panel and documents, briefly and to the point. Starting
from scratch — [byway in plain words](beginner.en.md).

## Connecting

### VPN

An encrypted channel from the router to a server abroad. A site sees the
server's address, and the ISP sees only that you are connected to that server.
byway does not sell or hand out VPNs: the server and its key come from your
VPN service.

### VPN server

The VPN service's computer that the traffic goes through. Its address is
written in the key. If the server is down or blocked, the "Link to the VPN" dot
in the panel is red.

### Key

A link from the VPN service holding everything needed to connect: the server
address, port, password or ID, and how the traffic is carried. It looks like
`vless://…`, `vmess://…`, `trojan://…`, `ss://…`, `socks://…`,
`hysteria2://…` or `wireguard://…`. Paste it whole, including the text after
`#` — that is the connection name. In detail — [keys and
connecting](keys.en.md).

### Subscription

An `https://…` link from which the VPN service hands out a list of keys and
keeps it up to date. It is not a key: it does not go into the "Key" field; the
panel has the "Loaded from a subscription" connection mode for it.

### Tunnel

The connection to the VPN server that traffic goes through. "The tunnel is up"
— the connection exists and traffic goes through it.

### Transport

How traffic is packed on the way to the server: `xhttp`, `ws` (WebSocket),
`grpc`, `tcp`, `httpupgrade`, `kcp`. The VPN service chooses it and it is
already written in the key — there is no need to change it yourself. The panel
shows the transport in the "Connection" line.

### Mux

Carrying several requests inside one connection to the server. It speeds up
transports where every new connection is expensive (`ws`, `httpupgrade`).
XHTTP, gRPC and a few others do this themselves, and byway turns mux off for
them.

### The Xray-core engine

The program that actually holds the connection to the VPN server and carries
the traffic. byway configures it, watches it and updates it. In detail — [the
Xray-core engine](engine.en.md).

## Lists

### List

The set of sites (domains) and addresses (subnets) that go through the VPN.
Anything not on it goes direct. Your own list is edited on the "Lists" tab.

### Domain

A site name: `youtube.com`. On a list, a domain also covers its subdomains —
`m.youtube.com`, `music.youtube.com`. Non-Latin domains (such as `.рф`) are
written in punycode, a Latin form like `xn--…`.

### Subnet

A range of IP addresses like `91.108.4.0/22`. Needed for services that connect
by address rather than by site name — Telegram, for example. A subnet that is
too wide pulls unrelated traffic into the VPN.

### Ready-made list

A list maintained by other people: for example, everything blocked in Russia.
It is connected on the "Lists" tab and refreshed by a button or on a schedule.

### Route

A separate list that goes through a different key instead of the main one: for
example, video through one server and work through another.

### By lists / Everything through the VPN

The two modes. "By lists" — only what is listed goes through the VPN, the rest
goes direct. "Everything through the VPN" — all home traffic, with `.ru`,
`.su` and `.рф` sites going direct by default.

## How byway recognises its traffic

### DNS

The service that turns a site name into an address: `youtube.com` →
`142.250.…`. Devices at home ask the router for it. A resolver is the program
that answers these questions; on the router dnsmasq takes them and passes them
to byway.

### DoH

DNS over an encrypted channel (DNS over HTTPS). The ISP can tamper with plain
DNS queries but not with encrypted ones, so byway itself talks to its DNS
server over DoH. But if DoH is on in a browser or on a phone ("Private DNS" on
Android), the device asks for addresses not from the router, and byway does
not recognise a site from the list. For such a device only subnets work.

### Placeholder address

A made-up address from the `198.18.0.0/15` range that byway gives a listed
site instead of its real one. That is how byway knows the connection must go
through the VPN. Such addresses do not exist on the internet and never leave
the router. In the documents — fakeip, and the range is the pool.

### Interception

The rules on the router that take traffic to listed sites and hand it to the
engine. "Interception did not come up" — the rules did not load, and traffic
goes around byway.

### QUIC

A fast way of connecting over UDP used by YouTube, Google and others. With
most keys it stalls inside the VPN, so byway rejects it by default, and the
browser switches to a normal connection right away.

## The router

### OpenWrt

A free firmware for routers; byway runs only on it, from version 22.03.

### LuCI

The OpenWrt web interface: what opens in a browser at the router's address.
The byway panel is its *Services → Byway* section.

### SSH and the console

Text access to the router: `ssh root@192.168.1.1` from PowerShell (Windows) or
Terminal (macOS, Linux). Needed for installing and for `byway …` commands.

### Service

byway running on the router all the time, in the background. It starts with
the router; "Restart" on the "Overview" tab restarts exactly that.
