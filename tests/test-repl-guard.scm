#!/usr/bin/env guile3
!#
;;; test-repl-guard.scm --- Tests for tool result anti-hallucination guard -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Tests for tool-result-needs-guard? and *tool-error-guard-message*
;; in sage/repl.scm. Ensures the guard detects all known error patterns
;; and passes clean results through unmodified.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage repl)
             (ice-9 format))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Tool Result Guard Tests ===~%")

;;; --- Error pattern detection ---

(run-test "guard detects 'Tool error:' prefix"
  (lambda ()
    (assert-true (tool-result-needs-guard? "Tool error: connection refused")
                 "Should detect Tool error:")))

(run-test "guard detects 'Permission denied'"
  (lambda ()
    (assert-true (tool-result-needs-guard? "Permission denied: /etc/shadow")
                 "Should detect Permission denied")))

(run-test "guard detects 'Unsafe path:'"
  (lambda ()
    (assert-true (tool-result-needs-guard? "Unsafe path: /etc/passwd")
                 "Should detect Unsafe path:")))

(run-test "guard detects 'File not found:'"
  (lambda ()
    (assert-true (tool-result-needs-guard? "File not found: /nonexistent.txt")
                 "Should detect File not found:")))

(run-test "guard detects 'No match found'"
  (lambda ()
    (assert-true (tool-result-needs-guard? "No match found for pattern")
                 "Should detect No match found")))

(run-test "guard detects generic 'not found'"
  (lambda ()
    (assert-true (tool-result-needs-guard? "Module xyz not found in workspace")
                 "Should detect not found")))

(run-test "guard detects 'No file results'"
  (lambda ()
    (assert-true (tool-result-needs-guard? "No file results for *.foo")
                 "Should detect No file results")))

;;; --- Empty/whitespace detection ---

(run-test "guard detects empty string"
  (lambda ()
    (assert-true (tool-result-needs-guard? "")
                 "Should detect empty string")))

(run-test "guard detects whitespace-only string"
  (lambda ()
    (assert-true (tool-result-needs-guard? "   ")
                 "Should detect whitespace-only")))

(run-test "guard detects newline-only string"
  (lambda ()
    (assert-true (tool-result-needs-guard? "\n\n")
                 "Should detect newline-only")))

(run-test "guard detects tab-only string"
  (lambda ()
    (assert-true (tool-result-needs-guard? "\t\t")
                 "Should detect tab-only")))

;;; --- Clean results pass through ---

(run-test "guard passes normal file content"
  (lambda ()
    (assert-false (tool-result-needs-guard?
                   "(define (hello) (display \"Hello, world!\\n\"))")
                  "Normal code should not trigger guard")))

(run-test "guard passes search results with matches"
  (lambda ()
    (assert-false (tool-result-needs-guard?
                   "src/sage/repl.scm:42: (define *running* #t)")
                  "Search results should not trigger guard")))

(run-test "guard passes directory listing"
  (lambda ()
    (assert-false (tool-result-needs-guard?
                   "src/\ntests/\nMakefile\nCLAUDE.md")
                  "Directory listing should not trigger guard")))

(run-test "guard passes multi-line output"
  (lambda ()
    (assert-false (tool-result-needs-guard?
                   "Line 1: all good\nLine 2: still good\nLine 3: done")
                  "Multi-line output should not trigger guard")))

;;; --- Guard message constant ---

(run-test "*tool-error-guard-message* is a non-empty string"
  (lambda ()
    (assert-true (and (string? *tool-error-guard-message*)
                      (> (string-length *tool-error-guard-message*) 0))
                 "Guard message should be a non-empty string")))

(run-test "*tool-error-guard-message* contains anti-hallucination keywords"
  (lambda ()
    (assert-contains *tool-error-guard-message* "NOT"
                     "Guard message should contain NOT")
    (assert-contains *tool-error-guard-message* "fabricate"
                     "Guard message should contain fabricate")
    (assert-contains *tool-error-guard-message* "hallucinate"
                     "Guard message should contain hallucinate")))

;;; Summary

(test-summary)
(if (= *tests-passed* *tests-run*)
    (format #t "All tests passed!~%")
    (begin
      (format #t "~a tests failed.~%" (- *tests-run* *tests-passed*))
      (exit 1)))
