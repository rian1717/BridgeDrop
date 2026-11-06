<h1 align="center">BridgeDrop</h1>

<p align="center">
  Send and receive files between your Mac and nearby Android devices,<br>
  using Android's native <b>Quick Share</b> experience.
</p>

<p align="center">
  <img alt="Platform: macOS 26+" src="https://img.shields.io/badge/platform-macOS%2026%2B-1d2b40">
  <img alt="Swift 6" src="https://img.shields.io/badge/swift-6.4-1d2b40">
  <img alt="Dependencies: none" src="https://img.shields.io/badge/dependencies-none-2a9d5c">
  <img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-1d2b40">
</p>

<p align="center">
  <img src="docs/screenshots/send.jpg" width="46%" alt="BridgeDrop Send: nearby devices and a live transfer list">
  &nbsp;&nbsp;
  <img src="docs/screenshots/receive.jpg" width="46%" alt="BridgeDrop Receive: visibility state, setup steps and transfer history">
</p>

---

Android phones can share files with each other in two taps. Macs can't join in —
Quick Share has no Apple client, and AirDrop doesn't speak to Android. BridgeDrop
fills that gap: your Mac shows up in your phone's Quick Share sheet, and your
phone shows up in BridgeDrop's device list.

Quick Share is undocumented, so BridgeDrop follows a reverse-engineered
specification — mDNS discovery, UKEY2 key agreement,
AES-256-CBC + HMAC-SHA256 secure messages, chunked transfer — depending on
nothing outside the OS.

## Features

- **Send** — pick a device and drag files onto it, or drop them on a device row
- **Finder Share extension** — send selected files without opening the main window
- **Receive** — flip visibility on and your Mac appears on the phone
- **Text and links** — saved to your downloads folder as files, never opened
- **PIN verification** — a 4-digit code on both screens before anything moves
- **Explicit consent** — every transfer requires PIN verification and approval
- **QR code** — reach a phone that can't discover you
- **Menu-bar app** — keeps running with the window closed
- **Command-line API** — drive it from scripts or an agent (off by default)
- **Clipboard** — copy text, images, or files on Android and press ⌘V on the Mac.
  Turn it on in Settings and pair the BridgeDrop Android app once. iPhone copies
  already paste through Apple Handoff.

## Install

Needs **macOS 26 or later**, and both devices on the same Wi-Fi network.

The project is currently a development preview. Public releases will be
Developer ID signed and notarized. Until then, build the app locally using the
instructions below.

## Using it

Both devices stay on the same Wi-Fi. Received files land in `~/Downloads`.
Change that folder in Settings.

**Send to a phone that is already listed.** On the Send tab, drop the file on
that phone. Accept on the phone. The four-digit PIN on both screens should
match.

**Send to a phone that is not listed.** This is the normal path for a Samsung,
and for any phone that does not appear. Tap **Use a QR code**, then drop the
file. The QR code appears on its own. Scan it with the phone's camera or Quick
Share, then accept. There is no second tap to reveal the code.

**Receive from the phone.** Open the Receive tab and turn visibility on. On the
phone, share the file with Quick Share and choose the Mac. Match the PIN and
accept. The phone's Quick Share settings page does not list devices. Start from
the share sheet in Gallery or Files instead.

**Copy on the phone, paste on the Mac.** An iPhone does not use this. iPhone
copies already paste through Apple Handoff when both devices use the same
Apple ID. For Android:

1. On the Mac, open **BridgeDrop → Settings…** and turn on **Paste phone copies here**. Leave the QR code and the 8-digit code on screen.
2. Install the BridgeDrop phone app. It is not on the Play Store. If Play Protect says the app is blocked and the only button is **OK**, open the Play Store, tap your profile, open **Play Protect**, tap the gear, and turn off **Improve harmful app detection**. If that switch is missing, turn off **Scan apps with Play Protect**. Install the app, then turn the switch back on.
3. On the phone, scan the Mac's QR code and open it in BridgeDrop. Or type the 8-digit code, tap **Find Mac on this Wi-Fi**, then tap the Mac's name. Tapping the name, without the code, asks you to tap **Allow** on the Mac.
4. Tap **Turn on clipboard access**. If BridgeDrop is marked **Controlled by restricted setting**, open **Settings → Apps → BridgeDrop**, tap the three dots, and choose **Allow restricted settings**. Then go back to **Accessibility → Downloaded apps**, tap BridgeDrop, and turn it on.
5. Tap **Allow this phone to keep BridgeDrop running**. On a Xiaomi phone that is Autostart. On a Samsung phone, keep BridgeDrop out of sleeping apps.
6. Copy text, a picture, or a file on the phone, then press **⌘V** on the Mac.

| | |
|---|---|
| `⌘1` / `⌘2` | Send / Receive |
| `⇧⌘V` | Toggle visibility |
| `⇧⌘O` | Open downloads folder |
| `⌃⌥←` / `⌃⌥→` | Snap window to screen edge |
| `⌘⌥I` | Build info |

## If your phone doesn't see your Mac

Usually this isn't a bug. Android discovers nearby devices by listening for
Bluetooth LE advertisements, and **macOS provides no API to emit them**. Nothing
in this app can fix that — it's a platform limitation, not an oversight.

In practice that means Mac → phone is the reliable direction, and phone → Mac
needs a hand:

- Make sure both devices are on the **same Wi-Fi network** — not one on 5 GHz
  and one on a guest SSID.
- Check the router isn't running **AP isolation** (often called "client
  isolation"), which blocks devices from seeing each other.
- Turn off any **VPN** on either device; most capture the traffic discovery needs.
- Still nothing? **Use the QR code.** It's the designed answer to this, not a
  workaround — scanning it skips discovery entirely.

## Security

Every transfer shows a **4-digit PIN on both screens** before any bytes move.
Matching it is what proves you're talking to the device you think you are.

Quick Share as implemented here exposes *no verifiable device identity*: UKEY2
keys are generated fresh for every handshake, and the certificate frames that
would carry a persistent identity aren't in the specification this is built
from. The only thing a sender proves is the name it chose to advertise.

BridgeDrop therefore never trusts a device name or automatically accepts native
Quick Share traffic. Verify the PIN on both screens for every transfer.

Received links are **saved as files, never opened**.

## Command line

BridgeDrop can host a small JSON API on `127.0.0.1:47821` for scripting and
automation. It is **off by default** — enable it in *Settings → Services*.

> While it's on, anything running under your account can ask BridgeDrop to send any
> file it can read to a nearby device. That's the point of the feature, and the
> reason it's opt-in.

```bash
ln -s "$(pwd)/BridgeDrop/Packaging/bridgedrop" /usr/local/bin/bridgedrop

bridgedrop list                                   # devices currently visible
bridgedrop send ~/photo.jpg --to "Pixel 8 Pro"    # blocks; exit 0 on success
bridgedrop status --json                          # machine-readable
```

Requests are authenticated with a token in `~/.config/bridgedrop/token`. Full
endpoint reference: **[docs/API.md](docs/API.md)**.

## How it works

```
Views (SwiftUI)  ──observe──▶  AppModel  ──▶  BridgeDropService
                                                     │
                                          ┌──────────┴──────────┐
                                     MockService          BridgeDropEngine
                              (BRIDGEDROP_MOCK=1)                 │
                                                    ┌───────────┴───────────┐
                                               Discovery              Transport
                                            mDNS · QR · TXT      framing · sessions
                                                                        │
                                                             Crypto ─── Wire
                                                            UKEY2 P-256  protobuf
```

`Sources/BridgeDropCore/` is the protocol; `Sources/BridgeDrop/` is the app.
The seam between them is one protocol (`BridgeDropService`), which is also what
makes the mock engine possible.

The whole thing is Swift 6 language mode: the transport runs on actors, the app
on the main actor, and the compiler checks the boundary rather than convention.

The wire format is hand-written rather than generated — only a small fraction of
the schema's messages are ever exchanged. Each is checked byte-identical against
a reference encoder, and the parsers that face the network are tested against
truncation, bit-flips, and random input.

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for the design and the
protocol details worth knowing.

## Build and develop

```bash
cd BridgeDrop
BridgeDrop/Packaging/build-app.sh
open BridgeDrop/build/BridgeDrop.app
```

The packaging step matters: real networking needs a proper `.app` bundle so
macOS will grant local-network access. A bare `swift run` binary can't get it.

```bash
swift test                        # unit + protocol tests
swift test --sanitize=thread      # concurrency
cd BridgeDrop
BRIDGEDROP_MOCK=1 swift run BridgeDrop    # UI work without a phone
```

`BRIDGEDROP_MOCK=1` runs a simulated engine that drives every UI state — devices, PINs,
progress, completion — with no network at all. The screenshots above were taken
with it.

`./Packaging/make-dmg.sh` builds the app and wraps it in a disk image, which is
how releases are cut.

## Credits

Quick Share is undocumented. The protocol was reverse-engineered and specified
by **@grishka**, published at
**[grishka/NearDrop](https://github.com/grishka/NearDrop)** and released into
the public domain.

The implementation foundation and protocol provenance are documented in
**[ATTRIBUTION.md](ATTRIBUTION.md)** and **[NOTICE](NOTICE)**.

Not affiliated with or endorsed by Google. "Quick Share" and "Nearby Share" are
their trademarks.

## License

[Apache-2.0](LICENSE).
