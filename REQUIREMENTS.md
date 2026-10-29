# Requirements — Magic Trackpad two-Mac handoff

Source: user brief (2026-07-11) + `/goal` statement (2026-10-28). Each
requirement has an ID, acceptance criteria, and how it is verified. Keep this
file in sync with behavior; re-run the verification column after changes.

## Environment

| | |
|---|---|
| Mac A | "Villegas's Mac mini" — personal, **main / orchestrator** (role `primary`) |
| Mac B | MacBook `SIS90258716M` — work, MDM-managed, user `isaimarcopolovillegas` (role `secondary`) |
| Device | "Villegas's Magic Trackpad" `d0-c0-50-cb-fa-2d` |
| Link | same LAN (Bonjour `_mtconnector._tcp`, TCP 7890); different Apple IDs, no iCloud |

## Functional requirements

| ID | Requirement | Acceptance criteria |
|---|---|---|
| R1 | **Two Macs only, any Apple ID.** Works between exactly two Macs on the same LAN with different Apple IDs. | No iCloud/Apple-ID dependency; peers find each other via Bonjour or a configured fallback host. |
| R2 | **Manual toggle.** From either Mac, send the device to the other Mac or bring it here. | Menu item "Send to … / Bring Here" and hotkey ⌃⌥⌘T. Device connected on the target within ~10 s; source no longer connected. Works in both directions, repeatedly. |
| R3 | **Main Mac = orchestrator / error fallback.** After any failure, the device ends up on the main Mac. | Failed transfer → sender reconnects (rollback); if that fails too and nobody holds the device, the main Mac claims it within one reconcile cycle (≤ 75 s). |
| R4 | **Lock → hand off.** When the Mac holding the device locks, the device goes to the other Mac if that Mac is awake and unlocked. | Holder locks, peer unlocked → device on peer. Peer also locked → device stays. |
| R5 | **Sleep / lid close / shutdown → hand off.** The holder hands the device to the other Mac if it is reachable (locked is fine). | Sleep is delayed until the handoff finishes (≤ 25 s). After the holder sleeps or shuts down, the device is connected to the peer. |
| R6 | **Only one Mac on → it's fine to be disconnected.** | No retries that disturb anything; no dialogs; device may stay disconnected. |
| R7 | **First Mac up takes it.** On launch / boot / wake / unlock, if no other Mac is using the device, take it. | Peer off / not running the app / doesn't hold the device → device connects here. |
| R8 | **Never steal from a Mac in use.** | On launch, if the peer holds the device and is unlocked, leave it there. On wake/unlock, leave it unless the peer has been idle ≥ 120 s. |
| R9 | **Take it from an unavailable holder.** | If the peer holds the device but is locked/asleep and this Mac is available → take it (also periodically). |
| R10 | **Zero interaction in normal use.** | No macOS "Connection Request" dialogs or app alerts during automatic handoffs (one-time permission prompts at setup are OK). |
| R11 | **Background, starts at login.** | Menu-bar app (no Dock icon), registers as a login item. |
| R12 | **Other Apple devices.** Magic Keyboard / Mouse can be moved together with the trackpad. | Settings lists paired devices; checked ones move as a group. |
| R13 | **MDM-friendly.** Nothing to install on the work Mac besides the app. | No Homebrew/blueutil dependency; one Bluetooth permission prompt per Mac. |

## Hardware facts (measured 2026-10-28, both Macs on macOS 27.2)

| # | Experiment | Result |
|---|---|---|
| E1 | MacBook pairs while mini holds trackpad connected | fails `0xe00002d6` (timeout); mini unaffected; no dialog |
| E2 | mini unpairs while connected → MacBook pairs | **works**, ~3 s total, 1st attempt, no dialogs |
| E3 | reverse (MacBook → mini) | **works**, ~3 s, no dialogs |
| E4 | owner's Bluetooth off (simulated crash) → other Mac pairs | **fails** `0x02` — trackpad stays bound to its last host |
| E4b | owner Bluetooth back on → owner `claim` (connect with own key) | works, ~2 s |
| E8 | released trackpad left alone 3 min, then pair | fails (`0xe00002d6`, then `0x04` page timeout) — trackpad stops answering |
| — | `blueutil --connectable` (old design's dialog guard) | **does not exist** (exit 64) — was a silent no-op |
| — | blueutil started by launchd (old Python daemon) | hangs forever (no TCC prompt possible) |

Consequences: a handoff must be *release-then-pair while the receiver is
ready* (never release into the void for long); a Mac that dies holding the
device can't be recovered by the other Mac — the user must switch the
trackpad off/on (or plug it in by cable).

Later measurements (same day):

| # | Experiment | Result |
|---|---|---|
| T6 | receiver unpairs 0.75 s / 5.5 s after pairing (HID not open yet) | unplug lost → **stranded** (`0x02` everywhere, cable needed) — fixed by waiting for the IOHIDDevice (`SerialNumber` = address) before unpairing |
| — | after fix: 2 × `Tools/e2e.sh` | 20/20 pass, every unplug acknowledged, no system dialogs |
| RT1 | real lock on MacBook (Apple menu → Sleep locks first) | handed to mini in 5 s; after unlock it stayed on the mini (mini in use) |
| RT2 | relaunch either app while the other Mac uses the trackpad | not stolen |
| RT3 | trackpad free, mini app off, MacBook app cold launch | MacBook claimed it in ~12 s |
| RT4 | real restart of MacBook holding trackpad (1st) | app killed ~4 s after power-off, mid-release; mini idle-waited 60 s; after boot MacBook stole it back (mini idle) → fixed: receiver watchdog, launch never steals |
| — | after MacBook reboot | it advertises `::1` / `fe80::1` as its own Bonjour addresses → mini's connections looped to itself → fixed: IPv4-only peer connections + self-loop detection (`from` field) |
| RT5 | real restart (2nd) | handed off via watchdog, ~19 s; app auto-started at login and left trackpad on mini |
| RT6 | real restart (3rd, fast shutdown path) | **2.3 s** power-off → trackpad on mini; no steal after boot |
| — | both Macs: `pmset -g` | `SleepDisabled 1` — system sleep never happens; lid close / Apple menu Sleep only lock (→ R4 path, RT1) |

## Status (2026-10-28)

| ID | Status |
|---|---|
| R1, R2, R3, R4, R7, R8, R9, R11, R13 | verified on hardware |
| R5 | shutdown/restart verified on hardware (RT5, RT6: 2.3 s). Lid close / Sleep on these Macs = lock (sleep disabled by `pmset`), verified via R4 (RT1). The sleep-hold path (IOKit, ≤25 s) only runs if sleep is re-enabled; covered by simulated events only |
| R6 | by design (no peer → keep device, rate-limited claims) |
| R10 | no Connection Request dialogs in any run; one-time Bluetooth/Local Network prompt per new build (ad-hoc signing) |
| R12 | implemented (Settings device list, devices move as a group); untested — no Magic Keyboard/Mouse available |
| Known limit | a Mac that crashes / loses power while holding the device strands it until cable/power-cycle (E4) |

## Verification

1. **Build:** `xcodebuild … -configuration Release build` (needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on the mini).
2. **Hardware primitives:** `Tools/ctl.sh '{"action":"bt","op":"release|acquire|claim|pair|state"}'` (add `-r mbp` for the MacBook via SSH).
3. **Policy end-to-end:** drive with `Tools/ctl.sh` `push` / `pull` / `event {"name":"lock|sleep|arrive"}` on each Mac and check `bt state` on both; real lock/sleep tests for R4/R5.
4. **Dialogs (R10):** list on-screen windows on both Macs after each step (CGWindowList owner names) — no Bluetooth/UserNotification dialog may appear.
5. **Model:** `python3 Tools/simulate_handoff.py` must print `all scenarios pass`.
