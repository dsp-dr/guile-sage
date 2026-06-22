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
#   UPSTREAM   real backend behind the proxy   (default 127.0.0.1:11434)
#   TOXI_LISTEN       sage-facing listen addr          (default 127.0.0.1:21434)
#   TOXI_API          toxiproxy control API            (default 127.0.0.1:8474)
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
LOGDIR="$ROOT/.logs"; mkdir -p "$LOGDIR"
SRV_LOG="$LOGDIR/toxiproxy-server.log"
SRV_PIDFILE="$LOGDIR/toxiproxy-server.pid"

# Backend behind the proxy. Two modes:
#   CHAOS_PROVIDER=ollama  (default) — upstream is a direct ollama /api host
#   CHAOS_PROVIDER=openai            — upstream is an OpenAI-shape gateway
#                                      (e.g. LiteLLM); set CHAOS_OPENAI_KEY.
# From a host that cannot reach a LAN ollama directly (firewall) but CAN reach a
# LiteLLM gateway, use openai mode — that is how this harness was validated.
CHAOS_PROVIDER="${CHAOS_PROVIDER:-ollama}"
UPSTREAM="${UPSTREAM:-127.0.0.1:11434}"
TOXI_LISTEN="${TOXI_LISTEN:-127.0.0.1:21434}"
TOXI_API="${TOXI_API:-127.0.0.1:8474}"
PROXY=backend

CLI="toxiproxy-cli -h $TOXI_API"

# sage's config-load-dotenv reloads $ROOT/.env over the shell env, which would
# clobber the inline chaos provider/host vars. Stash .env for the duration of
# the run and restore it on exit (even on error/interrupt).
ENV_STASH="$ROOT/.env.chaos-stash"
restore_env() { [ -f "$ENV_STASH" ] && mv -f "$ENV_STASH" "$ROOT/.env" || true; }
stash_env()   { [ -f "$ROOT/.env" ] && mv -f "$ROOT/.env" "$ENV_STASH" || true; }
trap restore_env EXIT INT TERM

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
  $CLI create -l "$TOXI_LISTEN" -u "$UPSTREAM" "$PROXY" 2>/dev/null \
    || echo "proxy '$PROXY' already exists"
  echo "proxy '$PROXY': $TOXI_LISTEN -> $UPSTREAM"
  if [ "$CHAOS_PROVIDER" = openai ]; then
    echo "point sage at it:  SAGE_PROVIDER=openai SAGE_OPENAI_BASE=http://$TOXI_LISTEN/v1"
  else
    echo "point sage at it:  SAGE_PROVIDER=ollama SAGE_OLLAMA_HOST=http://$TOXI_LISTEN"
  fi
}

# Reset to a clean baseline (enabled, no toxics) by recreating the proxy.
# toxiproxy-cli has only `toggle`, so recreate is the reliable way to reset.
reset_proxy() {
  $CLI delete "$PROXY" 2>/dev/null || true
  $CLI create -l "$TOXI_LISTEN" -u "$UPSTREAM" "$PROXY" >/dev/null 2>&1 || true
}

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
  stash_env   # ensure the repo .env does not override the inline chaos vars
  tmux kill-session -t chaos 2>/dev/null || true
  tmux new-session -d -s chaos -x 200 -y 50
  if [ "$CHAOS_PROVIDER" = openai ]; then
    SAGE_ENV="SAGE_PROVIDER=openai SAGE_OPENAI_BASE=http://$TOXI_LISTEN/v1 SAGE_OPENAI_API_KEY=${CHAOS_OPENAI_KEY:-x} SAGE_MODEL=${CHAOS_MODEL:-ollama-qwen2.5-coder}"
  else
    SAGE_ENV="SAGE_PROVIDER=ollama SAGE_OLLAMA_HOST=http://$TOXI_LISTEN SAGE_MODEL=${CHAOS_MODEL:-llama3.2}"
  fi
  # NOTE: sage reloads .env over the shell env, so run from a dir whose .env
  # does not override these — or invoke with a chaos-specific .env. Here we pass
  # the vars inline for a fresh process that has no .env in CWD.
  tmux send-keys -t chaos \
    "cd $ROOT && env $SAGE_ENV SAGE_HTTP_MAX_RETRIES=2 SAGE_YOLO_MODE=1 guile3 -L src -c '(use-modules (sage repl)) (repl-start)'" Enter
}

scenario() {
  require_toxiproxy
  reset_proxy
  case "$1" in
    1) echo "[#1] proxy disabled (connection refused) -> fast-fail + clean error"
       # A latency toxic delays the RESPONSE (bounded by curl --max-time), so it
       # does NOT exercise --connect-timeout. Refusing the connection does:
       # curl fails the connect fast, sage surfaces a clean connection error.
       $CLI toggle "$PROXY" >/dev/null ;;
    2) echo "[#2] latency 3000ms -> slow backend tolerated, REPL survives"
       $CLI toxic add -t latency -a latency=3000 "$PROXY" ;;
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
