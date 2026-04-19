# IRC Integration Report

**Date:** 2026-01-27
**Project:** guile-sage
**Contributors:** Claude Opus 4.5, Sage

## Summary

This session implemented IRC connectivity for guile-sage, enabling agent communication over the SageNet IRC network. Two integration paths were completed: an MCP server for Claude Code and a native Guile module for the guile-sage agent.

## Deliverables

### Native IRC Module (`src/sage/irc.scm`)

A socket-based IRC client providing:

- `irc-connect` - Connect to IRC server
- `irc-join` - Join a channel
- `irc-send` - Send message to channel or user
- `irc-disconnect` - Disconnect from server
- `irc-log-task` - Send task updates to #sage-tasks
- `irc-log-debug` - Send debug messages to #sage-debug

The module handles PING/PONG keepalive automatically and validates IPv4 connectivity.

### MCP Server (`~/.claude/tools/mcp-guile-irc`)

An MCP-compliant server exposing IRC tools to Claude Code:

- `irc_connect` - Establish connection
- `irc_join` - Join channel
- `irc_send` - Send message
- `irc_part` - Leave channel

### Agent Integration

The agent module (`src/sage/agent.scm`) broadcasts task events to IRC when connected:

- Task created
- Task started
- Task completed

### Agent Tools

Two tools expose IRC and identity functionality to the agent:

| Tool | Description |
|------|-------------|
| `whoami` | Returns agent identity and capabilities |
| `irc_send` | Sends message to specified IRC channel |

### Identity Updates

- System prompt updated with agent identity
- Git commits attributed to "Sage <sage@noreply.defrecord.com>"

## Development Approach

### MCP Server First

The MCP server was developed first as a rapid prototyping target:

1. Initial testing with echo and JSON-RPC `tools/list` to verify protocol compliance
2. Implemented core connection tools (`irc_connect`, `irc_join`, `irc_send`)
3. Registered in Claude Code's MCP configuration
4. Verified messages appeared in irssi monitoring session

### Manual Review via tmux

Development used tmux sessions for parallel monitoring:

- `sysadmin`: inspircd server process
- `claude`: irssi client for message verification, sage REPL for native testing

This setup enabled real-time observation of IRC traffic during both MCP and native module development.

### Native Module Development

With the MCP server validated, the native Guile module (`src/sage/irc.scm`) was implemented using the same IRC protocol logic, then cross-validated against the working MCP server.

## Validation

Cross-validation confirmed both integration paths function correctly:

| Test | MCP Server | Native Module |
|------|------------|---------------|
| Connect to localhost:6667 | Pass | Pass |
| Join #sage-agents | Pass | Pass |
| Send message | Pass | Pass |
| Message visible in irssi | Pass | Pass |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SAGE_IRC_ENABLED` | - | Set to "1" to enable IRC |
| `SAGE_IRC_SERVER` | localhost | IRC server hostname |
| `SAGE_IRC_PORT` | 6667 | IRC server port |
| `SAGE_IRC_NICK` | sage | IRC nickname |

### Channels

| Channel | Purpose |
|---------|---------|
| #sage-agents | Agent coordination |
| #sage-tasks | Task status updates |
| #sage-debug | Debug and monitoring |

## Self-Modification Path

The `irc_send` tool was added as hardcoded source during this session with assistance from Claude Code. However, Sage has the capability to self-modify without external intervention:

| Tool | Purpose |
|------|---------|
| `create_tool` | Register new tools at runtime |
| `reload_module` | Hot-reload modified Guile modules |
| `write_file` | Modify source files |
| `eval_scheme` | Execute arbitrary Scheme code |

Future tool additions could follow a self-modification pattern:

1. Sage identifies need for new capability
2. Uses `create_tool` to register tool dynamically, or
3. Uses `write_file` to add tool to source, then `reload_module`

This contrasts with MCP servers which require external processes. Native tools run in-process and can be created, modified, and reloaded by the agent itself.

## Related Issues

- guile-sage-eqx: IRC message queue (closed)
- guile-sage-qkd: Agent identity (closed)
- guile-sage-de1: Self-hosting capability (closed)

## Files Changed

```
src/sage/irc.scm              (new)
src/sage/agent.scm            (modified)
src/sage/tools.scm            (modified)
resources/prompts/system-prompt.md (modified)
```
