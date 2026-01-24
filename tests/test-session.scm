#!/usr/bin/env guile3
!#
;;; test-session.scm --- Tests for session management

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage session)
             (sage config)
             (ice-9 format))

;;; Test helpers

(define *tests-run* 0)
(define *tests-passed* 0)

(define (run-test name thunk)
  (set! *tests-run* (1+ *tests-run*))
  (catch #t
    (lambda ()
      (thunk)
      (set! *tests-passed* (1+ *tests-passed*))
      (format #t "PASS: ~a~%" name))
    (lambda (key . args)
      (format #t "FAIL: ~a - ~a: ~a~%" name key args))))

;;; Setup

(format #t "~%=== Session Tests ===~%")

;;; Token Estimation Tests

(format #t "~%--- Token Estimation ---~%")

(run-test "estimate-tokens for short text"
  (lambda ()
    (let ((tokens (estimate-tokens "Hello world")))
      (unless (and (number? tokens) (> tokens 0))
        (error "should return positive number" tokens)))))

(run-test "estimate-tokens for empty string"
  (lambda ()
    (let ((tokens (estimate-tokens "")))
      (unless (= tokens 0)
        (error "should return 0 for empty string" tokens)))))

;;; Path Encoding Tests (Claude-style)

(format #t "~%--- Path Encoding ---~%")

(run-test "path->project-id encodes path"
  (lambda ()
    (let ((id (path->project-id "/home/user/project")))
      (unless (equal? id "-home-user-project")
        (error "wrong encoding" id)))))

(run-test "project-id->path decodes path"
  (lambda ()
    (let ((path (project-id->path "-home-user-project")))
      (unless (equal? path "/home/user/project")
        (error "wrong decoding" path)))))

(run-test "path encoding roundtrip (no hyphens)"
  (lambda ()
    ;; Note: paths with hyphens don't roundtrip (same as Claude Code)
    (let* ((original "/home/user/projects/test")
           (encoded (path->project-id original))
           (decoded (project-id->path encoded)))
      (unless (equal? original decoded)
        (error "roundtrip failed" original decoded)))))

(run-test "current-project-id returns encoded cwd"
  (lambda ()
    (let ((id (current-project-id)))
      (unless (string-prefix? "-" id)
        (error "should start with dash" id)))))

;;; Session Creation Tests

(format #t "~%--- Session Creation ---~%")

(run-test "session-create returns session"
  (lambda ()
    (let ((session (session-create #:name "test-session")))
      (unless session
        (error "should return session"))
      (unless (equal? (assoc-ref session "name") "test-session")
        (error "wrong name" (assoc-ref session "name"))))))

(run-test "session has required fields"
  (lambda ()
    (let ((session (session-create)))
      (unless (assoc-ref session "name")
        (error "missing name"))
      (unless (assoc-ref session "messages")
        (error "missing messages"))
      (unless (assoc-ref session "stats")
        (error "missing stats")))))

;;; Message Tests

(format #t "~%--- Message Management ---~%")

(run-test "session-add-message adds to history"
  (lambda ()
    (session-create #:name "msg-test")
    (session-add-message "user" "Hello")
    (let ((messages (session-get-messages)))
      (unless (= (length messages) 1)
        (error "should have 1 message" (length messages))))))

(run-test "session-add-message tracks stats"
  (lambda ()
    (session-create #:name "stats-test")
    (session-add-message "user" "Test message")
    (let ((status (session-status)))
      (unless (> (assoc-ref status "total_tokens") 0)
        (error "should track tokens")))))

(run-test "multiple messages accumulate"
  (lambda ()
    (session-create #:name "multi-test")
    (session-add-message "user" "Hello")
    (session-add-message "assistant" "Hi there!")
    (session-add-message "user" "How are you?")
    (let ((messages (session-get-messages)))
      (unless (= (length messages) 3)
        (error "should have 3 messages" (length messages))))))

;;; Context Tests

(format #t "~%--- Context Management ---~%")

(run-test "session-get-context returns formatted messages"
  (lambda ()
    (session-create)
    (session-add-message "user" "Test")
    (let ((context (session-get-context)))
      (unless (list? context)
        (error "should return list"))
      (let ((msg (car context)))
        (unless (and (assoc-ref msg "role")
                     (assoc-ref msg "content"))
          (error "missing required fields"))))))

;;; Clear Tests

(format #t "~%--- Session Clear ---~%")

(run-test "session-clear! removes messages"
  (lambda ()
    (session-create)
    (session-add-message "user" "Test")
    (session-clear!)
    (let ((messages (session-get-messages)))
      (unless (null? messages)
        (error "should be empty" messages)))))

(run-test "session-clear! resets stats"
  (lambda ()
    (session-create)
    (session-add-message "user" "Test")
    (session-clear!)
    (let ((status (session-status)))
      (unless (= (assoc-ref status "total_tokens") 0)
        (error "tokens should be 0")))))

;;; Compact Tests

(format #t "~%--- Session Compact ---~%")

(run-test "session-compact! keeps recent messages"
  (lambda ()
    (session-create)
    (session-add-message "user" "Message 1")
    (session-add-message "assistant" "Response 1")
    (session-add-message "user" "Message 2")
    (session-add-message "assistant" "Response 2")
    (session-add-message "user" "Message 3")
    (session-add-message "assistant" "Response 3")
    (session-compact! #:keep-recent 2)
    (let ((messages (session-get-messages)))
      (unless (<= (length messages) 3)  ; 2 + possible summary
        (error "should keep ~2 messages" (length messages))))))

(run-test "session-compact! with summarize adds summary"
  (lambda ()
    (session-create)
    (session-add-message "user" "Message 1")
    (session-add-message "assistant" "Response 1")
    (session-add-message "user" "Message 2")
    (session-add-message "assistant" "Response 2")
    (session-compact! #:keep-recent 2 #:summarize #t)
    (let* ((messages (session-get-messages))
           (first (car messages)))
      (when (equal? (assoc-ref first "role") "system")
        ;; Summary was added
        (unless (string-contains (assoc-ref first "content") "Compacted")
          (error "summary should mention compacted"))))))

;;; Status Tests

(format #t "~%--- Status Reporting ---~%")

(run-test "session-status returns alist"
  (lambda ()
    (session-create)
    (let ((status (session-status)))
      (unless (list? status)
        (error "should return alist"))
      (unless (assoc-ref status "name")
        (error "should have name"))
      (unless (assoc-ref status "messages")
        (error "should have message count")))))

(run-test "format-session-status returns string"
  (lambda ()
    (session-create #:name "format-test")
    (let ((formatted (format-session-status)))
      (unless (string? formatted)
        (error "should return string"))
      (unless (string-contains formatted "format-test")
        (error "should contain session name")))))

;;; Summary

(format #t "~%=== Summary ===~%")
(format #t "Tests: ~a/~a passed~%" *tests-passed* *tests-run*)

(if (= *tests-passed* *tests-run*)
    (begin
      (format #t "All tests passed!~%")
      (exit 0))
    (begin
      (format #t "Some tests failed!~%")
      (exit 1)))
