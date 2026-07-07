#!/usr/bin/env python3
"""
Two-Mac Magic Trackpad handoff simulator.

Models the empirically-observed trackpad behavior:
  - stores a single link key (one paired host at a time)
  - erases its own pairing and enters pairing mode ONLY on HID Virtual Cable
    Unplug, i.e. when the current host unpairs it WHILE THE LINK IS UP
  - while in pairing mode it actively "hunts": initiates connections to every
    Mac it remembers; if that Mac has page scan on (connectable) macOS pops
    the "Connection Request" dialog  -> recorded as a DIALOG event (observed
    on real hardware even when the Mac still had a stale pairing record)
  - --pair from a host succeeds only while the trackpad is in pairing mode
    and not connected; otherwise blueutil fails with 0x02 (No Connection)
  - when idle-but-paired, the trackpad auto-reconnects to its paired host if
    that host is connectable and still has the record (macOS auto-reconnect)

The driver replays the EXACT blueutil sequences from the Swift code
(BluetoothManager / ToggleCoordinator / PeerServer as of this commit) in
"new" mode, and the previous revision's sequences in "old" mode as a
sensitivity check (old mode must produce DIALOG events or the model is too
lenient to prove anything).

Time is logical: hunt() runs between every command and on explicit tick()s,
which over-approximates continuous hunting (if no dialog fires here, no
interleaving of these steps can fire one in the model).
"""

import sys

FAIL = []


class World:
    def __init__(self):
        # Trackpad starts paired+connected to A; both Macs have known it.
        self.tp_paired_host = "A"     # host whose link key the trackpad holds
        self.tp_connected = "A"       # host with active link, or None
        self.tp_pairing_mode = False
        self.tp_remembered = ["A", "B"]  # hosts the trackpad ever knew
        self.hosts = {
            "A": {"record": True, "connectable": True},
            "B": {"record": True, "connectable": True},  # stale record
        }
        self.events = []
        self.log = []

    # ---- trackpad autonomous behavior, runs "between" every command ----
    def hunt(self, phase):
        if self.tp_connected is not None:
            return
        if self.tp_pairing_mode:
            # Freshly-unplugged trackpad initiates connections to every
            # remembered, page-scanning host. Observed: macOS prompts even
            # when it still holds a (stale) pairing record.
            for h in self.tp_remembered:
                if self.hosts[h]["connectable"]:
                    self.events.append(f"DIALOG on Mac {h} during [{phase}]")
        else:
            # Idle but paired: device/macOS auto-reconnect when possible.
            ph = self.tp_paired_host
            if ph and self.hosts[ph]["record"] and self.hosts[ph]["connectable"]:
                self.tp_connected = ph
                self.log.append(f"    (auto-reconnect to {ph} during [{phase}])")

    def tick(self, phase):
        self.hunt(phase)

    # ---- fake blueutil ----
    def bt(self, host, *args):
        self.hunt(f"{host}: before {' '.join(args)}")
        cmd = args[0]
        ok = True
        if cmd == "--connect":
            # Host-initiated connect: works only if both sides share the key.
            if self.hosts[host]["record"] and self.tp_paired_host == host:
                if self.tp_connected in (None, host):
                    self.tp_connected = host
                    self.tp_pairing_mode = False
            # otherwise: command may exit 0 but no link comes up
        elif cmd == "--wait-connect":
            # the wait window is hunting time for the trackpad
            for _ in range(3):
                self.hunt(f"{host}: during wait-connect")
                if self.tp_connected == host:
                    break
            ok = self.tp_connected == host
        elif cmd == "--wait-disconnect":
            ok = self.tp_connected != host
        elif cmd == "--disconnect":
            if self.tp_connected == host:
                self.tp_connected = None
            else:
                ok = False
        elif cmd == "--unpair":
            was_linked = self.tp_connected == host
            self.hosts[host]["record"] = False
            if was_linked:
                # Virtual Cable Unplug: device erases its key, becomes pairable
                self.tp_connected = None
                self.tp_paired_host = None
                self.tp_pairing_mode = True
        elif cmd == "--pair":
            if self.tp_pairing_mode and self.tp_connected is None:
                self.tp_paired_host = host
                self.tp_pairing_mode = False
                self.hosts[host]["record"] = True
                self.tp_remembered = [host] + [x for x in self.tp_remembered if x != host]
            else:
                ok = False  # 0x02 No Connection
        elif cmd == "--connectable":
            self.hosts[host]["connectable"] = args[1] == "1"
        elif cmd == "--is-connected":
            return self.tp_connected == host
        else:
            raise ValueError(cmd)
        self.log.append(f"  {host}: blueutil {' '.join(args)} -> {'ok' if ok else 'FAIL'}")
        self.hunt(f"{host}: after {' '.join(args)}")
        return ok


# ---------- sequences transcribed from the Swift code (NEW revision) ----------

def release_for_handoff(w, host):
    """BluetoothManager.releaseForHandoff"""
    if not w.bt(host, "--is-connected"):
        w.bt(host, "--connect")
        w.bt(host, "--wait-connect", "5")
    w.bt(host, "--connectable", "0")           # BEFORE unpair (the fix)
    w.bt(host, "--is-connected")
    w.bt(host, "--unpair")                     # VC unplug
    w.bt(host, "--wait-disconnect", "3")


def pair_after_handoff(w, host):
    """BluetoothManager.pairAfterHandoff"""
    w.bt(host, "--connectable", "0")           # stay dark until paired
    w.bt(host, "--unpair")                     # drop stale local record
    success = False
    for attempt in range(6):
        if w.bt(host, "--pair"):
            w.bt(host, "--connect")
            success = w.bt(host, "--wait-connect", "10")
            if success:
                break
        w.tick(f"{host}: pair retry gap")
    if success:
        w.bt(host, "--connectable", "1")       # restore only once paired
    # on failure: stay dark, 30s failsafe restores (modeled by scenario end)
    return success


def send(w, sender, receiver, label):
    """ToggleCoordinator.sendTrackpadToPeer + PeerServer 'connect' handler"""
    w.log.append(f"--- {label}: SEND {sender} -> {receiver}")
    w.bt(receiver, "--connectable", "0")       # PeerServer 'ready' handler braces
    w.tick("network: ready response")
    release_for_handoff(w, sender)
    w.tick(f"{sender}: 300ms settle")
    w.tick("network: command to peer")
    ok = pair_after_handoff(w, receiver)
    # 30s failsafe restores the sender's connectable
    w.tick(f"{sender}: release window")
    w.bt(sender, "--connectable", "1")
    w.tick("after release window")
    return ok


def take(w, taker, holder, label):
    """ToggleCoordinator.bringTrackpadHere + PeerServer 'disconnect' handler"""
    w.log.append(f"--- {label}: TAKE by {taker} from {holder}")
    w.bt(taker, "--connectable", "0")          # go dark before the unplug
    w.tick("network: disconnect command")
    release_for_handoff(w, holder)             # peer executes
    w.tick(f"{taker}: 500ms settle")
    ok = pair_after_handoff(w, taker)
    w.tick(f"{holder}: release window")
    w.bt(holder, "--connectable", "1")
    w.tick("after release window")
    return ok


# ---------- OLD revision (sensitivity check: must produce dialogs) ----------

def old_send(w, sender, receiver, label):
    w.log.append(f"--- {label}: OLD SEND {sender} -> {receiver}")
    # old releaseForHandoff: unpair first, connectable after
    w.bt(sender, "--is-connected")
    w.bt(sender, "--unpair")
    w.bt(sender, "--connectable", "0")
    w.bt(sender, "--wait-disconnect", "6")
    w.tick("old: 1000ms settle")
    # old receiver: connectable 1 first, then unpair+pair
    w.bt(receiver, "--connectable", "1")
    w.bt(receiver, "--unpair")
    for attempt in range(6):
        if w.bt(receiver, "--pair"):
            w.bt(receiver, "--connect")
            if w.bt(receiver, "--wait-connect", "10"):
                break
        w.tick("old: pair retry gap")
    w.tick("old: release window")
    w.bt(sender, "--connectable", "1")


def check(w, name, expect_host):
    good = (w.tp_connected == expect_host and w.tp_paired_host == expect_host
            and not w.tp_pairing_mode)
    dialogs = [e for e in w.events]
    status = "PASS" if good and not dialogs else "FAIL"
    if status == "FAIL":
        FAIL.append(name)
    print(f"[{status}] {name}: connected_to={w.tp_connected} paired={w.tp_paired_host} "
          f"pairing_mode={w.tp_pairing_mode} dialogs={len(dialogs)}")
    for d in dialogs:
        print(f"         {d}")
    w.events = []


def main():
    verbose = "-v" in sys.argv

    # Scenario 1: full ping-pong via SEND, 3 round trips
    w = World()
    for i in range(3):
        send(w, "A", "B", f"round{i}")
        check(w, f"send A->B (round {i})", "B")
        send(w, "B", "A", f"round{i}-back")
        check(w, f"send B->A (round {i})", "A")
    if verbose:
        print("\n".join(w.log))

    # Scenario 2: transfer via TAKE in both directions
    w = World()
    send(w, "A", "B", "seed")
    w.events = []
    take(w, "A", "B", "takeback")
    check(w, "take by A from B", "A")
    take(w, "B", "A", "take2")
    check(w, "take by B from A", "B")

    # Scenario 3: take-back INSIDE the sender's release window
    w = World()
    w.bt("B", "--connectable", "0")   # ready
    release_for_handoff(w, "A")
    w.tick("A: 300ms settle")
    pair_after_handoff(w, "B")
    # user immediately takes back; A still dark from its release
    take(w, "A", "B", "immediate takeback")
    check(w, "take-back within release window", "A")

    # Scenario 4: peer vanishes after 'ready' -> sender rollback re-pairs
    w = World()
    w.bt("B", "--connectable", "0")   # ready succeeded, B braced
    release_for_handoff(w, "A")
    w.tick("A: settle")
    # 'connect' command to B fails; rollback on A (pairAfterHandoff manages dark)
    ok = pair_after_handoff(w, "A")
    if not ok:
        FAIL.append("rollback")
    w.tick("B: failsafe window")
    w.bt("B", "--connectable", "1")   # B's 30s failsafe
    w.tick("after failsafe")
    check(w, "rollback after failed send", "A")

    # Sensitivity check: OLD code must trip dialogs, or this model proves nothing
    w = World()
    old_send(w, "A", "B", "old")
    old_dialogs = len(w.events)
    sens = "PASS" if old_dialogs > 0 else "FAIL"
    if sens == "FAIL":
        FAIL.append("sensitivity")
    print(f"[{sens}] sensitivity: old sequence produces {old_dialogs} dialog(s) in the model")

    print()
    if FAIL:
        print(f"RESULT: {len(FAIL)} FAILURE(S): {FAIL}")
        sys.exit(1)
    print("RESULT: all scenarios pass — no Connection Request dialog is reachable "
          "in the model, trackpad lands on the right Mac every time")


if __name__ == "__main__":
    main()
