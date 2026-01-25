;;; test-harness.scm --- Test harness framework -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Comprehensive test harness for guile-sage.
;; Provides test utilities, assertions, and reporting.

(add-to-load-path "src")

(use-modules (sage tools)
             (sage config)
             (sage util)
             (ice-9 format)
             (ice-9 match)
             (srfi srfi-1))

;;; Test Framework
(define *tests-run* 0)
(define *tests-passed* 0)
(define *tests-failed* 0)
(define *test-results* '())
(define *current-suite* "default")

(define (test-suite name thunk)
  "Run a test suite with the given name."
  (set! *current-suite* name)
  (format #t "~%=== ~a ===~%" name)
  (thunk))

(define (test name thunk)
  "Run a single test."
  (set! *tests-run* (1+ *tests-run*))
  (catch #t
    (lambda ()
      (thunk)
      (set! *tests-passed* (1+ *tests-passed*))
      (set! *test-results* (cons `(pass ,*current-suite* ,name) *test-results*))
      (format #t "PASS: ~a~%" name))
    (lambda (key . args)
      (set! *tests-failed* (1+ *tests-failed*))
      (set! *test-results* (cons `(fail ,*current-suite* ,name ,key ,args) *test-results*))
      (format #t "FAIL: ~a (~a: ~a)~%" name key args))))

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

(define (test-summary)
  "Print test summary."
  (format #t "~%=== Test Summary ===~%")
  (format #t "Total: ~a~%" *tests-run*)
  (format #t "Passed: ~a~%" *tests-passed*)
  (format #t "Failed: ~a~%" *tests-failed*)
  (format #t "Pass Rate: ~a%~%"
          (if (> *tests-run* 0)
              (inexact->exact (round (* 100 (/ *tests-passed* *tests-run*))))
              0))
  (when (> *tests-failed* 0)
    (format #t "~%Failed tests:~%")
    (for-each
     (lambda (r)
       (match r
         (('fail suite name key args)
          (format #t "  - ~a/~a: ~a~%" suite name key))
         (_ #f)))
     *test-results*))
  (format #t "~%Tests: ~a/~a passed~%" *tests-passed* *tests-run*))

;;; Initialize tools
(init-default-tools)

;;; Export test utilities
(define-public test-suite test-suite)
(define-public test test)
(define-public assert-true assert-true)
(define-public assert-false assert-false)
(define-public assert-equal assert-equal)
(define-public assert-contains assert-contains)
(define-public assert-not-contains assert-not-contains)
(define-public assert-error assert-error)
(define-public test-summary test-summary)
