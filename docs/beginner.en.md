# byway in plain words

*[Русская версия](beginner.md)*

The short path from a bare router to a working byway, without internals and
fine print. An unfamiliar word — see the [glossary](glossary.en.md). Details —
in the [README](../README.en.md).

## What byway does

byway goes on the router and splits your home traffic in two. Sites on your
[lists](glossary.en.md#list) go through the [VPN](glossary.en.md#vpn),
everything else goes direct, as usual. Nothing needs setting up on the devices
at home: phones, laptops and the TV get it from the router.

byway does not provide a VPN itself. You need your own
[key](glossary.en.md#key) from a VPN service — byway only decides what to send
through it.

## What you need

- **A router with OpenWrt 22.03 or newer.** The version is shown in [LuCI](glossary.en.md#luci) (the
  router's web interface): *Status → Overview*, the *Firmware Version* line.
  On 21.02 and older byway will not install — the installer refuses and says
  why. Whether your model is supported is in the
  [OpenWrt Table of Hardware](https://openwrt.org/toh/start). The firmware for
  it is built by the [Firmware Selector](https://firmware-selector.openwrt.org/);
  the first installation is described in the
  [OpenWrt guide](https://openwrt.org/docs/guide-quick-start/start).
- **A key from a VPN service** — a link like `vless://…`, `trojan://…`,
  `ss://…` and the like, or a [subscription](glossary.en.md#subscription)
  address (`https://…`). It comes in an email, in your account with the
  service or from its bot.
- **A computer on the home network** — for installing and setting up.

## Installing

1. Open the router's console. On Windows — PowerShell, on macOS and Linux —
   Terminal. The command (the address is your router's, most often this one):

   ```sh
   ssh root@192.168.1.1
   ```

   The password is the same as for logging in to LuCI. More on logging in — on
   the [OpenWrt wiki](https://openwrt.org/docs/guide-quick-start/sshadministration).

2. Paste the install line and press Enter:

   ```sh
   sh -c "$(wget -O - https://raw.githubusercontent.com/tomon-one/byway/v0.3.0/install.sh)"
   ```

   If `raw.githubusercontent.com` is unreachable, there is a line through a
   mirror in the README, section [Installing](../README.en.md#installing).

3. The installer asks up to four questions: language, the `procd-ujail`
   package (only if it is missing), the
   [core](glossary.en.md#the-xray-core-engine) version and the web panel. If
   unsure — Enter everywhere: the defaults fit.

The core is downloaded from GitHub; the router's flash needs 25 MB free for
that. With less, the installer says so and installs the core from the OpenWrt
packages.

## Setting up

Open `http://192.168.1.1` (or your router's address) in a browser, log in and
choose *Services → Byway*.

1. **The "Overview" tab.** At the top is the "Getting started" block. Paste the
   key into the "Key" field and press "Save & Apply" at the bottom of the page.
   If the service gave a subscription address, choose the "Loaded from a
   subscription" connection mode, press "Load the list of keys" and tick the
   one you need.
2. **The "Check the key" button** on the same tab checks the key without
   breaking anything: "WORKS" — the key is alive, "DOES NOT WORK" — you need
   another one.
3. **The "Lists" tab.** This is where the sites that should go through the VPN
   go, one per line: `youtube.com`, `instagram.com`. A site covers its
   subdomains: `youtube.com` includes `m.youtube.com` too. Instead of a manual
   list you can pick [ready-made lists](glossary.en.md#ready-made-list) — for
   example, everything blocked in Russia — press "Save & Apply" and "Download
   now". To send absolutely everything through the VPN, use "Everything
   through the VPN" mode.

The other tabs are not needed for the first setup.

## How to tell it works

The "Overview" tab has four dots. Half a minute after saving, press "Check
now".

| dot | green means |
|---|---|
| **Service** | byway is running on the router |
| **Link to the VPN** | the server from the key answers |
| **Traffic through the VPN** | traffic really goes through the server |
| **DNS** | byway's [resolver](glossary.en.md#dns) answers |

A red dot has a note under it on what to do. A yellow one saying "starting"
during the first half minute after a start is normal.

The last check is from a phone or laptop: open a site from the list.

## Common troubles

**The "Link to the VPN" dot is red.** The key is incomplete or out of date, or
the server is down. Press "Check the key". "DOES NOT WORK" — get a fresh key
from the VPN service. byway is not the cause here: the server does not answer
other programs either.

**All dots are green, but a site does not open.** There are usually two
reasons.

- The site is not on the list, or it loads pictures and video from other
  domains. Add those domains or connect a ready-made list.
- The device has "Private DNS" (Android) or [DoH](glossary.en.md#doh) in the
  browser turned on. Such a device learns site addresses not from the router,
  and byway does not see that the site is on the list. Turn that setting off
  on the device ([Android](https://support.google.com/android/answer/9654714?hl=en), [Firefox](https://support.mozilla.org/en-US/kb/firefox-dns-over-https),
  [Chrome](https://support.google.com/chrome/answer/10468685?hl=en&co=GENIE.Platform%3DDesktop)). More in [when it does not work](troubleshooting.en.md).

**Sites from the list stopped opening altogether.** If the VPN on the router
did not come up, byway by default closes the sites on the lists so they do not
go around the VPN. This is the "If the VPN does not come up" setting on the
"Overview" tab: "Block" — close them, "Go direct" — let them through without
the VPN. Fix the VPN by the dots above first; if you need the internet right
now, choose "Go direct".

**After an update the panel looks odd or shows errors.** The browser shows the
old panel from its cache. Reload the page without the cache: Ctrl+Shift+R (on
a Mac — Cmd+Shift+R).

None of this fits — the "Maintenance" tab → "Check the environment": byway
checks the router and writes how to fix each fault it finds.

## Updating

*Maintenance → Updates* → "Check for an update", then "Install the update".
Settings and lists are kept; the tunnel drops for a few seconds. After the
update, reload the page (F5).

## Removing

In the router's console:

```sh
byway-uninstall
```

The key and lists stay on the router — in case you install again. To wipe
everything: `byway-uninstall --purge`.

## Where next

- [Glossary](glossary.en.md)
- [README](../README.en.md) — all features, console commands, the whole panel
- [When it does not work](troubleshooting.en.md) — troubleshooting in detail
- [Keys and connecting](keys.en.md) — which keys byway understands
