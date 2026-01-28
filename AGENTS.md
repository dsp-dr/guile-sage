# Agent Instructions

This file is automatically loaded into sage's context on startup.

## Project Conventions

- **Documentation**: Org-mode (`.org`), not Markdown
  - `README.org`, `CONTRIBUTING.org`, `docs/*.org`
  - Exception: `AGENTS.md` (this file) for tool compatibility
- **Language**: Guile Scheme (guile3)
- **Testing**: `make check`
- **REPL**: `make run` or `guile3 -L src`

---

## Core Philosophy: Tools Over Memory

**Sage uses tools, not in-memory state.**

| DON'T (Memory)               | DO (Tools)                        |
|------------------------------|-----------------------------------|
| Remember TODOs in context    | `sage_task_create` → beads        |
| Track state in conversation  | `write_file` → persist to disk    |
| Say "I'll remember that"     | `git_add_note` → attach to commit |
| Keep mental list of changes  | `git_status` → actual state       |

Everything persists to files. Nothing lives only in conversation.

---

## Sage Agent System (v0.5.0+)

Sage can break down complex tasks and work through them systematically using beads for persistent memory.

### Task Tools

When given a multi-step request, use these tools:

- **sage_task_create** - Create a task: `{"title": "...", "description": "..."}`
- **sage_task_complete** - Mark done: `{"result": "Completed: ..."}`
- **sage_task_list** - List pending tasks
- **sage_task_status** - Check agent mode and iteration count

### Workflow

1. **Analyze** the request - identify discrete steps
2. **Create tasks** for each step using `sage_task_create`
3. **Work through** each task, using tools as needed
4. **Complete tasks** with `sage_task_complete` when done
5. **Continue** until all tasks finished

### Example

```
User: Create a UUID generator tool and test it

Sage actions:
1. sage_task_create: "Define UUID tool schema"
2. sage_task_create: "Implement UUID generation"
3. sage_task_create: "Test the tool"
4. Work on task 1... sage_task_complete
5. Work on task 2... sage_task_complete
6. Work on task 3... sage_task_complete
```

### Agent Modes

- **interactive** (default): Pause after each task for user review
- **autonomous**: Run until all tasks complete
- **yolo**: Autonomous + auto-approve dangerous tools

Set mode: `/agent autonomous`

---

## Beads Issue Tracking

This project uses **bd** (beads) for issue tracking. Run `bd quickstart` for setup or `bd onboard` for a minimal snippet.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

---

## Task Decomposition Patterns

When working on complex tasks, decompose them systematically:

### Decomposition Hierarchy

```
Epic (guile-xxx)           # Large feature or milestone
├── Feature (guile-yyy)    # Discrete capability
│   ├── Task (guile-zzz)   # Single unit of work
│   └── Task (guile-aaa)
└── Feature (guile-bbb)
    └── Task (guile-ccc)
```

### Task Sizing Rules

| Size | Description | Example |
|------|-------------|---------|
| XS | < 10 lines, single file | Fix typo, add comment |
| S | < 50 lines, 1-2 files | Add function, fix bug |
| M | 50-200 lines, 2-5 files | New tool, refactor module |
| L | > 200 lines, many files | New feature → decompose further |

**Rule**: If a task is size L, break it into M or smaller tasks.

### Task Creation Template

```bash
bd create "Verb + Object + Context" -p 1 --label task \
  --description "Why: ...
What: ...
Acceptance: ..."
```

### Saving Tasks to Beads

```bash
# Create task
bd create "Title" -p 1 --label task --description "Details..."

# Claim task
bd update <id> --status in_progress

# Complete with result
bd close <id> --comment "Result: ..."

# Sync to git
bd sync && git push
```

---

## Worktree Workflow (Self-Modification)

Sage can modify its own source code using git worktrees for isolation.

### Why Worktrees?

- **Isolation**: Changes in worktree don't affect main checkout
- **Parallel work**: Multiple tasks can run simultaneously
- **Safe rollback**: Just delete the worktree if something goes wrong
- **Test before merge**: Run tests in worktree before merging

### Worktree Directory Structure

```
guile-sage/                 # Main checkout (main branch)
├── src/sage/
├── tests/
└── worktrees/              # All worktrees live here (gitignored)
    ├── fix-session-lock/   # Worktree for session locking task
    ├── add-retry-logic/    # Worktree for retry feature
    └── refactor-tools/     # Worktree for tools refactor
```

### Self-Modification Workflow

```bash
# 1. Create worktree for task
mkdir -p worktrees
git worktree add worktrees/fix-<name> -b fix/<name>
cd worktrees/fix-<name>

# 2. Make changes
# ... edit files ...

# 3. Test in worktree
make check

# 4. Commit if tests pass
git add <files>
git commit -m "fix: description

Co-Authored-By: sage <sage@guile-sage.local>"

# 5. Return to main and merge
cd ../..
git merge fix/<name> --no-ff -m "Merge fix/<name>"

# 6. Clean up
git worktree remove worktrees/fix-<name>
git branch -d fix/<name>

# 7. Push
git push origin main
```

### Sage Self-Modification Tools

When sage needs to modify itself:

1. **Create task**: `sage_task_create` with clear scope
2. **Create worktree**: `git_commit` after creating worktree
3. **Edit source**: `edit_file` or `write_file`
4. **Run tests**: `run_tests` (requires YOLO mode)
5. **Commit**: `git_commit` with descriptive message
6. **Merge**: Manual or via `eval_scheme` (YOLO)

### Worktree Quick Reference

```bash
# List worktrees
git worktree list

# Create worktree
git worktree add worktrees/<name> -b <branch>

# Remove worktree
git worktree remove worktrees/<name>

# Prune stale worktrees
git worktree prune
```

---

## Parallel Sessions

Multiple sage instances can run concurrently with proper coordination.

### Session Isolation

Each sage instance should:
1. Use a unique session ID
2. Lock session files before writing
3. Use beads for cross-session task coordination

### Task Claiming Protocol

```bash
# Instance 1: Find and claim work
bd ready                           # See available tasks
bd update guile-xxx --status in_progress  # Claim it

# Instance 2: Sees task is claimed
bd ready                           # guile-xxx not shown
bd show guile-xxx                  # Shows "in_progress"
```

### Conflict Avoidance

| Scenario | Solution |
|----------|----------|
| Same file | Use worktrees (separate branches) |
| Same task | Claim via beads before starting |
| Same session | Use unique session IDs |
| Git conflicts | Pull before push, rebase if needed |

### Multi-Instance Workflow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Instance 1 │     │  Instance 2 │     │  Instance 3 │
│  (main)     │     │  (worktree) │     │  (worktree) │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       ▼                   ▼                   ▼
   ┌───────────────────────────────────────────────┐
   │              Beads Task Queue                 │
   │  (.beads/issues.jsonl - shared via git)      │
   └───────────────────────────────────────────────┘
```

