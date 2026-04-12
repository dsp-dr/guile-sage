# 20260215: safe-tools list permits write operations without YOLO

## Status

Resolved 2026-04-11. `*safe-tools*` no longer contains `write_file`,
`edit_file`, `git_commit`, `git_add_note`, `git_push` — these now require
`SAGE_YOLO_MODE`. `tests/test-security.scm` unsets YOLO at the top of the
file so denial tests work even when CI sets `SAGE_YOLO_MODE=1` globally,
and `tests/test-tools.scm`'s "write_file is safe (dev mode)" was rewritten
as "write_file requires YOLO" to exercise both paths.

## Problem

`*safe-tools*` in `src/sage/tools.scm:39-46` includes destructive tools that
should require YOLO mode:

```scheme
(define *safe-tools* '("read_file" "list_files" "git_status" "git_diff"
                       "git_log" "glob_files" "search_files"
                       "write_file" "edit_file"        ;; <-- should be gated
                       "git_commit" "git_add_note" "git_push"  ;; <-- should be gated
                       "read_logs" "search_logs"
                       "sage_task_create" "sage_task_complete"
                       "sage_task_list" "sage_task_status"
                       "generate_image"))
```

`check-permission` grants access to anything in `*safe-tools*` without
checking `YOLO_MODE`. Three security tests expect these tools to return
"Permission denied" without YOLO, but they execute and fail with `misc-error`
from runtime failures (missing files, bad git state) instead.

## Failing Tests

```
tests/test-security.scm — Permission Bypass Attempts:
  FAIL: write_file denied without YOLO (misc-error)
  FAIL: edit_file denied without YOLO (misc-error)
  FAIL: git_commit denied without YOLO (misc-error)
```

## Root Cause

`write_file`, `edit_file`, `git_commit`, and `git_push` were added to
`*safe-tools*` (likely during agent/autonomous mode work) but the security
tests were written assuming a read-only safe list.

## Proposed Fix

Split `*safe-tools*` into read-only and write tiers:

```scheme
(define *read-tools* '("read_file" "list_files" "git_status" "git_diff"
                       "git_log" "glob_files" "search_files"
                       "read_logs" "search_logs"
                       "sage_task_list" "sage_task_status"))

(define *write-tools* '("write_file" "edit_file"
                        "git_commit" "git_add_note" "git_push"
                        "sage_task_create" "sage_task_complete"
                        "generate_image"))
```

`check-permission` logic:

- Read tools: always allowed
- Write tools: require YOLO or interactive confirmation
- Everything else: require YOLO

## Impact

Low — the tools still have path traversal and injection guards. The
permission layer is defense-in-depth. But the tests should pass.

## Related Files

- `src/sage/tools.scm` — `*safe-tools*`, `check-permission`
- `tests/test-security.scm` — Permission Bypass Attempts suite
