#!/bin/sh
# scripts/doc-check.sh — Minimum documentation accuracy check
#
# Treats docs/ as a lossy projection of system state. Checks that
# the projection is accurate enough for agents to act on. If any
# check fails, the doc is "dirty" and needs a rebuild.
#
# Usage: scripts/doc-check.sh          (exits non-zero on failure)
#        scripts/doc-check.sh --fix    (prints what to fix)
#
# Living docs (docs/) MUST match implementation.
# Reports (docs/reports/) are frozen — never checked here.

set -eu
cd "$(git rev-parse --show-toplevel)"

ERRORS=0
WARNINGS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo "WARN: $1"; WARNINGS=$((WARNINGS + 1)); }
pass() { echo "  ok: $1"; }

echo "=== doc-check: minimum documentation accuracy ==="
echo

# 1. Every src/sage/*.scm module appears in ARCHITECTURE.org
echo "--- Module coverage (ARCHITECTURE.org) ---"
for f in src/sage/*.scm; do
  base=$(basename "$f")
  if grep -q "$base" docs/ARCHITECTURE.org 2>/dev/null; then
    pass "$base in ARCHITECTURE.org"
  else
    fail "$base NOT in docs/ARCHITECTURE.org"
  fi
done

echo
# 2. Every src/sage/*.scm module appears in AGENTS.md
echo "--- Module coverage (AGENTS.md) ---"
for f in src/sage/*.scm; do
  base=$(basename "$f")
  if grep -q "$base" AGENTS.md 2>/dev/null; then
    pass "$base in AGENTS.md"
  else
    fail "$base NOT in AGENTS.md"
  fi
done

echo
# 3. No hardcoded IPs in docs/
echo "--- No hardcoded IPs (living docs only, not reports/) ---"
count=$(grep -rn '192\.168\.' docs/*.org docs/*.md AGENTS.md README.org .env.template 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -eq 0 ]; then
  pass "zero hardcoded IPs"
else
  fail "$count lines with hardcoded IPs"
fi

echo
# 4. All reports have YYYYMMDD prefix
echo "--- Report naming convention ---"
bad=$(ls docs/reports/ 2>/dev/null | grep -v '^[0-9]' | head)
if [ -z "$bad" ]; then
  pass "all reports YYYYMMDD-prefixed"
else
  fail "undated reports: $bad"
fi

echo
# 5. docs/ contains only living docs (no point-in-time snapshots)
echo "--- docs/ is minimal (no stale snapshots) ---"
doc_count=$(find docs -maxdepth 1 -type f | wc -l | tr -d ' ')
if [ "$doc_count" -le 15 ]; then
  pass "$doc_count living docs (≤15 threshold)"
else
  warn "$doc_count living docs (>15 — review for bloat)"
fi

echo
# 6. Version in AGENTS.md matches src/sage/version.scm
echo "--- Version consistency ---"
src_ver=$(grep 'define \*version\*' src/sage/version.scm | grep -o '"[^"]*"' | tr -d '"')
if grep -q "$src_ver" AGENTS.md 2>/dev/null; then
  pass "AGENTS.md mentions $src_ver"
else
  warn "AGENTS.md may not reference current version $src_ver"
fi

echo
# 7. Test suite table in AGENTS.md lists every test file
echo "--- Test file coverage (AGENTS.md) ---"
for f in tests/test-*.scm; do
  base=$(basename "$f")
  if grep -q "$base" AGENTS.md 2>/dev/null; then
    pass "$base in AGENTS.md"
  else
    warn "$base NOT in AGENTS.md test table"
  fi
done

echo
echo "=== Results: $ERRORS errors, $WARNINGS warnings ==="
[ "$ERRORS" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$ERRORS"
