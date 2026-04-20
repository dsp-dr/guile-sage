#!/bin/sh
# demo.sh — scripted asciinema demo of guile-sage (v0.9.0+)
#
# Usage: asciinema rec -c scripts/demo.sh --rows 36 --cols 110 docs/images/demo.cast
#
# Showcases core primitives against the examples/petstore/ project:
# - /tools catalogue of built-in tools (33+)
# - /hooks listing PreToolUse + PostToolUse pair (SAGE_DEMO_HOOKS=1)
# - fetch_url with XML envelope + scratch storage for large bodies
# - scratch_get paged retrieval
# - sage_task_push LIFO decomposition
# - edit_file with unified-diff output
# - /context + /compact + /stats (local usage ledger)
#
# Uses local Ollama with llama3.2. MCP is disabled; LSP contracts are
# specified in docs/ but not implemented yet.

set -e

# Clean environment — never inherit host credentials or MCP config.
unset OPENAI_API_KEY OPENAI_API_BASE GEMINI_API_KEY LITELLM_KEY
export USER=sage
export SAGE_PROVIDER=ollama
export SAGE_OLLAMA_HOST=http://localhost:11434
export SAGE_MODEL=llama3.2:latest
export MODEL_TIER_FAST=llama3.2:latest
export MODEL_TIER_STANDARD=llama3.2:latest
export SAGE_YOLO_MODE=1
export SAGE_MCP_DISABLE=1
export SAGE_NO_PREFETCH=1
export SAGE_DEMO_HOOKS=1
export TERM=xterm-256color

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/examples/petstore"

exec expect <<ENDEXPECT
  set timeout 90
  log_user 1
  spawn guile -L $REPO/src -c "(use-modules (sage repl)) (repl-start)"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 1. /hooks — PreToolUse + PostToolUse pair pre-registered
  send -- "/hooks\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 2. read_file — PostToolUse observer fires visibly
  send -- "use read_file once on README.md then answer in one sentence.\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 3. search_files — second tool call with observer trace
  send -- "use search_files once to grep 'describe' in *.py.\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 4. edit_file — unified-diff summary visible
  send -- "use edit_file on pet.py: search='age: Optional[int] = None' replace='age: Optional[int] = None  # years'\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 5. /context — inspect conversation token usage
  send -- "/context\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 6. /compact — core primitive, keep last 2 messages
  send -- "/compact 2\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 7. /stats — local usage ledger aggregate
  send -- "/stats\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 8. Post-compaction LLM turn — memory survives
  send -- "one-line docstring for the Pet class, based on what you read.\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  send -- "/exit\r"
  expect eof
ENDEXPECT
