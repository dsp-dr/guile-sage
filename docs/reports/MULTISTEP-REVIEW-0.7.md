# Multi-Step Tool Chain Dispatch -- Validation Review

**Date:** 2026-04-12
**Reviewer:** validation agent (bd: guile-qa1)
**Implementation commit:** `70b242d feat(repl): multi-step tool chain dispatch loop (bd: guile-qa1)`
**Validation commit:** see below
**Model tested:** llama3.2:latest via localhost:11434

---

## 1. What the implementation changed

Commit `70b242d` replaced the single-tool-single-followup pattern in
`src/sage/repl.scm` with a re-prompt loop (`execute-tool-chain`). Key changes:

- **New function `execute-tool-chain`** (lines 599-648): iterates until the model
  stops emitting `tool_calls` or a safety cap of `*max-tool-iterations*` (10) is hit.
- **All `tool_calls` in a single response are now executed**, not just the first one.
  This enables parallel tool use within a single model turn.
- **Follow-ups use `ollama-chat-with-tools`** (not `ollama-chat`), so the model can
  request further tools in subsequent turns.
- **Both streaming and non-streaming paths** delegate to the shared
  `execute-tool-chain`, eliminating ~60 lines of duplication.
- **Safety cap `*max-tool-iterations*`** set to 10, preventing infinite loops if
  the model keeps requesting tools.

---

## 2. Test results

### 2.1 Existing test suite (gmake check)

All existing test suites pass after the implementation commit:

| Suite | Result |
|-------|--------|
| test-commands.scm | 19/19 |
| test-compaction-security.scm | 4/4 |
| test-compaction.scm | 9/9 |
| test-context.scm | 26/26 |
| test-http-debug.scm | 8/8 |
| test-image-gen.scm | 19/19 |
| test-log-introspection.scm | 23/23 |
| test-mcp.scm | 16/17 (pre-existing: bare name collision) |
| test-model-tier.scm | 21/21 |
| test-ollama.scm | 18/18 |
| test-pbt.scm | 74/74 (pre-existing count) |
| test-repl-guard.scm | 17/17 |
| test-repl.scm | 13/13 |
| test-security.scm | 37/37 |
| test-session.scm | 18/18 |
| test-telemetry.scm | 18/18 |
| test-tools.scm | 42/42 |

**No regressions introduced by the dispatch loop change.**

### 2.2 New validation tests (test-repl-chains.scm)

9 tests, all passing:

| # | Test | Status |
|---|------|--------|
| 1 | *max-tool-iterations* is a positive integer | PASS |
| 2 | *max-tool-iterations* is 10 (the documented default) | PASS |
| 3 | execute-tool-chain is a procedure | PASS |
| 4 | execute-tool-chain returns content when tool_calls is empty | PASS |
| 5 | execute-tool-chain returns content when tool_calls is #f | PASS |
| 6 | execute-tool-chain handles single tool_call (backward compat) | PASS |
| 7 | execute-tool-chain terminates at *max-tool-iterations* (safety cap) | PASS |
| 8 | execute-tool-chain processes multiple tool_calls in one response | PASS |
| 9 | execute-tool-chain handles two-step chain (tool -> follow-up tool -> done) | PASS |

Tests use `@@` to access private bindings and `dynamic-wind` + `module-set!` to
mock `ollama-chat-with-tools` without touching the network.

### 2.3 New PBT properties (appended to test-pbt.scm)

2 new properties, 200 additional trials, all passing:

| Property | Trials | Status |
|----------|--------|--------|
| N-tool-call sequence terminates within N+1 iterations | 100 | PASS |
| max-iterations cap always fires at *max-tool-iterations* (never exceeds) | 100 | PASS |

**Total PBT suite after additions: 76 properties, 7600 trials, 76/76 passing.**

---

## 3. Live validation (tmux sage-chains)

Tested 3 of the 6 multi-step prompts from `docs/MULTISTEP-CHAINS-0.6.x.md` plus
the single-tool control prompt (prompt 5). Results:

| # | Prompt | Chain looped? | Correct result? | Notes |
|---|--------|---------------|-----------------|-------|
| 1 | read_file CLAUDE.md + list_files tests/ | YES (10 iterations, cap fired) | NO | Model fired list_files first, then read_file on wrong paths in follow-ups |
| 2 | git_status + git_log + git_diff | YES (10 iterations, cap fired) | NO | Model looped on git_diff/git_status, never progressed to git_log |
| 3 | Read version.scm and util.scm | YES (10 iterations, cap fired) | NO | Model looped on list_files with unsafe /home/sage/workspace path |
| 5 | Read CLAUDE.md + reason about test suites | YES (chaining) | NO | Model called search_files in a loop instead of read_file |

### Key observations

1. **The dispatch loop works correctly.** Tool calls are executed, follow-ups are
   re-prompted with tools enabled, and the safety cap fires at exactly 10 iterations.

2. **llama3.2 does not use the chain well.** The model consistently:
   - Picks the wrong tool for the first step (last-tool-wins is still the dominant pattern)
   - Gets stuck in loops calling the same tool repeatedly in follow-ups
   - Never converges on a multi-step plan

3. **The safety cap is essential.** Without it, every prompt would loop indefinitely.
   All 3 multi-step prompts hit the 10-iteration cap.

4. **Context window pressure is severe.** After a 10-iteration chain, the context
   fills to 219% (17534/8000 tokens), degrading model quality further.

**Live multi-step success rate: 0/4** (same as 0.6.x baseline for multi-step).
The dispatch loop is mechanically correct but llama3.2 cannot exploit it.

---

## 4. Remaining gaps and edge cases

### G1 -- Model-side planning failure
The dispatch loop provides the mechanism for multi-step chains, but llama3.2
does not produce useful multi-step plans. The model either:
- Emits only 1 tool_call per response (the follow-up loop works but cannot force
  the model to call the RIGHT tool)
- Gets stuck in a degenerate loop calling the same tool repeatedly

**Recommendation:** Test with qwen3, llama3.3, or other models that may have
better tool-use planning. The dispatch loop is model-agnostic and should work
with any model that produces multi-tool sequences.

### G2 -- Context window exhaustion
10 iterations of tool calls + results + follow-ups rapidly fills the context
window. With llama3.2's 8K context, the window overflows after ~5 iterations.

**Recommendation:** Add automatic compaction between chain iterations when
context exceeds 80%. Alternatively, reduce `*max-tool-iterations*` to 5 for
small-context models.

### G3 -- No per-chain telemetry
The dispatch loop emits token usage counters per follow-up, but does not emit
a chain-level metric (total iterations, tools invoked, chain outcome).

**Recommendation:** Add `guile_sage.chain.iterations` and
`guile_sage.chain.tools_invoked` counters.

### G4 -- execute-tool-chain and *max-tool-iterations* are not exported
Tests must use `@@` to access them. If external consumers or future modules
need to configure the cap or call the chain directly, these should be exported.

### G5 -- Degenerate loop detection
The model sometimes calls the same tool with the same arguments 10 times in a
row. The dispatch loop could detect this pattern and break early with a warning.

**Recommendation:** Track the last N tool calls; if 3 consecutive calls have
the same name and arguments, break the loop and warn the user.

---

## 5. Recommendations

1. **Close guile-qa1.** The dispatch loop implementation is correct. The safety
   cap works. All tests pass. The remaining issues are model-quality and
   UX improvements, not dispatch-loop bugs.

2. **File follow-up issues:**
   - guile-sage-XXX: Degenerate loop detection (G5)
   - guile-sage-XXX: Per-chain telemetry counters (G3)
   - guile-sage-XXX: Context-aware iteration cap (G2)
   - guile-sage-XXX: Test with qwen3/llama3.3 for multi-step planning (G1)

3. **Consider reducing `*max-tool-iterations*` to 5** for llama3.2 until
   model-side planning improves. 10 iterations with no progress wastes
   significant compute and fills the context window.
