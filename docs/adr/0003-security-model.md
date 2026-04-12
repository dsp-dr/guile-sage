# ADR-0003: Security Model — Safe/Unsafe Tool Separation

## Status

Accepted (2025-12). Updated 2026-04-11 to reflect commit 5bcc284
("fix(tools): require YOLO for write/edit/git mutating tools") which
moved every filesystem and git mutator out of `*safe-tools*`.

## Context

AI assistants execute arbitrary tools and touch the filesystem. The
permission model has to:

- Default to *least privilege*: a malicious or hallucinated tool call
  must not be able to write the workspace, mutate git, or evaluate
  code without explicit operator consent.
- Stay out of the way for read-only flows (browsing the codebase,
  introspecting logs, listing tasks).
- Be a *single switch* for trusted environments — no ten-checkbox UX.
- Be cheap to test, so the security tests are the contract.

## Decision

Two tiers, plus a single global override:

1. **Safe tools** — always permitted. Read-only or scoped to
   sage-managed state (sessions, tasks, image cache).
2. **Unsafe tools** — denied unless `SAGE_YOLO_MODE` (or `YOLO_MODE`)
   is set in the environment. Filesystem writes, git mutators,
   arbitrary code execution.

`check-permission` in `src/sage/tools.scm` is the only enforcement
point:

```scheme
(define (check-permission tool-name args)
  (or (member tool-name *safe-tools*)
      (config-get "YOLO_MODE")
      #f))
```

`execute-tool` consults `check-permission` before dispatching and
returns the literal string `"Permission denied for tool: <name>"`
on rejection. Tools are never invoked when permission is denied.

## The Contract (post-5bcc284)

`*safe-tools*` is a static list in `src/sage/tools.scm`. The lists
below are the canonical contract — `tests/test-tools.scm` and
`tests/test-pbt.scm` pin them.

### Safe tools (always permitted)

| Tool                  | Why it is safe                          |
|-----------------------|-----------------------------------------|
| `read_file`           | Read-only, workspace-scoped             |
| `list_files`          | Read-only, workspace-scoped             |
| `glob_files`          | Read-only, workspace-scoped             |
| `search_files`        | Read-only, workspace-scoped             |
| `git_status`          | Read-only git query                     |
| `git_diff`            | Read-only git query                     |
| `git_log`             | Read-only git query                     |
| `read_logs`           | Read-only, scoped to `.logs/`           |
| `search_logs`         | Read-only, scoped to `.logs/`           |
| `sage_task_create`    | Mutates beads state, not workspace      |
| `sage_task_complete`  | Mutates beads state, not workspace      |
| `sage_task_list`      | Read-only beads query                   |
| `sage_task_status`    | Read-only beads query                   |
| `generate_image`      | Writes to image cache, not workspace    |

A handful of additional tools (`log_stats`, `log_errors`,
`log_timeline`, `log_search_advanced`, `whoami`, `irc_send`) register
themselves via `register-safe-tool` at `init-default-tools` time and
get appended to `*safe-tools*` at runtime. They are still part of
the safe tier but are not in the static list above because the list
is meant to be the *minimum* contract — anything that should never
require YOLO.

### Unsafe tools (require `SAGE_YOLO_MODE`)

| Tool             | Why it is gated                         |
|------------------|-----------------------------------------|
| `write_file`     | Writes arbitrary workspace bytes        |
| `edit_file`      | Mutates workspace files                 |
| `git_commit`     | Mutates git history                     |
| `git_add_note`   | Mutates git refs/notes                  |
| `git_push`       | Publishes to remote                     |
| `eval_scheme`    | Arbitrary code execution                |
| `create_tool`    | Adds to the dispatch table at runtime   |
| `reload_module`  | Replaces live code                      |
| `run_tests`      | Spawns subprocesses                     |

### History

Before 5bcc284, the static list also contained `write_file`,
`edit_file`, `git_commit`, `git_add_note`, `git_push`. They were
added during agent/autonomous-mode work and silently bypassed YOLO.
The 3 known security-test failures tracked in
`docs/reports/20260215-safe-tools-permission-mismatch.md` were the
fallout. 5bcc284 removed them from the static list; this ADR is now
the source of truth that any future tool-list edit must respect.

## Path Safety (independent of permission tier)

Even safe read-only tools enforce path constraints via
`safe-path?` and `resolve-path` in `src/sage/tools.scm`:

1. **Workspace boundary** — relative paths are anchored under
   `(workspace)`; absolute paths must be under `/tmp/` or under the
   workspace root after canonicalisation.
2. **Sensitive prefixes blocked** — `.env`, `.git/`, `.ssh`,
   `.gnupg` are never returned as safe, even with YOLO. YOLO is a
   *permission* override, not a *path* override.
3. **No `..` traversal** — any input containing `..` is rejected
   before canonicalisation.

## YOLO Mode

- Set `SAGE_YOLO_MODE=1` (or `YOLO_MODE=1`) in the environment, or
  use the `-y/--yolo` CLI flag, or `make run` (which sets it for
  you). `make run-safe` deliberately leaves it unset.
- Bypasses the permission check, **not** path safety.
- CI sets it job-wide so write/edit/git tools execute under
  `make check`. `tests/test-security.scm` explicitly unsets it at
  the top of the file so its denial cases still work.

## Test Coverage

The security model is enforced by:

| File                              | Cases | What it pins                                  |
|-----------------------------------|-------|-----------------------------------------------|
| `tests/test-security.scm`         | 37    | Path traversal, command injection, denial     |
| `tests/test-tools.scm`            | 36    | Permission gate, write_file requires YOLO     |
| `tests/test-pbt.scm` (security)   | 6     | Path-rejection invariants over random inputs  |
| `tests/test-pbt.scm` (permission) | 3     | Permission gate, safe-tool registration       |

If a future change to `src/sage/tools.scm` regresses the contract
above, at least one of these suites is expected to fail.

## Alternatives Considered

### Per-tool approval prompts

- Pro: fine-grained, matches Claude Code's UX.
- Con: interactive only, useless for non-interactive agent runs and
  CI; user fatigue leads to rubber-stamping.
- Decision: rejected for v0.x; revisit if/when sage gets a TUI mode.

### Capability-based security

- Pro: more granular than two-tier.
- Con: complex to implement, hard to test exhaustively.
- Decision: out of scope until v1.0.

### OS-level sandboxing (jail/seccomp)

- Pro: strongest isolation.
- Con: platform-specific, ties sage to FreeBSD jails or Linux
  namespaces.
- Decision: out of scope.

## Consequences

- Users must explicitly opt into YOLO. `make run` does it for you;
  `make run-safe` does not.
- Read-only flows work without configuration.
- Future tool additions MUST be classified explicitly. The PR check
  is: "is the tool already in `*safe-tools*` or registered with
  `register-safe-tool`? If yes, justify it in this ADR."
- Test count is the contract. If the security tests pass, the model
  holds; if they regress, the model is broken.

## References

- `src/sage/tools.scm` — `*safe-tools*`, `check-permission`,
  `safe-path?`, `resolve-path`
- `tests/test-security.scm`, `tests/test-tools.scm`,
  `tests/test-pbt.scm`
- `docs/reports/20260215-safe-tools-permission-mismatch.md` — the
  bug that motivated the 5bcc284 fix
- OWASP Top 10
- Claude Code permission model
