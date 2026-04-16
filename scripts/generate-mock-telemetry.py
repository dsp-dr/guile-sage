#!/usr/bin/env python3
"""Generate mock telemetry data for guile-sage visualizations.

Simulates 50 REPL sessions across 3 providers with realistic tool call
distributions, latencies, and token counts. Outputs:
  1. CSV for gnuplot/spreadsheet: output/mock-telemetry.csv
  2. Prometheus push (optional): POST to pushgateway if --push flag
  3. JSON summary: output/mock-telemetry-summary.json

Usage:
  python3 scripts/generate-mock-telemetry.py
  python3 scripts/generate-mock-telemetry.py --push  # push to prometheus
"""

import json
import os
import random
import sys
from datetime import datetime, timedelta

random.seed(42)  # Reproducible

OUTPUT_DIR = "output"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# --- Model profiles ---
PROFILES = {
    "ollama/llama3.2:latest": {
        "provider": "ollama", "cost_per_1k_in": 0, "cost_per_1k_out": 0,
        "latency_base_ms": 800, "latency_per_token_ms": 15,
        "tool_call_rate": 0.6, "chain_rate": 0.2, "error_rate": 0.05,
    },
    "gemini-2.5-flash": {
        "provider": "openai", "cost_per_1k_in": 0.15, "cost_per_1k_out": 0.60,
        "latency_base_ms": 400, "latency_per_token_ms": 8,
        "tool_call_rate": 0.85, "chain_rate": 0.4, "error_rate": 0.02,
    },
    "qwen3:0.6b": {
        "provider": "ollama", "cost_per_1k_in": 0, "cost_per_1k_out": 0,
        "latency_base_ms": 200, "latency_per_token_ms": 5,
        "tool_call_rate": 0.3, "chain_rate": 0.05, "error_rate": 0.15,
    },
}

TOOLS = [
    "list_files", "read_file", "write_file", "search_files", "glob_files",
    "git_status", "git_diff", "git_log", "git_commit",
    "run_tests", "eval_scheme", "generate_image",
    "sage_task_create", "sage_task_list",
]

SAFE_TOOLS = {"list_files", "read_file", "search_files", "glob_files",
              "git_status", "git_diff", "git_log", "sage_task_list",
              "sage_task_create", "generate_image"}

# --- Generate sessions ---
sessions = []
start_time = datetime(2026, 4, 14, 8, 0, 0)

for i in range(50):
    model_name = random.choice(list(PROFILES.keys()))
    profile = PROFILES[model_name]
    session_start = start_time + timedelta(minutes=random.randint(0, 720))
    num_turns = random.randint(3, 25)
    turns = []

    for t in range(num_turns):
        prompt_tokens = random.randint(50, 500)
        completion_tokens = random.randint(30, 800)

        # Tool call decision
        tool_calls = []
        chain_length = 0
        if random.random() < profile["tool_call_rate"]:
            # Single tool call
            tool = random.choice(TOOLS)
            tool_calls.append(tool)
            chain_length = 1

            # Chain?
            if random.random() < profile["chain_rate"]:
                chain_length = random.randint(2, 4)
                for _ in range(chain_length - 1):
                    tool_calls.append(random.choice(TOOLS))

        # Latency
        latency_ms = (profile["latency_base_ms"]
                      + completion_tokens * profile["latency_per_token_ms"]
                      + random.randint(-100, 200))
        latency_ms = max(100, latency_ms)

        # Error?
        has_error = random.random() < profile["error_rate"]
        error_type = random.choice(["timeout", "model-not-found", "parse-error"]) if has_error else None

        # Cost
        cost = (prompt_tokens / 1000 * profile["cost_per_1k_in"]
                + completion_tokens / 1000 * profile["cost_per_1k_out"])

        # Tool safety decisions
        decisions = []
        for tc in tool_calls:
            decisions.append({
                "tool": tc,
                "safe": tc in SAFE_TOOLS,
                "decision": "accept",
                "latency_ms": random.randint(5, 500),
            })

        turns.append({
            "turn": t + 1,
            "timestamp": (session_start + timedelta(seconds=t * 30)).isoformat(),
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "latency_ms": latency_ms,
            "tool_calls": tool_calls,
            "chain_length": chain_length,
            "has_error": has_error,
            "error_type": error_type,
            "cost_usd": round(cost, 6),
            "decisions": decisions,
        })

    sessions.append({
        "session_id": f"session-{i+1:03d}",
        "model": model_name,
        "provider": profile["provider"],
        "start_time": session_start.isoformat(),
        "turns": turns,
        "total_tokens": sum(t["prompt_tokens"] + t["completion_tokens"] for t in turns),
        "total_cost": round(sum(t["cost_usd"] for t in turns), 4),
        "total_tool_calls": sum(len(t["tool_calls"]) for t in turns),
        "total_errors": sum(1 for t in turns if t["has_error"]),
    })

# --- CSV output ---
csv_path = os.path.join(OUTPUT_DIR, "mock-telemetry.csv")
with open(csv_path, "w") as f:
    f.write("session,model,provider,turn,timestamp,prompt_tokens,completion_tokens,"
            "latency_ms,chain_length,tool_calls,has_error,error_type,cost_usd\n")
    for s in sessions:
        for t in s["turns"]:
            tools = "|".join(t["tool_calls"]) if t["tool_calls"] else ""
            f.write(f'{s["session_id"]},{s["model"]},{s["provider"]},{t["turn"]},'
                    f'{t["timestamp"]},{t["prompt_tokens"]},{t["completion_tokens"]},'
                    f'{t["latency_ms"]},{t["chain_length"]},{tools},'
                    f'{t["has_error"]},{t["error_type"] or ""},{t["cost_usd"]}\n')

# --- Summary JSON ---
summary = {
    "generated": datetime.now().isoformat(),
    "sessions": len(sessions),
    "total_turns": sum(len(s["turns"]) for s in sessions),
    "total_tokens": sum(s["total_tokens"] for s in sessions),
    "total_cost_usd": round(sum(s["total_cost"] for s in sessions), 4),
    "total_tool_calls": sum(s["total_tool_calls"] for s in sessions),
    "total_errors": sum(s["total_errors"] for s in sessions),
    "by_model": {},
    "by_tool": {},
    "tool_chain_distribution": {str(i): 0 for i in range(5)},
}

for s in sessions:
    m = s["model"]
    if m not in summary["by_model"]:
        summary["by_model"][m] = {"sessions": 0, "turns": 0, "tokens": 0,
                                   "cost": 0, "tool_calls": 0, "errors": 0,
                                   "avg_latency_ms": 0, "latencies": []}
    bm = summary["by_model"][m]
    bm["sessions"] += 1
    bm["turns"] += len(s["turns"])
    bm["tokens"] += s["total_tokens"]
    bm["cost"] += s["total_cost"]
    bm["tool_calls"] += s["total_tool_calls"]
    bm["errors"] += s["total_errors"]
    for t in s["turns"]:
        bm["latencies"].append(t["latency_ms"])
        cl = str(min(t["chain_length"], 4))
        summary["tool_chain_distribution"][cl] = summary["tool_chain_distribution"].get(cl, 0) + 1
        for tc in t["tool_calls"]:
            summary["by_tool"][tc] = summary["by_tool"].get(tc, 0) + 1

# Compute avg latencies and remove raw lists
for m, bm in summary["by_model"].items():
    bm["avg_latency_ms"] = round(sum(bm["latencies"]) / len(bm["latencies"])) if bm["latencies"] else 0
    bm["cost"] = round(bm["cost"], 4)
    del bm["latencies"]

json_path = os.path.join(OUTPUT_DIR, "mock-telemetry-summary.json")
with open(json_path, "w") as f:
    json.dump(summary, f, indent=2)

# --- Terminal report ---
print(f"Generated {len(sessions)} sessions, {summary['total_turns']} turns")
print(f"Total tokens: {summary['total_tokens']:,}")
print(f"Total cost: ${summary['total_cost_usd']:.4f}")
print(f"Total tool calls: {summary['total_tool_calls']}")
print(f"Total errors: {summary['total_errors']}")
print()
print("By model:")
for m, bm in sorted(summary["by_model"].items()):
    print(f"  {m}: {bm['sessions']} sessions, {bm['turns']} turns, "
          f"{bm['tokens']:,} tokens, ${bm['cost']:.4f}, "
          f"avg {bm['avg_latency_ms']}ms, {bm['errors']} errors")
print()
print("Tool usage (top 10):")
for tool, count in sorted(summary["by_tool"].items(), key=lambda x: -x[1])[:10]:
    print(f"  {tool}: {count}")
print()
print("Chain length distribution:")
for cl, count in sorted(summary["tool_chain_distribution"].items()):
    bar = "#" * (count // 5)
    print(f"  {cl} tools: {count:3d} {bar}")
print()
print(f"CSV: {csv_path}")
print(f"JSON: {json_path}")
