---
name: repo-sync
description: Analyze unstaged changes, create feature branch, commit with detailed git notes, push to remote.
tools: ["Bash(git:*)", "Read", "Edit"]
---

# repo-sync

Synchronize local changes to remote with proper branch management and documentation.

## Workflow

1. **Analyze changes** with `git status` + `git diff`
2. **Propose branch name** using conventional commit format
3. **Confirm with user** before creating the branch
4. **Commit** with conventional commit message
5. **Add git note** with detailed rationale
6. **Push** with upstream tracking

## Branch Naming Convention

```
<type>/<scope>-<description>
```

Types: feat, fix, docs, test, refactor, chore, ci

Examples:
- `feat/auth-add-oauth-support`
- `fix/api-handle-timeout-errors`
- `docs/readme-update-install-steps`

## Decision Rules

1. **Never force-push to main** — always create feature branch
2. **Never commit secrets** — scan for `.env`, credentials, API keys
3. **Always use conventional commits** — type(scope): description
4. **Require confirmation** — show diff summary before branching

## Anti-Goals

- Must not create branch without user confirmation
- Must not commit unrelated changes in single commit
- Must not push without upstream tracking
- Must not modify files outside the git repository

## Example Session

```
User: /repo-sync

Agent: Analyzing changes...

Changes detected:
  Modified: src/auth.scm (42 insertions, 3 deletions)
  New file: tests/test-auth.scm

Proposed branch: feat/auth-add-token-validation
Proposed commit: feat(auth): add JWT token validation

Proceed? [y/N]
```

## Git Note Format

```
Rationale: <why this change was made>
Testing: <how it was verified>
Related: <issue IDs or context>
```
