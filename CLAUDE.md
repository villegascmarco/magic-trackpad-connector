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

**Link-key handling (critical):** Magic devices store a single Bluetooth link key. Once the trackpad pairs with the other Mac, this Mac's stored key is invalidated and every plain connect is silently rejected — this is why a naive connect/disconnect swap can move the trackpad once but never bring it back. `connect()` therefore tries `--connect`/`--wait-connect` (5 s) first, and on timeout falls back to `--unpair` → `--pair` → `--wait-connect` (retried 4×, 2 s gaps — the sender's macOS may still be fighting for the device). Magic devices pair via Just Works SSP (no PIN), so the re-pair needs no user action. `connectSimple()` skips the fallback and is used only in claim mode, where the pairing is known-fresh and an unpair on a transient failure would be harmful.

**Inter-Mac protocol** (`Network/`) is newline-delimited JSON over TCP:
- Commands: `{"action": "ready" | "connect" | "disconnect" | "status"}`
- Responses: `{"status": "ok" | "error", "message": "..."}`
- `ready` is a pre-flight check (validates blueutil + MAC configured) answered before any BT state is changed.

**Transfer flow** (`Coordinator/ToggleCoordinator.swift`):
- *Send to peer*: pre-flight `ready` → disconnect locally → **poll `isConnected` until false** (up to 20 × 300 ms) → 500 ms buffer → tell peer to connect.
- *Take from peer*: tell peer to disconnect → wait 1.5 s → connect locally (re-pairs automatically if the link key went stale).
- The poll-until-released step is critical: `blueutil --disconnect` returns before the BT hardware tears down the link; sending `connect` to the peer too early causes it to fail.

## Key project-wide setting

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set in build settings. This causes synthesised `Codable` conformances to inherit `@MainActor`. `Models.swift` uses **manual** `Encodable`/`Decodable` implementations with `nonisolated` to work around this — follow the same pattern for any new Codable types.

## Debugging

`NSLog("[BT] ...")` and `NSLog("[Coordinator] ...")` are sprinkled throughout. Filter Console.app by the process name `magic-trackpad-connector` to see real-time Bluetooth and coordination events including exact blueutil exit codes and stderr output.
