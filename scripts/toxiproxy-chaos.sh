#!/bin/sh
# toxiproxy-chaos.sh --- deterministic network-fault validation for guile-sage.
#
# Concrete implementation of docs/CHAOS-TOXIPROXY-SPEC.org. Opt-in: NOT part of
# `gmake check`/`lint`. Needs the toxiproxy package and a reachable backend.
#
#   pkg install toxiproxy-server toxiproxy-cli      # FreeBSD
#
# Usage:
#   scripts/toxiproxy-chaos.sh up          # start server + register proxies
#   scripts/toxiproxy-chaos.sh scenario N  # apply toxic N and assert the boundary
#   scripts/toxiproxy-chaos.sh all         # up; run every scenario; down
#   scripts/toxiproxy-chaos.sh down        # remove toxics + stop server
#
# Config via env (all have defaults):
#   OLLAMA_UPSTREAM   real backend behind the proxy   (default 127.0.0.1:11434)
#   TOXI_LISTEN       sage-facing listen addr          (default 127.0.0.1:21434)
#   TOXI_API          toxiproxy control API            (default 127.0.0.1:8474)
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
LOGDIR="$ROOT/.logs"; mkdir -p "$LOGDIR"
SRV_LOG="$LOGDIR/toxiproxy-server.log"
SRV_PIDFILE="$LOGDIR/toxiproxy-server.pid"

OLLAMA_UPSTREAM="${OLLAMA_UPSTREAM:-127.0.0.1:11434}"
TOXI_LISTEN="${TOXI_LISTEN:-127.0.0.1:21434}"
TOXI_API="${TOXI_API:-127.0.0.1:8474}"
PROXY=ollama

CLI="toxiproxy-cli -h $TOXI_API"

require_toxiproxy() {
  if ! command -v toxiproxy-server >/dev/null 2>&1 || \
     ! command -v toxiproxy-cli   >/dev/null 2>&1; then
    echo "SKIP: toxiproxy not installed."
    echo "  FreeBSD: pkg install toxiproxy-server toxiproxy-cli"
    echo "  other:   go install github.com/Shopify/toxiproxy/v2/cmd/...@latest"
    # Clean skip, not a failure: this is an opt-in target. A non-zero exit is
    # reserved for an actual chaos failure (REPL died under a toxic).
    exit 0
  fi
}

up() {
  require_toxiproxy
  if [ -f "$SRV_PIDFILE" ] && kill -0 "$(cat "$SRV_PIDFILE")" 2>/dev/null; then
    echo "toxiproxy-server already running (pid $(cat "$SRV_PIDFILE"))"
  else
    echo "starting toxiproxy-server on $TOXI_API ..."
    toxiproxy-server -host "${TOXI_API%:*}" -port "${TOXI_API##*:}" \
      >"$SRV_LOG" 2>&1 &
    echo $! >"$SRV_PIDFILE"
    # wait for the control API to answer
    i=0; until $CLI list >/dev/null 2>&1 || [ "$i" -ge 20 ]; do i=$((i+1)); sleep 0.2; done
  fi
  $CLI create -l "$TOXI_LISTEN" -u "$OLLAMA_UPSTREAM" "$PROXY" 2>/dev/null \
    || echo "proxy '$PROXY' already exists"
  echo "proxy '$PROXY': $TOXI_LISTEN -> $OLLAMA_UPSTREAM"
  echo "point sage at it:  SAGE_OLLAMA_HOST=http://$TOXI_LISTEN"
}

clear_toxics() { $CLI toxic list "$PROXY" 2>/dev/null | awk '/name:/{print $2}' \
  | while read -r t; do $CLI toxic delete -n "$t" "$PROXY" 2>/dev/null || true; done; }

down() {
  command -v toxiproxy-cli >/dev/null 2>&1 && $CLI delete "$PROXY" 2>/dev/null || true
  if [ -f "$SRV_PIDFILE" ]; then
    kill "$(cat "$SRV_PIDFILE")" 2>/dev/null || true
    rm -f "$SRV_PIDFILE"
    echo "toxiproxy-server stopped"
  fi
}

# --- assertion helper: launch sage in tmux against the proxy, return banner+ALIVE
probe_banner() {
  tmux kill-session -t chaos 2>/dev/null || true
  tmux new-session -d -s chaos -x 200 -y 50
  tmux send-keys -t chaos \
    "cd $ROOT && SAGE_OLLAMA_HOST=http://$TOXI_LISTEN SAGE_PROVIDER=ollama SAGE_MODEL=qwen3-coder SAGE_YOLO_MODE=1 guile3 -L src -c '(use-modules (sage repl)) (repl-start)'" Enter
}

scenario() {
  require_toxiproxy
  clear_toxics
  case "$1" in
    1) echo "[#1] latency 8000ms -> probe must fast-fail at ~5s (connect-timeout)"
       $CLI toxic add -t latency -a latency=8000 "$PROXY" ;;
    2) echo "[#2] timeout 0 (black-hole) -> clean connection-failed error, no hang"
       $CLI toxic add -t timeout -a timeout=0 "$PROXY" ;;
    3) echo "[#3] reset_peer 1500ms mid-stream -> streaming survives, no SIGSEGV"
       $CLI toxic add -t reset_peer -a timeout=1500 "$PROXY" ;;
    4) echo "[#4] bandwidth 64 + slicer -> SSE data: reassembly under fragmentation"
       $CLI toxic add -t bandwidth -a rate=64 "$PROXY"
       $CLI toxic add -t slicer -a average_size=16 -a delay=1000 "$PROXY" ;;
    *) echo "unknown scenario '$1' (1-4)"; exit 2 ;;
  esac
  T0=$(date +%s)
  probe_banner
  sleep 12
  PANE=$(tmux capture-pane -t chaos -p 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -8)
  ALIVE=$(pgrep -f 'repl-start' >/dev/null && echo ALIVE || echo DEAD)
  ELAPSED=$(( $(date +%s) - T0 ))
  tmux kill-session -t chaos 2>/dev/null || true
  echo "--- result (elapsed ~${ELAPSED}s, $ALIVE) ---"
  echo "$PANE"
  [ "$ALIVE" = ALIVE ] || { echo "FAIL: REPL died (possible segfault)"; return 1; }
}

case "${1:-}" in
  up)        up ;;
  down)      down ;;
  scenario)  shift; scenario "${1:?scenario N}" ;;
  all)       up; rc=0; for n in 1 2 3 4; do scenario "$n" || rc=1; done; down; exit $rc ;;
  *) echo "usage: $0 {up|down|scenario N|all}"; exit 2 ;;
esac
