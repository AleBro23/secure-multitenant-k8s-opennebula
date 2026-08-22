#!/usr/bin/env bash
set -uo pipefail

# port-forward.sh — exposes both tenant webapps on the Azure lab VM host,
# so they can be reached from a laptop via SSH tunnel.
# Safe to re-run: kills any previous port-forward before starting new ones.

PIDFILE_ALPHA=/tmp/pf-alpha.pid
PIDFILE_BETA=/tmp/pf-beta.pid
LOG_ALPHA=/tmp/pf-alpha.log
LOG_BETA=/tmp/pf-beta.log

stop_if_running() {
  local pidfile=$1
  if [ -f "$pidfile" ]; then
    local pid
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Stopping existing port-forward (PID $pid)..."
      kill "$pid"
      sleep 1
    fi
    rm -f "$pidfile"
  fi
}

echo "==> Stopping any existing port-forwards..."
stop_if_running "$PIDFILE_ALPHA"
stop_if_running "$PIDFILE_BETA"

echo "==> Starting port-forward for team-alpha (localhost:5000)..."
nohup kubectl port-forward -n team-alpha svc/webapp 5000:5000 --address 0.0.0.0 > "$LOG_ALPHA" 2>&1 &
echo $! > "$PIDFILE_ALPHA"

echo "==> Starting port-forward for team-beta (localhost:5001)..."
nohup kubectl port-forward -n team-beta svc/webapp 5001:5000 --address 0.0.0.0 > "$LOG_BETA" 2>&1 &
echo $! > "$PIDFILE_BETA"

sleep 2

echo ""
echo