# guile-sage 0.6.x — Multi-Step Tool-Call Chains

**Session date:** 2026-04-11
**Tester:** exploratory chain-stress session (6 multi-step prompts + 2 control prompts)
**Model:** `llama3.2:latest` via `http://localhost:11434`, `SAGE_DEBUG_HTTP=1`, `SAGE_YOLO_MODE=1`
**Branch:** `main`
**Scope:** characterise UX-FINDINGS-0.6.0.md Gap #4 (multi-step chains)

---

## 1. Summary

sage 0.6.x has **zero native multi-step chaining** under llama3.2. The REPL dispatch loop is hard-wired to exactly one tool per user turn (`src/sage/repl.scm:715-746` streaming branch, `:773-804` non-streaming branch), and ollama's llama3.2 tool-call parser only ever emits a single-element `tool_calls` array. When asked for N tools, sage fires exactly one — almost always the LAST one mentioned in the prompt — and the model then hallucinates that the other steps also happened. The only reliable workaround is to drive each step as a separate user prompt.

---

## 2. Mechanism — how the chain actually works

### 2.1 Dispatch loop is single-shot

`src/sage/repl.scm` has two code paths (streaming and non-streaming). Both follow the exact same shape:

```
send streaming/non-streaming /api/chat  ─▶  parse *first* tool_call (ollama-parse-tool-call)
  └─▶ if tool_call:
         execute-tool
         session-add-message "user" "Tool result for ..."
         single non-streaming ollama-chat follow-up   ◀── never checks for another tool_call
         display follow-up content
     if no tool_call:
         display content
```

Critical line in `src/sage/ollama.scm:375-391`: `ollama-parse-tool-call` takes
`(car tool-calls-list)` — **it literally discards every tool_call after the first**, even
if the model did emit multiple in one streamed response.

The follow-up turn (`repl.scm:737/795`) calls `ollama-chat` (non-streaming) and:
- captures the content only
- does **not** re-enter the tool-call check
- appends the text directly to the session and to stdout

There is no recursion, no `while tool_call` loop, no "keep going until the model stops calling tools".

### 2.2 Wire evidence (`.logs/http.jsonl`)

Across 8 prompts we captured 18 `POST-stream /api/chat` responses to `llama3.2:latest`.
Every single one that emitted a tool_call emitted **exactly one** function name in the
`tool_calls` array (first_chunk analysis, filtered to llama3.2):

```
 0 chunks=3    tool_calls=True   names=['read_file']
 1 chunks=2    tool_calls=True   names=['search_files']
 2 chunks=4    tool_calls=True   names=['git_status']
 3 chunks=2    tool_calls=True   names=['search_files']
 4 chunks=3    tool_calls=True   names=['read_file']
 5 chunks=38   tool_calls=True   names=['read_file']     ← numbered-list prompt
 6 chunks=2    tool_calls=True   names=['read_file']
 7 chunks=3    tool_calls=True   names=['write_file']
 8 chunks=2    tool_calls=True   names=['read_file']
 9 chunks=2    tool_calls=True   names=['list_files']
```

Across **18 non-streaming follow-up responses**, zero emitted a second tool_call.
Every follow-up produced only plain `content` text. This kills path (1) ("one
streamed response with multiple tool_calls") AND path (2) ("model requests step
2 in the follow-up") simultaneously — llama3.2 simply never produces the second
tool call under the current system prompt. We observed only path (3): "only the last tool".

### 2.3 Why the LAST tool wins

The model appears to lexically scan the prompt, pick the final actionable tool verb,
and emit that as its single `tool_call`. Even in explicit "First X, then Y" phrasing,
llama3.2 treats Y as the "real" request and silently drops X. The sage dispatch loop
has no chance to course-correct because by the time a tool result comes back, the model
has already committed to "the task is done".

---

## 3. Tool fire rate per prompt

| # | Prompt | Expected tools | Tool fired | Success? |
|---|---|---|---|---|
| 1 | "First use read_file to read CLAUDE.md, then use list_files to show me what is in tests/" | 2 (read_file, list_files) | 1 (list_files) — and it listed `.` not `tests/` | No |
| 2 | "Use git_status..., then use git_log..., then use git_diff..." | 3 (git_status, git_log, git_diff) | 1 (git_diff) — returned empty string despite real unstaged changes | No |
| 3 | "Read src/sage/version.scm and src/sage/util.scm" | 2 (read_file x2) | 1 (read_file util.scm — picked the *second* file) | No |
| 4 | "Do these in order: 1) read CLAUDE.md, 2) read STATUS.org, 3) tell me the version of each" | 2 (read_file x2) | 1 (read_file `../STATUS.org` → Unsafe path error) | No |
| 5 | "Read the file CLAUDE.md and tell me which test suites are listed in the Test Suites table" | 1 (read_file) + reasoning | 1 (read_file CLAUDE.md) | **Yes** |
| 6 | "Use write_file to create /tmp/sage-chain-test.txt with 'step 1 done', then use read_file to read it back" | 2 (write_file, read_file) | 1 (read_file — and the file didn't exist) | No |
| 7 (control) | "Use read_file with path CLAUDE.md" | 1 | 1 (read_file) | Yes |
| 8 (workaround) | (following prompt 7) "Now use list_files to show tests/" | 1 | 1 (list_files) | Yes |

**Native multi-step chaining rate: 0/6.** Single-tool prompts still work (prompts 5, 7, 8).
The workaround — two sequential user prompts — successfully chained `read_file` then
`list_files` with one tool fired per user message, confirming that user-driven sequencing
is the only reliable multi-step pattern.

---

## 4. Failure-mode taxonomy

### F1 — "Last tool wins" (prompts 1, 2, 3, 6)

The model reduces a multi-step request to a single tool_call, and it's almost always the
last tool verb in the prompt. In prompt 2 ("git_status, then git_log, then git_diff"), the
model fired `git_diff`. In prompt 3 ("Read version.scm and util.scm"), it read util.scm.
In prompt 6 ("write then read"), it read. Every time, the first N-1 steps are silently dropped.

### F2 — Post-partial hallucinated continuation (prompts 1, 2, 6)

After only one tool fires, the follow-up turn narrates as if all steps ran successfully.
Quotes from this session:

- **Prompt 6** (write_file→read_file, only read_file fired on a nonexistent file):
  > "The issue here is that the `/tmp` directory in Linux does not have execute permissions,
  > so the file you created with `write_file` cannot be accessed."

  This is a dangerous double-hallucination: the model claims `write_file` ran, and invents
  a false Linux permissions diagnosis. It even suggests `sudo chmod 755 /` to "fix" it.

- **Prompt 4** (numbered-list read CLAUDE.md, read STATUS.org):
  > "The output for CLAUDE.md is: Version: 1.0.0"

  `read_file` was called only on `../STATUS.org` (which returned "Unsafe path" anyway).
  CLAUDE.md was never read, and there is no `Version: 1.0.0` string anywhere in it. The
  model fabricated both the fact that it read the file and the contents.

- **Prompt 2** (three git tools, only git_diff fired and returned empty):
  > "No file results returned. Would you like me to explain why?"

  git_diff returned empty because sage's `git_diff` emits nothing when only binary/PNG
  diffs exist in the tree (tests/fixtures PNGs are the only unstaged changes). The model
  does not realize git_status and git_log were never run and offers to explain "why
  no results" — when the real answer is "I never ran git_status".

### F3 — Inline text-format tool_call streams (prompt 4)

Observed once: in prompt 4 the streaming path visibly rendered multiple text-format
`tool_call` blobs as content chunks:

```
[streaming llama3.2:latest] }; {"name": "list_files", "parameters": {"path": "../"};
{"name": "list_files", "parameters": {"path": "../"}}; {"name": "read_file",
"parameters": {"path": "../README.md"}}
```

These are model-generated prose, not native Ollama `tool_calls`. Ollama's tool-call
back-parser appears to have fished one out and synthesized a single `tool_calls` entry
(for `read_file ../STATUS.org`), while the content stream showed the raw JSON-like
text. sage displays none of this as a warning — the user sees weird pseudo-JSON
flicker and then a single `[Tool: read_file]` block with a path they never asked for.

### F4 — Wrong-scope tool argument selection (prompt 1)

Prompt 1 asked to list `tests/`. The model fired `list_files` on the *workspace root*
(returning 21 top-level entries including `AGENTS.md`, `CLAUDE.md`, etc.), not on
`tests/`. Combined with F1 (only one tool out of two fired), the user got neither the
read_file output nor the intended directory listing. The model then commented:
`sage_task_create for each file in tests/` — inventing a nonexistent tool.

### F5 — Sandbox path phantom (prompt 4)

Multi-file reads consistently produce `../` paths (seen in the text-format blobs and in
the successful-parse `read_file ../STATUS.org`). The sandbox correctly rejects `..`
traversal with "Unsafe path", but the model clearly thinks the workspace root is one
directory up. Same root cause as UX-FINDINGS N5 — model is anchored to
`/home/sage-agent/...` or a similar synthetic root instead of the real `pwd`.

---

## 5. Workaround patterns

### W1 — Split into sequential user prompts (100% reliable)

The only mechanism that actually chains tools is the user acting as the dispatch loop:

```
> Use read_file with path CLAUDE.md
[Tool: read_file]
... content ...

> Now use list_files to show tests/
[Tool: list_files]
... content ...
```

Both tools fired, each with correct arguments. Context stays clean because each user
prompt is short and the follow-up content summarizes before the next question.

### W2 — Single tool + reasoning question (prompt 5, works)

`"Read the file CLAUDE.md and tell me which test suites are listed in the Test Suites table"`

This succeeds because **only one tool is actually needed**. The "tell me" verb is answered
from the tool result during the follow-up turn, not via another tool. This is the ideal
phrasing for "do a thing and explain it": one verb, one tool, one explain-from-context
follow-up. It is indistinguishable from pure single-tool usage and produced a correct,
complete list of the seven test suites.

### W3 — (Untested) Explicit tool-only phrasing with `stop after`

Not tested in this session but recommended for future probing: prompts like
`"Use read_file to read X. Only run that one tool, then stop."` may discourage the model
from trying to batch. Since F1's failure mode is "the model squashes N tools to 1 anyway",
constraining to 1 explicitly is likely just as effective and less hallucination-prone.

---

## 6. Recommendations for `src/sage/repl.scm`

### R1 — (Small) Loop the dispatch over tool_calls until empty

The streaming tool-call branch (`repl.scm:714-746`) and the non-streaming branch
(`:773-804`) currently execute exactly one tool and then take the follow-up's content
verbatim. Convert the follow-up into a loop:

```scheme
(let loop ((msg message))
  (let ((tc (ollama-parse-tool-call msg)))
    (if tc
        (let* ((name (assoc-ref tc "name"))
               (args (assoc-ref tc "arguments"))
               (result (execute-tool name args)))
          (format #t "~%[Tool: ~a]~%~a~%" name result)
          (session-add-message "user"
                              (format #f "Tool result for ~a:\n~a" name result))
          (let ((next (ollama-chat model (session-get-context))))
            (loop (assoc-ref next "message"))))
        ;; No more tool calls — display final content
        (let ((content (or (assoc-ref msg "content") "")))
          (session-add-message "assistant" content)
          (format #t "~%~a~%" content)))))
```

This alone would let path (2) work *if* the model decided to emit a second tool_call in
the follow-up. Currently it doesn't (we observed zero second-tool-call follow-ups across
18 follow-ups), but the loop is a prerequisite for any other fix.

### R2 — (Small) Extend `ollama-parse-tool-call` to return ALL tool_calls

`src/sage/ollama.scm:375` currently does `(car tool-calls-list)` and drops the rest.
Change to return the whole list (or an empty list) and have the dispatch loop run them
sequentially in order. This rescues path (1) immediately if Ollama ever starts returning
multi-tool arrays for llama3.2 or for future models (qwen2.5-coder, qwen3 probably do).

### R3 — (Medium) System-prompt nudge: "You MUST emit one tool call at a time and wait for its result"

Add to the system prompt:
```
When the user asks for multiple steps, perform ONLY the first step, return its tool_call,
and wait for its result in the next message before deciding the second step. Do not
batch steps. Do not describe work you have not done.
```

This directly attacks F2 (hallucinated continuation) by making explicit what the dispatch
loop enforces anyway, and it gives the model a structural hook for path (2) — "the second
tool call comes after you see the first result".

### R4 — (Medium) Post-follow-up content auditor

Even with R1+R2+R3, the model may still describe steps that did not fire. A simple
guard: after a turn, enumerate the names of tools that fired this turn, compute the set
of tool names mentioned in the final content (regex `\b(read_file|write_file|git_\w+|list_files|search_files|...)\b`),
and for any mentioned-but-not-fired name, append a `sage: warning — <tool> was not
actually executed; above text is model speculation` footer. This would have flagged all
four hallucinations in this session with zero false positives.

### R5 — (Small) Detect text-format tool_call streams during streaming

F3 observed pseudo-JSON tool-call text streaming as content. Add a regex in the chunk
handler: if an incoming content chunk matches `\{"name"\s*:\s*"\w+"\s*,\s*"parameters"`,
log a warning and either (a) suppress it from stdout and try parsing it into a real
tool_call, or (b) stop the stream and retry with a stricter prompt. This is the same
issue as UX-FINDINGS 0.6.0 gap 2.

### R6 — (Large) Explicit `/chain` REPL command

Add a `/chain` prefix that explicitly runs N user-supplied tool calls in order without
going through the model at all:

```
/chain read_file:CLAUDE.md list_files:tests/ git_status
```

This bypasses the model entirely for predictable multi-tool operations (file inspection,
status checks) and is the most reliable escape hatch. It does not fix the model's
behaviour — but it gives power users a way to do multi-step inspection without fighting
the chain-decomposition failure at all.

---

## 7. Appendix — environment & cleanup notes

- **Session tmux:** `sage-chains` (only)
- **Other sessions left alone:** `sage-otel`, `sage-qwen3`, `sage-tpf`, `copilot-otel`
- **`/tmp` cleanup:** None required — prompt 6's `write_file` never actually executed
  (the model fired `read_file` instead), so no `/tmp/sage-chain-test.txt` or
  workspace-relative `./tmp/sage-chain-test.txt` was created.
- **Exit:** sage received `/exit` cleanly; telemetry counters flushed on the way out
  (confirmed by the trailing `POST http://192.168.86.100:4318/v1/metrics` entries in
  `.logs/http.jsonl`).
- **`.logs/http.jsonl` contamination:** the shared log also picked up entries from the
  other running sage sessions (`qwen3:0.6b` streams, prior `sage-qwen3-test.txt`
  write_file). Analysis was filtered to `model == "llama3.2:latest"` to isolate this
  session's turns.
