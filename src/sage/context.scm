;;; context.scm --- Context window management for sage -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Context window tracking and management:
;; - Loads system prompt into session context on startup.
;; - Tracks token usage against per-model context window limits.
;; - Emits threshold warnings at 75%, 90%, 95% of context capacity.
;; - Suggests compaction when usage exceeds 90%.
;; Pure Guile - no shell calls.

(define-module (sage context)
  #:use-module (sage config)
  #:use-module (sage logging)
  #:use-module (sage session)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:export (load-agents-context
            load-context-files  ; backward compat alias
            context-status
            ;; Context window tracking
            context-usage
            context-usage-ratio
            context-check-thresholds
            context-format-usage
            context-window-status
            ;; Warning thresholds
            *context-thresholds*
            ;; Warning/suggestion logic
            context-warnings
            context-format-warnings
            reset-fired-thresholds!))

;;; State
(define *context-source* #f)

;;; workspace-or-cwd: Get workspace or current directory
(define (workspace-or-cwd)
  (or (config-get "WORKSPACE")
      (config-get "SAGE_WORKSPACE")
      (getcwd)))

;;; load-context-file: Load a single context file into session
(define (load-context-file path label)
  "Load a context file and add to session as system message.
Returns #t on success, #f on failure."
  (if (file-exists? path)
      (catch #t
        (lambda ()
          (let ((content (call-with-input-file path get-string-all)))
            (session-add-message "system"
                                 (string-append
                                  "=== " label " ===\n"
                                  content))
            (set! *context-source* label)
            (log-info "context" (format #f "Loaded ~a" label)
                      `(("chars" . ,(string-length content))
                        ("path" . ,path)))
            #t))
        (lambda (key . args)
          (log-warn "context" (format #f "Failed to read ~a" label)
                    `(("error" . ,(format #f "~a" key))))
          #f))
      #f))

;;; load-agents-context: Load SAGE.md into session
(define (load-agents-context)
  "Load SAGE.md into session as system message."
  (let ((base (workspace-or-cwd)))
    (or (load-context-file (string-append base "/SAGE.md") "SAGE.md")
        (begin
          (log-debug "context" "No SAGE.md found")
          #f))))

;;; Backward compatibility alias
(define load-context-files load-agents-context)

;;; context-status: Show context status
(define (context-status)
  "Return status of loaded context."
  (if *context-source*
      (format #f "~a loaded into context." *context-source*)
      "No context loaded."))

;;; ============================================================
;;; Context Window Tracking
;;; ============================================================

;;; Warning thresholds as (ratio . label) pairs, sorted descending.
;;; Each threshold triggers at most once per crossing.
(define *context-thresholds*
  '((0.95 . "critical")
    (0.90 . "high")
    (0.75 . "warning")))

;;; Track which thresholds have already fired to avoid repeating.
(define *fired-thresholds* '())

;;; reset-fired-thresholds!: Clear threshold tracking (e.g. after compaction)
(define (reset-fired-thresholds!)
  (set! *fired-thresholds* '()))

;;; get-session-tokens: Late-bound accessor for session token count.
;;; Tests that set *session* via module-ref into (sage session) see a
;;; DIFFERENT *session* than a direct (session-total-tokens) call from
;;; inside (sage context) because Guile captures the binding at compile
;;; time. Late-bound resolve via module-ref reads the live binding every
;;; call. Reverts commit ea2c2ca; RFC v2 change #3 needs a different
;;; approach (likely a test-harness fix, not a call-site fix).
(define (get-session-tokens)
  (let ((proc (module-ref (resolve-module '(sage session))
                          'session-total-tokens)))
    (proc)))

;;; context-usage: Get current token usage and context window limit
;;; Arguments:
;;;   model - Optional model name for limit lookup
;;; Returns: alist with tokens, limit, ratio, and percentage
(define* (context-usage #:optional (model #f))
  (let* ((tokens (get-session-tokens))
         (limit (get-token-limit model))
         (ratio (if (> limit 0) (/ tokens limit) 0))
         (pct (inexact->exact (round (* 100.0 ratio)))))
    `(("tokens" . ,tokens)
      ("limit" . ,limit)
      ("ratio" . ,ratio)
      ("percentage" . ,pct))))

;;; context-usage-ratio: Get just the usage ratio (0.0 to 1.0+)
;;; Arguments:
;;;   model - Optional model name for limit lookup
;;; Returns: Exact rational or 0
(define* (context-usage-ratio #:optional (model #f))
  (let* ((tokens (get-session-tokens))
         (limit (get-token-limit model)))
    (if (> limit 0) (/ tokens limit) 0)))

;;; context-check-thresholds: Check if any warning thresholds are crossed
;;; Arguments:
;;;   model - Optional model name for limit lookup
;;; Returns: List of newly-crossed threshold alists, or '() if none.
;;;          Each alist: (("level" . label) ("ratio" . r) ("tokens" . n) ("limit" . l))
(define* (context-check-thresholds #:optional (model #f))
  (let* ((usage (context-usage model))
         (ratio (assoc-ref usage "ratio"))
         (tokens (assoc-ref usage "tokens"))
         (limit (assoc-ref usage "limit")))
    (let loop ((thresholds *context-thresholds*)
               (newly-fired '()))
      (if (null? thresholds)
          (reverse newly-fired)
          (let* ((pair (car thresholds))
                 (threshold-ratio (car pair))
                 (label (cdr pair)))
            (if (and (>= ratio threshold-ratio)
                     (not (member label *fired-thresholds*)))
                (begin
                  (set! *fired-thresholds* (cons label *fired-thresholds*))
                  (log-warn "context"
                            (format #f "Context window ~a: ~a% used (~a/~a tokens)"
                                    label
                                    (assoc-ref usage "percentage")
                                    tokens limit)
                            `(("threshold" . ,label)
                              ("ratio" . ,(exact->inexact ratio))))
                  (loop (cdr thresholds)
                        (cons `(("level" . ,label)
                                ("ratio" . ,ratio)
                                ("tokens" . ,tokens)
                                ("limit" . ,limit))
                              newly-fired)))
                (loop (cdr thresholds) newly-fired)))))))

;;; context-format-usage: Format context usage for display
;;; Arguments:
;;;   model - Optional model name for limit lookup
;;; Returns: Human-readable string
(define* (context-format-usage #:optional (model #f))
  (let* ((usage (context-usage model))
         (tokens (assoc-ref usage "tokens"))
         (limit (assoc-ref usage "limit"))
         (pct (assoc-ref usage "percentage")))
    (format #f "Context: ~a/~a tokens (~a%)" tokens limit pct)))

;;; context-window-status: Full status for /status command
;;; Arguments:
;;;   model - Optional model name for limit lookup
;;; Returns: Multi-line status string with usage bar
(define* (context-window-status #:optional (model #f))
  (let* ((usage (context-usage model))
         (tokens (assoc-ref usage "tokens"))
         (limit (assoc-ref usage "limit"))
         (pct (assoc-ref usage "percentage"))
         (ratio (assoc-ref usage "ratio"))
         (bar-width 30)
         (filled (min bar-width (inexact->exact (round (* bar-width (min 1.0 (exact->inexact ratio)))))))
         (empty (- bar-width filled))
         (bar (string-append (make-string filled #\#)
                             (make-string empty #\-)))
         (level-label (cond
                       ((>= ratio 0.95) " CRITICAL")
                       ((>= ratio 0.90) " HIGH")
                       ((>= ratio 0.75) " WARNING")
                       (else ""))))
    (format #f "Context window: [~a] ~a%~a~%  ~a / ~a tokens"
            bar pct level-label tokens limit)))

;;; ============================================================
;;; Warning and Suggestion Messages
;;; ============================================================

;;; context-warnings: Generate user-facing warning strings for crossed thresholds
;;; Arguments:
;;;   model - Optional model name for limit lookup
;;; Returns: List of warning strings (empty if no new thresholds crossed)
(define* (context-warnings #:optional (model #f))
  (let ((crossed (context-check-thresholds model)))
    (map (lambda (threshold)
           (let* ((level (assoc-ref threshold "level"))
                  (tokens (assoc-ref threshold "tokens"))
                  (limit (assoc-ref threshold "limit"))
                  (pct (inexact->exact
                        (round (* 100.0 (exact->inexact
                                         (assoc-ref threshold "ratio")))))))
             (cond
              ((equal? level "critical")
               (format #f "~a Context window ~a% full (~a/~a tokens). Context may be truncated. Run /compact now."
                       "[!]" pct tokens limit))
              ((equal? level "high")
               (format #f "~a Context window ~a% full (~a/~a tokens). Consider running /compact to free space."
                       "[!]" pct tokens limit))
              ((equal? level "warning")
               (format #f "~a Context window ~a% full (~a/~a tokens)."
                       "[*]" pct tokens limit))
              (else
               (format #f "[*] Context window at ~a% (~a/~a tokens)."
                       pct tokens limit)))))
         crossed)))

;;; context-format-warnings: Format warnings for REPL display with ANSI colors
;;; Arguments:
;;;   model - Optional model name for limit lookup
;;; Returns: Single string with newlines, or "" if no warnings
(define* (context-format-warnings #:optional (model #f))
  (let ((warnings (context-warnings model)))
    (if (null? warnings)
        ""
        (string-join
         (map (lambda (w)
                ;; Use yellow for warnings, red for high/critical
                (cond
                 ((string-contains w "[!]")
                  (format #f "\x1b[1;31m~a\x1b[0m" w))  ; bold red
                 (else
                  (format #f "\x1b[33m~a\x1b[0m" w))))   ; yellow
              warnings)
         "\n"))))
