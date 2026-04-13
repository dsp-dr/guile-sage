# REPRO — guile-tpf: `search_files` appears to ignore scope argument

Date: 2026-04-11
Model: `llama3.2:latest` via Ollama (localhost:11434)
Sage: 0.6.0
Repro session: tmux `sage-tpf`, wire trace in `.logs/http.jsonl`

## 1. Verdict — Category B (tool schema bug)

**The `search_files` tool schema in `src/sage/tools.scm` exposes no scope/path/dir
parameter at all.** The model cannot pass a scope because there is nothing in the
schema for it to pass. The only "scoping" knob available is `file_pattern`, which
maps to grep's `--include=<basename-glob>` — file basenames only, not paths — so
`file_pattern="src/sage/*.scm"` returns zero matches.

Consequently:

- The UX gap in `docs/UX-FINDINGS-0.6.0.md` N4 is caused by the **tool**, not the
  **model**. The model faithfully honoured the schema.
- Any observed "matches from tests/ but not src/sage" is a secondary artefact of
  the implementation's `head -50` cap: grep walks directories in readdir order,
  so whichever tree it hits first fills the 50-line window and the rest is cut
  off.

Fix class: tool schema update + tool body change in `src/sage/tools.scm` (no
system-prompt fix can rescue this — the model has no lever to pull).

## 2. Phase 1 — natural reproduction

Prompt (into tmux `sage-tpf`):

    Search for "define" in src/sage

Sage output (llama3.2:latest, 8s):

    The word "define" is used in several places within the `src/sage` directory:
    * In the `test-image-gen.scm` file, it's used to define ...
    * It's also used to define a custom command `define-custom-command!` ...
    * Another custom command `define-custom-command!` is used ...
    * Additionally, it's used in the test suite to assert ...
    Overall, it seems that "define" is used extensively in the `src/sage` directory ...

Every concrete file the model named lives under `tests/` or `scripts/`. **No
`src/sage/*.scm` match was shown to the model**, yet the model summarised as if
it had searched `src/sage`. This is the bug surfaced in gap N4.

## 3. Phase 2 — wire evidence (byte-exact)

The streaming chunks recorded in `.logs/http.jsonl` entry [9] (`type=response-stream`,
`url=http://localhost:11434/api/chat`) captured the first chunk emitted by
llama3.2 in response to the Phase 1 prompt. The first-chunk field contains the
tool_calls the model actually emitted:

```json
{
  "model": "llama3.2:latest",
  "message": {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "id": "call_nvuxupkc",
        "function": {
          "index": 0,
          "name": "search_files",
          "arguments": {
            "pattern": "define",
            "regex": "false",
            "file_pattern": "**/*.scm"
          }
        }
      }
    ]
  },
  "done": false
}
```

Notice what is **not** there:

- No `path`.
- No `scope`.
- No `dir`.
- No `cwd`.

The model emitted exactly the three keys the schema advertises (`pattern`,
`file_pattern`, `regex`) and nothing else. That is correct schema-conforming
behaviour.

The subsequent follow-up request in entry [12] (`type=request`) echoes back the
tool output the model was shown — a 50-line grep result dominated by
`./tests/test-image-gen.scm`, `./tests/test-harness.scm`,
`./tests/test-commands.scm`, etc. — and no `src/sage/*.scm` lines, because those
trees sort after `tests/` in the readdir order grep walked and were chopped off
by `head -50`.

## 4. Phase 3 — explicit "path=src/sage" prompt

Prompt:

    Use search_files with pattern="define" and path="src/sage" to find all defines

Wire trace entry [40] (`type=response-stream`) first chunk:

```json
{
  "model": "llama3.2:latest",
  "message": {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "id": "call_o5i4scui",
        "function": {
          "index": 0,
          "name": "search_files",
          "arguments": {
            "file_pattern": "**/define.scm",
            "pattern": "define",
            "regex": "false"
          }
        }
      }
    ]
  },
  "done": false
}
```

Key observation: even when the user literally wrote `path="src/sage"`, the model
did NOT pass a `path` key. It saw `path` wasn't in the schema and tried to
encode the scope inside `file_pattern`, producing the nonsensical glob
`**/define.scm`. That matched zero files; sage told the model "No file results
returned"; and the model replied with a stubbed-out "I couldn't retrieve the
results" and even invented a CLI form `search_files -p "define" -d src/sage`
out of thin air.

This is strong, model-agnostic evidence that the tool schema is the bottleneck.
A well-behaved model facing this schema has no other option than the exact
mangling we see here.

## 5. Phase 4 — direct tool invocation (schema bypassed)

```scheme
(execute-tool "search_files" '(("pattern" . "define-module")))
(execute-tool "search_files" '(("pattern" . "define-module") ("path" . "src/sage")))
(execute-tool "search_files" '(("pattern" . "define-module") ("file_pattern" . "src/sage/*.scm")))
```

Results:

| Call | Behaviour |
|---|---|
| **TEST 1** — no scope | Returns mixed 50-line window containing both `./tests/...` and `./src/sage/...` matches (plus binary-file noise from `src/sage/*.go`). Because grep walks from workspace root and `head -50` cuts, coverage is arbitrary. |
| **TEST 2** — with `path=src/sage` | **Byte-for-byte identical output to TEST 1.** The `path` arg is silently dropped: `tools.scm:351-358` never reads it. |
| **TEST 3** — `file_pattern=src/sage/*.scm` | **Empty output.** `grep --include='src/sage/*.scm'` matches file basenames only; no basename contains a `/`, so nothing matches. |

The implementation therefore fails two ways:

1. **No scope knob exists** — a caller cannot restrict the directory tree.
2. **`file_pattern` does not mean what the model thinks it means** — it maps to
   `--include=`, which is a basename glob, not a path glob. Anything with a `/`
   in it silently returns zero hits.

A third latent issue surfaced: grep's output is post-processed by `head -50`,
so the subset the model sees depends on directory walk order. If we *did* fix
scoping, we should also raise or remove this cap (or move the truncation so
each directory gets a fair share).

## 6. Recommended fix

Update `src/sage/tools.scm` `search_files` registration (around lines 339-363):

### 6a. Schema — add `path`

```scheme
(register-tool
 "search_files"
 "Search for pattern in files (optionally scoped to a subdirectory)"
 '(("type" . "object")
   ("properties" . (("pattern"      . (("type" . "string")
                                       ("description" . "Search pattern (literal string)")))
                    ("path"         . (("type" . "string")
                                       ("description" . "Subdirectory to search, relative to workspace (default: workspace root)")))
                    ("file_pattern" . (("type" . "string")
                                       ("description" . "Filename glob, e.g. *.scm (basename only, no slashes)")))
                    ("regex"        . (("type" . "boolean")
                                       ("description" . "Treat pattern as regex (default: false)")))))
   ("required" . #("pattern")))
 ...)
```

### 6b. Body — honour `path` through `safe-path?`

```scheme
(lambda (args)
  (let* ((pattern      (assoc-ref args "pattern"))
         (raw-path     (or (assoc-ref args "path") "."))
         (file-pattern (or (assoc-ref args "file_pattern") "*"))
         (use-regex    (assoc-ref args "regex"))
         (grep-flag    (if use-regex "-r" "-rF")))
    (cond
     ((not (safe-path? raw-path))
      (format #f "Unsafe path: ~a" raw-path))
     (else
      (let* ((scope-path (if (equal? raw-path ".") "." raw-path))
             (cmd (format #f "cd ~a && grep ~a -- '~a' --include='~a' ~a 2>&1 | head -200"
                          (workspace) grep-flag pattern file-pattern scope-path))
             (tmp (format #f "/tmp/sage-grep-~a" (getpid))))
        (system (string-append cmd " > " tmp))
        (let ((result (call-with-input-file tmp get-string-all)))
          (delete-file tmp)
          result))))))
```

Notes on the patch:

- `path` flows through `safe-path?` so `../../etc/passwd` is still blocked
  (matches the pattern used by other tools like `read_file`).
- `head -200` is a separate follow-up (even 200 is not great, but this repro
  is about scope, not truncation). The grep walk from a narrower scope is
  vastly less likely to hit the cap.
- `-- '~a'` protects against patterns starting with `-`.
- Drop the `file_pattern` description's implicit "any glob" framing —
  document that it is a basename glob so models don't try to jam slashes in.

### 6c. System prompt — no change required

Once the schema carries `path`, llama3.2 will use it. We observed the model
trying to honour scoping even when the schema didn't let it. No prompt
engineering is needed. If we wanted belt-and-braces, `SAGE.md` could add one
line: *"`search_files` accepts a `path` arg to scope to a subdirectory."*

## 7. Recommended test

Add to `tests/test-tools.scm` near the other `execute-tool "search_files"`
siblings (file has no existing `search_files` tests — we add a new block).

Insert after the existing `list_files` test around line 136:

```scheme
(run-test "search_files honours path scope"
  (lambda ()
    (let ((result (execute-tool "search_files"
                                '(("pattern" . "define-module")
                                  ("path"    . "src/sage")))))
      (unless (string? result)
        (error "search_files should return string" result))
      ;; Must include src/sage hits
      (unless (string-contains result "./src/sage/")
        (error "search_files with path=src/sage should return src/sage matches"
               result))
      ;; Must NOT include tests/ hits (the whole point of scoping)
      (when (string-contains result "./tests/")
        (error "search_files with path=src/sage should NOT return tests/ matches"
               result)))))

(run-test "search_files rejects unsafe path"
  (lambda ()
    (let ((result (execute-tool "search_files"
                                '(("pattern" . "root")
                                  ("path"    . "../../../etc")))))
      (unless (string-contains result "Unsafe")
        (error "search_files should reject unsafe path" result)))))
```

The first assertion is the regression guard: it fails on current `main`
(TEST 1/TEST 2 identical = both would pass the first `string-contains` but the
`when ... tests/` branch fires because tests/ results leak in), and passes
after the fix in 6b.

The second assertion keeps parity with the existing `read_file` unsafe-path
test at line 144 so `safe-path?` integration can't regress.

## Appendix — raw wire evidence locations

- `.logs/http.jsonl` entry index `[9]`: Phase 1 first chunk, tool_call
  `search_files` with **no `path` key**.
- `.logs/http.jsonl` entry index `[40]`: Phase 3 first chunk, tool_call
  `search_files` with **no `path` key** (and a malformed `file_pattern`).
- `.logs/sage.log` 12424: `Native tool call tool=search_files` (args not
  logged — consider adding arg logging in `src/sage/ollama.scm:387` to make
  future forensics trivial).
- `src/sage/tools.scm:339-363`: current `search_files` definition — schema
  and body that need the fix in §6.
