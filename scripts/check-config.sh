#!/bin/sh
# check-config.sh - Validate guile-sage configuration
# Usage: ./scripts/check-config.sh [--verbose]

set -e

VERBOSE=${1:-""}
ERRORS=0
WARNINGS=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_ok() {
    printf "${GREEN}[OK]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
    WARNINGS=$((WARNINGS + 1))
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
    ERRORS=$((ERRORS + 1))
}

log_info() {
    if [ -n "$VERBOSE" ]; then
        printf "[INFO] %s\n" "$1"
    fi
}

echo "=== Guile-Sage Configuration Check ==="
echo ""

# Check guile (prefer guile3, fall back to guile on macOS/brew)
echo "--- Runtime ---"
if command -v guile3 >/dev/null 2>&1; then
    GUILE_BIN=guile3
    VERSION=$(guile3 --version | head -1)
    log_ok "guile3 found: $VERSION"
elif command -v guile >/dev/null 2>&1; then
    GUILE_BIN=guile
    VERSION=$(guile --version | head -1)
    log_ok "guile found: $VERSION"
else
    GUILE_BIN=guile3
    log_error "guile/guile3 not found in PATH"
fi

# Check curl
if command -v curl >/dev/null 2>&1; then
    log_ok "curl found"
else
    log_error "curl not found (required for HTTP)"
fi

# Check .env file
echo ""
echo "--- Configuration ---"
if [ -f ".env" ]; then
    log_ok ".env file found"

    # Check for required variables
    if grep -q "SAGE_OLLAMA_HOST" .env 2>/dev/null; then
        HOST=$(grep "SAGE_OLLAMA_HOST" .env | cut -d= -f2)
        log_info "SAGE_OLLAMA_HOST=$HOST"
        log_ok "SAGE_OLLAMA_HOST configured"
    else
        log_warn "SAGE_OLLAMA_HOST not set, will use default"
    fi

    if grep -q "SAGE_MODEL" .env 2>/dev/null; then
        MODEL=$(grep "SAGE_MODEL" .env | cut -d= -f2)
        log_info "SAGE_MODEL=$MODEL"
        log_ok "SAGE_MODEL configured"
    else
        log_warn "SAGE_MODEL not set, will use default"
    fi

    if grep -q "OLLAMA_API_KEY" .env 2>/dev/null; then
        log_ok "OLLAMA_API_KEY configured (cloud mode)"
    else
        log_info "No OLLAMA_API_KEY (local mode)"
    fi
else
    log_warn ".env file not found, using defaults"
    log_info "Copy .env.template to .env to configure"
fi

# Check Ollama connectivity
echo ""
echo "--- Ollama API ---"
OLLAMA_HOST="${SAGE_OLLAMA_HOST:-http://localhost:11434}"
if [ -f ".env" ]; then
    OLLAMA_HOST=$(grep "SAGE_OLLAMA_HOST" .env 2>/dev/null | cut -d= -f2 || echo "$OLLAMA_HOST")
fi

log_info "Testing connection to $OLLAMA_HOST"
if curl -s --connect-timeout 5 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
    log_ok "Ollama API reachable at $OLLAMA_HOST"

    # List models
    MODELS=$(curl -s "$OLLAMA_HOST/api/tags" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | head -5)
    if [ -n "$MODELS" ]; then
        log_ok "Available models:"
        echo "$MODELS" | while read -r model; do
            echo "       - $model"
        done
    fi
else
    log_error "Cannot connect to Ollama at $OLLAMA_HOST"
    log_info "Make sure Ollama is running: ollama serve"
fi

# Check source files
echo ""
echo "--- Source Files ---"
for f in src/sage/config.scm src/sage/util.scm src/sage/ollama.scm; do
    if [ -f "$f" ]; then
        log_ok "$f exists"
    else
        log_error "$f missing"
    fi
done

# Check if modules load
echo ""
echo "--- Module Loading ---"
if "$GUILE_BIN" -L src -c "(use-modules (sage config))" 2>/dev/null; then
    log_ok "(sage config) loads"
else
    log_error "(sage config) failed to load"
fi

if "$GUILE_BIN" -L src -c "(use-modules (sage util))" 2>/dev/null; then
    log_ok "(sage util) loads"
else
    log_error "(sage util) failed to load"
fi

if "$GUILE_BIN" -L src -c "(use-modules (sage ollama))" 2>/dev/null; then
    log_ok "(sage ollama) loads"
else
    log_error "(sage ollama) failed to load"
fi

# Summary
echo ""
echo "=== Summary ==="
if [ $ERRORS -eq 0 ]; then
    if [ $WARNINGS -eq 0 ]; then
        printf "${GREEN}All checks passed!${NC}\n"
    else
        printf "${YELLOW}Passed with $WARNINGS warning(s)${NC}\n"
    fi
    exit 0
else
    printf "${RED}$ERRORS error(s), $WARNINGS warning(s)${NC}\n"
    exit 1
fi
