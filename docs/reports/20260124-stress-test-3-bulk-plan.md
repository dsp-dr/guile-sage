# Bulk Ingestion & Synthetic Session Plan

## Approach 1: Synthetic Session Creation

Create a session JSON directly with large documents, bypassing the slow API.

### Session Format
```json
{
  "updated": "1769350031",
  "stats": {
    "total_tokens": 500000,
    "input_tokens": 450000,
    "output_tokens": 50000,
    "request_count": 10,
    "tool_calls": 0
  },
  "messages": [
    {"role": "user", "content": "<entire guile manual>", "timestamp": "...", "tokens": 200000},
    {"role": "assistant", "content": "I have read the Guile manual.", "timestamp": "...", "tokens": 10},
    {"role": "user", "content": "<entire emacs manual>", "timestamp": "...", "tokens": 250000},
    {"role": "assistant", "content": "I have read the Emacs manual.", "timestamp": "...", "tokens": 10}
  ]
}
```

### Generator Script

```bash
#!/bin/bash
# generate-synthetic-session.sh

OUTPUT="synthetic-session.json"
TIMESTAMP=$(date +%s)

# Fetch Guile manual
GUILE_DOC=$(curl -s "https://www.gnu.org/software/guile/manual/guile.html" | \
  sed 's/"/\\"/g' | tr '\n' ' ')

# Estimate tokens (~4 chars per token)
GUILE_TOKENS=$((${#GUILE_DOC} / 4))

cat > "$OUTPUT" << EOF
{
  "updated": "$TIMESTAMP",
  "stats": {
    "total_tokens": $GUILE_TOKENS,
    "input_tokens": $GUILE_TOKENS,
    "output_tokens": 0,
    "request_count": 1,
    "tool_calls": 0
  },
  "messages": [
    {
      "role": "user",
      "content": "Please read and understand this reference documentation:\n\n$GUILE_DOC",
      "timestamp": "$TIMESTAMP",
      "tokens": $GUILE_TOKENS
    },
    {
      "role": "assistant",
      "content": "I have read and understood the Guile reference manual.",
      "timestamp": "$TIMESTAMP",
      "tokens": 15
    }
  ]
}
EOF
```

## Approach 2: Add `/ingest` Command to REPL

Add a new command that reads files and adds them to context without API calls.

### Implementation in repl.scm

```scheme
;;; /ingest <file> - Add file content to session without API call
(define (cmd-ingest args session)
  (if (null? args)
      (display "Usage: /ingest <file-path>\n")
      (let* ((file-path (car args))
             (content (call-with-input-file file-path get-string-all))
             (tokens (estimate-tokens content))
             (timestamp (current-time))
             (user-msg (make-message "user"
                         (format #f "Reference document (~a):\n\n~a" file-path content)
                         timestamp tokens))
             (ack-msg (make-message "assistant"
                        (format #f "Ingested ~a (~a tokens)" file-path tokens)
                        timestamp 10)))
        (session-add-message! session user-msg)
        (session-add-message! session ack-msg)
        (format #t "Ingested ~a (~a tokens)\n" file-path tokens))))
```

## Approach 3: Force Compaction Testing

Once we have a large session (synthetic or real), force compaction:

```scheme
;; In sage REPL:
> /load synthetic-500k
Loaded synthetic-500k (4 messages, 500000 tokens)
> /compact
Compacting... (500000 tokens -> target 100000)
Compacted to 95000 tokens
> /save synthetic-500k-compacted
```

## Document Sources for Bulk Ingestion

### Local Sources
```bash
# Guile source files
find /usr/local/share/guile -name "*.scm" -exec cat {} \; > guile-stdlib.txt

# Man pages (text)
man guile | col -b > guile-man.txt
man emacs | col -b > emacs-man.txt

# Info pages (if available)
info guile --output=guile-info.txt
```

### Remote Sources
```bash
# Guile manual (HTML - large)
curl -s "https://www.gnu.org/software/guile/manual/guile.html" > guile-manual.html

# Guile manual (text version)
curl -s "https://www.gnu.org/software/guile/manual/guile.txt" > guile-manual.txt

# SRFI documents
for i in 1 9 13 41 43 64; do
  curl -s "https://srfi.schemers.org/srfi-$i/srfi-$i.html" >> srfi-docs.html
done
```

## Quick Synthetic Session Generator

```bash
#!/bin/bash
# quick-synthetic.sh - Generate 100k token synthetic session

cd $HOME/ghq/github.com/dsp-dr/guile-sage

# Use existing sage source as content
CONTENT=$(cat src/sage/*.scm | head -c 400000)  # ~100k tokens
TOKENS=$((${#CONTENT} / 4))
TS=$(date +%s)

# Escape for JSON
ESCAPED=$(echo "$CONTENT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

cat > experiments/stress-test-session-3/synthetic-100k.json << EOF
{
  "updated": "$TS",
  "stats": {
    "total_tokens": $TOKENS,
    "input_tokens": $TOKENS,
    "output_tokens": 50,
    "request_count": 1,
    "tool_calls": 0
  },
  "messages": [
    {
      "role": "user",
      "content": $ESCAPED,
      "timestamp": "$TS",
      "tokens": $TOKENS
    },
    {
      "role": "assistant",
      "content": "I have read and indexed the sage source code.",
      "timestamp": "$TS",
      "tokens": 15
    }
  ]
}
EOF

# Copy to sessions directory
cp experiments/stress-test-session-3/synthetic-100k.json \
   ~/.local/share/sage/projects/-home-user-ghq-github.com-dsp-dr-guile-sage/sessions/

echo "Created synthetic-100k session with ~$TOKENS tokens"
echo "Load with: /load synthetic-100k"
```

## Compaction Test Plan

1. Create synthetic 500k token session
2. Load into sage: `/load synthetic-500k`
3. Verify token count: `/status`
4. Trigger compaction: `/compact` (or hit token limit)
5. Verify compaction worked: `/status`
6. Save compacted session: `/save synthetic-500k-compacted`
7. Compare before/after sizes

## Token Estimation

Rough approximation: 1 token ≈ 4 characters (for English text)

| Source | Est. Size | Est. Tokens |
|--------|-----------|-------------|
| Guile manual HTML | ~2 MB | ~500k |
| Emacs manual HTML | ~5 MB | ~1.25M |
| sage/*.scm | ~50 KB | ~12k |
| SRFI docs (10) | ~500 KB | ~125k |
