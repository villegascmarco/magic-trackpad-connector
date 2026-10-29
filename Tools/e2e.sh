#!/bin/bash
# End-to-end test on the REAL two-Mac setup (see REQUIREMENTS.md).
# Run on the main Mac; the other Mac is reached as ssh host "$PEER" (default mbp).
# Both Macs must run the app with automatic handoff on, trackpad on this Mac.
#   Tools/e2e.sh            # all scenarios
#   Tools/e2e.sh fallback   # one scenario
set -u
cd "$(dirname "$0")/.."
PEER="${PEER:-mbp}"
WINS="${WINS:-}" # optional path to a CGWindowList owner lister (dialog check)
pass=0; fail=0
[[ -n "$WINS" ]] && scp -q "$WINS" "$PEER:/tmp/mtc-wins"

L() { Tools/ctl.sh "$1"; }
R() { Tools/ctl.sh -r "$PEER" "$1"; }
connected() { grep -q '"connected":true'; }
where() {
  local a b
  L '{"action":"bt","op":"state"}' | connected && a=1 || a=0
  R '{"action":"bt","op":"state"}' | connected && b=1 || b=0
  case "$a$b" in 10) echo main;; 01) echo peer;; 00) echo nowhere;; *) echo both;; esac
}
idle() { "$@" '{"action":"status"}' | sed -E 's/.*"idle":([0-9]+).*/\1/'; }
dialogs() { # system dialog processes (Connection Request, permission prompts)
  [[ -z "$WINS" ]] && return 0
  local sys='UserNotificationCenter|BluetoothUIServer|bluetoothuserd|CoreServicesUIAgent|SecurityAgent|universalAccessAuthWarn'
  local d; d=$( { "$WINS"; ssh "$PEER" /tmp/mtc-wins; } | cut -f1 | grep -E "^($sys)$" | sort -u | tr '\n' ' ')
  [[ -n "$d" ]] && { echo "    DIALOG on screen: $d"; fail=$((fail+1)); }
  return 0
}
expect() { # name expected-location [timeout-seconds]
  local name="$1" want="$2" t="${3:-0}" got
  got=$(where)
  while [[ "$got" != "$want" && $t -gt 0 ]]; do sleep 3; t=$((t-3)); got=$(where); done
  if [[ "$got" == "$want" ]]; then echo "PASS $name (on $got)"; pass=$((pass+1))
  else echo "FAIL $name: expected $want, got $got"; fail=$((fail+1)); fi
  dialogs
}
ensure_main() { [[ $(where) == main ]] || L '{"action":"pull"}' >/dev/null; }
ensure_peer() { [[ $(where) == peer ]] || L '{"action":"push"}' >/dev/null; }

s_toggle() {
  ensure_main
  L '{"action":"toggle"}' >/dev/null; expect "R2 toggle main->peer" peer
  R '{"action":"toggle"}' >/dev/null; expect "R2 toggle peer->main" main
  R '{"action":"toggle"}' >/dev/null; expect "R2 pull from peer side" peer
  L '{"action":"toggle"}' >/dev/null; expect "R2 pull from main side" main
}
s_race() { # holder leaves right after receiving (the original T6 failure)
  ensure_main
  L '{"action":"push"}' >/dev/null
  R '{"action":"event","name":"sleep"}' >/dev/null
  expect "R5 sleep right after receiving" main
}
s_lock() {
  ensure_main
  L '{"action":"event","name":"lock"}' >/dev/null
  expect "R4 lock hands to unlocked peer" peer
}
s_sleep() {
  ensure_peer
  R '{"action":"event","name":"sleep"}' >/dev/null
  expect "R5 peer sleep hands to main" main
}
s_arrive() {
  ensure_peer
  local pi; pi=$(idle R)
  L '{"action":"event","name":"arrive"}' >/dev/null
  if (( pi >= 120 )); then expect "R9 arrive takes from idle peer (idle ${pi}s)" main
  else expect "R8 arrive leaves active peer alone (idle ${pi}s)" peer; fi
  ensure_main
  local mi; mi=$(idle L)
  R '{"action":"event","name":"arrive"}' >/dev/null
  if (( mi < 120 )); then expect "R8 peer arrive leaves active main alone (idle ${mi}s)" main
  else expect "R9 peer arrive takes from idle main (idle ${mi}s)" peer; fi
}
s_shutdown() { # fast path used when macOS is shutting down / restarting
  ensure_peer
  local t0=$SECONDS
  R '{"action":"event","name":"shutdown"}' >/dev/null
  expect "R5 peer shutdown hands to main" main 30
  echo "    (took $((SECONDS-t0))s)"
}
s_launch() { # R8: a Mac starting up never takes from an unlocked holder
  ensure_main
  R '{"action":"event","name":"launch"}' >/dev/null
  expect "R8 peer launch leaves unlocked holder alone" main
}
s_abandon() { # sender killed right after releasing (shutdown) -> receiver picks it up
  ensure_peer
  R '{"action":"push","abandon":true}' >/dev/null
  expect "R5 sender dies mid-handoff -> receiver takes it" main 45
}
s_fallback() { # devices released into the void -> orchestrator recovers them
  ensure_peer
  R '{"action":"bt","op":"release"}' >/dev/null
  expect "R3 main Mac recovers orphaned devices" main 90
}

scenarios="${*:-toggle race lock sleep shutdown arrive launch abandon fallback}"
for s in $scenarios; do "s_$s"; done
echo "== $pass passed, $fail failed"
[[ $fail -eq 0 ]]
