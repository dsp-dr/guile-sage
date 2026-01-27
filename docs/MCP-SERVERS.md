# MCP Server Development for Claude Code

## Quick Start

### 1. Create the Server

```bash
mkdir -p ~/.claude/tools
cat > ~/.claude/tools/my-server <<'EOF'
#!/usr/bin/env guile
!#
;; Minimal MCP server in Guile
(use-modules (ice-9 rdelim) (ice-9 match))

;; Your tool implementations here
(define (my-tool args)
  "Tool result string")

;; MCP protocol handling (see full example below)
...
EOF
chmod +x ~/.claude/tools/my-server
```

### 2. Register with Claude Code

```bash
# Add the server
claude mcp add my-server -- ~/.claude/tools/my-server

# Verify it's connected
claude mcp list

# Get details
claude mcp get my-server

# Remove if needed
claude mcp remove my-server
```

### 3. Test the Protocol

```bash
# Test initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ~/.claude/tools/my-server

# Test tools/list
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | ~/.claude/tools/my-server

# Test tool call
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"my_tool","arguments":{}}}' | ~/.claude/tools/my-server
```

## MCP Protocol Basics

MCP uses JSON-RPC 2.0 over stdio. Required methods:

| Method | Purpose |
|--------|---------|
| `initialize` | Handshake, return capabilities |
| `tools/list` | Return available tools |
| `tools/call` | Execute a tool |
| `notifications/initialized` | Acknowledgment (no response) |

### Initialize Response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {"tools": {}},
    "serverInfo": {"name": "my-server", "version": "0.1"}
  }
}
```

### Tools List Response

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "my_tool",
        "description": "Does something useful",
        "inputSchema": {
          "type": "object",
          "properties": {
            "arg1": {"type": "string", "description": "First argument"}
          },
          "required": ["arg1"]
        }
      }
    ]
  }
}
```

### Tool Call Response

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {"type": "text", "text": "Tool output here"}
    ]
  }
}
```

## Example: guile-irc MCP Server

Located at `~/.claude/tools/mcp-guile-irc`:

- Connects to SageNet IRC (localhost:6667)
- Tools: `irc_connect`, `irc_join`, `irc_send`, `irc_part`
- Uses raw Guile sockets (no external dependencies)

### Test Sequence

```bash
# Full test
~/.claude/tools/mcp-guile-irc <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"irc_connect","arguments":{}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"irc_join","arguments":{"channel":"#sage-agents"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"irc_send","arguments":{"message":"Hello from MCP!"}}}
EOF
```

## Debugging

### Check Server Health

```bash
claude mcp list
```

### Manual Protocol Test

```bash
# With stderr visible
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ~/.claude/tools/my-server

# Stderr to file
echo '...' | ~/.claude/tools/my-server 2>debug.log
```

### Common Issues

| Issue | Fix |
|-------|-----|
| Server won't start | Check shebang, permissions (`chmod +x`) |
| "Parse error" | JSON syntax issue or exception in handler |
| IPv6 connection refused | Use `INADDR_LOOPBACK` for localhost |
| Module not found | Check load path (`add-to-load-path`) |

## Guile-Specific Tips

### Minimal JSON Parser

For throwaway servers, inline a simple parser:

```scheme
(define (json-parse str) ...)  ; See mcp-guile-irc for example
```

### Socket Connections (IPv4)

```scheme
(let ((sock (socket AF_INET SOCK_STREAM 0))
      (addr (make-socket-address AF_INET INADDR_LOOPBACK 6667)))
  (connect sock addr)
  ...)
```

### Error Handling

```scheme
(catch #t
  (lambda () (do-work))
  (lambda (key . args)
    (format #f "Error: ~a" key)))
```

## See Also

- [MCP Specification](https://modelcontextprotocol.io/specification)
- [Claude Code MCP Docs](https://code.claude.com/docs/en/mcp)
- `~/.claude/tools/mcp-guile-irc` - Working example
