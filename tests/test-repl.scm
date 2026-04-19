#!/usr/bin/env guile3
!#
;;; test-repl.scm --- Tests for REPL module -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Tests for sage/repl.scm, particularly the *commands* alist
;; and command handlers. Ensures forward reference warnings are fixed.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage repl)
             (sage config)
             (srfi srfi-1)
             (ice-9 format))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== REPL Commands Tests ===~%")

;;; Tests

(run-test "*commands* is defined and is a list"
  (lambda ()
    (assert-true (list? *commands*)
                 "*commands* should be a list")))

(run-test "*commands* is non-empty"
  (lambda ()
    (assert-true (> (length *commands*) 0)
                 "*commands* should not be empty")))

(run-test "*commands* contains /help"
  (lambda ()
    (assert-true (assoc "/help" *commands*)
                 "/help should be in commands")))

(run-test "*commands* contains /exit"
  (lambda ()
    (assert-true (assoc "/exit" *commands*)
                 "/exit should be in commands")))

(run-test "*commands* contains /status"
  (lambda ()
    (assert-true (assoc "/status" *commands*)
                 "/status should be in commands")))

(run-test "*commands* contains /model"
  (lambda ()
    (assert-true (assoc "/model" *commands*)
                 "/model should be in commands")))

(run-test "*commands* contains /agent"
  (lambda ()
    (assert-true (assoc "/agent" *commands*)
                 "/agent should be in commands")))

(run-test "All command handlers are procedures"
  (lambda ()
    (for-each
     (lambda (cmd-pair)
       (assert-true (procedure? (cdr cmd-pair))
                    (format #f "Handler for ~a should be a procedure"
                            (car cmd-pair))))
     *commands*)))

(run-test "/exit and /quit use same handler"
  (lambda ()
    (let ((exit-handler (assoc-ref *commands* "/exit"))
          (quit-handler (assoc-ref *commands* "/quit")))
      (assert-true (eq? exit-handler quit-handler)
                   "/exit and /quit should use same handler"))))

(run-test "/stats has its own handler (usage ledger, not session status)"
  (lambda ()
    (let ((status-handler (assoc-ref *commands* "/status"))
          (stats-handler (assoc-ref *commands* "/stats")))
      (assert-true (procedure? stats-handler)
                   "/stats should dispatch to a procedure")
      (assert-true (not (eq? status-handler stats-handler))
                   "/stats should be distinct from /status (bd: guile-sage-b5c)"))))

(run-test "/reload and /refresh use same handler"
  (lambda ()
    (let ((reload-handler (assoc-ref *commands* "/reload"))
          (refresh-handler (assoc-ref *commands* "/refresh")))
      (assert-true (eq? reload-handler refresh-handler)
                   "/reload and /refresh should use same handler"))))

(run-test "handle-command returns #t for /help"
  (lambda ()
    (assert-true (handle-command "/help")
                 "/help should return #t")))

(run-test "handle-command returns #f for non-commands"
  (lambda ()
    (assert-false (handle-command "hello world")
                  "Non-command should return #f")))

;;; Summary

(test-summary)
(if (= *tests-passed* *tests-run*)
    (format #t "All tests passed!~%")
    (begin
      (format #t "~a tests failed.~%" (- *tests-run* *tests-passed*))
      (exit 1)))
