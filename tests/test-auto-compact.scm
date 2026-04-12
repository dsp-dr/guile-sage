#!/usr/bin/env guile3
!#
;;; test-auto-compact.scm --- Tests for auto-compaction at 80% context limit

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage session)
             (sage compaction)
             (sage config)
             (ice-9 format))

(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Auto-Compaction Tests ===~%")

;;; Helper: create a session with N messages of ~K tokens each
(define (setup-session! n-messages tokens-per-msg)
  (session-create)
  (let loop ((i 0))
    (when (< i n-messages)
      (session-add-message
       (if (even? i) "user" "assistant")
       (make-string (* tokens-per-msg 4) #\x)  ; ~4 chars per token
       #:tokens tokens-per-msg)
      (loop (1+ i)))))

;;; --- Threshold behavior ---

(format #t "~%--- Threshold behavior ---~%")

(run-test "auto-compact does NOT fire below 80% threshold"
  (lambda ()
    (setup-session! 5 100)  ; 500 tokens
    (let ((result (session-maybe-compact!
                   1000          ; context limit
                   compact-auto
                   message-tokens)))
      ;; 500/1000 = 50%, below 80%
      (when result
        (error "should not compact at 50% usage" result)))))

(run-test "auto-compact FIRES at 80% threshold"
  (lambda ()
    (setup-session! 8 100)  ; 800 tokens
    (let ((result (session-maybe-compact!
                   1000          ; context limit
                   compact-auto
                   message-tokens)))
      ;; 800/1000 = 80%, at threshold
      (unless result
        (error "should compact at 80% usage")))))

(run-test "auto-compact FIRES above 80% threshold"
  (lambda ()
    (setup-session! 10 100)  ; 1000 tokens
    (let ((result (session-maybe-compact!
                   1000          ; context limit
                   compact-auto
                   message-tokens)))
      ;; 1000/1000 = 100%, above threshold
      (unless result
        (error "should compact at 100% usage")))))

;;; --- Compaction reduces tokens ---

(format #t "~%--- Token reduction ---~%")

(run-test "auto-compact reduces message count"
  (lambda ()
    (setup-session! 10 100)  ; 1000 tokens in 10 messages
    (let ((before-count (length (session-get-messages))))
      (session-maybe-compact! 1000 compact-auto message-tokens)
      (let ((after-count (length (session-get-messages))))
        (unless (< after-count before-count)
          (error (format #f "compaction should reduce messages: ~a -> ~a"
                         before-count after-count)))))))

(run-test "auto-compact targets fewer messages than original"
  (lambda ()
    (setup-session! 20 100)  ; 2000 tokens in 20 messages, limit 2000
    (let ((before-count (length (session-get-messages))))
      (session-maybe-compact! 2000 compact-auto message-tokens)
      (let ((after-count (length (session-get-messages))))
        ;; Should be substantially fewer messages
        (unless (< after-count (* before-count 0.8))
          (error (format #f "post-compact msgs ~a should be < 80% of ~a"
                         after-count before-count)))))))

;;; --- Edge cases ---

(format #t "~%--- Edge cases ---~%")

(run-test "auto-compact on empty session returns #f"
  (lambda ()
    (session-create)  ; fresh, no messages
    (let ((result (session-maybe-compact! 1000 compact-auto message-tokens)))
      (when result
        (error "empty session should not compact")))))

(run-test "auto-compact on nil session returns #f"
  (lambda ()
    (set! *session* #f)
    (let ((result (session-maybe-compact! 1000 compact-auto message-tokens)))
      (when result
        (error "nil session should return #f")))))

(run-test "auto-compact preserves system messages"
  (lambda ()
    (session-create)
    (session-add-message "system" "You are a helpful agent." #:tokens 10)
    (setup-session! 15 100)  ; 1500 + 10 system = 1510 tokens
    (session-maybe-compact! 1500 compact-auto message-tokens)
    ;; System message should still be present
    (let* ((msgs (session-get-messages))
           (system-msgs (filter (lambda (m)
                                  (equal? (assoc-ref m "role") "system"))
                                msgs)))
      (when (null? system-msgs)
        (error "system message should survive compaction")))))

(run-test "auto-compact result message has token counts"
  (lambda ()
    (setup-session! 10 100)
    (let ((result (session-maybe-compact! 1000 compact-auto message-tokens)))
      (unless (and result
                   (string-contains result "->")
                   (string-contains result "tokens"))
        (error "result should mention token reduction" result)))))

;;; --- /compact slash command ---

(format #t "~%--- /compact command ---~%")

(run-test "session-compact! reduces messages"
  (lambda ()
    (setup-session! 20 50)  ; 1000 tokens in 20 messages
    (let ((before-count (length (session-get-messages))))
      (session-compact! #:keep-recent 5)
      (let ((after-count (length (session-get-messages))))
        (unless (<= after-count 6)  ; 5 + maybe 1 system
          (error (format #f "compact keep-recent=5 should leave ≤6 msgs, got ~a"
                         after-count)))))))

(test-summary)
