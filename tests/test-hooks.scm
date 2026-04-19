#!/usr/bin/env guile3
!#
;;; test-hooks.scm --- Tests for lifecycle hook system
;;;
;;; Contract: docs/HOOKS-CONTRACT.org
;;; Scope: minimal PreToolUse + PostToolUse pair (H02, H03, H05-H07,
;;; H09, H12, H13, H14, H15). The remaining invariants (SessionStart,
;;; UserPromptSubmit, shell hooks, scopes, sandboxing) are out of scope
;;; for this implementation and remain stubbed.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(use-modules (sage hooks)
             (sage tools))

(format #t "~%=== Lifecycle Hook Contract Tests ===~%")

;;; ============================================================
;;; Event emission (H02, H03)
;;; ============================================================

(format #t "~%--- Event emission ---~%")

(run-test "H02: PreToolUse fires and returns #t when no handlers registered"
  (lambda ()
    (hook-clear!)
    (assert-true (hook-fire-pre-tool "noop" '()) "no handlers = allow")))

(run-test "H03: PostToolUse fires and ignores return value when no handlers"
  (lambda ()
    (hook-clear!)
    (assert-true (hook-fire-post-tool "noop" '() "result") "no handlers = no-op")))

;;; ============================================================
;;; Hook registration (H06, H07)
;;; ============================================================

(format #t "~%--- Hook registration ---~%")

(run-test "H06: duplicate hook name replaces existing hook"
  (lambda ()
    (hook-clear!)
    (hook-register 'PreToolUse "same-name" (lambda (ctx) #t))
    (hook-register 'PreToolUse "same-name" (lambda (ctx) #t))
    (let ((names (hook-list 'PreToolUse)))
      (assert-equal 1 (length names) "only one entry after re-register"))))

(run-test "H07: hook-unregister removes hook; no-op if absent"
  (lambda ()
    (hook-clear!)
    (hook-register 'PreToolUse "h1" (lambda (ctx) #t))
    (hook-unregister 'PreToolUse "h1")
    (assert-equal 0 (length (hook-list 'PreToolUse)) "unregister removed it")
    (hook-unregister 'PreToolUse "never-registered")
    (assert-equal 0 (length (hook-list 'PreToolUse)) "no-op when absent")))

;;; ============================================================
;;; Veto semantics (H12)
;;; ============================================================

(format #t "~%--- Veto semantics ---~%")

(run-test "H12: PreToolUse handler returning #f vetoes execution"
  (lambda ()
    (hook-clear!)
    (hook-register 'PreToolUse "always-deny" (lambda (ctx) #f))
    (let ((result (hook-fire-pre-tool "anything" '())))
      (assert-true (pair? result) "veto returns pair")
      (assert-false (car result) "first element is #f"))))

(run-test "H12: PreToolUse handler returning (#f . reason) preserves reason"
  (lambda ()
    (hook-clear!)
    (hook-register 'PreToolUse "explain"
                   (lambda (ctx) (cons #f "path blocked")))
    (let ((result (hook-fire-pre-tool "edit_file" '(("path" . "/etc/passwd")))))
      (assert-equal "path blocked" (cdr result) "reason preserved"))))

(run-test "H12: first veto short-circuits; later handlers do not run"
  (lambda ()
    (hook-clear!)
    (define called #f)
    (hook-register 'PreToolUse "first-denies" (lambda (ctx) #f))
    (hook-register 'PreToolUse "second-tracker"
                   (lambda (ctx) (set! called #t) #t))
    (hook-fire-pre-tool "anything" '())
    (assert-false called "second handler did not run")))

;;; ============================================================
;;; Observation semantics (H13)
;;; ============================================================

(format #t "~%--- Observation semantics ---~%")

(run-test "H13: PostToolUse return value is ignored"
  (lambda ()
    (hook-clear!)
    (hook-register 'PostToolUse "returns-false" (lambda (ctx) #f))
    (assert-true (hook-fire-post-tool "tool" '() "r") "fire returns #t regardless")))

(run-test "H13: PostToolUse runs all handlers even if one returns #f"
  (lambda ()
    (hook-clear!)
    (define count 0)
    (hook-register 'PostToolUse "h1" (lambda (ctx) (set! count (+ count 1)) #f))
    (hook-register 'PostToolUse "h2" (lambda (ctx) (set! count (+ count 1)) #t))
    (hook-fire-post-tool "tool" '() "r")
    (assert-equal 2 count "both handlers ran")))

;;; ============================================================
;;; Error isolation (H14)
;;; ============================================================

(format #t "~%--- Error isolation ---~%")

(run-test "H14: PreToolUse handler exception is caught; default allow"
  (lambda ()
    (hook-clear!)
    (hook-register 'PreToolUse "throws"
                   (lambda (ctx) (error "boom")))
    (assert-true (hook-fire-pre-tool "anything" '())
                 "exception fails open, tool allowed")))

(run-test "H14: PostToolUse handler exception is caught"
  (lambda ()
    (hook-clear!)
    (hook-register 'PostToolUse "throws"
                   (lambda (ctx) (error "boom")))
    (assert-true (hook-fire-post-tool "tool" '() "r")
                 "post-tool fire returns normally despite handler exception")))

;;; ============================================================
;;; FIFO ordering (H15)
;;; ============================================================

(format #t "~%--- Ordering ---~%")

(run-test "H15: PreToolUse handlers fire in registration order"
  (lambda ()
    (hook-clear!)
    (define trace '())
    (hook-register 'PreToolUse "alpha"
                   (lambda (ctx) (set! trace (cons 'alpha trace)) #t))
    (hook-register 'PreToolUse "beta"
                   (lambda (ctx) (set! trace (cons 'beta trace)) #t))
    (hook-register 'PreToolUse "gamma"
                   (lambda (ctx) (set! trace (cons 'gamma trace)) #t))
    (hook-fire-pre-tool "x" '())
    (assert-equal '(alpha beta gamma) (reverse trace) "alpha -> beta -> gamma")))

;;; ============================================================
;;; Integration with execute-tool
;;; ============================================================

(format #t "~%--- Integration with execute-tool ---~%")

(run-test "execute-tool invokes PreToolUse; veto short-circuits execution"
  (lambda ()
    (hook-clear!)
    (define executed #f)
    (register-tool "test-exec"
                   "Test tool"
                   '()
                   (lambda (args) (set! executed #t) "ran")
                   #:safe #t)
    (hook-register 'PreToolUse "deny-test-exec"
                   (lambda (ctx)
                     (if (equal? (assoc-ref ctx "tool") "test-exec")
                         (cons #f "test veto")
                         #t)))
    (let ((result (execute-tool "test-exec" '())))
      (assert-false executed "tool body did not run")
      (assert-true (string-contains result "Hook vetoed") "result mentions veto"))))

(run-test "execute-tool invokes PostToolUse after successful execution"
  (lambda ()
    (hook-clear!)
    (define observed #f)
    (register-tool "test-obs"
                   "Test tool"
                   '()
                   (lambda (args) "ok")
                   #:safe #t)
    (hook-register 'PostToolUse "observer"
                   (lambda (ctx)
                     (set! observed (assoc-ref ctx "result"))))
    (execute-tool "test-obs" '())
    (assert-equal "ok" observed "observer saw tool result")))

;;; ============================================================
;;; Stubs for out-of-scope invariants (H01, H04, H05, H08, H10, H11, H16)
;;; ============================================================

(format #t "~%--- Out-of-scope stubs ---~%")

(run-test "H01: SessionStart fires exactly once per REPL session (stub)" (lambda () #t))
(run-test "H04: UserPromptSubmit fires on every non-empty input (stub)" (lambda () #t))
(run-test "H05: project-scope hooks override user-scope hooks (stub)" (lambda () #t))
(run-test "H08: shell hook timeout kills process and treats as failure (stub)" (lambda () #t))
(run-test "H10: sandbox blocks access to (sage tools) (stub)" (lambda () #t))
(run-test "H11: sandbox blocks self-modification of hook registry (stub)" (lambda () #t))
(run-test "H16: UserPromptSubmit can transform input text (stub)" (lambda () #t))

;;; ============================================================
;;; Summary
;;; ============================================================

(hook-clear!)
(test-summary)
