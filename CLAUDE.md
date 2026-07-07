# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```bash
# Build (Debug)
xcodebuild -project magic-trackpad-connector.xcodeproj \
  -scheme magic-trackpad-connector -configuration Debug build

# Build (Release)
xcodebuild -project magic-trackpad-connector.xcodeproj \
  -scheme magic-trackpad-connector -configuration Release build

# Open in Xcode
open magic-trackpad-connector.xcodeproj
```

There are no tests.

## Runtime dependency

`blueutil` must be installed on every Mac that runs the app:

```bash
brew install blueutil
```

The app checks `/opt/homebrew/bin/blueutil` and `/usr/local/bin/blueutil`. All Bluetooth operations shell out to this CLI via `Process` — there is no CoreBluetooth usage.

## Architecture

```
AppDelegate
  ├── PeerServer        — TCP listener (port 7890), advertises _mtconnector._tcp via Bonjour
  ├── BonjourService    — discovers the peer Mac's _mtconnector._tcp service
  ├── ToggleCoordinator — owns the transfer state machine (@MainActor)
  └── StatusBarController — menu-bar UI, rebuilds menu on open
```

**BluetoothManager** (`Bluetooth/BluetoothManager.swift`) is a singleton that wraps every blueutil call. All `Process` invocations run on a caller-owned serial queue (userInitiated) so the main thread never blocks.

**Link-key handling (critical):** Magic devices store a single Bluetooth link key and only accept pairing while in *pairing mode*. Two consequences drive the whole design:

1. **The sender must unpair while the link is up** (`releaseForHandoff()`): macOS then sends the HID Virtual Cable Unplug, the trackpad erases its own pairing and enters pairing mode. A plain `--disconnect` leaves the trackpad bound to the sender, and the receiver's `--pair` fails with `0x02 (No Connection)` — observed in practice; retrying cannot fix it.
2. **The receiver must re-pair, not just connect** — its stored key went stale the moment the trackpad paired elsewhere. Magic devices pair via Just Works SSP (no PIN), so no user action is needed.
3. **Host-initiated pairing must win the race.** A freshly-unplugged trackpad actively tries to connect to Macs it remembers; a device-initiated connection from an unpaired device pops the macOS "Connection Request" dialog (observed in practice — and accepting it on the sender breaks the transfer). Countermeasures: the receiver uses `pairAfterHandoff()` (immediate `--unpair` → `--pair` loop, 6×, 1 s gaps, no connect fast path), and the releasing Mac sets `--connectable 0` for the release window so the trackpad can't crawl back (restored when release mode ends and defensively on every launch).

`connect()` (launch/manual paths) tries `--connect`/`--wait-connect` (5 s) first and falls back to the re-pair loop (4×, 2 s gaps) on timeout. `connectSimple()` skips the fallback and is used only in claim mode, where the pairing is known-fresh and an unpair on a transient failure would be harmful. Manual recovery if a handoff strands the trackpad: power-cycle it (it enters pairing mode when its stored host rejects it) or plug it into either Mac via cable, which re-pairs instantly.

**Inter-Mac protocol** (`Network/`) is newline-delimited JSON over TCP:
- Commands: `{"action": "ready" | "connect" | "disconnect" | "status"}`
- Responses: `{"status": "ok" | "error", "message": "..."}`
- `ready` is a pre-flight check (validates blueutil + MAC configured) answered before any BT state is changed.

**Transfer flow** (`Coordinator/ToggleCoordinator.swift`):
- *Send to peer*: pre-flight `ready` → `releaseForHandoff()` locally (unpair while connected → Virtual Cable Unplug, then `--connectable 0`) → 1 s settle → tell peer to connect (peer runs `pairAfterHandoff()`).
- *Take from peer*: tell peer to release (its `disconnect` handler runs `releaseForHandoff()` and blocks until the device is gone) → wait 1 s → `pairAfterHandoff()` locally.
- On launch the app only claims the trackpad if the peer is offline or reports it disconnected (`status` command) — a release is now a full unpair, far too aggressive to trigger automatically.

## Key project-wide setting

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set in build settings. This causes synthesised `Codable` conformances to inherit `@MainActor`. `Models.swift` uses **manual** `Encodable`/`Decodable` implementations with `nonisolated` to work around this — follow the same pattern for any new Codable types.

## Debugging

`NSLog("[BT] ...")` and `NSLog("[Coordinator] ...")` are sprinkled throughout. Filter Console.app by the process name `magic-trackpad-connector` to see real-time Bluetooth and coordination events including exact blueutil exit codes and stderr output.
