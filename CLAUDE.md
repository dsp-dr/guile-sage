# guile-sage Agent Instructions

## Quick Start

```bash
gmake check          # Run test suite (598+ tests across 27 suites, all green)
gmake run            # Start sage REPL (Ollama provider, YOLO mode)
cp .env.template .env && $EDITOR .env  # Configure provider
bd ready             # Find available work
bd show <id>         # View issue details
bd update <id> --claim  # Claim work
bd close <id>        # Complete work
```

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
  tools.scm         Tool registry (22+ built-in, safe/unsafe split)
  agent.scm         In-memory task system
  session.scm       Session persistence (JSON, XDG paths)
  compaction.scm    Context compaction (5 strategies)
  context.scm       Context window management + warnings
  config.scm        Configuration (XDG, env vars, .env files)
  model-tier.scm    Model tier selection (auto by token count)
  telemetry.scm     OTLP/HTTP JSON metric emission
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
- Documentation in org-mode except AGENTS.md and CLAUDE.md
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
