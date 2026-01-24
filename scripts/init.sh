#!/bin/sh
# init.sh - Initialize and validate guile-sage
# Usage: ./scripts/init.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== Guile-Sage Initialization ==="
echo ""

# Step 1: Check configuration
echo "Step 1: Checking configuration..."
if ! sh scripts/check-config.sh; then
    echo ""
    echo "Configuration check failed. Fix errors above and retry."
    exit 1
fi

# Step 2: Create .env if missing
echo ""
echo "Step 2: Environment setup..."
if [ ! -f ".env" ]; then
    echo "Creating .env from template..."
    cp .env.template .env
    echo "Edit .env to configure your settings."
fi

# Step 3: Run unit tests
echo ""
echo "Step 3: Running unit tests..."
if guile3 -L src tests/test-ollama.scm; then
    echo "Unit tests passed."
else
    echo "Unit tests failed!"
    exit 1
fi

# Step 4: Test Ollama chat
echo ""
echo "Step 4: Testing Ollama chat..."
guile3 -L src -c '
(use-modules (sage config)
             (sage ollama))

(config-load-dotenv)

(format #t "Host: ~a~%" (ollama-host))
(format #t "Model: ~a~%" (ollama-model))

(let* ((messages (list (list (cons "role" "user")
                             (cons "content" "Respond with only: INIT_OK"))))
       (response (ollama-chat (ollama-model) messages)))
  (let ((content (assoc-ref (assoc-ref response "message") "content")))
    (if (string-contains content "INIT_OK")
        (begin
          (format #t "~%Chat test: PASSED~%")
          (format #t "Response: ~a~%" content))
        (begin
          (format #t "~%Chat test: UNEXPECTED RESPONSE~%")
          (format #t "Response: ~a~%" content)))))
'

echo ""
echo "=== Initialization Complete ==="
echo ""
echo "Next steps:"
echo "  make repl     - Start interactive REPL"
echo "  make check    - Run all tests"
echo "  make run      - Run sage CLI"
