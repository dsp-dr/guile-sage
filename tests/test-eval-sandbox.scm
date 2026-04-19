;;; test-eval-sandbox.scm --- eval_scheme Sandbox Tests -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Proves the eval_scheme sandbox blocks shell-out, pipe creation, and
;; filesystem mutation regardless of YOLO mode, while still permitting
;; pure math/list/string operations.
;;
;; Covers beads guile-sage-6tp (CRITICAL: eval_scheme no sandbox) and
;; guile-sage-h9y (v1 fix: add eval_scheme sandbox), and enforces NC12
;; from docs/HOOK-NEGATIVE-CONTRACTS.org: "guards fire even in YOLO
;; mode, they are safety invariants not permission checks".

(add-to-load-path "src")

(use-modules (sage tools)
             (sage config)
             (ice-9 format))

;; Sandbox is a safety invariant — NC12 says it must fire even when
;; YOLO is enabled. Turn YOLO on BEFORE the harness loads so eval_scheme
;; is *callable* (it's an unsafe tool per ADR-0003); the sandbox is
;; orthogonal and must reject dangerous code inside the evaluation.
(setenv "SAGE_YOLO_MODE" "1")
(setenv "YOLO_MODE" "1")

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

;;; Unique filenames per test run so a stale file from a previous
;;; run can't mask a regression.
(define rce-proof-path
  (format #f "/tmp/sage-rce-proof-~a" (getpid)))

(define delete-target-path
  (format #f "/tmp/sage-delete-target-~a" (getpid)))

;;; Helper: write a fresh file at path (used to prove delete-file
;;; would have worked if not for the sandbox).
(define (touch-file path)
  (call-with-output-file path
    (lambda (port) (display "sentinel" port))))

;;; Helper: clean up between tests.
(define (cleanup-files)
  (for-each
    (lambda (p) (when (file-exists? p) (delete-file p)))
    (list rce-proof-path delete-target-path)))

;;; ============================================================
;;; BLOCKED: Shell-out via (system ...)
;;; ============================================================

(test-suite "eval_scheme sandbox blocks shell-out"
  (lambda ()
    (cleanup-files)

    (test "reject (system \"touch ...\")"
      (lambda ()
        (let* ((code (format #f "(system \"touch ~a\")" rce-proof-path))
               (result (execute-tool "eval_scheme" `(("code" . ,code)))))
          (assert-contains result "sandbox denied"
                           "system call should be denied by sandbox")
          (assert-false (file-exists? rce-proof-path)
                        "RCE proof file must NOT exist after sandboxed call"))))

    (test "reject (system* ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(system* \"/bin/touch\" \"/tmp/x\")")))))
          (assert-contains result "sandbox denied"
                           "system* must be denied"))))

    (test "reject nested (let) wrapping system"
      (lambda ()
        ;; Defense-in-depth: even if the call is hidden inside a let
        ;; or lambda, symbol-walk should find it.
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(let ((x system)) (x \"echo pwned\"))")))))
          (assert-contains result "sandbox denied"
                           "system aliased inside let must be denied"))))

    (cleanup-files)))

;;; ============================================================
;;; BLOCKED: Pipe creation via (open-input-pipe ...)
;;; ============================================================

(test-suite "eval_scheme sandbox blocks pipes"
  (lambda ()
    (test "reject (open-input-pipe ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(open-input-pipe \"echo test\")")))))
          (assert-contains result "sandbox denied"
                           "open-input-pipe must be denied"))))

    (test "reject (open-output-pipe ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(open-output-pipe \"cat > /tmp/x\")")))))
          (assert-contains result "sandbox denied"
                           "open-output-pipe must be denied"))))

    (test "reject (open-pipe ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(open-pipe \"sh\" OPEN_BOTH)")))))
          (assert-contains result "sandbox denied"
                           "open-pipe must be denied"))))))

;;; ============================================================
;;; BLOCKED: Filesystem mutation
;;; ============================================================

(test-suite "eval_scheme sandbox blocks filesystem mutation"
  (lambda ()
    (cleanup-files)
    (touch-file delete-target-path)

    (test "reject (delete-file ...)"
      (lambda ()
        (let* ((code (format #f "(delete-file \"~a\")" delete-target-path))
               (result (execute-tool "eval_scheme" `(("code" . ,code)))))
          (assert-contains result "sandbox denied"
                           "delete-file must be denied")
          (assert-true (file-exists? delete-target-path)
                       "target file must still exist after sandboxed delete"))))

    (test "reject (rename-file ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(rename-file \"/tmp/a\" \"/tmp/b\")")))))
          (assert-contains result "sandbox denied"
                           "rename-file must be denied"))))

    (test "reject (copy-file ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(copy-file \"/etc/passwd\" \"/tmp/x\")")))))
          (assert-contains result "sandbox denied"
                           "copy-file must be denied"))))

    (test "reject (chmod ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(chmod \"/tmp/x\" 511)")))))
          (assert-contains result "sandbox denied"
                           "chmod must be denied"))))

    (cleanup-files)))

;;; ============================================================
;;; BLOCKED: Recursive eval / module loading
;;; ============================================================

(test-suite "eval_scheme sandbox blocks code loading"
  (lambda ()
    (test "reject (eval-string ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(eval-string \"(system \\\"ls\\\")\")")))))
          (assert-contains result "sandbox denied"
                           "recursive eval-string must be denied"))))

    (test "reject (primitive-load ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(primitive-load \"/tmp/evil.scm\")")))))
          (assert-contains result "sandbox denied"
                           "primitive-load must be denied"))))

    (test "reject (load ...)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(load \"/tmp/evil.scm\")")))))
          (assert-contains result "sandbox denied"
                           "load must be denied"))))))

;;; ============================================================
;;; ALLOWED: Pure math / list / string operations
;;; ============================================================

(test-suite "eval_scheme sandbox permits legitimate operations"
  (lambda ()
    (test "allow (+ 1 2)"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(+ 1 2)")))))
          (assert-not-contains result "sandbox denied"
                               "(+ 1 2) should not be denied")
          (assert-contains result "3"
                           "(+ 1 2) should evaluate to 3"))))

    (test "allow (map 1+ '(1 2 3))"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(map 1+ '(1 2 3))")))))
          (assert-not-contains result "sandbox denied"
                               "map should not be denied")
          (assert-contains result "2 3 4"
                           "(map 1+ '(1 2 3)) should evaluate to (2 3 4)"))))

    (test "allow (string-upcase \"hi\")"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(string-upcase \"hi\")")))))
          (assert-not-contains result "sandbox denied"
                               "string-upcase should not be denied")
          (assert-contains result "HI"
                           "(string-upcase \"hi\") should return \"HI\""))))

    (test "allow (let ...) with arithmetic"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(let ((x 5) (y 7)) (* x y))")))))
          (assert-not-contains result "sandbox denied"
                               "let+arithmetic should not be denied")
          (assert-contains result "35"
                           "let+* should evaluate correctly"))))

    (test "allow (fold + 0 '(1 2 3 4 5))"
      (lambda ()
        ;; Prove higher-order functions work — this is a common and
        ;; safe pattern we don't want the sandbox to break.
        (let ((result (execute-tool "eval_scheme"
                        `(("code" . "(fold + 0 '(1 2 3 4 5))")))))
          (assert-not-contains result "sandbox denied"
                               "fold should not be denied")
          (assert-contains result "15"
                           "fold + 0 '(1..5) should be 15"))))))

(test-summary)
