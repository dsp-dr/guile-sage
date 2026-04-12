# guile-sage Agent Instructions

## Quick Start

```bash
gmake check          # Run test suite (34/37 passing, 3 known)
gmake run            # Start sage REPL
guile3 -L src        # Load modules manually
bd ready             # Find available work
bd show <id>         # View issue details
bd update <id> --claim  # Claim work
bd close <id>        # Complete work
```

## Runtime

- **ONLY use guile3** (not guile, not guile2)
- FreeBSD 14.3, amd64, GNU Guile 3.0.10
- Load path: `guile3 -L src`

## Architecture

```
src/sage/
  main.scm          CLI entry point
  repl.scm          Interactive REPL (readline, /commands)
  agent.scm         Agent task system (beads integration)
  ollama.scm        Ollama API client (HTTP via curl)
  tools.scm         Tool registry (22 tools, safe/unsafe split)
  session.scm       Session persistence (JSON)
  compaction.scm    Context compaction (5 strategies)
  context.scm       Context window management
  config.scm        Configuration (XDG, env vars)
  model-tier.scm    Model selection (capability-based)
  logging.scm       Structured JSONL logging
  status.scm        Status display
  util.scm          HTTP/JSON utilities
  irc.scm           IRC integration (optional)
  telemetry.scm     OTLP/HTTP JSON metric emission to infra-host:4318
  version.scm       Semver constants
```

OTLP telemetry: see `docs/TELEMETRY.org` for the manual verification harness
and metric naming. Counters land in Prometheus on nexus and surface on the
AI Tools — Multi-Provider dashboard at `/d/ai-tools/`.

## Test Suites

| Suite | Tests | Notes |
|-------|-------|-------|
| test-session.scm | 18 | Session CRUD |
| test-tools.scm | 26 | Tool dispatch, safety |
| test-security.scm | 31 (3 known fail) | Sandbox enforcement |
| test-compaction.scm | 9 | Context compression |
| test-compaction-security.scm | 4 | Compaction + safety |
| test-pbt.scm | 40 | Property-based (4,000 trials) |
| test-telemetry.scm | 13 | OTLP payload + counter accumulation |

## Conventions

- Progressive commits: one concept per commit, explicit staging
- Never `git add -A` or `git add .`
- Commit format: `<type>(<scope>): <description>`
- Documentation in org-mode except AGENTS.md and CLAUDE.md
- Tools over memory: persist state to files, not conversation

## Session Completion

1. Run quality gates: `gmake check`
2. Update issues via bd
3. Push to remote: `git pull --rebase && bd sync && git push`

## Known Issues

- 3 test-security.scm failures: write_file, edit_file, git_commit in *safe-tools*
- Uses shell `curl` for HTTP — guile-curl migration planned (guile-sage-eeh)
- Shell calls for git — native Guile migration planned (guile-sage-k53)

## Roadmap (epics)

- v0.2.0 (guile-sage-m81): Robustness & streaming
- v0.3.0 (guile-sage-rtz): Context & memory
- v0.4.0 (guile-sage-00g): MCP protocol
- v0.5.0 (guile-sage-grv): Agent modes
