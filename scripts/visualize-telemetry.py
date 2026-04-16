#!/usr/bin/env python3
"""Render ASCII visualizations of sage telemetry data.

Reads output/mock-telemetry-summary.json and produces terminal-friendly
charts for: model comparison, tool usage, chain distribution, error rates,
and CLASS dimensions (Cost, Latency, Accuracy, Stability, Security).

Usage: python3 scripts/visualize-telemetry.py
"""

import json
import os
import sys

SUMMARY = "output/mock-telemetry-summary.json"

def bar(value, max_value, width=40, char="#"):
    if max_value == 0:
        return ""
    filled = int(value / max_value * width)
    return char * filled

def color(text, code):
    return f"\033[{code}m{text}\033[0m"

def green(t): return color(t, 32)
def yellow(t): return color(t, 33)
def red(t): return color(t, 31)
def dim(t): return color(t, 2)
def bold(t): return color(t, 1)


def main():
    if not os.path.exists(SUMMARY):
        print(f"ERROR: {SUMMARY} not found. Run scripts/generate-mock-telemetry.py first.")
        sys.exit(1)

    with open(SUMMARY) as f:
        data = json.load(f)

    print(bold("=" * 70))
    print(bold("  guile-sage Agent / Tool Performance Dashboard"))
    print(bold("=" * 70))
    print(f"  {data['sessions']} sessions | {data['total_turns']} turns | "
          f"{data['total_tokens']:,} tokens | ${data['total_cost_usd']:.2f}")
    print()

    # --- 1. Model Comparison ---
    print(bold("1. Model Comparison"))
    print("-" * 70)
    models = data["by_model"]
    max_turns = max(m["turns"] for m in models.values())
    max_tokens = max(m["tokens"] for m in models.values())

    print(f"  {'Model':<30} {'Sessions':>8} {'Turns':>8} {'Tokens':>10} {'Cost':>10} {'Avg ms':>8} {'Errors':>7}")
    print(f"  {'-'*30} {'-'*8} {'-'*8} {'-'*10} {'-'*10} {'-'*8} {'-'*7}")
    for name, m in sorted(models.items(), key=lambda x: -x[1]["turns"]):
        err_color = red if m["errors"] > 10 else yellow if m["errors"] > 3 else green
        lat_color = red if m["avg_latency_ms"] > 5000 else yellow if m["avg_latency_ms"] > 2000 else green
        print(f"  {name:<30} {m['sessions']:>8} {m['turns']:>8} "
              f"{m['tokens']:>10,} ${m['cost']:>9.2f} "
              f"{lat_color(str(m['avg_latency_ms'])):>18} "
              f"{err_color(str(m['errors'])):>17}")
    print()

    # Turns bar chart
    for name, m in sorted(models.items(), key=lambda x: -x[1]["turns"]):
        b = bar(m["turns"], max_turns, 35)
        print(f"  {name:<30} {green(b)} {m['turns']}")
    print()

    # --- 2. Tool Usage ---
    print(bold("2. Tool Usage (top 12)"))
    print("-" * 70)
    tools = data["by_tool"]
    max_usage = max(tools.values()) if tools else 1
    for tool, count in sorted(tools.items(), key=lambda x: -x[1])[:12]:
        b = bar(count, max_usage, 35)
        safe = green("safe") if tool in {
            "list_files", "read_file", "search_files", "glob_files",
            "git_status", "git_diff", "git_log", "sage_task_list",
            "sage_task_create", "generate_image"
        } else red("YOLO")
        print(f"  {tool:<22} {b} {count:>4} [{safe}]")
    print()

    # --- 3. Chain Distribution ---
    print(bold("3. Tool Chain Length Distribution"))
    print("-" * 70)
    chains = data["tool_chain_distribution"]
    max_chain = max(int(v) for v in chains.values()) if chains else 1
    labels = ["no tools", "1 tool  ", "2-chain ", "3-chain ", "4-chain "]
    for i, (cl, count) in enumerate(sorted(chains.items())):
        label = labels[int(cl)] if int(cl) < len(labels) else f"{cl}-chain "
        b = bar(count, max_chain, 40)
        pct = count / data["total_turns"] * 100
        print(f"  {label} {green(b)} {count:>4} ({pct:.0f}%)")
    print()

    # --- 4. Error Rate by Model ---
    print(bold("4. Error Rate by Model"))
    print("-" * 70)
    for name, m in sorted(models.items(), key=lambda x: -x[1]["errors"]):
        rate = m["errors"] / m["turns"] * 100 if m["turns"] else 0
        if rate > 10:
            b = red(bar(rate, 20, 30, "!"))
            grade = red("FAIL")
        elif rate > 3:
            b = yellow(bar(rate, 20, 30, "*"))
            grade = yellow("WARN")
        else:
            b = green(bar(rate, 20, 30, "#"))
            grade = green("PASS")
        print(f"  {name:<30} {b} {rate:>5.1f}% ({m['errors']}/{m['turns']}) {grade}")
    print()

    # --- 5. CLASS Dimensions ---
    print(bold("5. CLASS Evaluation Dimensions"))
    print("-" * 70)
    # Cost: lower is better (0=free local, $$=cloud)
    total_cost = data["total_cost_usd"]
    cost_score = max(0, 10 - total_cost / 10)  # $0=10, $100=0
    # Latency: lower is better
    avg_lat = sum(m["avg_latency_ms"] * m["turns"] for m in models.values()) / data["total_turns"]
    lat_score = max(0, 10 - avg_lat / 1000)  # 0ms=10, 10s=0
    # Accuracy: tool call success rate
    total_tool_turns = sum(1 for _ in range(1))  # approximate
    err_rate = data["total_errors"] / data["total_turns"] * 100
    acc_score = max(0, 10 - err_rate)
    # Stability: session completion (mock: 95% complete)
    stab_score = 9.5
    # Security: guardrail coverage (mock: 70% — known bypass paths)
    sec_score = 7.0

    dimensions = [
        ("Cost", cost_score, f"${total_cost:.2f} across {data['sessions']} sessions"),
        ("Latency", lat_score, f"{avg_lat:.0f}ms weighted avg"),
        ("Accuracy", acc_score, f"{err_rate:.1f}% error rate"),
        ("Stability", stab_score, "95% session completion (estimated)"),
        ("Security", sec_score, "70% guardrail coverage (3 bypass paths)"),
    ]
    for dim_name, score, detail in dimensions:
        if score >= 8:
            c = green
        elif score >= 5:
            c = yellow
        else:
            c = red
        b = c(bar(score, 10, 30))
        print(f"  {dim_name:<12} {b} {c(f'{score:.1f}')}/10  {dim(detail)}")
    print()

    # --- 6. Pre-v1 Gate Classification ---
    print(bold("6. Pre-v1 Task Gate Classification"))
    print("-" * 70)
    gates = [
        ("YOLO (no gate)", green, [
            "Mock telemetry generation",
            "ASCII visualization",
            "Eval harness dry runs",
            "Documentation updates",
            "Image generation",
            "Non-destructive tool calls (read, list, search, glob)",
        ]),
        ("Feedback Required", yellow, [
            "Provider switching (guardrail bypass risk)",
            "write_file / edit_file in YOLO mode",
            "git_commit / git_push",
            "eval_scheme (arbitrary code execution)",
            "run_tests (context blowup risk)",
        ]),
        ("Planning Required", yellow, [
            "MCP server integration (new tool sources)",
            "Context compaction strategy changes",
            "Multi-step tool chains (>3 iterations)",
            "LiteLLM guardrail policy changes",
        ]),
        ("DDP / Beads Tracking", red, [
            "12 untested MCP-CONTRACT.org invariants (guile-sage-w2d)",
            "Streaming guardrail bypass fix (guile-sage-iyk → closed)",
            "Provider switching guardrail (guile-sage-slc → closed)",
            "Tool output guardrail screening (guile-sage-82c)",
            "EU AI Act doc update (guile-sage-hpq)",
        ]),
        ("Meta / Skills Review", red, [
            "CLASS evaluation scoring methodology",
            "Negative contract completeness (audit drift score)",
            "Lossy projection integrity (docs vs code)",
            "Cross-repo contract check (hegel-guile sync)",
        ]),
    ]
    for gate_name, c, items in gates:
        print(f"\n  {c(gate_name)}:")
        for item in items:
            print(f"    - {item}")
    print()

    print(bold("=" * 70))
    print(f"  Data: {SUMMARY}")
    print(f"  CSV:  output/mock-telemetry.csv")
    print(bold("=" * 70))


if __name__ == "__main__":
    main()
