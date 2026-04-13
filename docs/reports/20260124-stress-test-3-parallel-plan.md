# Parallel Session Plan for Token Grinding

## Concept

Run multiple sage REPL instances simultaneously, each building context independently.
This multiplies token accumulation rate by the number of parallel sessions.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  tmux: sage-parallel                                         │
├─────────────┬─────────────┬─────────────┬─────────────────────┤
│  pane 0     │  pane 1     │  pane 2     │  pane 3             │
│  sage-a     │  sage-b     │  sage-c     │  sage-d             │
│  cloud API  │  cloud API  │  host.lan    │  host.lan            │
│  glm-4.7    │  glm-4.7    │  qwen3-coder│  qwen3-coder        │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

## Session Naming Convention

- `stress-test-3a` - Cloud API instance A
- `stress-test-3b` - Cloud API instance B
- `stress-test-3c` - Local (host.lan) instance C
- `stress-test-3d` - Local (host.lan) instance D

## Setup Commands

```bash
# Create new tmux session with 4 panes
tmux new-session -d -s sage-parallel
tmux split-window -h -t sage-parallel
tmux split-window -v -t sage-parallel:0.0
tmux split-window -v -t sage-parallel:0.1

# Start sage in each pane (need separate .env per instance or env vars)
tmux send-keys -t sage-parallel:0.0 "SAGE_OLLAMA_HOST=https://ollama.com SAGE_MODEL=glm-4.7 guile3 -L src -c '(use-modules (sage repl)) (repl-start)'" Enter
tmux send-keys -t sage-parallel:0.1 "SAGE_OLLAMA_HOST=https://ollama.com SAGE_MODEL=glm-4.7 guile3 -L src -c '(use-modules (sage repl)) (repl-start)'" Enter
tmux send-keys -t sage-parallel:0.2 "SAGE_OLLAMA_HOST=http://host.lan:11434 SAGE_MODEL=qwen3-coder:latest guile3 -L src -c '(use-modules (sage repl)) (repl-start)'" Enter
tmux send-keys -t sage-parallel:0.3 "SAGE_OLLAMA_HOST=http://host.lan:11434 SAGE_MODEL=qwen3-coder:latest guile3 -L src -c '(use-modules (sage repl)) (repl-start)'" Enter
```

## Implementation Requirements

### 1. Environment Variable Override (Already Supported)
The config.scm already reads from environment:
```scheme
(define (config-get key)
  (or (getenv (string-upcase (string-replace key "-" "_")))
      ...))
```

### 2. Session Isolation
Each pane needs unique session names to avoid conflicts:
- `/save stress-test-3a`
- `/save stress-test-3b`
- etc.

### 3. API Rate Limiting Considerations
- Cloud API: May have rate limits per API key
- Local host.lan: Limited by GPU/CPU capacity
- Recommendation: 2 cloud + 2 local for balance

### 4. Prompt Distribution
Different prompts per session to maximize diversity:
- Session A: Systems programming topics
- Session B: Web/distributed systems topics
- Session C: PL theory topics
- Session D: Math/algorithms topics

## Monitoring Script

```bash
#!/bin/bash
# monitor-sessions.sh
while true; do
  clear
  echo "=== Parallel Session Status ==="
  for pane in 0 1 2 3; do
    echo "--- Pane $pane ---"
    tmux capture-pane -t sage-parallel:0.$pane -p | grep -E "(Tokens:|Messages:|sage>)" | tail -3
  done
  sleep 30
done
```

## Token Aggregation

Total tokens = sum of all session tokens:
```
stress-test-3a: X tokens
stress-test-3b: Y tokens
stress-test-3c: Z tokens
stress-test-3d: W tokens
─────────────────────────
Total: X+Y+Z+W tokens
```

## Expected Throughput

With current observations:
- Cloud API: ~1000 tokens per 10 min response
- Local API: ~500 tokens per 5 min response (when working)

Parallel (2 cloud + 2 local):
- ~2000 tokens/10min (cloud) + ~2000 tokens/10min (local)
- ~4000 tokens/10min = ~24k tokens/hour
- ~576k tokens/day (theoretical max)

## Risks

1. **API rate limits** - Cloud may throttle multiple concurrent requests
2. **Session file conflicts** - Must use unique session names
3. **Resource exhaustion** - host.lan GPU may struggle with 2 concurrent models
4. **Monitoring complexity** - Need to track 4 sessions instead of 1

## Recommended Start

1. Start with 2 sessions (1 cloud, 1 local)
2. Verify no rate limiting or resource issues
3. Scale to 4 if stable

## Quick Start

```bash
# Terminal 1 - Cloud
cd /home/dsp-dr/ghq/github.com/dsp-dr/guile-sage
SAGE_OLLAMA_HOST=https://ollama.com \
OLLAMA_API_KEY=027735e40fdc46fa898012cdb4754732.3fXx1j_0nKITgSn1AYgPGeJZ \
SAGE_MODEL=glm-4.7 \
guile3 -L src -c '(use-modules (sage repl)) (repl-start)'
# Then: /load stress-test-3a (or create new)

# Terminal 2 - Local
cd /home/dsp-dr/ghq/github.com/dsp-dr/guile-sage
SAGE_OLLAMA_HOST=http://host.lan:11434 \
SAGE_MODEL=qwen3-coder:latest \
guile3 -L src -c '(use-modules (sage repl)) (repl-start)'
# Then: /load stress-test-3b (or create new)
```
