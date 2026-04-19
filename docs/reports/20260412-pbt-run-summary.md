# 20260412: PBT run summary — 74 properties, 7400 trials

## Status

Green. 74/74 properties pass at seed 42.

## Environment

| Field             | Value                                  |
|-------------------|----------------------------------------|
| Date              | 2026-04-12                             |
| Host              | FreeBSD infra-host 14.3-RELEASE-p7 amd64 |
| Guile             | GNU Guile 3.0.10                       |
| HEAD              | `e55ece7` (post 7a46c87 search_files PBT) |
| Seed              | 42 (`*pbt-seed*` in `tests/test-pbt.scm`)  |
| Trials / property | 100                                    |
| Total trials      | 7400                                   |
| Wall time         | ~30s (single Guile process)            |

## How to reproduce

```sh
guile3 -L src tests/test-pbt.scm
```

The seed and trial count are constants at the top of
`tests/test-pbt.scm`. Edit `*pbt-seed*` to re-shuffle the input
distributions, or `*pbt-trials*` to change coverage depth.

## Property inventory by section

| # | Section                                 | Properties | Trials |
|---|-----------------------------------------|------------|--------|
| 1 | Session State Invariants                | 4          | 400    |
| 2 | Token Estimation                        | 3          | 300    |
| 3 | Security Sandbox                        | 5          | 500    |
| 4 | Tool Dispatch                           | 3          | 300    |
| 5 | Permission Contract (ADR-0003)          | 6          | 600    |
| 6 | resolve-path Semantics                  | 4          | 400    |
| 7 | Compaction Invariants                   | 7          | 700    |
| 8 | Model Tier Ordering                     | 5          | 500    |
| 9 | Configuration                           | 5          | 500    |
| 10 | JSON Roundtrip                         | 3          | 300    |
| 11 | String Utilities                       | 3          | 300    |
| 12 | Compaction Score                       | 2          | 200    |
| 13 | as-list Shape Coercion                 | 5          | 500    |
| 14 | json-empty-object Sentinel             | 4          | 400    |
| 15 | Model Fallback Invariants              | 5          | 500    |
| 16 | coerce->int Input-Shape Coverage       | 2          | 200    |
| 17 | write_file Path Honesty (guile-ecn)    | 2          | 200    |
| 18 | search_files Path Scope (guile-tpf)    | 3          | 300    |
| 19 | Telemetry Invariants                   | 3          | 300    |
|   | **Total**                               | **74**     | **7400** |

## What each section pins

### 1. Session State Invariants (4 props)

`session-create` always produces a record with a valid name, timestamp,
empty messages list, and zero-initialised stats. Catches accidental
mutation of the default constructor.

### 2. Token Estimation (3 props)

`estimate-tokens` is non-negative for any string, monotonic in string
length, and returns 0 for non-strings. Pins the contract that token
counting can never panic on hostile input.

### 3. Security Sandbox (5 props)

For any randomly-generated path string, `safe-path?` always rejects
inputs containing `..`, `.env`, `.git/`, `.ssh`, or `.gnupg`. The
sensitive-prefix rejection holds regardless of where in the path the
prefix appears.

### 4. Tool Dispatch (3 props)

Every name in the known-tools list resolves via `get-tool`; randomly
generated unknown names always return `#f`; `execute-tool` on an
unknown tool returns the literal "Unknown tool" message instead of
crashing.

### 5. Permission Contract — ADR-0003 (6 props, added 50368ab)

Pins the post-5bcc284 `*safe-tools*` contract:

- ADR-safe tools (`read_file`, `list_files`, `git_status`, …) are always
  permitted without YOLO.
- ADR-unsafe tools (`write_file`, `edit_file`, `git_commit`,
  `git_add_note`, `git_push`, `eval_scheme`, `create_tool`,
  `reload_module`, `run_tests`) are always denied without YOLO.
- The same set is always permitted under YOLO.
- ADR-unsafe tools are absent from the static `*safe-tools*` list.
- Every ADR-safe tool name resolves via `get-tool` (catches typos).
- `execute-tool` returns "Permission denied" for ADR-unsafe tools
  without YOLO.

`with-yolo-on` / `with-yolo-off` helpers save and restore the ambient
state so this section composes safely with the write_file roundtrip
section that needs YOLO on.

### 6. resolve-path Semantics — guile-ecn (4 props, added 50368ab)

Pins the four cases `resolve-path`'s docstring promises:

- Identity on absolute paths: `(resolve-path "/tmp/foo") == "/tmp/foo"`.
- Idempotent: `(resolve-path (resolve-path p)) == (resolve-path p)`.
- Relative paths anchored under `(workspace)` with the input as a
  suffix.
- Any non-`#f` input produces an absolute output (starts with `/`).

### 7. Compaction Invariants (7 props)

`compact-truncate` shrinks output to ≤ input length and preserves
system messages; `compact-token-limit` respects the budget;
`compact-importance` respects the keep-count; `compact-summarize` adds
a summary header when it actually compacts; `extract-topics` and
`identify-intent` produce well-typed output.

### 8. Model Tier Ordering (5 props)

`resolve-model-for-tokens` always returns a tier; resolution is
reflexive (same tokens → same tier) and monotonic (more tokens → same
or higher tier); `tier-available?` agrees with the model list;
`filter-available-tiers` never returns empty.

### 9. Configuration (5 props)

`config-get` honours defaults for missing keys; `path->project-id`
replaces every `/` with `-`; the slash-only roundtrip is exact;
`get-token-limit` is always positive; `*token-limits*` entries are
all positive integers.

### 10. JSON Roundtrip (3 props)

`json-write-string -> json-read-string` is exact for strings, numbers,
and alists.

### 11. String Utilities (3 props)

`string-replace-substring` is identity for an empty needle, idempotent
when the needle is not found, and the result never contains the
search term when it was found.

### 12. Compaction Score (2 props)

`compaction-score` is always in `[0, 100]`; higher info retention
yields a higher score (monotonicity).

### 13. as-list Shape Coercion (5 props)

`as-list` is identity on lists, decomposes vectors element-wise,
returns `()` for `#f` and `'()`, and length matches the input across
all four shapes. Pins the contract for the LLM-tool-arg coercion that
killed `read_logs` before commit 769da88.

### 14. json-empty-object Sentinel (4 props)

The `json-empty-object` sentinel always serialises to literal `{}`,
survives nesting inside an alist, and `json-write-string '()` still
emits `null` (backward compat). Pins the fix from 15c7960.

### 15. Model Fallback Invariants (5 props)

`select-fallback-model` never returns an embedding or image model,
returns the preferred model when present, picks the smallest
chat-capable when the preferred is missing, and `model-available?`
agrees with `assoc` lookup.

### 16. coerce->int Input-Shape Coverage — guile-bcy (2 props)

`read_logs` and `search_logs` survive any input shape for their
integer arguments (int, string-int, inexact int, garbage string,
missing) without `wrong-type-arg`. Pins the fix from 769da88.

### 17. write_file Path Honesty — guile-ecn (2 props)

`write_file -> read_file` roundtrips for absolute `/tmp/` paths and
for workspace-relative paths. The success message must echo the
resolved path verbatim, not the input. Pins the fix from 728bcc4.

### 18. search_files Path Scope — guile-tpf (3 props, added 7a46c87)

Every match line in a scoped `search_files` result contains the scope
substring; the default scope returns a non-empty result; an unsafe
scope path (`../../../etc`) is rejected. Pins the fix from 048dcc7.

### 19. Telemetry Invariants (3 props)

`normalize-labels` output is sorted by key and idempotent under
re-application; `counter-key` is stable across input ordering for
unique keys.

## Failures

None.

## Recent additions

| Commit  | Section            | Properties | Trials |
|---------|--------------------|------------|--------|
| 50368ab | Permission Contract | +6        | +600   |
| 50368ab | resolve-path        | +4        | +400   |
| 7a46c87 | search_files scope  | +3        | +300   |

Net change since the last summary baseline (61 properties / 6100
trials): **+13 properties / +1300 trials**, all green.

## Related

- `tests/test-pbt.scm` — the source of truth
- `docs/adr/0003-security-model.md` — contract pinned by section 5
- `docs/reports/20260215-safe-tools-permission-mismatch.md` — the
  bug that motivated section 5
- `bd guile-ecn` — `resolve-path` / `write_file` honesty
- `bd guile-tpf` — `search_files` path scope
- `bd guile-bcy` — `coerce->int` input-shape coverage
