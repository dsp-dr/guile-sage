;;; test-compaction.scm --- Compaction strategy evaluation tests -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Tests and evaluations for context compaction strategies.
;; Measures information retention, intent preservation, and compression quality.

(add-to-load-path "src")

(use-modules (sage compaction)
             (sage session)
             (ice-9 format)
             (srfi srfi-1))

;;; ============================================================
;;; Test Framework
;;; ============================================================

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

(define (assert-equal actual expected msg)
  (unless (equal? actual expected)
    (error (format #f "~a: got ~s, expected ~s" msg actual expected))))

;;; ============================================================
;;; Test Data: Synthetic Conversation
;;; ============================================================

(define *test-conversation*
  '((("role" . "system")
     ("content" . "You are a helpful coding assistant.")
     ("tokens" . 10))
    (("role" . "user")
     ("content" . "I need help fixing a bug in my authentication module. Users can't login.")
     ("tokens" . 20))
    (("role" . "assistant")
     ("content" . "I'll help you fix the authentication bug. Let me look at your code.")
     ("tokens" . 18))
    (("role" . "user")
     ("content" . "Here's the login function: (define (login user pass) ...)")
     ("tokens" . 50))
    (("role" . "assistant")
     ("content" . "I see the issue. The password comparison is using = instead of string=?")
     ("tokens" . 25)
     ("tool_call" . #t))
    (("role" . "user")
     ("content" . "You're right! Can you show me the fix?")
     ("tokens" . 12))
    (("role" . "assistant")
     ("content" . "Here's the corrected code: (define (login user pass) (string=? pass (get-password user)))")
     ("tokens" . 30))
    (("role" . "user")
     ("content" . "That works! Now I also need to add session management.")
     ("tokens" . 15))
    (("role" . "assistant")
     ("content" . "For session management, you'll want to create a session token on successful login.")
     ("tokens" . 22))
    (("role" . "user")
     ("content" . "Can you implement that?")
     ("tokens" . 8))
    (("role" . "assistant")
     ("content" . "I'll create a session module with token generation and validation.")
     ("tokens" . 18)
     ("tool_call" . #t))
    (("role" . "user")
     ("content" . "Great, also add a logout function.")
     ("tokens" . 10))
    (("role" . "assistant")
     ("content" . "Added logout function that invalidates the session token.")
     ("tokens" . 15))))

;;; ============================================================
;;; Unit Tests
;;; ============================================================

(format #t "~%=== Compaction Strategy Tests ===~%")

(test "compact-truncate keeps recent messages"
  (lambda ()
    (let ((result (compact-truncate *test-conversation* #:keep 5)))
      (assert-true (= (length result) 5)
                   "Should keep exactly 5 messages")
      ;; System message should be preserved
      (assert-true (equal? (assoc-ref (car result) "role") "system")
                   "Should preserve system message"))))

(test "compact-truncate preserves system messages"
  (lambda ()
    (let* ((result (compact-truncate *test-conversation* #:keep 3))
           (system-count (length (filter (lambda (m)
                                           (equal? (assoc-ref m "role") "system"))
                                         result))))
      (assert-true (>= system-count 1)
                   "Should preserve at least one system message"))))

(test "compact-token-limit respects budget"
  (lambda ()
    (let* ((result (compact-token-limit *test-conversation* #:max-tokens 100))
           (total-tokens (fold + 0 (map (lambda (m)
                                          (or (assoc-ref m "tokens") 0))
                                        result))))
      (assert-true (<= total-tokens 100)
                   "Should respect token budget"))))

(test "compact-importance scores tool calls higher"
  (lambda ()
    (let* ((result (compact-importance *test-conversation* #:keep 5))
           (has-tool-call (any (lambda (m) (assoc-ref m "tool_call")) result)))
      (assert-true has-tool-call
                   "Should preserve messages with tool calls"))))

(test "compact-summarize creates summary"
  (lambda ()
    (let* ((result (compact-summarize *test-conversation* #:keep-recent 3))
           (first-msg (car result))
           (content (assoc-ref first-msg "content")))
      (assert-true (string-contains content "Context Summary")
                   "Should include context summary"))))

(test "compact-intent identifies conversation intent"
  (lambda ()
    (let* ((result (compact-intent *test-conversation* #:max-tokens 150))
           (intent-msg (find (lambda (m)
                               (let ((content (or (assoc-ref m "content") "")))
                                 (string-contains content "Intent")))
                             result)))
      (assert-true intent-msg
                   "Should include intent marker"))))

;;; ============================================================
;;; Evaluation Tests
;;; ============================================================

(format #t "~%=== Compaction Evaluation Tests ===~%")

(test "evaluate-compaction returns metrics"
  (lambda ()
    (let* ((compacted (compact-truncate *test-conversation* #:keep 5))
           (eval-result (evaluate-compaction *test-conversation* compacted)))
      (assert-true (assoc-ref eval-result "compression_ratio")
                   "Should have compression ratio")
      (assert-true (assoc-ref eval-result "overall_score")
                   "Should have overall score"))))

(test "compaction-score penalizes aggressive compression"
  (lambda ()
    (let ((aggressive-score (compaction-score 0.5 0.5 0.2))  ; 20% of original
          (balanced-score (compaction-score 0.8 0.8 0.5)))   ; 50% of original
      (assert-true (> balanced-score aggressive-score)
                   "Balanced compression should score higher"))))

(test "run-compaction-eval compares all strategies"
  (lambda ()
    (let ((results (run-compaction-eval *test-conversation* #:target-tokens 100)))
      (assert-true (= (length results) 5)
                   "Should evaluate all 5 strategies")
      (for-each (lambda (r)
                  (assert-true (assoc-ref (cdr r) "overall_score")
                               "Each result should have score"))
                results))))

;;; ============================================================
;;; Strategy Comparison
;;; ============================================================

(format #t "~%=== Strategy Comparison ===~%")

(let ((results (run-compaction-eval *test-conversation* #:target-tokens 100)))
  (format #t "~%Strategy Performance (target: 100 tokens):~%")
  (format #t "~60a~%" (make-string 60 #\-))
  (format #t "~15a ~10a ~10a ~10a ~10a~%"
          "Strategy" "Tokens" "Ratio" "Info" "Score")
  (format #t "~60a~%" (make-string 60 #\-))

  (for-each (lambda (r)
              (let* ((name (car r))
                     (eval (cdr r))
                     (tokens (assoc-ref eval "compacted_tokens"))
                     (ratio (assoc-ref eval "compression_ratio"))
                     (info (assoc-ref eval "key_info_retention"))
                     (score (assoc-ref eval "overall_score")))
                (format #t "~15a ~10a ~10,2f ~10,2f ~10,1f~%"
                        name tokens ratio info score)))
            results)

  ;; Find best strategy
  (let* ((sorted (sort results
                       (lambda (a b)
                         (> (assoc-ref (cdr a) "overall_score")
                            (assoc-ref (cdr b) "overall_score")))))
         (best (car sorted)))
    (format #t "~%Best strategy: ~a (score: ~,1f)~%"
            (car best)
            (assoc-ref (cdr best) "overall_score"))))

;;; ============================================================
;;; Summary
;;; ============================================================

(format #t "~%=== Test Summary ===~%")
(format #t "Tests: ~a/~a passed~%" *tests-passed* *tests-run*)

(exit (if (= *tests-passed* *tests-run*) 0 1))
