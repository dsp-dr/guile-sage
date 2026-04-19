#!/bin/sh
# demo.sh — scripted asciinema demo of guile-sage
#
# Usage: asciinema rec -c scripts/demo.sh --rows 36 --cols 110 docs/images/demo.cast
#
# Showcases core primitives against the examples/petstore/ project:
# - /tools catalogue of built-in tools
# - read_file + search_files tool calls (visible [Tool: ...] trace)
# - PostToolUse hook observer (registered via SAGE_DEMO_HOOKS=1)
# - /hooks to list registered lifecycle hooks
# - /context to inspect conversation
# - /compact 2 to compact history (core primitive)
# - post-compaction LLM turn (memory survives)
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

  # 1. Tool catalogue (instant)
  send -- "/tools\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 2. Lifecycle hooks registered at startup via SAGE_DEMO_HOOKS=1
  send -- "/hooks\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 3. First LLM turn — read_file tool call; PostToolUse observer fires
  send -- "use read_file once on README.md then answer in one sentence.\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 4. Second LLM turn — search_files; PostToolUse observer fires again
  send -- "use search_files once to grep 'describe' in *.py.\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  # 5. Context introspection
  send -- "/context\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 6. Core primitive: compact conversation history
  send -- "/compact 2\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 2

  # 7. Post-compaction LLM turn — memory survives
  send -- "one-line docstring for the Pet class, based on what you read.\r"
  expect -re {sage\\[[^\\]]+\\]> }
  sleep 1

  send -- "/exit\r"
  expect eof
ENDEXPECT
