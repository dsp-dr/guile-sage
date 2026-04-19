#!/usr/bin/env guile3
!#
;;; test-hooks-observer-uat.scm --- UAT for SAGE_DEMO_HOOKS PostToolUse observer
;;;
;;; Bead: guile-sage-0mg
;;; Base: a282bcc
;;;
;;; Proves that the PostToolUse observer that `scripts/demo.sh` showcases
;;; (SAGE_DEMO_HOOKS=1) fires visibly on stdout after every tool execution.
;;;
;;; The test registers the two demo hooks directly via `hook-register`
;;; rather than relying on the `SAGE_DEMO_HOOKS` env var at runtime, so
;;; it is deterministic regardless of how `gmake check` is invoked.
;;; The demo hook source of truth lives in src/sage/repl.scm:1148-1163.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(use-modules (sage hooks)
             (sage tools)
             (ice-9 regex))

(format #t "~%=== SAGE_DEMO_HOOKS PostToolUse Observer UAT ===~%")

;;; Mirror of the SAGE_DEMO_HOOKS block in src/sage/repl.scm. Registering
;;; directly (instead of spawning a subprocess with the env var set) keeps
;;; the test deterministic regardless of how `gmake check` is invoked.
(define (register-demo-hooks!)
  (hook-register 'PreToolUse "demo-guard"
                 (lambda (ctx)
                   (if (equal? (assoc-ref ctx "tool") "git_push")
                       (cons #f "git_push blocked by demo PreToolUse guard")
                       #t)))
  (hook-register 'PostToolUse "demo-observer"
                 (lambda (ctx)
                   (format #t "  \x1b[2m[PostToolUse: ~a -> ~a bytes]\x1b[0m~%"
                           (assoc-ref ctx "tool")
                           (let ((r (format #f "~a" (assoc-ref ctx "result"))))
                             (string-length r))))))

;;; Regex: match the observer trace with any number of bytes, allowing
;;; for the surrounding ANSI dim escape sequence. Name match is
;;; case-sensitive on "PostToolUse" and the tool name.
(define observer-trace-rx
  (make-regexp "\\[PostToolUse: list_files -> [0-9]+ bytes\\]"))

(run-test "PostToolUse observer emits a visible trace after list_files"
  (lambda ()
    (hook-clear!)
    (register-demo-hooks!)
    (let ((captured
           (with-output-to-string
             (lambda ()
               (execute-tool "list_files" '(("path" . ".")))))))
      (assert-true (regexp-exec observer-trace-rx captured)
                   (format #f "observer trace not in captured stdout: ~s"
                           captured)))))

(run-test "Observer fires on every successful tool call (stable across invocations)"
  (lambda ()
    (hook-clear!)
    (register-demo-hooks!)
    (let ((captured
           (with-output-to-string
             (lambda ()
               (execute-tool "list_files" '(("path" . ".")))
               (execute-tool "list_files" '(("path" . ".")))
               (execute-tool "list_files" '(("path" . ".")))))))
      ;; Count occurrences of the trace; must be exactly 3.
      (let loop ((pos 0) (count 0))
        (let ((m (regexp-exec observer-trace-rx captured pos)))
          (if m
              (loop (match:end m) (+ count 1))
              (assert-equal 3 count "observer fired once per tool call")))))))

(test-summary)
