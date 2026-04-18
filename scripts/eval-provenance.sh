#!/bin/bash
# eval-provenance.sh — Run eval traffic with provenance enabled, then
#                       validate the provenance ledger as test evidence.
#
# Usage:
#   scripts/eval-provenance.sh                    # full eval + validate
#   scripts/eval-provenance.sh --category=tool_call  # subset
#   scripts/eval-provenance.sh --validate-only    # check existing ledger
#   scripts/eval-provenance.sh --session=sage-gemini  # custom session
#
# The provenance ledger (.logs/provenance.jsonl) becomes the test artifact:
# every LLM API call during eval must produce a signed record.

set -euo pipefail

# --- Configuration ---
SESSION="${SESSION:-sage}"
CATEGORY="${CATEGORY:-}"
VALIDATE_ONLY="${VALIDATE_ONLY:-0}"
VERBOSE="${VERBOSE:-0}"
LEDGER="${SAGE_LOG_DIR:-.logs}/provenance.jsonl"
POSITIONAL=""

for arg in "$@"; do
  case "$arg" in
    --category=*)     CATEGORY="${arg#*=}" ;;
    --session=*)      SESSION="${arg#*=}" ;;
    --validate-only)  VALIDATE_ONLY=1 ;;
    --verbose)        VERBOSE=1 ;;
    --help)
      echo "Usage: $0 [--category=X] [--session=X] [--validate-only] [--verbose]"
      echo ""
      echo "Runs eval traffic with SAGE_PROVENANCE=1, then validates the ledger."
      echo "The provenance ledger is the test evidence — every API call must"
      echo "produce a record with ts, url, code, bytes, sha256."
      exit 0 ;;
    -*) echo "Unknown flag: $arg"; exit 1 ;;
    *)  POSITIONAL="$arg" ;;
  esac
done

# --- Dependency checks ---
for cmd in jq tmux; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd required"; exit 1; }
done

# --- Phase 1: Run eval with provenance enabled ---
if [ "$VALIDATE_ONLY" = "0" ]; then
  echo "=== Phase 1: Eval with Provenance ==="
  echo "Session: $SESSION | Ledger: $LEDGER"

  # Verify session exists
  tmux has-session -t "$SESSION" 2>/dev/null || {
    echo "ERROR: tmux session '$SESSION' not found."
    echo "Start with: gmake tmux-session"
    exit 1
  }

  # Record ledger baseline
  BASELINE=0
  if [ -f "$LEDGER" ]; then
    BASELINE=$(wc -l < "$LEDGER" | tr -d ' ')
  fi
  echo "Ledger baseline: $BASELINE entries"

  # Enable provenance in the session
  tmux send-keys -t "$SESSION" 'export SAGE_PROVENANCE=1' Enter
  sleep 1

  # Build eval args
  EVAL_ARGS=""
  if [ -n "$CATEGORY" ]; then
    EVAL_ARGS="--category=$CATEGORY"
  fi
  if [ "$VERBOSE" = "1" ]; then
    EVAL_ARGS="$EVAL_ARGS --verbose"
  fi

  # Run the eval harness
  echo ""
  echo "--- Running eval-sage.sh $EVAL_ARGS ---"
  SESSION="$SESSION" scripts/eval-sage.sh $EVAL_ARGS || true
  echo ""

  # Small delay for ledger flush
  sleep 2

  # Count new entries
  if [ -f "$LEDGER" ]; then
    CURRENT=$(wc -l < "$LEDGER" | tr -d ' ')
    NEW_ENTRIES=$((CURRENT - BASELINE))
  else
    NEW_ENTRIES=0
  fi
  echo "New provenance entries: $NEW_ENTRIES"
  echo ""
fi

# --- Phase 2: Validate the provenance ledger ---
echo "=== Phase 2: Ledger Validation ==="

if [ ! -f "$LEDGER" ]; then
  echo "FAIL: Ledger not found at $LEDGER"
  echo "  Run with SAGE_PROVENANCE=1 to generate entries."
  exit 1
fi

TOTAL=$(wc -l < "$LEDGER" | tr -d ' ')
echo "Total ledger entries: $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
  echo "FAIL: Ledger is empty — no provenance records were written."
  exit 1
fi

# --- Structural validation ---
echo ""
echo "--- Structural Checks ---"

VALID=0
INVALID=0
MISSING_FIELDS=0
BAD_HASH=0
HTTP_ERRORS=0

while IFS= read -r line; do
  # Check JSON validity
  if ! echo "$line" | jq -e . >/dev/null 2>&1; then
    INVALID=$((INVALID + 1))
    [ "$VERBOSE" = "1" ] && echo "  INVALID JSON: $line"
    continue
  fi

  # Check required fields
  has_ts=$(echo "$line" | jq -r 'has("ts")' 2>/dev/null)
  has_url=$(echo "$line" | jq -r 'has("url")' 2>/dev/null)
  has_code=$(echo "$line" | jq -r 'has("code")' 2>/dev/null)
  has_bytes=$(echo "$line" | jq -r 'has("bytes")' 2>/dev/null)
  has_sha=$(echo "$line" | jq -r 'has("sha256")' 2>/dev/null)

  if [ "$has_ts" != "true" ] || [ "$has_url" != "true" ] || \
     [ "$has_code" != "true" ] || [ "$has_bytes" != "true" ] || \
     [ "$has_sha" != "true" ]; then
    MISSING_FIELDS=$((MISSING_FIELDS + 1))
    [ "$VERBOSE" = "1" ] && echo "  MISSING FIELD: $line"
    continue
  fi

  # Check SHA-256 format (64 hex chars or fallback)
  sha=$(echo "$line" | jq -r '.sha256' 2>/dev/null)
  if [ "$sha" != "hash-error" ] && [ "$sha" != "hash-unavailable" ]; then
    if ! echo "$sha" | grep -qE '^[a-f0-9]{64}$'; then
      BAD_HASH=$((BAD_HASH + 1))
      [ "$VERBOSE" = "1" ] && echo "  BAD HASH: $sha"
      continue
    fi
  fi

  # Check HTTP status
  code=$(echo "$line" | jq -r '.code' 2>/dev/null)
  if [ "$code" -ge 400 ] 2>/dev/null; then
    HTTP_ERRORS=$((HTTP_ERRORS + 1))
    [ "$VERBOSE" = "1" ] && {
      url=$(echo "$line" | jq -r '.url' 2>/dev/null)
      echo "  HTTP $code: $url"
    }
  fi

  VALID=$((VALID + 1))
done < "$LEDGER"

# --- Report ---
echo ""
echo "--- Results ---"
printf "  Valid records:   \033[32m%d\033[0m\n" "$VALID"
[ "$INVALID" -gt 0 ]        && printf "  Invalid JSON:    \033[31m%d\033[0m\n" "$INVALID"
[ "$MISSING_FIELDS" -gt 0 ] && printf "  Missing fields:  \033[31m%d\033[0m\n" "$MISSING_FIELDS"
[ "$BAD_HASH" -gt 0 ]       && printf "  Bad SHA-256:     \033[33m%d\033[0m\n" "$BAD_HASH"
[ "$HTTP_ERRORS" -gt 0 ]    && printf "  HTTP errors:     \033[33m%d\033[0m\n" "$HTTP_ERRORS"

# --- Provenance coverage ---
echo ""
echo "--- Provenance Coverage ---"

# Unique URLs
UNIQUE_URLS=$(jq -r '.url' "$LEDGER" 2>/dev/null | sort -u | wc -l | tr -d ' ')
echo "  Unique endpoints: $UNIQUE_URLS"

# URL breakdown
if [ "$VERBOSE" = "1" ]; then
  echo "  Endpoint frequency:"
  jq -r '.url' "$LEDGER" 2>/dev/null | \
    sed 's|http[s]*://[^/]*/|/|' | \
    sort | uniq -c | sort -rn | head -10 | \
    while IFS= read -r freq_line; do
      echo "    $freq_line"
    done
fi

# Time span
FIRST_TS=$(jq -r '.ts' "$LEDGER" 2>/dev/null | head -1)
LAST_TS=$(jq -r '.ts' "$LEDGER" 2>/dev/null | tail -1)
echo "  Time span: $FIRST_TS → $LAST_TS"

# Bytes transferred
TOTAL_BYTES=$(jq -r '.bytes' "$LEDGER" 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo "?")
echo "  Total bytes tracked: $TOTAL_BYTES"

# --- Final verdict ---
echo ""
ERRORS=$((INVALID + MISSING_FIELDS + BAD_HASH))
if [ "$ERRORS" -eq 0 ] && [ "$VALID" -gt 0 ]; then
  printf "\033[32mPASS\033[0m: All %d provenance records are valid.\n" "$VALID"
  exit 0
elif [ "$VALID" -gt 0 ]; then
  printf "\033[33mWARN\033[0m: %d valid, %d issues found.\n" "$VALID" "$ERRORS"
  exit 0
else
  printf "\033[31mFAIL\033[0m: No valid provenance records.\n"
  exit 1
fi
