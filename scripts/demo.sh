#!/bin/sh
# demo.sh — scripted asciinema demo of guile-sage
#
# Usage: asciinema rec -c scripts/demo.sh --rows 30 --cols 100 docs/images/demo.cast
#
# Shows REPL startup, a few slash commands, and one short turn
# against a small local model. No secrets, no internal endpoints.

set -e

# Clean environment — never inherit host credentials.
unset OPENAI_API_KEY OPENAI_API_BASE GEMINI_API_KEY LITELLM_KEY
export USER=sage
export SAGE_PROVIDER=ollama
export SAGE_OLLAMA_HOST=http://localhost:11434
export SAGE_MODEL=qwen3:0.6b
export SAGE_YOLO_MODE=0
export TERM=xterm-256color

cd "$(dirname "$0")/.."

exec expect <<'ENDEXPECT'
  set timeout 45
  log_user 1
  spawn guile -L src -c "(use-modules (sage repl)) (repl-start)"
  expect -re {sage\[[^\]]+\]> }
  sleep 1
  send -- "/status\r"
  expect -re {sage\[[^\]]+\]> }
  sleep 2
  send -- "/tools | head -20\r"
  expect -re {sage\[[^\]]+\]> }
  sleep 2
  send -- "what is the capital of france? one word.\r"
  expect -re {sage\[[^\]]+\]> }
  sleep 1
  send -- "/exit\r"
  expect eof
ENDEXPECT
