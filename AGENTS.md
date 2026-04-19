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

## IRC Communication

Sage agents can communicate over IRC on SageNet for coordination.

### Channels

| Channel | Purpose |
|---------|---------|
| `#sage-agents` | Agent coordination and status |
| `#sage-tasks` | Task updates and progress |
| `#sage-debug` | Debug logging and troubleshooting |

### Enable IRC

```bash
# In .env
SAGE_IRC_ENABLED=1
SAGE_IRC_SERVER=localhost
SAGE_IRC_PORT=6667
SAGE_IRC_NICK=sage-001
```

### IRC Tools

- `irc_send` - Send message to a channel
- `whoami` - Get agent identity (includes IRC info)

### Example

```
sage> Send a message to #sage-tasks
[Tool: irc_send]
Sent to #sage-tasks: Starting work on guile-m86 (session locking)
```

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
   │  (.beads/issues.jsonl - local; synced via     │
   │   `bd dolt push` to Dolt remote, not git)    │
   └───────────────────────────────────────────────┘
```


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
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
<!-- END BEADS INTEGRATION -->

---

# Project Reference (merged from former CLAUDE.md)

## Runtime

- GNU Guile 3.x (`guile` on macOS/Linux, `guile3` on FreeBSD)
- Makefile auto-detects via `command -v`
- Load path: `guile -L src`

## Architecture

```
src/sage/
  main.scm          CLI entry point (-p, -m, -y, --plan flags)
  repl.scm          Interactive REPL (readline, /commands, history)
  provider.scm      Multi-provider dispatch (ollama|openai|gemini)
  ollama.scm        Ollama native API client (/api/chat)
  openai.scm        OpenAI-compat client (LiteLLM, vLLM, etc.)
  gemini.scm        Google AI Gemini client
  mcp.scm           MCP SSE client (skills-hub, tools/list, tools/call)
  tools.scm         Tool registry (33+ built-in, safe/unsafe split, fetch_url, edit_file diff)
  scratch.scm       Content-addressed scratch store for large tool outputs
  hooks.scm         PreToolUse + PostToolUse lifecycle hooks with veto semantics
  agent.scm         Task queue (FIFO task-create + LIFO task-push!)
  session.scm       Session persistence (JSON, XDG paths)
  compaction.scm    Context compaction (5 strategies)
  context.scm       Context window management + warnings
  config.scm        Configuration (XDG, env vars, .env files, per-model token limits)
  model-tier.scm    Model tier selection (auto by token count)
  telemetry.scm     OTLP/HTTP JSON metric emission (opt-in)
  usage-stats.scm   Local JSONL usage ledger for /stats (opt-out via SAGE_STATS_DISABLE)
  provenance.scm    Ingress provenance (SHA-256, XML trust wrapping, optional GPG)
  logging.scm       Structured JSONL logging
  status.scm        Status display (thinking, streaming, done)
  util.scm          HTTP/JSON utilities, as-list, json-empty-object
  commands.scm      Custom /command registry (XDG-persisted)
  irc.scm           IRC integration (optional, only when connected)
  version.scm       Semver constants
```

## Providers

sage supports three LLM backends via `SAGE_PROVIDER`:

| Provider | Env var | Endpoint | Use case |
|----------|---------|----------|----------|
| `ollama` (default) | `SAGE_OLLAMA_HOST` | `/api/chat` | Local inference, free |
| `openai` / `litellm` | `SAGE_OPENAI_BASE`, `SAGE_OPENAI_API_KEY` | `/v1/chat/completions` | LiteLLM proxy with guardrails |
| `gemini` | `GEMINI_API_KEY` | Google AI API | Native Gemini |

## Hosts (conceptual roles)

| Role | Service | What it does |
|------|---------|--------------|
| **dev-host** | Ollama, sage, LiteLLM proxy | Local inference + REPL + proxy |
| **infra-host** | OTel Collector, Prometheus, Grafana, skills-hub | Observability + MCP server |

Configure host addresses via env vars / `.env` files — never hardcoded.

## Observability

Telemetry flows: sage → OTLP/HTTP JSON → OTel Collector → Prometheus → Grafana.
See `docs/TELEMETRY.org` for setup, metric names, and verification.

Counters emitted: `session.count`, `token.usage`, `cost.usage`, `active.time`, `code_edit.tool_decision`, `mcp.tool_call`.

LiteLLM guardrail headers (`x-litellm-applied-guardrails`) are surfaced in the REPL as 🛡️ emoji.

## Documentation Architecture

docs/ and reports/ have different contracts:

**`docs/`** — Living documents. MUST match the current implementation.
If a doc describes something that doesn't match `src/`, that's a bug.
Update the doc when changing the code. These are the contract barrier
for the architecture level.

| Document | What it covers | Update when |
|----------|---------------|-------------|
| `ARCHITECTURE.org` | C4 diagrams, module list, startup sequence, data flow | Any module added/removed/renamed |
| `TELEMETRY.org` | Metric names, OTLP setup, verification | Any counter added or endpoint changed |
| `CLI-COMPARISON.org` | Feature matrix vs other CLIs | Any feature shipped or gap closed |
| `TIMING-PROTOCOL.org` | Benchmark methodology + locked-in numbers | Model defaults change or new provider |
| `MCP-CONTRACT.org` | MCP protocol invariants (23) | MCP client behavior changes |
| `EU-AI-ACT-GUARDRAILS.org` | LiteLLM guardrail spec | Guardrail config changes |
| `ROADMAP.org` | Epics with shipped/open status | Epic completed or new one filed |
| `RELEASE-0.6.0.org` | v0.6.0 changelog (frozen) | Never (it's a release snapshot) |
| `TOOLS.org` / `TOOLS-GUIDE.org` | Tool reference | Any tool added/removed/changed |
| `COMMANDS.org` | Slash command reference | Any /command added |

**`docs/reports/`** — Point-in-time snapshots. YYYYMMDD-prefixed.
Never updated after creation. Future agents read these for context
but they are NOT the source of truth for current behavior.

**`docs/adr/`** — Architecture Decision Records. Numbered, immutable
after acceptance. Record WHY a decision was made.

## Test Suites

| Suite | Notes |
|-------|-------|
| test-session.scm | Session CRUD |
| test-tools.scm | Tool dispatch, safety, path scope, coerce->int |
| test-security.scm | Sandbox enforcement |
| test-compaction.scm | Context compression strategies |
| test-compaction-security.scm | Compaction + safety |
| test-compaction-deep.scm | 5 strategies × 3 provider fixtures |
| test-auto-compact.scm | 80% threshold + /compact command |
| test-pbt.scm | Property-based (6400+ trials) |
| test-telemetry.scm | OTLP payload + backoff |
| test-model-fallback.scm | Graceful model removal |
| test-model-tier.scm | Tier selection + defaults |
| test-model-capability.scm | Model capability checks |
| test-http-debug.scm | Wire-level debug logging |
| test-mcp.scm | MCP SSE + JSON-RPC |
| test-provider.scm | Multi-provider dispatch |
| test-repl.scm | REPL integration |
| test-repl-chains.scm | Multi-step tool chain loop |
| test-repl-guard.scm | Anti-hallucination guard |
| test-commands.scm | Slash command dispatch |
| test-context.scm | Context window management |
| test-ollama.scm | Ollama client + JSON parser |
| test-log-introspection.scm | Log search/stats tools |
| test-image-gen.scm | Image generation (flux) |
| test-harness.scm | SRFI-64 compat shim (shared by all tests) |

## Conventions

- Progressive commits: one concept per commit, explicit staging
- Never `git add -A` or `git add .`
- Commit format: `<type>(<scope>): <description>`
- Structured git notes (CPRR): attribution, testing, conjecture, validation, research
- Documentation in org-mode except AGENTS.md (this file)
- Tools over memory: persist state to files, not conversation
- Use `bd` for all issue tracking (not TaskCreate or markdown TODOs)
- Use tmux for long-running / non-blocking work

## Session Completion

1. Run quality gates: `gmake check`
2. Update issues via bd
3. Push to remote: `git pull --rebase && bd dolt push && git push`

## Known Issues

- Context limit defaults to 8000 (Ollama tier) for all providers — should read model capability from LiteLLM
- `run_tests` output can blow up context (needs truncation + ANSI stripping)
- Streaming disabled for openai provider (SSE format differs from Ollama NDJSON)

## Roadmap (v0.7.0 epics)

| Epic | Priority | Status |
|------|----------|--------|
| Multi-step tool chains | P1 | ✓ shipped (dispatch loop) |
| /compact slash command | P1 | ✓ wired (5 strategies) |
| Stdio MCP transport | P1 | open |
| Multi-provider (Ollama + Gemini + LiteLLM) | P1 | ✓ shipped |
| Prompt caching via Ollama | P2 | open |
| Web search tool | P2 | open |
| Plan/read-only mode | P2 | open |
| Auto-memory | P2 | open |


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
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
<!-- END BEADS INTEGRATION -->
