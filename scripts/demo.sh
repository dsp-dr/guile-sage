#!/bin/sh
# demo.sh — scripted asciinema demo of guile-sage
#
# Usage: asciinema rec -c scripts/demo.sh --rows 36 --cols 110 docs/images/demo.cast
#
# Shows sage against a small example project (examples/petstore/): built-in
# tool catalogue, workspace, two turns that exercise tools, context
# introspection, /compact as a core primitive, and a post-compaction turn
# whose memory survives.
#
# Uses local Ollama with llama3.2. MCP is disabled so the demo uses only
# built-in tools and never contacts external hosts.

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
export TERM=xterm-256color

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/examples/petstore"

exec expect <<ENDEXPECT
  set timeout 90
  log_user 1
  spawn guile -L $REPO/src -c "(use-modules (sage repl)) (repl-start)"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 1. Tool catalogue — what's available (instant)
  send -- "/tools\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 2. Workspace (instant)
  send -- "/workspace\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 3. First turn — exercise list_files + read_file
  send -- "call list_files once then read_file on README.md. stop.\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 4. Context introspection
  send -- "/context\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 5. Core primitive: compact conversation history
  send -- "/compact 2\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 6. Post-compaction: context survives as a summary
  send -- "/context\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 7. Second LLM turn — exercises search_files
  send -- "call search_files once to grep 'describe' in *.py. stop.\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  send -- "/exit\r"
  expect eof
ENDEXPECT
