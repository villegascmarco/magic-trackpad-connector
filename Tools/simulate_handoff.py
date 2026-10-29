#!/usr/bin/env python3
"""
Two-Mac Magic Trackpad handoff simulator.

Models the trackpad behavior MEASURED on real hardware (REQUIREMENTS.md,
"Hardware facts", 2026-10-28):
  - holds ONE host link key; a host can connect only with that key
  - pairing succeeds only while the trackpad holds no key (pairable), is not
    connected, and was released recently (a released trackpad stops answering
    after a few minutes — E8)
  - a host's unpair while connected sends the Virtual Cable Unplug, which the
    trackpad processes ONLY if its HID channel is already open (opens ~2 s
    after connect). Otherwise the host loses its record but the trackpad keeps
    the dead key: stranded, every host gets 0x02 until power-cycle (T6/R3).
  - a host that vanishes keeps the binding; the other host can't pair (E4)

Replays the Bluetooth recipes transcribed from
Coordinator/HandoffCoordinator.swift (release / acquireAfterRelease / claim /
pairAndConnect) and BluetoothManager.settle. "old" mode drops the HID wait
from release + pair success, as a sensitivity check: the race scenario must
strand in old mode, or the model is too lenient to prove anything.

Time is logical seconds advanced by each operation.
"""

import sys

HID_OPEN_DELAY = 2.0     # connect -> HID channel open
PAIRABLE_WINDOW = 120.0  # released trackpad keeps answering (conservative)


class World:
    def __init__(self, holder="A"):
        self.t = 0.0
        self.bound = holder           # host whose key the trackpad holds
        self.connected = holder
        self.hid_at = 0.0             # time HID opens for the current link
        self.pairable_until = 0.0
        self.record = {"A": holder == "A", "B": holder == "B"}
        self.alive = {"A": True, "B": True}

    def tick(self, s):
        self.t += s

    def stranded(self):
        return self.bound is not None and not self.record[self.bound]

    # ---- primitives (BluetoothManager) ----
    def is_connected(self, h):
        return self.connected == h

    def is_paired(self, h):
        return self.record[h]

    def hid_ready(self, h):
        return self.connected == h and self.t >= self.hid_at

    def connect(self, h):
        self.tick(0.5)
        if self.connected is None and self.bound == h and self.record[h] and self.alive[h]:
            self.connected, self.hid_at = h, self.t + HID_OPEN_DELAY
        elif self.connected != h:
            self.tick(4.5)  # page timeout

    def unpair(self, h):
        self.tick(0.1)
        self.record[h] = False
        if self.connected == h:
            if self.t >= self.hid_at:            # unplug delivered
                self.bound = None
                self.pairable_until = self.t + PAIRABLE_WINDOW
                self.tick(0.8)
            else:                                # unplug lost -> stranded
                self.tick(2.8)
            self.connected = None

    def pair(self, h):
        self.tick(1.0)
        if self.bound is None and self.connected is None and self.t < self.pairable_until:
            self.bound, self.record[h] = h, True
            self.connected, self.hid_at = h, self.t + HID_OPEN_DELAY
            return True
        self.tick(1.0 if self.bound is not None else 14.0)  # 0x02 vs timeout
        return False

    def settle(self, h, old):
        if old:
            return self.is_connected(h)
        deadline = self.t + 12
        while not self.hid_ready(h):
            if not self.is_connected(h) or self.t >= deadline:
                return False
            self.tick(0.2)
        self.tick(1.0)
        return self.is_connected(h)


# ---- recipes, transcribed from HandoffCoordinator.swift ----

def release(w, h, old=False, confirm=True):
    # confirm=False (shutdown) only skips waiting for the disconnect after
    # the unplug — not modeled, the unplug itself is identical.
    if not w.is_paired(h):
        return True
    if not w.is_connected(h):
        w.connect(h)
    if not w.is_connected(h):
        return False
    if not w.settle(h, old):
        return False
    w.unpair(h)
    return True


def pair_and_connect(w, h, old=False):
    if not w.pair(h):
        return False
    if not w.is_connected(h):
        w.connect(h)
        if not w.is_connected(h):
            return False
    return w.settle(h, old)


def acquire_after_release(w, h, old=False):
    if w.is_connected(h):
        return True
    if w.is_paired(h):
        w.unpair(h)
    for _ in range(6):
        if pair_and_connect(w, h, old):
            return True
        w.tick(1)
    return False


def claim(w, h, old=False):
    if w.is_connected(h):
        return True
    if w.is_paired(h):
        w.connect(h)
        if w.is_connected(h):
            return w.settle(h, old)
    return pair_and_connect(w, h, old)


# ---- flows (HandoffCoordinator.push / pull) ----

def push(w, src, dst, old=False):
    if not release(w, src, old):
        return "refused"                        # nothing changed
    w.tick(0.5)
    if acquire_after_release(w, dst, old):
        return "ok"
    return "rolled back" if acquire_after_release(w, src, old) else "lost"


def pull(w, me, peer, old=False):
    if not release(w, peer, old):
        return "refused"
    return "ok" if acquire_after_release(w, me, old) else "lost"


# ---- scenarios ----

def check(name, cond, failures):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        failures.append(name)


def run(old):
    f = []
    w = World("A")
    check("push A->B", push(w, "A", "B", old) == "ok" and w.connected == "B", f)
    check("pull back to A", pull(w, "A", "B", old) == "ok" and w.connected == "A", f)

    w = World("A")  # holder leaves right after receiving (sleep/lock race)
    r1 = push(w, "A", "B", old)
    r2 = push(w, "B", "A", old)
    check("race: immediate re-handoff", r1 == r2 == "ok" and w.connected == "A" and not w.stranded(), f)

    w = World("A")  # receiver dead after release -> rollback to sender
    w.alive["B"] = False
    w.pair = (lambda orig: (lambda h: False if h == "B" else orig(h)))(w.pair)
    check("receiver fails -> rolled back to sender", push(w, "A", "B", old) == "rolled back" and w.connected == "A", f)

    w = World("B")  # orphaned by a release, orchestrator claims within 60 s
    release(w, "B", old)
    w.tick(60)
    check("orchestrator recovers orphan within 60 s", claim(w, "A", old) and w.connected == "A", f)

    w = World("A")  # owner vanishes holding it: nobody else can take it (E4)
    w.alive["A"], w.connected = False, None
    check("vanished owner: other Mac can't claim (expected)", not claim(w, "B", old) and w.bound == "A", f)
    w.alive["A"] = True
    check("vanished owner returns: reclaims with its key", claim(w, "A", old) and w.connected == "A", f)

    w = World("A")  # claim never strands
    for _ in range(3):
        claim(w, "B", old)
    check("claim from non-holder leaves holder intact", w.connected == "A" and not w.stranded(), f)
    return f


def main():
    print("== new (current Swift recipes)")
    new = run(old=False)
    print("== old (no HID wait) — sensitivity check, must fail the race")
    old = run(old=True)
    sensitive = any("race" in n for n in old)
    if not sensitive:
        print("MODEL TOO LENIENT: old recipes pass the race scenario")
    if new or not sensitive:
        sys.exit(1)
    print("all scenarios pass")


if __name__ == "__main__":
    main()
