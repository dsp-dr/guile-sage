#!/usr/bin/env guile3
!#
;;; test-context.scm --- Tests for context window management

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage context)
             (sage session)
             (sage config)
             (ice-9 format))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

;;; ============================================================
;;; Context Usage Tests
;;; ============================================================

(format #t "~%--- Context Usage ---~%")

(run-test "context-usage returns alist with required keys"
  (lambda ()
    (session-create #:name "ctx-usage-test")
    (let ((usage (context-usage)))
      (unless (assoc-ref usage "tokens")
        (error "missing tokens key"))
      (unless (assoc-ref usage "limit")
        (error "missing limit key"))
      ;; ratio and percentage can be 0
      (unless (number? (assoc-ref usage "ratio"))
        (error "ratio should be a number"))
      (unless (number? (assoc-ref usage "percentage"))
        (error "percentage should be a number")))))

(run-test "context-usage tokens match session total"
  (lambda ()
    (session-create #:name "ctx-tokens-test")
    (session-add-message "user" "hello world testing context")
    (let* ((usage (context-usage))
           (usage-tokens (assoc-ref usage "tokens"))
           (session-tokens (session-total-tokens)))
      (unless (= usage-tokens session-tokens)
        (error "tokens mismatch" usage-tokens session-tokens)))))

(run-test "context-usage limit is positive"
  (lambda ()
    (session-create #:name "ctx-limit-test")
    (let ((usage (context-usage)))
      (unless (> (assoc-ref usage "limit") 0)
        (error "limit should be positive" (assoc-ref usage "limit"))))))

(run-test "context-usage percentage is 0 for empty session"
  (lambda ()
    (session-create #:name "ctx-empty-test")
    (let ((usage (context-usage)))
      (unless (= (assoc-ref usage "percentage") 0)
        (error "percentage should be 0 for empty session")))))

(run-test "context-usage-ratio returns number"
  (lambda ()
    (session-create #:name "ctx-ratio-test")
    (let ((ratio (context-usage-ratio)))
      (unless (number? ratio)
        (error "ratio should be a number")))))

(run-test "context-usage-ratio increases with messages"
  (lambda ()
    (session-create #:name "ctx-ratio-inc-test")
    (let ((r1 (context-usage-ratio)))
      (session-add-message "user" (make-string 400 #\a))
      (let ((r2 (context-usage-ratio)))
        (unless (> r2 r1)
          (error "ratio should increase" r1 r2))))))

;;; ============================================================
;;; Context Format Tests
;;; ============================================================

(format #t "~%--- Context Formatting ---~%")

(run-test "context-format-usage returns string"
  (lambda ()
    (session-create #:name "ctx-fmt-test")
    (let ((formatted (context-format-usage)))
      (unless (string? formatted)
        (error "should return string"))
      (unless (string-contains formatted "Context:")
        (error "should contain Context:" formatted)))))

(run-test "context-format-usage shows token counts"
  (lambda ()
    (session-create #:name "ctx-fmt-tokens-test")
    (session-add-message "user" "test message")
    (let ((formatted (context-format-usage)))
      (unless (string-contains formatted "tokens")
        (error "should contain 'tokens'" formatted)))))

(run-test "context-window-status returns multi-line string"
  (lambda ()
    (session-create #:name "ctx-win-test")
    (let ((status (context-window-status)))
      (unless (string? status)
        (error "should return string"))
      (unless (string-contains status "Context window:")
        (error "should contain 'Context window:'" status)))))

(run-test "context-window-status shows progress bar"
  (lambda ()
    (session-create #:name "ctx-bar-test")
    (let ((status (context-window-status)))
      ;; Should contain the bar brackets
      (unless (string-contains status "[")
        (error "should contain progress bar" status)))))

;;; ============================================================
;;; Threshold Warning Tests
;;; ============================================================

(format #t "~%--- Threshold Warnings ---~%")

(run-test "context-check-thresholds returns empty for low usage"
  (lambda ()
    (session-create #:name "ctx-thresh-low-test")
    (reset-fired-thresholds!)
    (session-add-message "user" "short message")
    (let ((warnings (context-check-thresholds)))
      (unless (null? warnings)
        (error "should return empty list for low usage" warnings)))))

(run-test "context-check-thresholds fires at 75%"
  (lambda ()
    (session-create #:name "ctx-thresh-75-test")
    (reset-fired-thresholds!)
    ;; Default limit is 8000 tokens; 75% = 6000 tokens = ~24000 chars
    (session-add-message "user" (make-string 24400 #\x))
    (let ((warnings (context-check-thresholds)))
      (unless (= (length warnings) 1)
        (error "should fire exactly 1 warning" (length warnings)))
      (let ((level (assoc-ref (car warnings) "level")))
        (unless (equal? level "warning")
          (error "should be 'warning' level" level))))))

(run-test "context-check-thresholds fires at 90%"
  (lambda ()
    (session-create #:name "ctx-thresh-90-test")
    (reset-fired-thresholds!)
    ;; 90% of 8000 = 7200 tokens = ~28800 chars
    (session-add-message "user" (make-string 29200 #\x))
    (let ((warnings (context-check-thresholds)))
      ;; Should fire both 'warning' and 'high'
      (unless (>= (length warnings) 2)
        (error "should fire at least 2 warnings" (length warnings))))))

(run-test "context-check-thresholds deduplicates"
  (lambda ()
    (session-create #:name "ctx-thresh-dedup-test")
    (reset-fired-thresholds!)
    ;; First check fires warning
    (session-add-message "user" (make-string 24400 #\x))
    (context-check-thresholds)
    ;; Second check should not re-fire
    (let ((second (context-check-thresholds)))
      (unless (null? second)
        (error "should not re-fire same threshold" second)))))

(run-test "reset-fired-thresholds! allows re-firing"
  (lambda ()
    (session-create #:name "ctx-thresh-reset-test")
    (reset-fired-thresholds!)
    (session-add-message "user" (make-string 24400 #\x))
    (context-check-thresholds)
    ;; Reset
    (reset-fired-thresholds!)
    ;; Should fire again
    (let ((warnings (context-check-thresholds)))
      (unless (= (length warnings) 1)
        (error "should fire again after reset" (length warnings))))))

;;; ============================================================
;;; Warning Message Tests
;;; ============================================================

(format #t "~%--- Warning Messages ---~%")

(run-test "context-warnings returns empty for low usage"
  (lambda ()
    (session-create #:name "ctx-warn-low-test")
    (reset-fired-thresholds!)
    (let ((warnings (context-warnings)))
      (unless (null? warnings)
        (error "should return empty list" warnings)))))

(run-test "context-warnings returns strings at 75%"
  (lambda ()
    (session-create #:name "ctx-warn-75-test")
    (reset-fired-thresholds!)
    (session-add-message "user" (make-string 24400 #\x))
    (let ((warnings (context-warnings)))
      (unless (= (length warnings) 1)
        (error "should have 1 warning" (length warnings)))
      (unless (string? (car warnings))
        (error "warning should be a string"))
      (unless (string-contains (car warnings) "[*]")
        (error "75% warning should have [*] marker")))))

(run-test "context-warnings suggests compact at 90%"
  (lambda ()
    (session-create #:name "ctx-warn-90-test")
    (reset-fired-thresholds!)
    (session-add-message "user" (make-string 29200 #\x))
    (let ((warnings (context-warnings)))
      ;; At least one should suggest /compact
      (unless (any (lambda (w) (string-contains w "/compact")) warnings)
        (error "90%+ warning should suggest /compact" warnings)))))

(run-test "context-format-warnings returns empty string for low usage"
  (lambda ()
    (session-create #:name "ctx-fmtwarn-low-test")
    (reset-fired-thresholds!)
    (let ((formatted (context-format-warnings)))
      (unless (string-null? formatted)
        (error "should return empty string for low usage")))))

(run-test "context-format-warnings returns ANSI colored string at 90%"
  (lambda ()
    (session-create #:name "ctx-fmtwarn-90-test")
    (reset-fired-thresholds!)
    (session-add-message "user" (make-string 29200 #\x))
    (let ((formatted (context-format-warnings)))
      (unless (string? formatted)
        (error "should return string"))
      ;; Should contain ANSI escape codes
      (unless (string-contains formatted "\x1b[")
        (error "should contain ANSI codes" formatted)))))

;;; ============================================================
;;; Context Status Display Tests
;;; ============================================================

(format #t "~%--- Context Status ---~%")

(run-test "context-status reports no context initially"
  (lambda ()
    (let ((status (context-status)))
      (unless (string-contains status "No context")
        (error "should report no context" status)))))

(run-test "context-window-status shows WARNING label at 75%"
  (lambda ()
    (session-create #:name "ctx-status-warn-test")
    (session-add-message "user" (make-string 24400 #\x))
    (let ((status (context-window-status)))
      (unless (string-contains status "WARNING")
        (error "should show WARNING label" status)))))

(run-test "context-window-status shows HIGH label at 90%"
  (lambda ()
    (session-create #:name "ctx-status-high-test")
    (session-add-message "user" (make-string 29200 #\x))
    (let ((status (context-window-status)))
      (unless (string-contains status "HIGH")
        (error "should show HIGH label" status)))))

(run-test "context-window-status shows CRITICAL label at 95%"
  (lambda ()
    (session-create #:name "ctx-status-crit-test")
    ;; 95% of 8000 = 7600 tokens = ~30400 chars
    (session-add-message "user" (make-string 30800 #\x))
    (let ((status (context-window-status)))
      (unless (string-contains status "CRITICAL")
        (error "should show CRITICAL label" status)))))

;;; ============================================================
;;; Per-Model Limit Tests
;;; ============================================================

(format #t "~%--- Per-Model Limits ---~%")

(run-test "context-usage respects model-specific limits"
  (lambda ()
    (session-create #:name "ctx-model-test")
    ;; Claude has 200000 limit, local default is 8000
    (let* ((local-usage (context-usage))
           (claude-usage (context-usage "claude-3.5-sonnet"))
           (local-limit (assoc-ref local-usage "limit"))
           (claude-limit (assoc-ref claude-usage "limit")))
      (unless (> claude-limit local-limit)
        (error "claude limit should be higher than default"
               claude-limit local-limit)))))

(run-test "context-usage-ratio differs by model"
  (lambda ()
    (session-create #:name "ctx-ratio-model-test")
    (session-add-message "user" (make-string 4000 #\x))
    (let ((local-ratio (context-usage-ratio))
          (claude-ratio (context-usage-ratio "claude-3.5-sonnet")))
      ;; Same tokens, bigger limit -> smaller ratio
      (unless (< claude-ratio local-ratio)
        (error "claude ratio should be smaller" claude-ratio local-ratio)))))

;;; Summary

(test-summary)

(if (= *tests-passed* *tests-run*)
    (begin
      (format #t "All tests passed!~%")
      (exit 0))
    (begin
      (format #t "Some tests failed!~%")
      (exit 1)))
