# guile-sage 0.6.0 — UX Findings

**Session date:** 2026-04-11
**Tester:** exploratory UX session (10 prompts, ~21 min)
**Model:** `llama3.2:latest` via `http://localhost:11434`, `SAGE_DEBUG_HTTP=1`, `SAGE_YOLO_MODE=1`
**Branch:** `main`

---

## 1. Summary

sage 0.6.0's plumbing is solid: the tool registry, streaming, and model-tier upgrade path all work, and the 22-tool dispatcher does invoke real tools most of the time. The dominant user-visible problem is **post-tool hallucination** — after a tool returns an error, empty result, or even a successful result, llama3.2 confidently fabricates file contents, TODOs, log lines, and "next step" tool calls that never ran. Combined with path misreporting on `write_file`, this makes it unsafe to trust any sage answer without re-reading the raw `[Tool: ...]` block.

---

## 2. Tool-reliability count

Of **10 prompts** that expected a tool call:

| Result | Count | Prompts |
|---|---|---|
| Invoked a real tool | 8 | glob_files, read_file, search_files, git_status, git_log, write_file, search_files (x2), list_files |
| Text-formatted tool call (no invocation) | 1 | "Read CLAUDE.md then STATUS.org then diff" — emitted a bogus `{"name":"diff", ...}` JSON blob, no tool fired |
| Wrong tool chosen | 1 | "Read CLAUDE.md and summarize runtime requirements" — called `search_files` (empty result) instead of `read_file` |

**Native-invocation rate: 8/10 = 80%.** Better than feared, but the 20% failure mode is loud: the "diff" case produced zero useful work, and the search_files substitution produced a confidently wrong answer ("no runtime requirements found").

The model tier auto-upgraded from `llama3.2:latest` → `qwen2.5-coder:7b` after the context crossed ~2.1k tokens, but the status line still shows `llama3.2@local` and streams reported `[streaming llama3.2:latest]`. Confusing — the advertised model and the actual model diverge silently.

---

## 3. Per-gap findings

### Gap 1 — Path misreporting on write_file: **CONFIRMED**

Prompt: `Use write_file to create /tmp/sage-uxtest.txt with the content "hello"`

- Tool output: `Wrote 5 bytes to /tmp/sage-uxtest.txt`
- Model response: `Created file /tmp/sage-uxtest.txt with contents: hello`
- Actual filesystem:
  - `/tmp/sage-uxtest.txt` — **does not exist**
  - `/Users/jwalsh/ghq/github.com/dsp-dr/guile-sage/tmp/sage-uxtest.txt` — **5 bytes, contains "hello"**

The sandbox silently strips the leading `/` and writes workspace-relative, but the success message parrots the absolute path the user asked for. Catastrophic for any workflow that actually needs `/tmp`. The fix should land in the tool itself (normalize + echo the real resolved path).

### Gap 2 — Streaming tool_call reliability: **CONFIRMED (minor)**

Seen once in 10 prompts: the multi-step "read A, read B, diff" prompt produced a raw JSON blob streamed as text (`{"name": "diff", ...}`) with no tool invocation at all. No follow-up, no error — just a silent failure and the prompt returned. The other 9/10 cases invoked tools natively, so this is primarily a problem for multi-step prompts and for tools the model invents (there is no `diff` tool).

### Gap 3 — Hallucination after tool result: **CONFIRMED — severe**

Observed **four separate times** in 10 prompts, including on successful results (not just errors):

1. **read_file Unsafe path → fabricated contents.** `Read src/sage/version.scm`: tool returned `Unsafe path: /home/sage-agent/src/sage/version.scm`. Model replied: "`read_file` successful on `/home/sage-agent/src/sage/version.scm`. File contents are: `(define-version 'sagemaker-image "3.0.0-sagemaker-2022-08" ...)`" — that file, function, and version string do not exist. sage-agent's sandbox root is getting mixed up with SageMaker, and the model hallucinated both.

2. **search_files empty → fabricated TODOs.** `Find any TODO comments in the source`: tool returned an empty result. Model replied with two fake TODOs: `sage: TODO: Implement a GUI for Sage` and `CLAUDE.md: TODO: Update Claude documentation to match changes in Sage 3.0.0-sagemaker-2022-08`. Neither exists in the repo.

3. **read_logs type error → fabricated log lines.** `Show me the last 20 lines of .logs/sage.log`: tool errored with `Tool error: wrong-type-arg (min Wrong type argument in position ~A: ~S (1 20) (20))`. Model replied with 10 lines of entirely invented 2023-02-20 log entries referencing `Sage v3.0.0-sagemaker-2022-08`, `Server listening on port 8080`, `Connected to database` — sage has no server, no database, no such version.

4. **search_files empty → fabricated conclusion.** `Read CLAUDE.md and summarize runtime requirements`: tool called `search_files` (wrong tool), got empty result, model confidently reported "No runtime requirements found" — CLAUDE.md clearly states the guile3-only runtime requirement.

The "sagemaker-2022-08" / "Sage 3.0" / "port 8080" pattern is especially damning — it shows llama3.2 is falling back to a pretraining-era "Sage" concept whenever the real tool data is missing or errors. The system prompt is not strongly anchoring the model to this codebase.

### Gap 4 — Multi-step chains: **CONFIRMED**

`Read CLAUDE.md, then read STATUS.org, then summarize the differences`: zero tools invoked. Model emitted a single text-format `{"name":"diff",...}` blob and returned. It did not decompose into sequential read_file calls. The dispatch loop appears to only support one tool call per model turn.

### Gap 5 — Long-output truncation / volume: **NOT CONFIRMED (inconclusive)**

`Search for "define" in src/sage` returned ~45 matches, all from `tests/` (notably *no* `src/sage/` results despite the prompt specifying that path — possible sandbox-root-vs-cwd issue). sage handled the volume without choking, but the summary only named 3 files and completely glossed over that the search scope was wrong. So volume is fine; scoping is the real problem.

---

## 4. New gaps discovered

### N1 — `read_logs` tool crashes on integer argument (real bug)

`read_logs` with `lines=20` (or any integer) produces:
```
Tool error: wrong-type-arg (min Wrong type argument in position ~A: ~S (1 20) (20))
```
Looks like `min` is being called on a string and an integer. The argument is probably coming in unparsed. This is a reproducible tool-side crash, not a model issue. File a bug.

### N2 — Silent model swap confuses the status line

After the context crosses the threshold, sage prints:
```
[model: llama3.2:latest -> qwen2.5-coder:7b (standard tier, 2527 tokens)]
[streaming llama3.2:latest]
```
Both lines are misleading: the prompt-label still says `llama3.2@local`, and the streaming marker contradicts the upgrade banner. If the model actually upgraded, the streaming line and the prompt prefix should reflect it. If it didn't, the upgrade banner is a lie.

### N3 — git_status parsing ambiguity in response

`git_status` correctly emitted `D tests/fixtures/test-custom-256.png` (deleted), but the model's rendering flattened it to "Modified (M)" alongside the other png files. Raw tool output is right; model is wrong. A small structured-status formatter (M/A/D labels) would help.

### N4 — search_files default scope unclear

"Search for 'define' in src/sage" returned only matches from `tests/`, `scripts/`, and `tmp/`. Either `search_files` ignored the scope argument, or the model omitted it. Needs a repro with `SAGE_DEBUG_HTTP` wire dump of the exact arguments sent, but worth investigating — scoped search is a core expectation.

### N5 — Prior-session "sage agent" root leaks into new sessions

The first prompt after restart (`reply with: hi`) mysteriously triggered `read_file` on `/home/sage agent/hi.txt` and then `/home/sage-agent/hi.txt`. That path doesn't come from anything in this session — suggests stale session state from a previous run, or the system prompt contains a `/home/sage-agent` example that the model is aggressively copying. Either way, the model keeps falling back to `/home/sage-agent/...` as its default root even though cwd is `/Users/jwalsh/.../guile-sage`.

---

## 5. Most painful UX issue

**Post-tool hallucination.** Four of ten prompts produced confidently false user-facing text because the model papered over a tool error, an empty result, or its own wrong tool choice with fabricated content. A user who trusts the prose without re-reading the `[Tool: ...]` block will be misled on basic questions like "what version is this?" or "what's in the log?".

The single most actionable fix: **after any tool error or empty result, inject a hard system message like `TOOL_ERROR: do not fabricate a successful result. Report the error verbatim and ask the user for guidance.`** Combine with a prose-level check: if the last tool returned error/empty, strip the model's free-form interpretation and show only the raw tool output plus a one-line "sage: tool failed, here's what happened" footer.

---

## 6. Recommendation table for 0.7.0 backlog

| Size | Item | Why |
|---|---|---|
| **S** | Fix `read_logs` int-arg crash (`min` on wrong types) | Real bug, tool is unusable with integer `lines` |
| **S** | Normalize + echo the **resolved** path in write_file output | Stops the `/tmp/` → `./tmp/` lie |
| **S** | Make model-swap banner update the streaming label and prompt prefix | Status line is currently dishonest |
| **S** | System-prompt anchor: "you are running in $(pwd), not `/home/sage-agent`" | Stops the sage-agent path phantom |
| **M** | Inject post-tool-error system message: "do not fabricate a successful result" | Directly attacks gap #3 |
| **M** | Detect text-format tool calls (`{"name":..., "parameters":...}` as streamed text) and either retry or surface a parse warning | Rescues the "diff" failure mode and similar |
| **M** | Support multi-tool-call turns in the dispatch loop | Fixes gap #4, unlocks "do X then Y then Z" |
| **M** | Strict/loose answer modes: `/strict` forces the model to only say what the last tool returned | Gives power users an escape hatch from hallucination |
| **M** | Improve git_status rendering: parse the porcelain codes and render M/A/D/?? with labels before the model sees them | Model keeps flattening D→M |
| **L** | Model evaluation harness: replay these 10 prompts against every supported model nightly, score tool-call rate and hallucination rate, fail CI under thresholds | Turns UX findings into a regression gate |
| **L** | Tool-output "honesty budget": after a run, diff the model's prose against the raw tool outputs and emit a telemetry warning when prose introduces strings that weren't in any tool output | Would have caught all four hallucination cases here automatically |

---

## Appendix — Turn log

| # | Prompt | Tool | Result | Turn time |
|---|---|---|---|---|
| 1 | List all the .scm files in src/sage | `glob_files` native | correct list, over-scoped but ok | ~14s |
| 2 | Read src/sage/version.scm | `read_file` native | **Unsafe path error, then hallucinated contents** | ~12s |
| 3 | Search for "telemetry" in src/sage | `search_files` native | correct | ~18s |
| 4 | Show me the git status | `git_status` native (after tier-upgrade stall) | correct data, wrong labels (D→M) | ~80s |
| 5 | Show me the last 3 commits | `git_log` native | correct | ~30s |
| 6 | Use write_file to create /tmp/sage-uxtest.txt | `write_file` native | **wrote to ./tmp/, reported /tmp/** | ~22s |
| 7 | Read CLAUDE.md then STATUS.org then diff | **none** (text-format) | zero tools, bogus JSON blob | ~15s |
| 8 | Find TODO comments in the source | `search_files` native (empty) | **hallucinated two TODOs** | ~19s |
| 9 | Search for "define" in src/sage | `search_files` native | wrong scope (returned tests/), model handled volume | ~33s |
| 10 | Show me the last 20 lines of .logs/sage.log | `read_logs` native | **tool error, then hallucinated fake 2023 log lines** | ~45s |
| 11 | Read CLAUDE.md and summarize runtime | `search_files` native (wrong tool, empty) | **"no runtime requirements found"** — wrong | ~38s |
| 12 | List test files in tests/ | `list_files` native | correct | ~65s |

Exited cleanly via `/exit`; telemetry counters should have flushed.
