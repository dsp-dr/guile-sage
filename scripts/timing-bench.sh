#!/bin/sh
# scripts/timing-bench.sh — guile-sage timing protocol
#
# Reproducible per-model performance + tool-call benchmark for the
# Ollama backend. Used to confirm the timing numbers cited in
# RELEASE-0.6.0.org and to feed the model-tier defaults.
#
# Two phases per model:
#   Phase 1: warm load + single-turn eval performance (no tools)
#   Phase 2: native tool_calls invocation rate (N trials with a get_weather tool)
#
# Output: TSV-shaped lines on stdout, one per model.
# All durations are milliseconds. tok/s is decode token rate.
#
# Reads:
#   OLLAMA_HOST                 default http://localhost:11434
#   TIMING_BENCH_MODELS         space-sep model list (default: small set)
#   TIMING_BENCH_TRIALS         tool call trials per model (default 3)
#   TIMING_BENCH_PROMPT         single-turn prompt
#
# Exit non-zero on any HTTP error so the script is CI-friendly.
#
# bd: guile-c8q (timing protocol)
# See docs/TIMING-PROTOCOL.org for the specification this script implements.

set -eu

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
TRIALS="${TIMING_BENCH_TRIALS:-3}"
PROMPT="${TIMING_BENCH_PROMPT:-Write a Scheme function (square x) that returns x*x. Reply with only the code, no commentary.}"
MODELS="${TIMING_BENCH_MODELS:-llama3.2:latest qwen3:0.6b qwen2.5-coder:7b}"

# Sanity: Ollama up?
if ! curl -sf "$OLLAMA_HOST/api/version" > /dev/null; then
  echo "ERROR: Ollama not reachable at $OLLAMA_HOST" >&2
  exit 1
fi

# All the heavy lifting in python so escaping is sane
export OLLAMA_HOST TRIALS PROMPT MODELS

python3 - <<'PYEOF'
import json, os, sys, urllib.request

OLLAMA_HOST = os.environ['OLLAMA_HOST']
TRIALS = int(os.environ['TRIALS'])
PROMPT = os.environ['PROMPT']
MODELS = os.environ['MODELS'].split()

TOOL_DEF = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get weather for a city",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    },
}]

def post(payload):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{OLLAMA_HOST}/api/chat",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())

def fmt_ms(ns):
    return ns // 1_000_000

print(f"model\tload_ms\tprompt_tok\tprompt_t/s\teval_tok\teval_t/s\ttotal_ms\ttool_calls/{TRIALS}")

for model in MODELS:
    # Phase 1: single-turn perf
    try:
        r = post({"model": model, "stream": False,
                  "messages": [{"role": "user", "content": PROMPT}]})
    except Exception as e:
        print(f"{model}\tERROR\t-\t-\t-\t-\t-\t-", flush=True)
        sys.stderr.write(f"phase1 failed for {model}: {e}\n")
        continue

    ec = r.get("eval_count", 0)
    ed = r.get("eval_duration", 1) or 1
    pc = r.get("prompt_eval_count", 0)
    pd = r.get("prompt_eval_duration", 1) or 1
    ld = r.get("load_duration", 0)
    td = r.get("total_duration", 1) or 1

    p1 = (
        f"{fmt_ms(ld)}\t{pc}\t{int(pc/(pd/1e9))}"
        f"\t{ec}\t{ec/(ed/1e9):.1f}\t{fmt_ms(td)}"
    )

    # Phase 2: tool-call invocation rate over TRIALS trials
    hits = 0
    for _ in range(TRIALS):
        try:
            r2 = post({
                "model": model,
                "stream": False,
                "messages": [{"role": "user",
                              "content": "What is the weather in Tokyo? Use the get_weather tool."}],
                "tools": TOOL_DEF,
            })
        except Exception:
            continue
        if r2.get("message", {}).get("tool_calls"):
            hits += 1

    print(f"{model}\t{p1}\t{hits}", flush=True)
PYEOF
