# ADR-0004: CLI/REPL/API Command Synergy

## Status
Accepted

## Context
Users interact with sage in multiple ways:
1. CLI flags (`sage --yolo -p "query"`)
2. REPL commands (`/model qwen3`)
3. Programmatic API (`(ollama-set-model "qwen3")`)

Need consistent, discoverable interface across all modes.

## Decision
**Every feature must be accessible via all three interfaces** with consistent naming.

## Design Principles

### 1. Naming Convention
| CLI Flag | Slash Command | Scheme API |
|----------|---------------|------------|
| `--model` | `/model` | `ollama-model`, `ollama-set-model` |
| `--yolo` | `/yolo` | `*yolo-mode*` |
| `--continue` | (auto-load) | `session-load` |
| `--debug` | `/debug` | `*debug*` |

### 2. Flag Styles
- Short: single letter, single dash (`-y`, `-c`, `-p`)
- Long: descriptive, double dash (`--yolo`, `--continue`, `--prompt`)
- Value: equals or space (`--model=qwen3` or `--model qwen3`)

### 3. Slash Command Styles
- Always start with `/`
- Lowercase, hyphenated for multi-word (`/add-dir`)
- Arguments space-separated (`/model qwen3-coder`)
- Optional args in brackets in help (`/compact [n]`)

### 4. API Style
- Procedures use kebab-case (`session-load`)
- Predicates end with `?` (`is-safe?`)
- Mutators end with `!` (`session-clear!`)
- Config vars use `*earmuffs*` (`*debug*`)

## Implementation Pattern

```scheme
;; 1. Core API (always implement first)
(define* (feature-action #:key (option default))
  "Do the feature thing."
  ...)

;; 2. Slash command (wraps API)
(define (cmd-feature args)
  (feature-action #:option (parse-arg args))
  #t)

(hash-set! *commands* "/feature" cmd-feature)

;; 3. CLI flag (in main.scm, calls API)
(when (member "--feature" args)
  (feature-action #:option (get-flag args "--feature")))
```

## Priority Matrix

| Feature | CLI | REPL | API | Version |
|---------|-----|------|-----|---------|
| Session continue | ✓ | ✓ | ✓ | v0.1 |
| Model selection | ✓ | ✓ | ✓ | v0.1 |
| YOLO mode | ✓ | ✓ | ✓ | v0.1 |
| Debug mode | ✓ | ✓ | ✓ | v0.1 |
| Headless query | ✓ | - | ✓ | v0.1 |
| Output format | ◐ | - | ✓ | v0.2 |
| MCP management | ◐ | ✓ | ✓ | v0.4 |
| Plan mode | ◐ | ✓ | ✓ | v0.5 |

Legend: ✓ Done, ◐ Partial, - N/A

## Consequences
- Consistent mental model for users
- Features testable at API level
- Documentation auto-generatable from code
- Easier to add new features systematically

## Custom Commands (v0.3)
Allow users to define their own commands:
```
~/.config/sage/commands/deploy.scm
.sage/commands/test.scm
```

Becomes `/deploy` and `/test` in REPL.

## References
- [Gemini CLI Custom Commands](https://cloud.google.com/blog/topics/developers-practitioners/gemini-cli-custom-slash-commands)
- [Claude Code Cheatsheet](https://shipyard.build/blog/claude-code-cheat-sheet/)
- docs/COMMANDS.org
