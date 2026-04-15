#!/bin/bash
# eval-sage.sh — Drive test traffic into a running sage REPL and evaluate responses
#
# Usage:
#   scripts/eval-sage.sh [tests/eval/traffic-cases.json]
#   scripts/eval-sage.sh --category=tool_call
#   scripts/eval-sage.sh --dry-run
#   scripts/eval-sage.sh --session=sage-test --verbose
#
# Requires: bash 4+, jq, tmux, running sage session

set -euo pipefail

# --- Configuration ---
SESSION="${SESSION:-sage}"
CATEGORY="${CATEGORY:-}"
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
POLL_INTERVAL=2
POSITIONAL=""

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --category=*) CATEGORY="${arg#*=}" ;;
    --session=*)  SESSION="${arg#*=}" ;;
    --verbose)    VERBOSE=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --help)
      echo "Usage: $0 [cases.json] [--category=X] [--session=X] [--verbose] [--dry-run]"
      exit 0 ;;
    -*) echo "Unknown flag: $arg"; exit 1 ;;
    *)  POSITIONAL="$arg" ;;
  esac
done

CASES_FILE="${POSITIONAL:-tests/eval/traffic-cases.json}"

# --- Dependency checks ---
for cmd in jq tmux; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd required"; exit 1; }
done

if [ "$DRY_RUN" = "0" ]; then
  tmux has-session -t "$SESSION" 2>/dev/null || {
    echo "ERROR: tmux session '$SESSION' not found. Start sage first."
    exit 1
  }
fi

[ -f "$CASES_FILE" ] || { echo "ERROR: $CASES_FILE not found"; exit 1; }

# --- Counters ---
TOTAL=0; PASS=0; NEUTRAL=0; FAIL=0

# --- Helpers ---
strip_ansi() {
  sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed 's/\x1b\].*\x07//g'
}

capture_pane() {
  tmux capture-pane -t "$SESSION" -p -S -300 | strip_ansi
}

count_prompts() {
  local n
  n=$(echo "$1" | grep -c 'sage\[' 2>/dev/null || true)
  echo "${n:-0}"
}

wait_for_response() {
  local max_wait="$1"
  local baseline_prompts="$2"
  local elapsed=0

  while [ "$elapsed" -lt "$max_wait" ]; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    local pane
    pane=$(capture_pane)
    local current_prompts
    current_prompts=$(count_prompts "$pane")
    if [ "$current_prompts" -gt "$baseline_prompts" ]; then
      echo "$pane"
      return 0
    fi
  done
  # Timeout — return whatever we have
  capture_pane
  return 1
}

extract_new_output() {
  local full_output="$1"
  local baseline_lines="$2"
  echo "$full_output" | tail -n +"$((baseline_lines + 1))"
}

# --- Evaluation ---
evaluate_case() {
  local output="$1"
  local expect_tools="$2"
  local expect_pattern="$3"
  local chain_min="$4"
  local chain_max="$5"
  local expect_error="$6"
  local expect_guardrail="$7"

  # Extract observed signals
  local tools_found
  tools_found=$(echo "$output" | grep -oP '\[Tool: \K[^\]]+' 2>/dev/null || true)
  local chain_length
  chain_length=$(echo "$output" | grep -c '\[Tool:' 2>/dev/null || true)
  chain_length=${chain_length:-0}
  local has_error
  has_error=$(echo "$output" | grep -c '^Error:' 2>/dev/null || true)
  has_error=${has_error:-0}
  local has_guardrail
  has_guardrail=$(echo "$output" | grep -cE 'BLOCKED by policy|Guardrails:|blocked|guardrail' 2>/dev/null || true)
  has_guardrail=${has_guardrail:-0}

  # Guardrail test
  if [ "$expect_guardrail" = "true" ]; then
    if [ "$has_guardrail" -gt 0 ]; then
      echo "PASS"
    else
      # Model might have just refused without guardrail header
      if [ -n "$expect_pattern" ] && echo "$output" | grep -qiE "$expect_pattern" 2>/dev/null; then
        echo "NEUTRAL"
      else
        echo "FAIL"
      fi
    fi
    return
  fi

  # Unexpected error
  if [ "$expect_error" = "false" ] && [ "$has_error" -gt 0 ]; then
    echo "FAIL"
    return
  fi

  # Tool-based evaluation
  if [ -n "$expect_tools" ] && [ "$expect_tools" != "[]" ]; then
    local all_found=1
    local some_found=0
    for tool in $(echo "$expect_tools" | jq -r '.[]' 2>/dev/null); do
      if echo "$tools_found" | grep -q "$tool" 2>/dev/null; then
        some_found=1
      else
        all_found=0
      fi
    done

    local pattern_ok=1
    if [ -n "$expect_pattern" ]; then
      echo "$output" | grep -qiE "$expect_pattern" 2>/dev/null || pattern_ok=0
    fi

    local chain_ok=0
    if [ "$chain_length" -ge "$chain_min" ] && [ "$chain_length" -le "$chain_max" ]; then
      chain_ok=1
    fi

    if [ "$all_found" = "1" ] && [ "$pattern_ok" = "1" ] && [ "$chain_ok" = "1" ]; then
      echo "PASS"
    elif [ "$some_found" = "1" ] || [ "$pattern_ok" = "1" ]; then
      echo "NEUTRAL"
    else
      echo "FAIL"
    fi
    return
  fi

  # Planning (no tools expected)
  local pattern_ok=1
  if [ -n "$expect_pattern" ]; then
    echo "$output" | grep -qiE "$expect_pattern" 2>/dev/null || pattern_ok=0
  fi

  # Allow optional tool use within chain range
  if [ "$chain_length" -ge "$chain_min" ] && [ "$chain_length" -le "$chain_max" ]; then
    if [ "$pattern_ok" = "1" ]; then
      echo "PASS"
    else
      echo "NEUTRAL"
    fi
  else
    # Unexpected tool call or too many
    if [ "$chain_length" -gt "$chain_max" ]; then
      echo "NEUTRAL"  # Model was thorough, not wrong
    else
      echo "NEUTRAL"
    fi
  fi
}

# --- Main ---
echo "=== guile-sage Eval Traffic Results ==="
model=$(jq -r '.meta.description // "unknown"' "$CASES_FILE")
echo "Cases: $CASES_FILE | Session: $SESSION | Date: $(date +%Y-%m-%d)"
echo

categories=$(jq -r '[.cases[].category] | unique | .[]' "$CASES_FILE")

for cat in $categories; do
  # Filter by --category if specified
  if [ -n "$CATEGORY" ] && [ "$cat" != "$CATEGORY" ]; then
    continue
  fi

  echo "--- $cat ---"

  # Reset session between categories
  if [ "$DRY_RUN" = "0" ]; then
    tmux send-keys -t "$SESSION" "/reset" Enter
    sleep 2
  fi

  # Iterate cases in this category
  jq -c ".cases[] | select(.category == \"$cat\")" "$CASES_FILE" | while IFS= read -r case_json; do
    id=$(echo "$case_json" | jq -r '.id')
    prompt=$(echo "$case_json" | jq -r '.prompt')
    hypothesis=$(echo "$case_json" | jq -r '.hypothesis')
    expect_tools=$(echo "$case_json" | jq -c '.expect_tools')
    expect_pattern=$(echo "$case_json" | jq -r '.expect_pattern')
    chain_min=$(echo "$case_json" | jq -r '.expect_chain_length[0]')
    chain_max=$(echo "$case_json" | jq -r '.expect_chain_length[1]')
    expect_error=$(echo "$case_json" | jq -r '.expect_error')
    expect_guardrail=$(echo "$case_json" | jq -r '.expect_guardrail')
    max_wait=$(echo "$case_json" | jq -r '.max_wait_seconds')

    if [ "$DRY_RUN" = "1" ]; then
      printf "  %-5s DRY-RUN  %-20s \"%s\"\n" "$id" "[$expect_tools]" "$prompt"
      continue
    fi

    # Record baseline prompt count
    before_prompts=$(capture_pane | grep -c 'sage\[' || true)
    before_prompts=${before_prompts:-0}

    # Send prompt
    tmux send-keys -t "$SESSION" "$prompt" Enter

    # Wait for new prompt to appear (response complete)
    elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
      now_prompts=$(capture_pane | grep -c 'sage\[' || true)
      now_prompts=${now_prompts:-0}
      [ "$now_prompts" -gt "$before_prompts" ] && break
    done

    # Capture full pane and extract the last response block
    capture_pane > "/tmp/sage-eval-pane-$$"
    # Get everything between the second-to-last and last sage prompt
    new_output=$(awk '/sage\[/{buf=prev; prev=""} {prev=prev $0 "\n"} END{printf "%s", buf prev}' "/tmp/sage-eval-pane-$$")
    rm -f "/tmp/sage-eval-pane-$$"

    # Evaluate
    result=$(evaluate_case "$new_output" "$expect_tools" "$expect_pattern" \
                           "$chain_min" "$chain_max" "$expect_error" "$expect_guardrail")

    # Extract tool info for display
    tools_display=$(echo "$new_output" | grep -o '\[Tool: [^]]*' 2>/dev/null | sed 's/\[Tool: //' | paste -sd, - || echo "none")
    chain_count=$(echo "$new_output" | grep -c '\[Tool:' 2>/dev/null || true)
    chain_count=${chain_count:-0}

    if [ "$chain_count" -gt 0 ]; then
      tool_info="[$tools_display, ${chain_count} steps]"
    else
      tool_info="[no tools]"
    fi

    # Color output
    case "$result" in
      PASS)    color="\033[32m" ;;  # green
      NEUTRAL) color="\033[33m" ;;  # yellow
      FAIL)    color="\033[31m" ;;  # red
      *)       color="" ;;
    esac
    reset="\033[0m"

    printf "  %-5s ${color}%-8s${reset} %-30s \"%s\"\n" "$id" "$result" "$tool_info" \
      "$(echo "$prompt" | head -c 50)"

    if [ "$VERBOSE" = "1" ]; then
      echo "    Hypothesis: $hypothesis"
      echo "    Output (last 5 lines):"
      echo "$new_output" | tail -5 | sed 's/^/      /'
      echo
    fi

    # Update counters (subshell workaround: write to temp file)
    echo "$result" >> "/tmp/sage-eval-results-$$"

    # Compact between heavy tests to prevent context overflow
    if [ "$cat" = "chain" ] || [ "$cat" = "synthesis" ]; then
      tmux send-keys -t "$SESSION" "/compact 2" Enter
      sleep 2
    fi
  done

  echo
done

# --- Summary ---
if [ "$DRY_RUN" = "1" ]; then
  echo "--- Dry Run Complete (no prompts sent) ---"
  exit 0
fi

results_file="/tmp/sage-eval-results-$$"
if [ -f "$results_file" ]; then
  TOTAL=$(wc -l < "$results_file" | tr -d ' ')
  PASS=$(grep -c "^PASS$" "$results_file" 2>/dev/null || true)
  PASS=${PASS:-0}
  NEUTRAL=$(grep -c "^NEUTRAL$" "$results_file" 2>/dev/null || true)
  NEUTRAL=${NEUTRAL:-0}
  FAIL=$(grep -c "^FAIL$" "$results_file" 2>/dev/null || true)
  FAIL=${FAIL:-0}
  rm -f "$results_file"
fi

echo "--- Summary ---"
printf "PASS: \033[32m%d\033[0m  NEUTRAL: \033[33m%d\033[0m  FAIL: \033[31m%d\033[0m  Total: %d\n" \
  "$PASS" "$NEUTRAL" "$FAIL" "$TOTAL"
echo

exit "$FAIL"
