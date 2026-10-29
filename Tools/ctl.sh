#!/bin/bash
# Send one JSON request to the app's loopback control port and print the reply.
#   Tools/ctl.sh '{"action":"status"}'               # this Mac
#   Tools/ctl.sh -r mbp '{"action":"log","count":40}' # another Mac via ssh
# Local-only actions: push pull toggle reconcile event auto config log bt
PORT="${MTC_PORT:-7890}"
if [[ "$1" == "-r" ]]; then
  host="$2"; shift 2
  printf '%s\n' "$1" | ssh "$host" "nc -w 120 localhost $PORT"
else
  printf '%s\n' "$1" | nc -w 120 localhost "$PORT"
fi
