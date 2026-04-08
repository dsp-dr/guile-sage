;;; test-harness.scm --- SRFI-64 compatibility shim -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Test harness for guile-sage, backed by SRFI-64.
;; Provides backward-compatible test/assert API so existing test files
;; work without modification.
;;
;; Usage: (load "tests/test-harness.scm") or (load "test-harness.scm")
;;        then call test, run-test, test-suite, assert-*, test-summary.

(add-to-load-path "src")

(use-modules (sage tools)
             (sage config)
             (sage util)
             (srfi srfi-64)
             (ice-9 format)
             (ice-9 match)
             (srfi srfi-1))

;;; ============================================================
;;; SRFI-64 Runner Setup
;;; ============================================================

;;; Custom runner that prints PASS/FAIL in the legacy format
;;; and avoids writing log files.

(define (make-sage-runner)
  (let ((runner (test-runner-simple)))
    (test-runner-on-test-end! runner
      (lambda (runner)
        (let ((name (test-runner-test-name runner))
              (result (test-result-kind runner)))
          (case result
            ((pass)  (format #t "PASS: ~a~%" name))
            ((fail)  (format #t "FAIL: ~a~%" name))
            ((xfail) (format #t "XFAIL: ~a~%" name))
            ((xpass) (format #t "XPASS: ~a~%" name))
            ((skip)  (format #t "SKIP: ~a~%" name))))))
    (test-runner-on-group-begin! runner
      (lambda (runner suite-name count)
        (format #t "~%=== ~a ===~%" suite-name)))
    (test-runner-on-group-end! runner (lambda (runner) #f))
    (test-runner-on-final! runner (lambda (runner) #f))
    runner))

(define *sage-runner* (make-sage-runner))
(test-runner-factory (lambda () (make-sage-runner)))
(test-runner-current *sage-runner*)

;;; Track the top-level suite name for test-summary
(define *suite-started* #f)

;;; ============================================================
;;; Compatibility Layer
;;; ============================================================

;;; Variables kept for backward compatibility.
;;; They shadow the SRFI-64 counters but are updated from the runner.
(define *tests-run* 0)
(define *tests-passed* 0)
(define *tests-failed* 0)
(define *current-suite* "default")

(define (sync-counters!)
  "Sync legacy counter variables from the SRFI-64 runner."
  (let ((runner (test-runner-current)))
    (when runner
      (set! *tests-passed* (test-runner-pass-count runner))
      (set! *tests-failed* (test-runner-fail-count runner))
      (set! *tests-run* (+ *tests-passed* *tests-failed*)))))

(define (test-suite name thunk)
  "Run a test suite with the given name."
  (set! *current-suite* name)
  (test-begin name)
  (set! *suite-started* #t)
  (thunk)
  (test-end name)
  (sync-counters!))

(define (test name thunk)
  "Run a single test."
  (test-assert name
    (catch #t
      (lambda ()
        (thunk)
        #t)
      (lambda (key . args)
        #f)))
  (sync-counters!))

;;; Alias: some test files use run-test instead of test
(define run-test test)

;;; ============================================================
;;; Assertions (throw on failure, compatible with test wrapper)
;;; ============================================================

(define (assert-true val msg)
  "Assert that val is true."
  (unless val
    (error msg)))

(define (assert-false val msg)
  "Assert that val is false."
  (when val
    (error msg)))

(define (assert-equal actual expected msg)
  "Assert that actual equals expected."
  (unless (equal? actual expected)
    (error (format #f "~a: got ~s, expected ~s" msg actual expected))))

(define (assert-contains str substr msg)
  "Assert that str contains substr."
  (unless (and (string? str) (string-contains str substr))
    (error (format #f "~a: '~a' not found in '~a'" msg substr str))))

(define (assert-not-contains str substr msg)
  "Assert that str does not contain substr."
  (when (and (string? str) (string-contains str substr))
    (error (format #f "~a: '~a' found in '~a'" msg substr str))))

(define (assert-error thunk msg)
  "Assert that thunk throws an error."
  (let ((threw #f))
    (catch #t
      (lambda () (thunk))
      (lambda args (set! threw #t)))
    (unless threw
      (error msg))))

;;; ============================================================
;;; Summary
;;; ============================================================

(define (test-summary)
  "Print test summary using SRFI-64 runner stats."
  (sync-counters!)
  (format #t "~%=== Test Summary ===~%")
  (format #t "Total: ~a~%" *tests-run*)
  (format #t "Passed: ~a~%" *tests-passed*)
  (format #t "Failed: ~a~%" *tests-failed*)
  (format #t "Pass Rate: ~a%~%"
          (if (> *tests-run* 0)
              (inexact->exact (round (* 100 (/ *tests-passed* *tests-run*))))
              0))
  (format #t "~%Tests: ~a/~a passed~%" *tests-passed* *tests-run*))

;;; ============================================================
;;; Initialize tools
;;; ============================================================

(init-default-tools)

;;; ============================================================
;;; Exports (for use-modules consumers; load consumers see all
;;; top-level defines automatically)
;;; ============================================================

(export test-suite)
(export test)
(export run-test)
(export assert-true)
(export assert-false)
(export assert-equal)
(export assert-contains)
(export assert-not-contains)
(export assert-error)
(export test-summary)
