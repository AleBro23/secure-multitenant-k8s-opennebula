#!/usr/bin/env bash
set -uo pipefail

# stop-port-forward.sh — stops the port-forward processes started by
# port-forward.sh, cleaning up PID files.

PIDFILE_ALPHA=/tmp/pf-alpha.pid
PIDFILE_BETA=/tmp/pf-beta.pid

stop_if_running() {
  local name=$1
  local pidfile=$2
  if [ -f "$pidfile" ]; then
    local pid
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      echo "$name: stopped (PID $pid)"
    else
      echo "$name: not running (stale PID file removed)"
    fi
    rm -f "$pidfile"
  else
    echo "$name: no PID file found, nothing to stop"
  fi
}

stop_if_running "team-alpha" "$PIDFILE_ALPHA"
stop_if_running "team-beta" "$PIDFILE_BETA"