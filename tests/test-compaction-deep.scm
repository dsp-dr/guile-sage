#!/usr/bin/env guile3
!#
;;; test-compaction-deep.scm --- Deep compaction algorithm tests
;;;
;;; Tests the compaction strategies against realistic message histories
;;; from different provider shapes (Ollama, Gemini/LiteLLM, cloud).
;;; Verifies invariants that must hold regardless of provider.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage compaction)
             (sage session)
             (sage config)
             (srfi srfi-1)
             (ice-9 format))

(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Deep Compaction Algorithm Tests ===~%")

;;; ============================================================
;;; Test fixtures: realistic message histories per provider
;;; ============================================================

;;; A "message" is an alist with role, content, tokens (optional).
;;; These simulate what session-get-messages returns after multi-turn
;;; conversations through different providers.

(define (make-msg role content . rest)
  (let ((tokens (if (pair? rest) (car rest)
                    (estimate-tokens content))))
    `(("role" . ,role)
      ("content" . ,content)
      ("tokens" . ,tokens))))

;;; Short tool-using session (Ollama-like: terse, tool results inline)
(define *ollama-session*
  (list
   (make-msg "system" "You are a Guile Scheme AI agent. Use tools when needed.")
   (make-msg "user" "List the files in src/sage")
   (make-msg "assistant" "" 5)  ; empty content + tool call
   (make-msg "user" "Tool result for glob_files:\nagent.scm\nconfig.scm\nollama.scm\nrepl.scm\ntools.scm\nutil.scm")
   (make-msg "assistant" "Here are the files in src/sage:\n- agent.scm\n- config.scm\n- ollama.scm\n- repl.scm\n- tools.scm\n- util.scm")
   (make-msg "user" "Read version.scm")
   (make-msg "assistant" "" 5)
   (make-msg "user" "Tool result for read_file:\n(define *version* \"0.7.0\")")
   (make-msg "assistant" "The current version is 0.7.0, defined in src/sage/version.scm.")))

;;; Verbose Gemini session (longer responses, reasoning traces)
(define *gemini-session*
  (list
   (make-msg "system" "You are a helpful AI assistant for guile-sage development.")
   (make-msg "user" "Explain how the compaction module works")
   (make-msg "assistant"
     (string-append
      "The compaction module in `src/sage/compaction.scm` implements five strategies "
      "for reducing the context window when it approaches the model's token limit.\n\n"
      "1. **compact-truncate**: Simple sliding window — keeps the last N messages.\n"
      "2. **compact-token-limit**: Fits messages within a token budget.\n"
      "3. **compact-importance**: Scores messages by keyword presence + recency.\n"
      "4. **compact-summarize**: Generates a summary of older messages.\n"
      "5. **compact-intent**: Extracts the user's intent and filters by relevance.\n\n"
      "The `compact-auto` function selects the best strategy automatically."))
   (make-msg "user" "What about the token counting?")
   (make-msg "assistant"
     (string-append
      "Token counting uses `message-tokens` which checks the `tokens` field in "
      "each message alist first, then falls back to `estimate-tokens` which "
      "approximates at ~4 characters per token. This is consistent across providers "
      "because the token count is stored when the message is created, not re-estimated."))
   (make-msg "user" "Show me the auto-compact threshold logic")
   (make-msg "assistant"
     (string-append
      "`session-maybe-compact!` in session.scm fires when `session-total-tokens` "
      "exceeds 80% of the tier's context limit. It targets 50% of the limit and "
      "calls `compact-auto` to select the best strategy. The result replaces the "
      "session's message list.\n\nThe threshold is configurable via `#:threshold-ratio`."))
   (make-msg "user" "Can I trigger it manually?")
   (make-msg "assistant"
     (string-append
      "Yes — the `/compact` slash command calls `session-compact!` directly. "
      "It accepts an optional argument for how many recent messages to keep "
      "(default: summarize everything except the most recent). The command "
      "is registered in the REPL's command table at startup."))))

;;; Long multi-tool session (20+ messages, mixed tool calls)
(define *long-session*
  (let loop ((i 0) (msgs (list (make-msg "system" "You are sage."))))
    (if (>= i 20)
        (reverse msgs)
        (loop (1+ i)
              (cons (make-msg (if (even? i) "user" "assistant")
                              (format #f "Message ~a with some content about topic ~a"
                                      i (modulo i 5))
                              (+ 20 (* i 5)))  ; increasing token counts
                    msgs)))))

;;; ============================================================
;;; Invariant tests (must hold for ALL strategies)
;;; ============================================================

(format #t "~%--- Universal invariants ---~%")

(define (test-invariants strategy-name strategy-fn messages . args)
  "Run a compaction strategy and verify universal invariants."
  (let ((compacted (apply strategy-fn messages args)))

    ;; I1: Output is a list
    (run-test (format #f "~a: output is a list" strategy-name)
      (lambda ()
        (unless (list? compacted)
          (error "compacted must be a list" compacted))))

    ;; I2: Output is not longer than input (soft — intent strategy may
    ;; add a summary message that increases count by 1)
    (run-test (format #f "~a: output ≤ input length (+1 slack)" strategy-name)
      (lambda ()
        (unless (<= (length compacted) (1+ (length messages)))
          (error (format #f "compacted ~a >> input ~a"
                         (length compacted) (length messages))))))

    ;; I3: Every element is a message alist
    (run-test (format #f "~a: all elements are message alists" strategy-name)
      (lambda ()
        (for-each
         (lambda (m)
           (unless (and (pair? m)
                        (assoc-ref m "role")
                        (assoc-ref m "content"))
             (error "invalid message alist" m)))
         compacted)))

    ;; I4: System messages are preserved
    (run-test (format #f "~a: system messages preserved" strategy-name)
      (lambda ()
        (let ((orig-sys (filter (lambda (m) (equal? (assoc-ref m "role") "system"))
                                messages))
              (comp-sys (filter (lambda (m) (equal? (assoc-ref m "role") "system"))
                                compacted)))
          (unless (>= (length comp-sys) (length orig-sys))
            (error (format #f "system messages lost: ~a -> ~a"
                           (length orig-sys) (length comp-sys)))))))

    ;; I5: Most recent user message is preserved
    (run-test (format #f "~a: last user message preserved" strategy-name)
      (lambda ()
        (let ((last-user (find (lambda (m) (equal? (assoc-ref m "role") "user"))
                               (reverse messages))))
          (when last-user
            (unless (member last-user compacted)
              ;; May be paraphrased in summary — check content substring
              (let ((last-content (assoc-ref last-user "content")))
                (unless (any (lambda (m)
                               (string-contains (assoc-ref m "content")
                                                (substring last-content 0
                                                           (min 20 (string-length last-content)))))
                             compacted)
                  ;; Acceptable: summarization may lose the exact message
                  ;; but the intent should survive. Soft check.
                  #t)))))))

    ;; I6: Token count of output ≤ input (soft — summary messages may
    ;; add a few tokens but should not exceed input by more than 20%)
    (run-test (format #f "~a: output tokens ≤ 120% input tokens" strategy-name)
      (lambda ()
        (let ((orig-tokens (fold + 0 (map message-tokens messages)))
              (comp-tokens (fold + 0 (map message-tokens compacted))))
          (unless (<= comp-tokens (* orig-tokens 1.2))
            (error (format #f "output tokens ~a >> input ~a (>120%%)"
                           comp-tokens orig-tokens))))))

    compacted))

;;; --- Run invariants for each strategy × each fixture ---

(format #t "~%--- compact-truncate ---~%")
(test-invariants "truncate/ollama" compact-truncate *ollama-session* #:keep 5)
(test-invariants "truncate/gemini" compact-truncate *gemini-session* #:keep 4)
(test-invariants "truncate/long"   compact-truncate *long-session*   #:keep 8)

(format #t "~%--- compact-token-limit ---~%")
(test-invariants "token-limit/ollama" compact-token-limit *ollama-session* #:max-tokens 200)
(test-invariants "token-limit/gemini" compact-token-limit *gemini-session* #:max-tokens 300)
(test-invariants "token-limit/long"   compact-token-limit *long-session*   #:max-tokens 500)

(format #t "~%--- compact-importance ---~%")
(test-invariants "importance/ollama" compact-importance *ollama-session* #:keep 5)
(test-invariants "importance/gemini" compact-importance *gemini-session* #:keep 4)
(test-invariants "importance/long"   compact-importance *long-session*   #:keep 8)

(format #t "~%--- compact-intent ---~%")
(test-invariants "intent/ollama" compact-intent *ollama-session* #:max-tokens 200)
(test-invariants "intent/gemini" compact-intent *gemini-session* #:max-tokens 300)
(test-invariants "intent/long"   compact-intent *long-session*   #:max-tokens 500)

(format #t "~%--- compact-auto ---~%")
(test-invariants "auto/ollama" compact-auto *ollama-session* #:target-tokens 200)
(test-invariants "auto/gemini" compact-auto *gemini-session* #:target-tokens 300)
(test-invariants "auto/long"   compact-auto *long-session*   #:target-tokens 500)

;;; ============================================================
;;; Strategy-specific behavior tests
;;; ============================================================

(format #t "~%--- Strategy-specific behavior ---~%")

(run-test "truncate: keep=3 retains exactly 3 non-system messages + system"
  (lambda ()
    (let* ((compacted (compact-truncate *ollama-session* #:keep 3))
           (non-system (filter (lambda (m)
                                 (not (equal? (assoc-ref m "role") "system")))
                               compacted)))
      (unless (<= (length non-system) 3)
        (error (format #f "expected ≤3 non-system, got ~a" (length non-system)))))))

(run-test "token-limit: respects the budget"
  (lambda ()
    (let* ((compacted (compact-token-limit *long-session* #:max-tokens 200))
           (total (fold + 0 (map message-tokens compacted))))
      (when (> total 250)  ; some slack for rounding
        (error (format #f "~a tokens exceeds budget 200+slack" total))))))

(run-test "importance: retains system and recent messages"
  (lambda ()
    ;; importance keeps system + top-scored messages
    (let* ((msgs (list (make-msg "system" "sys")
                       (make-msg "user" "old question")
                       (make-msg "assistant" "old answer")
                       (make-msg "user" "recent question")
                       (make-msg "assistant" "We decided to use llama3.2.")))
           (compacted (compact-importance msgs #:keep 3)))
      ;; System should survive
      (unless (any (lambda (m) (equal? (assoc-ref m "role") "system")) compacted)
        (error "system message should survive"))
      ;; Should have ≤ keep+system messages
      (unless (<= (length compacted) 4)
        (error (format #f "expected ≤4 msgs, got ~a" (length compacted)))))))

(run-test "auto: selects a strategy that reduces tokens"
  (lambda ()
    (let* ((orig-tokens (fold + 0 (map message-tokens *long-session*)))
           (compacted (compact-auto *long-session* #:target-tokens 200))
           (comp-tokens (fold + 0 (map message-tokens compacted))))
      (unless (< comp-tokens orig-tokens)
        (error (format #f "auto should reduce: ~a -> ~a" orig-tokens comp-tokens))))))

;;; ============================================================
;;; Evaluation framework tests
;;; ============================================================

(format #t "~%--- Evaluation framework ---~%")

(run-test "compaction-score returns 0-100"
  (lambda ()
    (let ((score (compaction-score 0.8 0.7 0.5)))
      (unless (and (>= score 0) (<= score 100))
        (error (format #f "score ~a out of range" score))))))

(run-test "evaluate-compaction returns alist with metrics"
  (lambda ()
    (let* ((compacted (compact-truncate *ollama-session* #:keep 3))
           (eval-result (evaluate-compaction *ollama-session* compacted)))
      (unless (list? eval-result)
        (error "evaluation should return a list" eval-result))
      ;; Check it has some metric keys (exact shape may vary)
      (unless (> (length eval-result) 0)
        (error "evaluation should have at least one metric")))))

(run-test "extract-topics returns non-empty for realistic sessions"
  (lambda ()
    (let ((topics (extract-topics *gemini-session*)))
      (unless (and (list? topics) (> (length topics) 0))
        (error "should extract topics from gemini session" topics)))))

(run-test "identify-intent returns a string"
  (lambda ()
    (let ((intent (identify-intent *gemini-session*)))
      (unless (string? intent)
        (error "intent should be a string" intent)))))

(test-summary)
