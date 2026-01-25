# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for guile-sage.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-guile-scheme-runtime.md) | Guile Scheme as Runtime | Accepted |
| [0002](0002-ollama-first-provider.md) | Ollama as Primary Provider | Accepted |
| [0003](0003-security-model.md) | Security Model - Safe/Unsafe Tools | Accepted |
| [0004](0004-command-synergy.md) | CLI/REPL/API Command Synergy | Accepted |
| [0005](0005-context-compaction.md) | Context Compaction Strategy | Accepted |

## Format

Each ADR follows this structure:
- **Status**: Proposed → Accepted → Deprecated/Superseded
- **Context**: Why was this decision needed?
- **Decision**: What was decided?
- **Rationale**: Why this option over alternatives?
- **Consequences**: What are the trade-offs?

## Adding New ADRs

1. Copy template: `cp 0001-guile-scheme-runtime.md 000N-title.md`
2. Update number and title
3. Fill in sections
4. Add to this index
5. Commit with `docs(adr): Add ADR-000N title`

## Stakeholder Review

ADRs requiring review should be tagged in beads:
```bash
bd create --type task --title "Review ADR-000N" --description "Stakeholder review needed"
```
