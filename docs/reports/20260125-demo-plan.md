# guile-sage Demo Plan

## Demo Objectives
Showcase guile-sage v0.2 capabilities for LLM-assisted Scheme development.

## Prerequisites (UI/UX Changes Needed)

### 1. Config-aware Prompt
Show model and endpoint in REPL prompt:
```
sage[glm-4.7@cloud]>
sage[qwen3@host.lan]>
sage[llama3@localhost]>
```

### 2. Context Size Display
Add token count to prompt or status bar:
```
sage[glm-4.7@cloud|12.3k]>
```
Or show via `/status` command (already exists).

### 3. Compaction Indicator
Show when context was compacted:
```
sage[glm-4.7@cloud|*4.2k]>   # asterisk = compacted
```

## Demo Scenarios

### Scenario 1: Basic Agentic Interaction (5 min)
1. Start sage with cloud config
2. Ask it to read a file and explain it
3. Show tool calls being made
4. Run `/status` to show token accumulation

### Scenario 2: Code Generation with Eval (10 min)
1. Show the eval framework: `guile3 -L src -L tests tests/eval/runner.scm list`
2. Pick Problem B (SemVer Ordering)
3. Ask sage to implement a solution
4. Have sage write to file
5. Run the eval: `runner.scm run semver-ordering solution.scm`
6. Iterate on failures

### Scenario 3: Parallel Grinding Session (5 min)
1. Show tmux dashboard with 4 sage instances
2. Each working on different utility library
3. Monitor with `scripts/monitor-parallel.sh`
4. Extract generated code artifacts

### Scenario 4: Context Management (5 min)
1. Accumulate context with multiple prompts
2. Show `/status` before compaction
3. Run `/compact 3` to keep last 3 messages
4. Show `/status` after compaction
5. Demonstrate continued conversation with context

## Demo Commands Cheatsheet

```bash
# Start sage
guile3 -L src -c '(use-modules (sage repl)) (repl-start)'

# Continue previous session
guile3 -L src -c '(use-modules (sage repl)) (repl-start #:continue? #t)'

# List eval problems
guile3 -L src -L tests tests/eval/runner.scm list

# Show problem spec
guile3 -L src -L tests tests/eval/runner.scm show semver-ordering

# Run solution evaluation
guile3 -L src -L tests tests/eval/runner.scm run semver-ordering solution.scm

# Start parallel sessions
tmux new-session -d -s sage-demo
tmux split-window -h
tmux split-window -v
tmux select-pane -t 0 && tmux split-window -v
# Then start sage in each pane
```

## Metrics to Capture During Demo
- Token accumulation rate per prompt
- Compaction ratio
- Tool call success rate
- Code generation accuracy (eval scores)

## Recording Notes
- Use terminal with good font (Fira Code, JetBrains Mono)
- Set TERM=xterm-256color for box drawing
- Increase font size for readability
- Consider asciinema for recording
