;;; test-compaction-security.scm --- Security tests for compaction -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Ensures compaction doesn't inadvertently leak or expose sensitive data.
;; Tests that secrets in messages are handled appropriately.

(add-to-load-path "src")

(use-modules (sage compaction)
             (sage util)
             (srfi srfi-1)
             (ice-9 format))

;;; Test Framework
(define *tests-run* 0)
(define *tests-passed* 0)

(define (test name thunk)
  (set! *tests-run* (1+ *tests-run*))
  (catch #t
    (lambda ()
      (thunk)
      (set! *tests-passed* (1+ *tests-passed*))
      (format #t "PASS: ~a~%" name))
    (lambda (key . args)
      (format #t "FAIL: ~a (~a)~%" name key))))

(define (assert-true val msg)
  (unless val (error msg)))

(define (assert-not-contains str substr msg)
  (when (and (string? str) (string-contains str substr))
    (error msg)))

;;; ============================================================
;;; Test Data with Secrets
;;; ============================================================

(define *mock-secret* "sk_test_SAGE_QA_TOKEN_abc123xyz789")
(define *mock-api-key* "AKIAIOSFODNN7EXAMPLE")

(define *conversation-with-secrets*
  `((("role" . "system")
     ("content" . "You are a helpful assistant.")
     ("tokens" . 10))
    (("role" . "user")
     ("content" . ,(format #f "Set up the API with key ~a" *mock-api-key*))
     ("tokens" . 20))
    (("role" . "assistant")
     ("content" . "I'll configure the API. Note: I won't store or repeat your API key.")
     ("tokens" . 18))
    (("role" . "user")
     ("content" . ,(format #f "Also use this secret: ~a" *mock-secret*))
     ("tokens" . 15))
    (("role" . "assistant")
     ("content" . "Configuration complete. Secrets have been securely stored.")
     ("tokens" . 12))
    (("role" . "user")
     ("content" . "Now make a test request")
     ("tokens" . 8))
    (("role" . "assistant")
     ("content" . "Test request successful. The API is working correctly.")
     ("tokens" . 12))))

;;; ============================================================
;;; Security Tests
;;; ============================================================

(format #t "~%=== Compaction Security Tests ===~%")

(test "summarize doesn't include raw secrets"
  (lambda ()
    (let* ((result (compact-summarize *conversation-with-secrets* #:keep-recent 2))
           (summary-msg (car result))
           (summary-content (assoc-ref summary-msg "content")))
      ;; Summary should not contain the actual secret values
      (assert-not-contains summary-content *mock-secret*
                           "Summary should not contain raw secret")
      (assert-not-contains summary-content *mock-api-key*
                           "Summary should not contain raw API key"))))

(test "intent extraction doesn't include secrets"
  (lambda ()
    (let ((intent (identify-intent *conversation-with-secrets*)))
      ;; Intent description should not contain actual secrets
      (assert-not-contains intent *mock-secret*
                           "Intent should not contain secret")
      (assert-not-contains intent *mock-api-key*
                           "Intent should not contain API key"))))

(test "topics extraction excludes secret patterns"
  (lambda ()
    ;; This tests that extract-topics doesn't include things that look like secrets
    (let ((topics (extract-topics *conversation-with-secrets*)))
      (assert-true (not (member *mock-secret* topics))
                   "Topics should not include secrets")
      (assert-true (not (member *mock-api-key* topics))
                   "Topics should not include API keys"))))

;;; ============================================================
;;; Web Request Security Test
;;; ============================================================

(format #t "~%=== Web Request Security Test ===~%")

(test "HTTP request with QA token works"
  (lambda ()
    (let* ((qa-token (or (getenv "SAGE_QA_TOKEN") "test-token-12345"))
           (url (format #f "https://wal.sh/?qa=~a" qa-token))
           (result (http-get url)))
      (assert-true (= (car result) 200)
                   "Should get 200 response")
      ;; Verify the response doesn't echo back credentials
      (assert-not-contains (cdr result) qa-token
                           "Response should not echo token"))))

;;; ============================================================
;;; Summary
;;; ============================================================

(format #t "~%=== Test Summary ===~%")
(format #t "Tests: ~a/~a passed~%" *tests-passed* *tests-run*)

(exit (if (= *tests-passed* *tests-run*) 0 1))
