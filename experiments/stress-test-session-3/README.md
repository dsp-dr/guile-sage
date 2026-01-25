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
| | | | |

## Captured Content

Any notable outputs will be saved to this directory:
- `analysis-*.md` - Generated analysis documents
- `code-*.scm` - Generated code samples
- `capture.txt` - Raw tmux captures
