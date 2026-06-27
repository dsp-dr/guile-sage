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
             (ice-9 format)
             (rnrs bytevectors))

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
    (test "bounds by BYTES, UTF-8-safe (multibyte body)"
      (lambda () (assert-true (<= (bytevector-length (string->utf8 (clean-error-message (make-string 300 #\λ)))) 210)
                              "<=200 bytes (+ellipsis)")))
    (test "tolerates non-strings"
      (lambda () (assert-equal (clean-error-message 42) "" "non-string -> empty")))
    (test "neutralizes ALL control bytes (NUL/BEL), not just whitespace"
      (lambda () (assert-true (not (string-any (lambda (c) (or (char<? c #\space) (char=? c #\delete)))
                                               (clean-error-message (string #\a #\nul #\x07 #\b))))
                              "no control bytes")))))

(test-suite "HTTP retryable status set (408/429/5xx)"
  (lambda ()
    (test "408 Request Timeout retryable" (lambda () (assert-true (retryable? 408) "408")))
    (test "429 retryable"                 (lambda () (assert-true (retryable? 429) "429")))
    (test "503 retryable"                 (lambda () (assert-true (retryable? 503) "503")))
    (test "404 NOT retryable"             (lambda () (assert-false (retryable? 404) "404")))
    (test "400 NOT retryable"             (lambda () (assert-false (retryable? 400) "400")))
    (test "0 fails fast (not retried)"    (lambda () (assert-false (retryable? 0)   "0")))))

(test-suite "safe-path? hostile input + per-token dotfile rule (cross-port 2026-06)"
  (lambda ()
    (test "rejects embedded NUL"     (lambda () (assert-false (safe-path? (string #\a #\nul #\b)) "NUL")))
    (test "rejects empty"            (lambda () (assert-false (safe-path? "") "empty")))
    (test "rejects .. traversal"     (lambda () (assert-false (safe-path? "../etc/passwd") "..")))
    (test "blocks .env"              (lambda () (assert-false (safe-path? "foo/.env") ".env")))
    (test "blocks .env.local"        (lambda () (assert-false (safe-path? ".env.local") ".env.local")))
    (test "blocks .env.production"   (lambda () (assert-false (safe-path? ".env.production") ".env.production")))
    (test "blocks .ssh"              (lambda () (assert-false (safe-path? ".ssh/id_rsa") ".ssh")))
    (test "blocks .git dir"          (lambda () (assert-false (safe-path? ".git/config") ".git")))
    (test "blocks dotfiles even in /tmp (gap closed)"
                                     (lambda () (assert-false (safe-path? "/tmp/.ssh/id_rsa") "/tmp/.ssh")))
    (test "ALLOWS my.env (segment, not substring)"
                                     (lambda () (assert-true (safe-path? "my.env") "my.env")))
    (test "ALLOWS .gitignore (exact .git only)"
                                     (lambda () (assert-true (safe-path? ".gitignore") ".gitignore")))))

(test-suite "env-affirmative? — value-gated dangerous flags (v4 footgun fix)"
  (lambda ()
    (test "=0 is OFF (the footgun)"   (lambda () (assert-false (env-affirmative? "0") "0")))
    (test "empty is OFF"              (lambda () (assert-false (env-affirmative? "") "empty")))
    (test "false/no/off are OFF"      (lambda () (assert-false (or (env-affirmative? "false")
                                                                   (env-affirmative? "no")
                                                                   (env-affirmative? "off")) "negatives")))
    (test "#f is OFF"                 (lambda () (assert-false (env-affirmative? #f) "#f")))
    (test "1/true/yes/on are ON"      (lambda () (assert-true (and (env-affirmative? "1")
                                                                   (env-affirmative? "true")
                                                                   (env-affirmative? "YES")
                                                                   (env-affirmative? "on")) "affirmatives")))))

(test-summary)
