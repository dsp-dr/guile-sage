# ADR-0005: Context Compaction Strategy

## Status
Accepted

## Context
LLMs have finite context windows. As conversations grow, we must:
- Keep within token limits
- Preserve important information
- Maintain conversation coherence
- Minimize information loss

## Decision
Implement **5 compaction strategies** with automatic evaluation scoring.

## Strategies

### 1. Truncate (baseline)
Keep N most recent messages, always preserve system messages.
- **Pros**: Simple, predictable, fast
- **Cons**: Loses early context entirely
- **Score**: 89.5 (best overall in testing)

### 2. Token-Limit
Keep messages within token budget, newest first.
- **Pros**: Precise token control
- **Cons**: May cut mid-conversation
- **Score**: 57.6

### 3. Importance
Score messages by role, keywords, tool calls; keep highest scores.
- **Pros**: Preserves "important" messages
- **Cons**: Subjective scoring, may miss context
- **Score**: 63.0

### 4. Summarize
LLM-generated summary of older messages.
- **Pros**: Preserves information density
- **Cons**: Requires LLM call, lossy
- **Score**: 54.3

### 5. Intent
Identify conversation intent, keep relevant messages.
- **Pros**: Goal-oriented preservation
- **Cons**: May misidentify intent
- **Score**: 53.5

## Evaluation Metrics

```scheme
(define (compaction-score key-info intent compression)
  (* 100 (+ (* 0.4 key-info)        ; keyword retention
            (* 0.4 intent)           ; intent preservation
            (* 0.2 compression))))   ; size reduction
```

| Metric | Weight | Measurement |
|--------|--------|-------------|
| Key info retention | 40% | % of keywords preserved |
| Intent preservation | 40% | Same intent identified? |
| Compression ratio | 20% | Size reduction achieved |

## Auto-Compaction (v0.2)

Trigger automatically at configurable threshold:
- Default: 80% of token limit
- Environment: `SAGE_COMPACTION_THRESHOLD=80`
- Strategy: truncate (highest scoring)

```scheme
(when (> (/ current-tokens max-tokens) threshold)
  (compact-truncate messages #:keep 10))
```

## Why Truncate Wins

Counter-intuitive finding: simple truncation outperforms "smart" strategies.

**Reasons:**
1. Recent messages most relevant to current task
2. Summarization loses nuance
3. Importance scoring is subjective
4. Intent detection error-prone
5. Users can `/save` before compaction if needed

## Security Consideration

Compaction must never leak secrets:
```scheme
;; identify-intent returns categories, not content
(identify-intent messages)
;; => "Bug fixing / troubleshooting"
;; NOT: "fix bug with API_KEY=sk-..."
```

## Consequences
- Default strategy is truncate
- Users can choose via `/compact [strategy]`
- Auto-compaction at 80% (configurable)
- Evaluation framework for testing new strategies

## Future Work (v0.3)
- Context pinning: mark messages to never compact
- Hierarchical summarization
- Semantic similarity clustering

## References
- Claude Code: 95% auto-compaction
- Copilot CLI: timeline messages for status
- tests/test-compaction.scm
