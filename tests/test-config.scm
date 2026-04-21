#!/usr/bin/env guile3
!#
;;; test-config.scm --- Tests for config.scm get-token-limit priority
;;;
;;; Bead: guile-sage-pdv
;;; Regression: TOKEN_LIMIT env/config must not shadow model-specific limits.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(use-modules (sage config)
             (ice-9 format))

(format #t "~%=== get-token-limit priority ===~%")

(run-test "model-specific limit wins over TOKEN_LIMIT env override"
  (lambda ()
    ;; Simulate a stale .env entry TOKEN_LIMIT=8000 alongside a Gemini model.
    (setenv "TOKEN_LIMIT" "8000")
    (let ((result (get-token-limit "gemini-2.5-flash")))
      (setenv "TOKEN_LIMIT" "")           ; clear immediately
      (unless (= result 1000000)
        (error "expected 1000000, got" result)))))

(run-test "TOKEN_LIMIT applies when no model is given"
  (lambda ()
    (setenv "TOKEN_LIMIT" "16000")
    (let ((result (get-token-limit)))
      (setenv "TOKEN_LIMIT" "")
      (unless (= result 16000)
        (error "expected 16000, got" result)))))

(run-test "gemini-2.5-pro returns 2000000"
  (lambda ()
    (setenv "TOKEN_LIMIT" "")
    (let ((result (get-token-limit "gemini-2.5-pro")))
      (unless (= result 2000000)
        (error "expected 2000000, got" result)))))

(run-test "gemini-2.5-flash-lite returns 1000000"
  (lambda ()
    (setenv "TOKEN_LIMIT" "")
    (let ((result (get-token-limit "gemini-2.5-flash-lite")))
      (unless (= result 1000000)
        (error "expected 1000000, got" result)))))

(run-test "llama3.2:latest returns 8000"
  (lambda ()
    (setenv "TOKEN_LIMIT" "")
    (let ((result (get-token-limit "llama3.2:latest")))
      (unless (= result 8000)
        (error "expected 8000, got" result)))))

(run-test "unknown model falls back to provider-based default"
  (lambda ()
    (setenv "TOKEN_LIMIT" "")
    (let ((result (get-token-limit "totally-unknown-model-xyz")))
      (unless (> result 0)
        (error "expected positive limit, got" result)))))

(test-summary)

(if (= *tests-passed* *tests-run*)
    (begin (format #t "All tests passed!~%") (exit 0))
    (begin (format #t "Some tests failed!~%") (exit 1)))
