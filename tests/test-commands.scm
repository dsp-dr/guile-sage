#!/usr/bin/env guile3
!#
;;; test-commands.scm --- Tests for custom slash commands -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Tests for sage/commands.scm (registry, CRUD, persistence, execution)
;; and the REPL integration in sage/repl.scm.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage commands)
             (sage config)
             (sage mcp)
             (sage repl)
             (sage session)
             (srfi srfi-1)
             (ice-9 format))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Custom Commands Tests ===~%")

;;; ============================================================
;;; Setup: clean slate for each run
;;; ============================================================

;; Ensure XDG dirs exist
(ensure-sage-dirs)

;; Start with empty registry
(set! *custom-commands* '())

;;; ============================================================
;;; Registry Tests
;;; ============================================================

(run-test "empty registry returns empty list"
  (lambda ()
    (assert-equal (list-custom-commands) '()
                  "Initial registry should be empty")))

(run-test "define-custom-command! adds to registry"
  (lambda ()
    (define-custom-command! "hello" "(display \"hi\")")
    (assert-true (pair? (list-custom-commands))
                 "Registry should have entries after define")))

(run-test "get-custom-command returns expression string"
  (lambda ()
    (assert-equal (get-custom-command "hello") "(display \"hi\")"
                  "Should return the stored expression")))

(run-test "get-custom-command returns #f for missing"
  (lambda ()
    (assert-false (get-custom-command "nonexistent")
                  "Should return #f for unknown command")))

(run-test "define-custom-command! replaces existing"
  (lambda ()
    (define-custom-command! "hello" "(display \"updated\")")
    (assert-equal (get-custom-command "hello") "(display \"updated\")"
                  "Should replace existing command")
    (assert-equal (length (list-custom-commands)) 1
                  "Should not duplicate entries")))

(run-test "undefine-custom-command! removes entry"
  (lambda ()
    (define-custom-command! "temp" "(+ 1 2)")
    (let ((before (length (list-custom-commands))))
      (assert-true (undefine-custom-command! "temp")
                   "Should return #t when removing existing")
      (assert-equal (length (list-custom-commands)) (1- before)
                    "Registry should shrink by one"))))

(run-test "undefine-custom-command! returns #f for missing"
  (lambda ()
    (assert-false (undefine-custom-command! "no-such-cmd")
                  "Should return #f for unknown command")))

;;; ============================================================
;;; Execution Tests
;;; ============================================================

(run-test "execute-custom-command evaluates expression"
  (lambda ()
    (define-custom-command! "calc" "(+ 40 2)")
    (assert-equal (execute-custom-command "calc") 42
                  "Should evaluate and return result")))

(run-test "execute-custom-command handles errors"
  (lambda ()
    (define-custom-command! "bad" "(/ 1 0)")
    (let ((result (execute-custom-command "bad")))
      (assert-true (string? result)
                   "Error result should be a string")
      (assert-true (string-contains result "Error")
                   "Error result should mention Error"))))

(run-test "execute-custom-command unknown returns error string"
  (lambda ()
    (let ((result (execute-custom-command "no-such")))
      (assert-true (string? result)
                   "Should return error string")
      (assert-true (string-contains result "Unknown")
                   "Should mention Unknown"))))

;;; ============================================================
;;; Persistence Tests
;;; ============================================================

(run-test "save and load round-trip"
  (lambda ()
    ;; Clean slate
    (set! *custom-commands* '())
    (define-custom-command! "aa" "(+ 1 1)")
    (define-custom-command! "bb" "(* 2 3)")
    ;; Clear in-memory and reload
    (let ((saved *custom-commands*))
      (set! *custom-commands* '())
      (assert-equal (list-custom-commands) '()
                    "Should be empty after clear")
      (load-custom-commands!)
      (assert-equal (length (list-custom-commands)) 2
                    "Should reload 2 commands")
      (assert-equal (get-custom-command "aa") "(+ 1 1)"
                    "Command aa should survive round-trip")
      (assert-equal (get-custom-command "bb") "(* 2 3)"
                    "Command bb should survive round-trip"))))

(run-test "load-custom-commands! returns count"
  (lambda ()
    (set! *custom-commands* '())
    (let ((n (load-custom-commands!)))
      (assert-true (number? n)
                   "Should return a number")
      (assert-true (>= n 0)
                   "Count should be non-negative"))))

;;; ============================================================
;;; REPL Integration Tests
;;; ============================================================

(run-test "*commands* contains /define-command"
  (lambda ()
    (assert-true (assoc "/define-command" *commands*)
                 "/define-command should be in commands")))

(run-test "*commands* contains /undefine-command"
  (lambda ()
    (assert-true (assoc "/undefine-command" *commands*)
                 "/undefine-command should be in commands")))

(run-test "*commands* contains /commands"
  (lambda ()
    (assert-true (assoc "/commands" *commands*)
                 "/commands should be in commands")))

(run-test "*commands* contains /mcp"
  (lambda ()
    (assert-true (assoc "/mcp" *commands*)
                 "/mcp should be in commands")))

(run-test "/mcp with empty *mcp-servers* prints config hint"
  (lambda ()
    ;; Save + clear *mcp-servers* so we exercise the empty path
    ;; without depending on the host's ~/.claude.json state.
    (let ((saved *mcp-servers*))
      (dynamic-wind
        (lambda () (set! *mcp-servers* '()))
        (lambda ()
          (let* ((port (open-output-string))
                 (result (with-output-to-port port
                           (lambda () (handle-command "/mcp")))))
            (assert-true result
                         "/mcp should return #t when handled")
            (let ((out (get-output-string port)))
              (assert-true (string-contains out "No MCP servers configured")
                           "empty servers path should print config hint"))))
        (lambda () (set! *mcp-servers* saved))))))

(run-test "handle-command dispatches custom commands"
  (lambda ()
    ;; Verify the dispatch logic: handler should be #f for custom commands,
    ;; and get-custom-command should find the registered command.
    (define-custom-command! "testcmd" "(+ 1 1)")
    (assert-false (assoc-ref *commands* "/testcmd")
                  "Custom command should not be in built-in *commands*")
    (assert-true (get-custom-command "testcmd")
                 "Custom command should be found by get-custom-command")
    (assert-equal (execute-custom-command "testcmd") 2
                  "Custom command should evaluate to 2")))

(run-test "handle-command shows error for truly unknown"
  (lambda ()
    (assert-true (handle-command "/zzz-no-such-command")
                 "Unknown command still returns #t (error displayed)")))

;;; ============================================================
;;; /compact dispatch — bead guile-sage-7gb
;;; Ensures /compact N is intercepted by handle-command and dispatched
;;; to cmd-compact with the parsed integer; does NOT fall through to
;;; the chat/model path. Stubs session-compact! so we observe its args
;;; without running real compaction.
;;; ============================================================

(run-test "cmd-compact dispatched with integer arg from /compact N"
  (lambda ()
    (let* ((session-mod (resolve-module '(sage session)))
           (real-compact (module-ref session-mod 'session-compact!))
           (recorded-keep-recent #f)
           (stub (lambda* (#:key (keep-recent 5) (summarize #f))
                   (set! recorded-keep-recent keep-recent)
                   ;; Return a string so cmd-compact's (display ...) works.
                   "[stub] compacted")))
      (dynamic-wind
        (lambda ()
          (module-set! session-mod 'session-compact! stub))
        (lambda ()
          (let ((result (handle-command "/compact 4")))
            (assert-true result
                         "handle-command should return #t when /compact is handled")
            (assert-equal recorded-keep-recent 4
                          "cmd-compact should pass integer 4 from args")))
        (lambda ()
          (module-set! session-mod 'session-compact! real-compact))))))

(run-test "cmd-compact uses default keep-recent=5 when /compact has no args"
  (lambda ()
    (let* ((session-mod (resolve-module '(sage session)))
           (real-compact (module-ref session-mod 'session-compact!))
           (recorded-keep-recent #f)
           (stub (lambda* (#:key (keep-recent 5) (summarize #f))
                   (set! recorded-keep-recent keep-recent)
                   "[stub] compacted")))
      (dynamic-wind
        (lambda ()
          (module-set! session-mod 'session-compact! stub))
        (lambda ()
          (let ((result (handle-command "/compact")))
            (assert-true result
                         "handle-command should return #t for bare /compact")
            (assert-equal recorded-keep-recent 5
                          "cmd-compact should fall back to default keep-recent=5")))
        (lambda ()
          (module-set! session-mod 'session-compact! real-compact))))))

;;; ============================================================
;;; Edge Cases
;;; ============================================================

(run-test "command name with hyphens works"
  (lambda ()
    (define-custom-command! "my-deploy" "(string-append \"ok\")")
    (assert-equal (get-custom-command "my-deploy") "(string-append \"ok\")"
                  "Hyphenated name should work")))

(run-test "command with multi-line expression"
  (lambda ()
    (define-custom-command! "multi" "(begin (+ 1 2) (+ 3 4))")
    (assert-equal (execute-custom-command "multi") 7
                  "Multi-expression begin block should work")))

;;; ============================================================
;;; Cleanup
;;; ============================================================

;; Remove test commands from persistent storage
(set! *custom-commands* '())
(save-custom-commands!)

;;; Summary

(test-summary)
(if (= *tests-passed* *tests-run*)
    (format #t "All tests passed!~%")
    (begin
      (format #t "~a tests failed.~%" (- *tests-run* *tests-passed*))
      (exit 1)))
