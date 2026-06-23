#!/usr/bin/env bash
# litellm-provision.sh — provision a LiteLLM gateway for guile-sage.
#
# Idempotently: registers the models, creates the `guile-sage` team and grants
# it those models, then mints a team-scoped virtual key. This is the automation
# behind docs/LITELLM-SETUP.org.
#
# Config is read from the environment (sage's gitignored .env provides it):
#   LITELLM_HOST        name-or-IP[:port]            (required)
#   LITELLM_MASTER_KEY  gateway admin key            (required; from .env, never committed)
#   OLLAMA_HOST         ollama name:port             (default: ollama-host:11434)
#   GEMINI_API_KEY      real gemini key, stored server-side (default: MOCK)
#
# Usage:
#   scripts/litellm-provision.sh            # provision, print the virtual key + .env lines
#   scripts/litellm-provision.sh --write-env  # also append the lines to ./.env
#
# No secrets or addresses are hardcoded. Safe to commit.
set -euo pipefail

: "${LITELLM_HOST:?set LITELLM_HOST (name-or-IP[:port])}"
: "${LITELLM_MASTER_KEY:?set LITELLM_MASTER_KEY (gateway admin key)}"
: "${OLLAMA_HOST:=ollama-host:11434}"
: "${GEMINI_API_KEY:=MOCK-gemini-api-key}"

TEAM_ALIAS="guile-sage"
MODELS=("ollama-qwen2.5-coder" "gemini-2.5-flash")
BASE="http://${LITELLM_HOST}"
AUTH=(-H "Authorization: Bearer ${LITELLM_MASTER_KEY}" -H "Content-Type: application/json")

api() { # api METHOD PATH [JSON]
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -sS --connect-timeout 5 -X "$method" "${BASE}${path}" "${AUTH[@]}" -d "$body"
  else
    curl -sS --connect-timeout 5 -X "$method" "${BASE}${path}" "${AUTH[@]}"
  fi
}

echo ">> gateway ${BASE} (master ${LITELLM_MASTER_KEY:0:6}…)"

# 1. Register models (ignore "already exists")
register_model() { # name litellm_params_json
  local name=$1 params=$2
  echo ">> model: ${name}"
  api POST /model/new "{\"model_name\":\"${name}\",\"litellm_params\":${params}}" \
    | grep -qiE "already|exists|success|model_id" || true
}
register_model "ollama-qwen2.5-coder" \
  "{\"model\":\"ollama/qwen2.5-coder:7b\",\"api_base\":\"http://${OLLAMA_HOST}\"}"
register_model "gemini-2.5-flash" \
  "{\"model\":\"gemini/gemini-2.5-flash\",\"api_key\":\"${GEMINI_API_KEY}\"}"

# 2. Find or create the team
models_json=$(printf '"%s",' "${MODELS[@]}"); models_json="[${models_json%,}]"
team_id=$(api GET /team/list | jq -r \
  --arg a "$TEAM_ALIAS" '.[]? | select(.team_alias==$a) | .team_id' 2>/dev/null | head -1)
if [ -z "${team_id:-}" ] || [ "$team_id" = "null" ]; then
  echo ">> creating team '${TEAM_ALIAS}'"
  team_id=$(api POST /team/new \
    "{\"team_alias\":\"${TEAM_ALIAS}\",\"models\":${models_json},\"max_budget\":5.0,\"budget_duration\":\"30d\"}" \
    | jq -r '.team_id')
else
  echo ">> team '${TEAM_ALIAS}' exists (${team_id}); ensuring models granted"
  api POST /team/model/add "{\"team_id\":\"${team_id}\",\"models\":${models_json}}" >/dev/null || true
fi
echo ">> team_id = ${team_id}"

# 3. Mint a team-scoped virtual key for sage
echo ">> minting virtual key"
key=$(api POST /key/generate \
  "{\"key_alias\":\"guile-sage\",\"team_id\":\"${team_id}\",\"models\":${models_json},\"max_budget\":5.0,\"rpm_limit\":60}" \
  | jq -r '.key')
[ -n "${key}" ] && [ "${key}" != "null" ] || { echo "!! key generation failed" >&2; exit 1; }

cat <<EOF

== guile-sage LiteLLM provisioning complete ==
  team_alias : ${TEAM_ALIAS}
  team_id    : ${team_id}
  models     : ${MODELS[*]}
  virtual key: ${key}

Add to sage .env (gitignored):
  SAGE_PROVIDER=openai
  SAGE_OPENAI_BASE=http://${LITELLM_HOST}/v1
  SAGE_OPENAI_API_KEY=${key}
  SAGE_MODEL=${MODELS[1]}
EOF

if [ "${1:-}" = "--write-env" ]; then
  {
    echo ""
    echo "# --- appended by scripts/litellm-provision.sh ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ---"
    echo "SAGE_PROVIDER=openai"
    echo "SAGE_OPENAI_BASE=http://${LITELLM_HOST}/v1"
    echo "SAGE_OPENAI_API_KEY=${key}"
    echo "SAGE_MODEL=${MODELS[1]}"
  } >> .env
  echo ">> appended to ./.env"
fi
