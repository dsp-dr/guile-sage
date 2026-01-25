# Testing and Evaluation Process

## Overview

guile-sage uses a multi-level testing approach where Claude Code (the higher-level tool) drives guile-sage (the tool under test) through tmux sessions, enabling:

1. **Autonomous stress testing** - Extended token accumulation runs
2. **Real-world usage patterns** - Natural conversation flows
3. **Self-hosting validation** - The tool testing itself

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Claude Code (Driver)                   │
│  - Sends prompts via tmux                                   │
│  - Monitors /status periodically                            │
│  - Documents bugs and issues                                │
│  - Creates gists of session outputs                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    tmux session (sage)                      │
│  - Persistent session for UAT                               │
│  - Captures full conversation history                       │
│  - Allows scrollback review                                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      guile-sage REPL                        │
│  - Processes user prompts                                   │
│  - Executes tool calls                                      │
│  - Tracks token usage                                       │
│  - Manages session state                                    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Cloud LLM API (glm-4.7)                  │
│  - Generates responses                                      │
│  - Returns token usage metrics                              │
│  - Supports tool calling                                    │
└─────────────────────────────────────────────────────────────┘
```

## Test Scenarios

### 1. Token Accumulation Stress Test

Goal: Accumulate ~1 million tokens over extended runs to validate:
- Token tracking accuracy
- Session persistence
- Memory management
- API stability

Commands used:
```
/status              # Check token counts
/compact             # Test context compaction
/save                # Persist session state
```

### 2. Tool Calling Exercise

Test all safe tools systematically:
- `read_file` - File content reading
- `search_files` - Pattern searching
- `glob_files` - File pattern matching
- `eval_scheme` - Scheme expression evaluation
- `exec` (when enabled) - Shell command execution

### 3. Code Analysis Prompts

Heavy prompts that exercise the full system:
- "Read ALL source files and provide line-by-line review"
- "Analyze the entire codebase architecture"
- "Perform security audit with CVSS scores"
- "Generate complete API reference"

### 4. Self-Modification Tests

When running in YOLO mode:
- Sage modifies its own code
- Commits are made with `scripts/sage-commit.sh`
- Progressive commit protocol is followed

## Metrics Tracked

| Metric | Description |
|--------|-------------|
| `Tokens` | Total tokens (in + out) |
| `Messages` | Conversation turn count |
| `Requests` | API call count |
| `Tool calls` | Tool execution count |

## Session Management

Sessions are saved to:
```
~/.local/share/sage/projects/-home-dsp-dr-ghq-github-com-dsp-dr-guile-sage/sessions/
```

## Observed Bugs for Self-Hosting

Document bugs discovered during testing:

1. **[Fixed]** Token key mismatch: `estimated_tokens` vs `total_tokens`
2. **[Documented]** popen segfault on FreeBSD - workaround uses temp files
3. **[Pending]** glob_files returns empty results in some cases
4. **[Pending]** search_files regex escaping issues
5. **[Pending]** write_file permission denied for /tmp - should allow .tmp and /tmp writes

## Running a UAT Session

```bash
# Start sage in tmux
tmux new-session -d -s sage
tmux send-keys -t sage 'cd /path/to/guile-sage && make repl' Enter

# Enable debug mode
tmux send-keys -t sage '/debug' Enter

# Check status periodically
tmux send-keys -t sage '/status' Enter
tmux capture-pane -t sage -p | grep Tokens

# Save session before exit
tmux send-keys -t sage '/save stress-test-run-1' Enter
```

## Commit Identity

For autonomous commits during testing:
```bash
./scripts/sage-commit.sh "fix(module): Description"
```

This uses the `guile-sage` identity: `sage@noreply.defrecord.com`
