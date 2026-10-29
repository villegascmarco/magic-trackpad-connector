# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Requirements, acceptance criteria and the measured Bluetooth facts live in
`REQUIREMENTS.md` — read it before changing behavior.

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # mini: xcode-select points at CLT
xcodebuild -project magic-trackpad-connector.xcodeproj -scheme magic-trackpad-connector \
  -configuration Release -derivedDataPath build/dd \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

Ad-hoc signed. Install on both Macs (`/Applications` here, `~/Applications`
on the MacBook via `rsync … mbp:`); first launch asks for Bluetooth and Local
Network permission once per Mac.

## Verification (run after any behavior change)

1. `python3 Tools/simulate_handoff.py` — must print `all scenarios pass`. It
   transcribes the Bluetooth recipes from `HandoffCoordinator.swift`
   (`release` / `acquireAfterRelease` / `claim` / `pairAndConnect`) and
   `BluetoothManager.settle`; **update it whenever those change.**
2. `Tools/e2e.sh` — real two-Mac end-to-end suite (toggle, lock, sleep, race,
   arrive/no-steal, orchestrator fallback). Needs SSH alias `mbp` to the other
   Mac and both apps running with automatic handoff on.
3. `Tools/ctl.sh [-r mbp] '{"action":…}'` — loopback control port for manual
   probing (`status`, `push`, `pull`, `toggle`, `event`, `auto`, `config`,
   `log`, `bt` with `op` = state|connect|disconnect|pair|unpair|release|acquire|claim|paired|hid).

Gotchas: `defaults write` from a sandboxed shell does not reach the app — use
the `config`/`auto` control actions. Xcode's debugger can leave a stopped old
instance holding port 7890.

## Architecture

```
AppDelegate
  ├── PeerServer          — TCP :7890, Bonjour _mtconnector._tcp; JSON lines; loopback-only control actions
  ├── BonjourService      — finds the peer (fallback: configured host)
  ├── SystemEvents        — lock/unlock, sleep (held until handoff done, ≤25 s), wake, power-off, idle time
  ├── HandoffCoordinator  — transfer flows + automatic policy (@MainActor)
  ├── StatusBarController — menu: location, Send/Bring (⌃⌥⌘T), Automatic Handoff, role
  └── Hotkey              — Carbon global hotkey ⌃⌥⌘T → toggle
```

**BluetoothManager** uses **IOBluetooth in-process** on one dedicated run-loop
thread, serialized by a queue. No blueutil: it can't get Bluetooth permission
under launchd/SSH (hangs), and its `--connectable` flag never existed. Unpair
uses the private `remove` selector (same as blueutil).

**Bluetooth facts (measured, see REQUIREMENTS.md):** Magic devices hold one
host key. A handoff = sender unpairs *while connected* (macOS sends the HID
Virtual Cable Unplug, device forgets its host and becomes pairable) → receiver
pairs immediately (Just Works, silent, ~3 s total, no dialogs).

- **Never unpair before the device's HID channel is open** (`isHIDReady`:
  an IOHIDDevice whose SerialNumber is the address). Unpairing ~1–5 s after a
  fresh connect removed the record without the device noticing → stranded
  (every host gets `0x02` until a cable/power-cycle). `settle()` waits for HID plus 1.5 s from when it first appeared (per link);
  `release()` refuses (changes nothing) if HID never opens.
- A released device stops answering within a few minutes → never release
  unless a receiver is pairing right now; with no reachable peer, sleep/shutdown
  keep the device.
- A Mac that dies holding the device can't be recovered by the other Mac
  (`0x02`); the user must cable/power-cycle it.

**Networking:** peer connections are **IPv4-only** — the MDM MacBook
advertises `::1`/`fe80::1` over Bonjour and Network.framework would connect to
our own loopback. Every response carries `from` (responder name); a reply
from ourselves is treated as unreachable.

**Peer protocol:** `{"action": "status"|"prepare"|"receive"|"release"|"cancel", "devices": [...]}`
→ `{"status": "ok"|"error", "from": name, …}`. After `prepare`, a watchdog
pairs immediately if the sender vanishes or `receive` never comes (shutdown
kills the app within seconds of the unplug). `status` returns `holds`, `available`
(awake+unlocked), `idle`, `busy`, `role`. A Mac with no devices configured
adopts the peer's list.

**Policy** (top of `HandoffCoordinator.swift`): lock → push if peer unlocked;
sleep/shutdown → push if peer reachable (shutdown skips the disconnect wait);
launch → take only if nobody holds or the holder is locked/asleep;
wake/unlock → also take from a holder idle ≥120 s; every 15 s → take from a
locked/asleep holder, and the **primary** (orchestrator) claims devices nobody
holds (rate-limited to once a minute).

## Key project-wide setting

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Background types are declared
`nonisolated` (BluetoothManager, PeerServer, Log, Wire). Messages are plain
`[String: Any]` JSON, avoiding the Codable/MainActor issue.

## Debugging

`~/Library/Logs/MagicTrackpadConnector.log` on each Mac (also `ctl.sh '{"action":"log"}'`),
tags `[BT] [Flow] [Policy] [Sys] [Net] [State]`.
