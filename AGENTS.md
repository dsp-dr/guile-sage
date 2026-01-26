# Agent Instructions

This file is automatically loaded into sage's context on startup.

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

