# Magic Trackpad Connector

A menu-bar app that moves an Apple Magic Trackpad (and optionally a Magic
Keyboard or Mouse) between **two Macs** automatically — no cables, no
re-pairing by hand, no "Connection Request" dialogs. The Macs can use
different Apple IDs (for example a personal Mac and a work Mac managed by
MDM); they only need to be on the same local network.

- **Lock, sleep or shut down** the Mac that has the trackpad → it moves to the
  other Mac within a few seconds.
- **Come back** to a Mac → it takes the trackpad back unless the other Mac is
  in use.
- **Manual toggle** from the menu bar or with **⌃⌥⌘T**.

## Requirements

- Two Macs on macOS 26.2 or later, on the same local network.
- The app installed and running on both.
- A Magic Trackpad, Magic Keyboard or Magic Mouse paired with one of them.

## Install

Download the latest `.dmg` from
[Releases](https://github.com/villegascmarco/magic-trackpad-connector/releases),
open it and drag the app to **Applications** — on **both** Macs. The app isn't
notarized, so the first launch is blocked by Gatekeeper: open
**System Settings → Privacy & Security** and click **Open Anyway**.

On a Mac managed by your company (MDM), **Open Anyway** may just show the
warning again. In that case, remove the download quarantine in Terminal and
open the app normally:

```bash
xattr -dr com.apple.quarantine /Applications/magic-trackpad-connector.app
```

### Build from source

With Xcode 26 or later (if `xcode-select` points at the Command Line Tools,
first `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`):

```bash
git clone https://github.com/villegascmarco/magic-trackpad-connector.git
cd magic-trackpad-connector
Tools/release.sh        # → build/release/Magic-Trackpad-Connector-<version>.dmg
```

## Setup

On **both** Macs:

1. Open the app and allow **Bluetooth** and **Local Network** access when
   asked.
2. Open **Settings → Network** and enter the same **pairing code** on both
   Macs (use **Generate** on one and type it on the other). The Macs ignore
   requests that aren't signed with this code, so other computers on the
   network can't take your devices.
3. In **Settings → General**, set **Role** to **Main** on exactly one Mac
   (the one that should get the devices when nothing else claims them) and
   **Secondary** on the other.
4. In **Settings → Devices**, check the devices to move.

The other Mac is found automatically over Bonjour. If your network blocks
that, enter its address under **Settings → Network → Fallback Address**.

## How it works

Magic devices remember only one host. To hand one over, the Mac holding it
unpairs it *while connected* — macOS sends the HID "Virtual Cable Unplug",
so the device forgets that Mac and becomes pairable — and the other Mac pairs
with it immediately (silent "Just Works" pairing, about 3 seconds). The two
apps coordinate over TCP port 7890. The details, and the measurements behind
them, are in [`REQUIREMENTS.md`](REQUIREMENTS.md) and [`CLAUDE.md`](CLAUDE.md).

## Limitations

- **If a Mac dies while holding the device** (crash, power loss), the device
  stays bound to it. Switch the device off and on; the other Mac then pairs
  with it automatically (the menu shows this hint).
- **Exactly two Macs.**
- **Not on the Mac App Store:** unpairing uses a private IOBluetooth method,
  and the app runs outside the sandbox.
- Tested with a Magic Trackpad on macOS 27.2. Keyboard and Mouse are
  supported by the same code path but haven't been tested on real hardware —
  reports welcome.

## Development

See [`CLAUDE.md`](CLAUDE.md) for the architecture, and run
`python3 Tools/simulate_handoff.py` after changing any handoff logic. The
end-to-end suite `Tools/e2e.sh` needs two Macs and SSH access to the other one
(`PEER=<ssh-host> Tools/e2e.sh`).

## License

[MIT](LICENSE)
