# Stress Test Session 3: Final Round

**Date**: 2026-01-24
**Model**: glm-4.7 (cloud API)
**Starting Tokens**: 164,052 (from session 1 checkpoint)
**Goal**: Push toward 1M tokens, understand compaction behavior

## Session Lineage

```
Session 1: 0 → 164,052 tokens (saved)
Session 2: 164,052 → 233,363 tokens (NOT saved - /save bug)
Session 3: 164,052 → ? (continuing from session 1)
```

Session 2 was lost because `/save` was failing silently. This session continues
from the session 1 checkpoint.

## Improvements Made During Testing

### Bug Fixes
1. **ollama.scm defensive handling** (`731964a`)
   - Added guards for API timeout/malformed responses
   - Complex prompts (HAMT implementation) caused timeouts
   - `wrong-type-arg` error when token counts were `#f`

2. **repl.scm cmd-save error handling** (`dc9c7a0`)
   - Wrapped save in `catch #t` for better error messages
   - Still investigating why save fails with `misc-error`

### New Features
1. **/reload command** (`f556e40`)
   - Hot-reload modules without losing session state
   - Reloads: util, config, ollama, tools, session
   - Similar to ClojureScript figwheel live reload

## Performance Observations

| Prompt Type | Response Time | Notes |
|-------------|---------------|-------|
| Short queries | <5s | Normal operation |
| Medium essays (2k words) | 30-60s | Acceptable |
| Structured output (100 tests) | 45-60s | JSON generation |
| Full code packages | 60-90s | Multi-file generation |
| Complex CS (HAMT) | TIMEOUT | API limit exceeded |

## Known Issues

1. **`/save` failing** - Still investigating root cause
2. **Cloud API instability** - 500 errors under heavy load
3. **Timeout on complex prompts** - Need to handle gracefully

## Token Accumulation Strategy

For session 3, focus on:
1. Interdisciplinary analysis prompts (2k-2.5k words)
2. Code generation with explanations
3. Multiple rounds of follow-up questions
4. Avoid prompts likely to timeout (complex algorithms)

## Checkpoints

| Time | Tokens | Messages | Notes |
|------|--------|----------|-------|
| Start | 164,052 | 146 | Resumed from session 1 |
| +fix | 164,171 | 148 | After curl fallback fix, short test |
| +essay | 167,903 | 150 | Memory essay (2k words) |
| +scoping | 169,447 | 153 | Lexical scoping explanation |
| +errors | 171,382 | 155 | Error handling comparison (800 words) |
| +conts | 172,856 | 157 | Continuations explanation (600 words) |
| +testing | 174,568 | 159 | Testing comparison PBT vs EBT (700 words) |
| compact | 174,568 | 51 | /compact 50 - removed 109 msgs (106k tokens) |
| eval-1 | 175,931 | 53 | Lisp history (400w) |
| eval-2 | 176,962 | 53 | FRP (400w) |
| eval-3 | 177,978 | 53 | Monads (400w) |
| eval-4 | 178,676 | 53 | S-expressions (400w) |
| eval-5 | 179,965 | 53 | GC algorithms (400w) |
| grind-1 | 191,175 | 62 | Type theory (2500w) |
| grind-2 | 195,500 | 64 | Database internals (2500w) |
| grind-3 | 199,405 | 66 | Distributed systems (2500w) |
| grind-4 | 203,624 | 69 | Compiler parsing (1500w) |
| grind-5 | 206,930 | 71 | Functional patterns (1500w) |
| grind-6 | 210,236 | 73 | Concurrency models (1500w) |
| grind-7 | 212,953 | 75 | Language design (1500w) |
| grind-8 | 215,769 | 77 | Architecture patterns (1500w) |
| grind-9 | 219,010 | 79 | Testing strategies (1500w) |
| grind-10 | 222,110 | 81 | API design (1500w) |
| grind-11 | 225,219 | 83 | Observability (1500w) |

## Compaction Behavior Observed

- Compaction keeps last N messages (50 configured)
- Token count is **cumulative** (total session throughput)
- Small compacts (3 msgs) after each prompt when already at limit
- Messages stable at 50-53 while tokens continue accumulating

## High-Token Strategy Results

| Prompt Type | Words | Tokens Generated | Efficiency |
|-------------|-------|------------------|------------|
| Short essay | 400w | ~1,000-1,500 | baseline |
| Long essay | 2500w | ~4,362 | 3x better |

Large multi-topic prompts (2500w) generate significantly more tokens per request.

## Bug Fixes During Session 3

1. **util.scm curl fallback for HTTPS** (`7457133`)
   - FreeBSD gnutls has CA certificate issues with ollama.com
   - Error: `tls-certificate-error (signer-not-found invalid)`
   - Fix: Use curl for HTTPS, native Guile for HTTP
   - Now working reliably

## High-Token Prompt Catalog

These prompts consistently generate 4000+ tokens each:

### Type Theory Deep Dive (2500w)
```
Write 2500 words on advanced type theory: 1) Simply Typed Lambda Calculus -
type inference, Hindley-Milner, 2) Dependent Types - Idris, Agda, proof
assistants, Curry-Howard correspondence, 3) Linear Types - Rust ownership,
affine types, session types, 4) Effect Systems - algebraic effects, handlers,
comparison to monads. Include code examples.
```

### Database Internals (2500w)
```
Write 2500 words on database internals: 1) B-tree vs LSM-tree indexing -
write amplification, read amplification tradeoffs, 2) MVCC (Multi-Version
Concurrency Control) - snapshot isolation, how Postgres implements it,
3) Write-Ahead Logging (WAL) - crash recovery, checkpointing, 4) Query
optimization - cost-based optimization, join algorithms. Include examples
from Postgres, MySQL, and RocksDB.
```

### Memory Architecture (2500w)
```
Write 2500 words analyzing memory across four domains: 1) Computer
architecture - cache hierarchies, virtual memory, 2) Cognitive psychology -
working memory, episodic vs semantic, 3) Philosophy of mind - extended mind
thesis, 4) Cultural theory - collective memory, archives. Map conceptual
transfers between domains.
```

### Distributed Systems (2500w)
```
Write 2500 words on distributed systems: 1) Consensus - Paxos, Raft,
Byzantine fault tolerance, 2) Consistency models - linearizability,
eventual consistency, CAP theorem, 3) Distributed transactions - 2PC,
Saga pattern, 4) Leader election - Zookeeper, etcd. Include failure modes
and real-world examples.
```

### Compiler Design (2500w)
```
Write 2500 words on compiler internals: 1) Parsing - recursive descent,
parser combinators, PEG, 2) Type checking - bidirectional typing,
constraint solving, 3) Optimization - SSA form, dead code elimination,
inlining, 4) Code generation - register allocation, instruction selection.
Include examples from GCC, LLVM, and V8.
```

## Captured Content

Any notable outputs will be saved to this directory:
- `analysis-*.md` - Generated analysis documents
- `code-*.scm` - Generated code samples
- `capture.txt` - Raw tmux captures
