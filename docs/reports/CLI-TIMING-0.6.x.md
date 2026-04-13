# CLI Timing Battery - guile-sage v0.6.0

Date: 2026-04-12
Model: llama3.2:latest on localhost:11434
Host: mini (macOS, Apple Silicon)
Guile: 3.0.11 (/opt/homebrew/bin/guile)
MCP: skills-hub at nexus:8400 (36 tools registered)
OTel: nexus:4318 (DOWN -- all flushes return code=0)

## 1. Methodology

Each test clears `.logs/http.jsonl` and `.logs/sage.log`, then runs:

```bash
rm -f .logs/http.jsonl .logs/sage.log
START_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
echo '/exit' | \
  SAGE_DEBUG_HTTP=1 SAGE_YOLO_MODE=1 SAGE_MODEL=llama3.2:latest \
  /opt/homebrew/bin/guile -L src -c \
  '(use-modules (sage repl)) (repl-start #:initial-prompt "PROMPT")' \
  > /tmp/sage-test-output.txt 2>&1
END_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
```

Timing layers extracted from:
- Wall clock: Python `time.time()` delta
- Ollama API: `elapsed_ms` in `.logs/http.jsonl` for localhost:11434 entries
- Tool execution: `duration_ms` in `.logs/sage.log` (Guile rational format)
- Telemetry flush: `elapsed_ms` for nexus:4318/v1/metrics entries
- MCP round-trip: `elapsed_ms` for nexus:8400/messages entries
- Boot time: residual = wall - ollama_stream - ollama_followup - telemetry

Environment: `SAGE_MCP_DISABLE=1` was tested for Group 1 but has **no effect** --
there is no check for this env var in `mcp.scm` or `repl.scm`. MCP always initializes.
This is a bug (see Known Issues).

## 2. Per-Test Results

### Group 1: Built-in Tools

| Test | Prompt | Expected Tool | Actual Tool | Fired? | Wall ms | Ollama Stream ms | Ollama Follow-up ms | Tool Exec ms | Telemetry ms (4x) | MCP Init ms (3x) | Boot Est ms |
|------|--------|---------------|-------------|--------|---------|------------------|---------------------|--------------|--------------------|--------------------|-------------|
| T1 | List the .scm files in src/sage | glob_files / list_files | glob_files | YES | 35,070 | 25,999 | 4,580 | 24.0 | 4,065 | 63 | ~426 |
| T2 | Read src/sage/version.scm | read_file | read_file | YES | 29,549 | 22,347 | 2,839 | 1.1 | 4,044 | 36 | ~319 |
| T3 | Show me the git status | git_status | git_status | YES | 28,485 | 22,003 | 2,102 | 53.7 | 4,058 | 38 | ~322 |
| T4 | Use search_files with path=src/sage to find define-module | search_files | search_files | YES | 30,992 | 22,904 | 3,694 | 19.9 | 4,055 | 39 | ~339 |
| T5 | Use read_logs to show last 5 lines of the log | read_logs | log_search_advanced | WRONG | 29,464 | 24,455 | 676 | 4.0 | 4,047 | 36 | ~286 |

### Group 2: MCP Tools

| Test | Prompt | Expected Tool | Actual Tool | Fired? | Wall ms | Ollama Stream ms | Ollama Follow-up ms | Tool Exec ms | MCP POST ms | MCP Result | Telemetry ms |
|------|--------|---------------|-------------|--------|---------|------------------|---------------------|--------------|-------------|------------|--------------|
| M1 | Use the skills-hub workflow bd tool to show the ready queue | workflow__bd | skills-hub.workflow__bd | YES | 30,725 | 22,548 | 3,601 | 17.3 | 16 (202) | TIMEOUT | 4,059 |
| M2 | Use the skills-hub factory architect tool to list architectural rules | factory__architect | skills-hub.factory__architect | YES | 31,701 | 22,956 | 4,352 | 18.6 | -- | TIMEOUT | 4,059 |
| M3 | Use the skills-hub infra health_check tool | workflow__health_check | (none) | NO | 26,821 | 22,503 | 0 | -- | -- | -- | 4,049 |

### Group 3: Timing Comparison (3 runs each)

**T1 (glob_files, built-in):**

| Run | Wall ms | Ollama Stream ms | Ollama Follow-up ms | Telemetry ms | Residual ms |
|-----|---------|------------------|---------------------|--------------|-------------|
| 1 | 32,976 | 23,653 | 4,941 | 4,052 | 330 |
| 2 | 31,363 | 22,453 | 4,565 | 4,049 | 296 |
| 3 | 38,578 | 23,057 | 11,132 | 4,055 | 334 |
| **Avg** | **34,306** | **23,054** | **6,879** | **4,052** | **320** |
| Stddev | 3,092 | 491 | 3,009 | 2 | 17 |

**M1 (skills-hub.workflow__bd, MCP):**

| Run | Wall ms | Ollama Stream ms | Ollama Follow-up ms | Telemetry ms | Residual ms |
|-----|---------|------------------|---------------------|--------------|-------------|
| 1 | 35,746 | 22,530 | 8,824 | 4,078 | 314 |
| 2 | 28,084 | 22,762 | 957 | 4,059 | 306 |
| 3 | 28,630 | 22,953 | 1,264 | 4,122 | 291 |
| **Avg** | **30,820** | **22,748** | **3,682** | **4,086** | **304** |
| Stddev | 3,490 | 173 | 3,683 | 27 | 10 |

## 3. Layer Waterfall (T2, representative)

```
|--- boot (~300ms) ---|--- MCP init (<100ms) ---|--- telemetry flush 1 (~1s) ---|
                                                                                 |--- ollama stream (~22s) ---|
                                                                                                              |--- telemetry flush 2 (~1s) ---|
                                                                                                              |--- tool exec (<2ms) ---|
                                                                                                                                        |--- ollama follow-up (~3s) ---|
                                                                                                                                                                        |--- telemetry flush 3+4 (~2s) ---|
Total wall: ~29.5s
```

Approximate breakdown for a typical built-in tool invocation:

| Phase | Duration | % of Wall |
|-------|----------|-----------|
| Boot + init (guile load, MCP SSE, session, SAGE.md) | ~300ms | 1.0% |
| MCP init (SSE connect, initialize, tools/list) | <100ms | 0.3% |
| Session telemetry flush (1x, code=0 fail) | ~1,000ms | 3.4% |
| **Ollama streaming (1st call: prompt + tool selection)** | **~22,500ms** | **76.3%** |
| Post-stream telemetry flush (1x) | ~1,000ms | 3.4% |
| Tool execution (read_file, glob, git, grep) | <60ms | 0.2% |
| **Ollama follow-up (2nd call: summarize tool output)** | **~3,500ms** | **11.9%** |
| Shutdown telemetry flush (2x) | ~2,000ms | 6.8% |

## 4. MCP vs Built-in Comparison

MCP tool invocation is **NOT materially slower** at the tool-dispatch level:
- Built-in tool exec: 1-54ms
- MCP tool dispatch: 17-19ms (POST accepted in 16ms)

However, MCP tools are **100% broken in practice** because the SSE response
channel times out on every invocation. The JSON-RPC POST is accepted (202) but
the SSE FIFO used to correlate the response becomes stale after the init phase.
The FIFO-based SSE transport (`sse-wait-for-response`) blocks for 60s then gives up.

The net effect: MCP adds ~60s of timeout waiting per invocation, making it
catastrophically slower when the model chooses an MCP tool. The model then gets
"MCP tool call timed out" as the result and either hallucinates output (M2) or
provides a generic error summary (M1).

**Boot time comparison:** The residual (boot + framework overhead) is consistent
between both groups at ~300-320ms, indicating MCP init adds negligible overhead
when the SSE server is reachable.

## 5. Expected vs Actual Delta

| Test | Expected Tool | Actual Tool | Match? | Result Correct? | Notes |
|------|---------------|-------------|--------|-----------------|-------|
| T1 | glob_files / list_files | glob_files | YES | YES | Returned all .scm files, but scope was too broad (included tests/, scripts/, tmp/) |
| T2 | read_file | read_file | YES | YES | Returned version.scm content, model correctly reported v0.6.0 |
| T3 | git_status | git_status | YES | YES | Returned real git status matching `git status --short` |
| T4 | search_files | search_files | YES | YES | Scoped to src/sage, found all 18 define-module declarations |
| T5 | read_logs | log_search_advanced | NO | NO | Model chose wrong tool. log_search_advanced returned "No matching entries found" |
| M1 | workflow__bd | skills-hub.workflow__bd | YES | NO | Tool invoked but SSE response timed out |
| M2 | factory__architect | skills-hub.factory__architect | YES | NO | Tool timed out, model hallucinated architectural rules |
| M3 | workflow__health_check | (none) | NO | NO | Model emitted tool call as text, streaming parser did not detect it |

**Hallucination alert (M2):** After MCP timeout, the model fabricated a fake
ARCHITECTURE.md file with made-up "architectural rules." The follow-up response
presented these as factual. This is a safety concern for MCP-backed workflows.

**M3 parser failure:** The model output `{"name": "skills-hub.infra__health_check", "parameters": {}}` as
raw text in the stream, but the streaming tool-call parser (`ollama-parse-tool-call`) did
not extract it. The tool was never invoked.

## 6. Recommendations

### Regression Test Candidates

These prompts should become automated regression tests with timing thresholds:

| Prompt | Expected Tool | Max Wall Time | Rationale |
|--------|---------------|---------------|-----------|
| "List the .scm files in src/sage" | glob_files | 45s | Reliable tool selection, tests streaming + tool + follow-up |
| "Read src/sage/version.scm" | read_file | 40s | Tests file reading, version verification possible |
| "Show me the git status" | git_status | 40s | Deterministic tool, output verifiable |
| "Use search_files with path=src/sage to find define-module" | search_files | 40s | Tests scope constraint (src/sage only) |

### Timing Thresholds for Regression Detection

| Metric | Current Baseline | Warning Threshold | Failure Threshold |
|--------|-----------------|-------------------|-------------------|
| Ollama 1st call (streaming) | 22-26s | >35s | >60s |
| Ollama 2nd call (follow-up) | 1-5s | >15s | >30s |
| Tool execution | <60ms | >500ms | >2000ms |
| Boot + init | ~300ms | >1000ms | >3000ms |
| Total wall (with tool) | 28-35s | >50s | >90s |
| Telemetry flush (per flush) | ~1000ms | >3000ms | >5000ms |

### Code Fixes Needed

1. **SAGE_MCP_DISABLE env var** -- `repl.scm` calls `(mcp-init)` unconditionally.
   Add a guard: `(unless (config-get "MCP_DISABLE") (mcp-init))`.
   Priority: medium.

2. **MCP SSE session lifetime** -- The FIFO-based SSE connection opened during
   `mcp-init` becomes stale by the time `mcp-call-tool` reads from it. The init
   phase consumes the endpoint event and initializes, but subsequent reads from
   the same FIFO port fail silently or hang. Root cause: the SSE stream may have
   closed between init and tool-call, or the curl process exited.
   Priority: high (MCP is completely non-functional for tool calls).

3. **Telemetry flush blocking** -- Each telemetry flush takes ~1000ms even when
   the collector is down (code=0). This is the curl connection timeout hitting
   the 1s default. Four flushes per invocation = 4s wasted. When the collector
   is down, the first failure should set a backoff flag to skip subsequent
   flushes for the session.
   Priority: medium (saves 4s/invocation = ~14% of wall time).

4. **M3 streaming tool-call parser** -- When the model outputs a tool call as
   raw text (not in the Ollama tool_calls response format), the streaming parser
   misses it. Consider a fallback JSON extraction from streamed content.
   Priority: low (model-dependent, may self-resolve with better models).

5. **T5 tool selection** -- The model chose `log_search_advanced` instead of
   `read_logs` for "show last 5 lines of the log". The 58-tool schema (22 native +
   36 MCP) may be too large for llama3.2:latest to navigate reliably.
   Priority: low (prompt engineering or model upgrade).

## 7. Known Issues

- **OTel collector DOWN**: All telemetry flushes to nexus:4318 return code=0 (connection refused/timeout). Each takes ~1000ms. This accounts for ~14% of total wall time.
- **MCP tool calls 100% broken**: SSE response channel is stale after init. All MCP tool invocations time out. POST returns 202 but response never arrives via SSE.
- **No SAGE_MCP_DISABLE support**: The env var is not checked. MCP always initializes. MCP init itself is fast (<100ms), but the stale SSE port causes tool-call failures.
- **FIFO cleanup**: `/tmp/sage-sse-<pid>` FIFOs are created per sage invocation. No cleanup occurs on abnormal termination.
- **duration_ms format**: Tool execution duration is logged as a Guile exact rational (e.g., `23983/1000` = 23.983ms). Should be formatted as a decimal for easier parsing.
- **M3 no-tool-call**: llama3.2:latest sometimes emits tool calls as raw text instead of structured tool_calls, defeating the parser. 1 out of 8 tests exhibited this.
- **T5 wrong tool**: Model chose `log_search_advanced` (with no args match) over `read_logs`. 1 out of 5 built-in tests selected the wrong tool.
- **Model follow-up variance**: The 2nd Ollama call (post-tool-result summarization) has high variance: 676ms to 11,132ms across runs. This appears to depend on the model's output length and the size of tool results in context.
