#!/bin/sh
# Launch Claude Code backed by a local Ollama instance
# Usage: ./scripts/claude-ollama.sh [model] [host]
# Reads SAGE_OLLAMA_HOST from .env if not specified

# Source .env if present
if [ -f .env ]; then
  eval "$(grep '^SAGE_OLLAMA_HOST=' .env)"
  eval "$(grep '^SAGE_MODEL=' .env)"
fi

MODEL="${1:-${SAGE_MODEL:-llama3.2:latest}}"
OLLAMA_HOST="${2:-${SAGE_OLLAMA_HOST:-http://localhost:11434}}"

exec env \
  ANTHROPIC_AUTH_TOKEN=ollama \
  ANTHROPIC_API_KEY="" \
  ANTHROPIC_BASE_URL="$OLLAMA_HOST" \
  claude --model "$MODEL"
