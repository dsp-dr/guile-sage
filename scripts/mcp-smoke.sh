#!/usr/bin/env bash
# mcp-smoke.sh — grind the guile-sage MCP server over stdio with the
# easiest-to-remember pattern: echo JSON-RPC | server | jq.
# Same shape as @jwalsh/mcp-server-qrcode's "NPM Package CLI" section.
#
#   gmake mcp-smoke              # grind the real server (sage mcp-server)
#   SERVER="mcp-server-qrcode" scripts/mcp-smoke.sh   # grind any stdio MCP server
#
# Default SERVER drives the in-tree server via guile3 (dev). Once installed
# (gmake install) you can use:  SERVER="sage mcp-server" scripts/mcp-smoke.sh
set -uo pipefail
cd "$(dirname "$0")/.."

# How to launch the server under test. Default = in-tree dev invocation.
# Override with $SERVER (a shell command), e.g.:
#   SERVER="sage mcp-server"        (installed binary)
#   SERVER="mcp-server-qrcode"      (any other stdio MCP server)
run_server() {
  if [ -n "${SERVER:-}" ]; then
    eval "$SERVER"
  else
    guile3 -L src -c '(use-modules (sage main)) (main (list "sage" "mcp-server"))'
  fi
}

rpc() { # rpc METHOD PARAMS_JSON  -> single JSON-RPC line on stdout
  printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}\n' "$1" "$2" | run_server 2>/dev/null
}

echo "== guile-sage MCP smoke (echo | server | jq) =="

# THE echo test — list tool names. The one everyone should remember.
echo "-- tools/list (the echo test) --"
rpc "tools/list" "{}" | jq -r '.result.tools[].name' | sed 's/^/   /'
NTOOLS=$(rpc "tools/list" "{}" | jq -r '.result.tools | length')
echo "   ($NTOOLS tools exposed, safe-only)"

echo "-- initialize (serverInfo) --"
rpc "initialize" "{}" | jq -c '.result.serverInfo'

echo "-- tools/call git_status (safe) -> first lines --"
rpc "tools/call" '{"name":"git_status","arguments":{}}' \
  | jq -r '.result.content[0].text' | head -3 | sed 's/^/   /'

echo "-- tools/call write_file (UNSAFE) -> blocked, and INDISTINGUISHABLE from unknown (no oracle) --"
UNSAFE=$(rpc "tools/call" '{"name":"write_file","arguments":{"path":"x","content":"y"}}' \
          | jq -c '{code:.error.code, msg:(.error.message|gsub("write_file";"<n>"))}')
UNKNOWN=$(rpc "tools/call" '{"name":"nope","arguments":{}}' \
          | jq -c '{code:.error.code, msg:(.error.message|gsub("nope";"<n>"))}')
echo "   unsafe : $UNSAFE"
echo "   unknown: $UNKNOWN"
if [ "$UNSAFE" = "$UNKNOWN" ]; then
  echo "   PASS: unexposed == unknown (-32601, no oracle leak)"
else
  echo "   FAIL: unexposed leaks an oracle (differs from unknown)"; exit 1
fi

echo "== ok =="
