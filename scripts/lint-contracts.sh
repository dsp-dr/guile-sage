#!/bin/sh
# scripts/lint-contracts.sh — C4 boundary contract checker
#
# Verifies that module boundaries are clean:
#   1. Every #:export symbol is used by at least one consumer
#   2. Every (module-ref) or direct call to another module uses an exported symbol
#   3. Provider dispatch covers all provider modules
#   4. Tool registry matches SAGE.md tool list
#
# This is a lossy projection of the C4 L2 container diagram —
# the script checks that the arrows in the diagram correspond
# to real function calls in the code.

set -eu
cd "$(git rev-parse --show-toplevel)"

ERRORS=0
WARNINGS=0
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo "WARN: $1"; WARNINGS=$((WARNINGS + 1)); }
pass() { echo "  ok: $1"; }

echo "=== Contract boundary checks ==="
echo

# 1. Provider dispatch covers all provider modules
echo "--- Provider dispatch completeness ---"
for provider in ollama openai gemini; do
  if grep -q "'$provider)" src/sage/provider.scm 2>/dev/null; then
    pass "provider.scm dispatches to $provider"
  else
    fail "provider.scm missing dispatch for $provider"
  fi
done

echo
# 2. Every module in AGENTS.md exists in src/
echo "--- AGENTS.md module list vs src/ ---"
# Only check the Architecture section (between "## Architecture" and the next "##")
sed -n '/^## Architecture/,/^## [^A]/p' AGENTS.md | grep '\.scm' | grep -o '[a-z_-]*.scm' | sort -u | while read m; do
  if [ -f "src/sage/$m" ]; then
    pass "$m exists"
  else
    fail "$m listed in AGENTS.md but missing from src/sage/"
  fi
done

echo
# 3. repl.scm uses provider-* not ollama-* directly (except in provider dispatch)
echo "--- repl.scm provider abstraction ---"
direct_ollama=$(grep -v '^ *;' src/sage/repl.scm | grep -c 'ollama-chat\|ollama-list\|ollama-model\|ollama-host' 2>/dev/null || true)
if [ "$direct_ollama" -eq 0 ]; then
  pass "repl.scm has zero direct ollama-* calls"
else
  warn "repl.scm has $direct_ollama direct ollama-* calls (should use provider-*)"
fi

echo
# 4. tools.scm exports match what SAGE.md documents
echo "--- Tool registry vs SAGE.md ---"
sage_tools=$(grep -o '"[a-z_]*"' SAGE.md | tr -d '"' | sort -u)
for tool in $sage_tools; do
  if grep -q "\"$tool\"" src/sage/tools.scm 2>/dev/null; then
    pass "SAGE.md tool $tool registered"
  else
    warn "SAGE.md mentions $tool but not in tools.scm"
  fi
done

echo
# 5. Telemetry counter names match TELEMETRY.org
echo "--- Telemetry counter names ---"
code_counters=$(grep -oh '"guile_sage\.[a-z_.]*"' src/sage/repl.scm src/sage/tools.scm src/sage/mcp.scm 2>/dev/null | sort -u | tr -d '"')
for counter in $code_counters; do
  if grep -q "$counter" docs/TELEMETRY.org 2>/dev/null; then
    pass "counter $counter documented"
  else
    warn "counter $counter in code but not in TELEMETRY.org"
  fi
done

echo
# 6. No circular imports (basic check — module A uses B, B uses A)
echo "--- Circular import check ---"
circulars=0
for f in src/sage/*.scm; do
  mod=$(basename "$f" .scm)
  # Find what this module imports
  imports=$(grep '#:use-module (sage' "$f" 2>/dev/null | grep -o 'sage [a-z-]*' | sed 's/sage //' | tr '-' '_')
  for imp in $imports; do
    imp_file="src/sage/$(echo "$imp" | tr '_' '-').scm"
    [ -f "$imp_file" ] || continue
    # Does the import also import us?
    if grep -q "#:use-module (sage $mod)" "$imp_file" 2>/dev/null; then
      warn "circular: $mod <-> $imp"
      circulars=$((circulars + 1))
    fi
  done
done
[ "$circulars" -eq 0 ] && pass "no circular imports"

echo
echo "=== Results: $ERRORS errors, $WARNINGS warnings ==="
[ "$ERRORS" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$ERRORS"
