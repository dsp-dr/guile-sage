;;; test-hardening.scm --- Cross-port hardening regression tests -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Regression tests for the hardening fixes surfaced by the 2026-06 cross-port
;; audit (docs/reports/20260626-cross-port-hardening-findings.org):
;;   - provider error messages are single-line + length-bounded (clean-error-message)
;;   - HTTP retryable set includes 408 (Request Timeout)
;;   - safe-path? rejects NUL bytes (and ".." traversal)
;; The MCP -32700 parse-error path is an stdio behaviour, covered by mcp-smoke.

(add-to-load-path "src")

(use-modules (sage util)
             (sage tools)
             (ice-9 format))

;;; Load shared harness (test-suite / test / assert-* / test-summary)
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(define retryable? (@@ (sage util) http-retryable-code?))

(test-suite "Provider error normalization (single-line + bounded)"
  (lambda ()
    (test "strips newlines"
      (lambda () (assert-true (not (string-index (clean-error-message "boom\nstack2\rstack3") #\newline))
                              "no newlines")))
    (test "strips tabs"
      (lambda () (assert-true (not (string-index (clean-error-message "a\tb") #\tab)) "no tabs")))
    (test "collapses whitespace runs"
      (lambda () (assert-equal (clean-error-message "  a   b   ") "a b" "collapsed")))
    (test "bounds length (<=200 + ellipsis)"
      (lambda () (assert-true (<= (string-length (clean-error-message (make-string 500 #\x))) 201) "bounded")))
    (test "tolerates non-strings"
      (lambda () (assert-equal (clean-error-message 42) "" "non-string -> empty")))))

(test-suite "HTTP retryable status set (408/429/5xx)"
  (lambda ()
    (test "408 Request Timeout retryable" (lambda () (assert-true (retryable? 408) "408")))
    (test "429 retryable"                 (lambda () (assert-true (retryable? 429) "429")))
    (test "503 retryable"                 (lambda () (assert-true (retryable? 503) "503")))
    (test "404 NOT retryable"             (lambda () (assert-false (retryable? 404) "404")))
    (test "400 NOT retryable"             (lambda () (assert-false (retryable? 400) "400")))
    (test "0 fails fast (not retried)"    (lambda () (assert-false (retryable? 0)   "0")))))

(test-suite "safe-path? hostile input (NUL + traversal)"
  (lambda ()
    (test "rejects embedded NUL"  (lambda () (assert-false (safe-path? (string #\a #\nul #\b)) "NUL")))
    (test "rejects .. traversal"  (lambda () (assert-false (safe-path? "../etc/passwd") "..")))
    (test "blocks .env"           (lambda () (assert-false (safe-path? "foo/.env") ".env")))))

(test-summary)
