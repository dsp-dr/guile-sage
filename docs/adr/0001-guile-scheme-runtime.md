# ADR-0001: Guile Scheme as Runtime

## Status
Accepted

## Context
We need to choose a runtime/language for building an AI-powered coding assistant CLI. Options considered:
- Python (like Aider)
- TypeScript/Node (like Claude Code, Copilot CLI)
- Go (like Continue CLI)
- Rust
- Guile Scheme

## Decision
Use **Guile 3.0 Scheme** as the runtime.

## Rationale

### Advantages
1. **Homoiconicity**: Code is data. Tools can generate and evaluate code naturally.
2. **REPL-native**: Interactive development is core to the language.
3. **Extensibility**: Users can extend with Scheme macros without recompilation.
4. **Lightweight**: Small binary, fast startup, no JIT warmup.
5. **POSIX integration**: Guile has excellent shell/system integration.
6. **Self-hosting potential**: The AI can modify its own tools in the same language.
7. **Unique positioning**: No other AI CLI uses Scheme - differentiation.

### Trade-offs
1. **Smaller ecosystem**: Fewer libraries than Python/Node.
2. **Learning curve**: Scheme is less familiar to most developers.
3. **JSON handling**: Requires custom implementation (done in util.scm).
4. **HTTP client**: Uses curl subprocess (acceptable for our use case).

### Mitigations
- JSON parser/writer implemented in pure Scheme
- HTTP via curl is reliable and well-tested
- Extensive documentation for contributors

## Consequences
- All modules written in Guile Scheme
- Build system uses Guild for compilation
- Users can extend with .scm files
- Unique value proposition in market

## References
- [GNU Guile Manual](https://www.gnu.org/software/guile/manual/)
- [SICP](https://mitpress.mit.edu/sites/default/files/sicp/index.html)
