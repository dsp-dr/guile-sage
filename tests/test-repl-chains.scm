#!/usr/bin/env guile3
!#
;;; test-repl-chains.scm --- Tests for multi-step tool chain dispatch -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Validation tests for execute-tool-chain and *max-tool-iterations*
;; introduced in commit 70b242d (bd: guile-qa1).
;;
;; Since execute-tool-chain and *max-tool-iterations* are not exported
;; from (sage repl), we access them via @@ (private module refs).
;; We mock ollama-chat-with-tools and session functions to isolate
;; the dispatch loop logic without hitting the network.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage repl)
             (sage session)
             (sage tools)
             (sage config)
             (sage util)
             (sage telemetry)
             (srfi srfi-1)
             (ice-9 format))

;;; Load shared test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Multi-Step Tool Chain Tests ===~%")

;;; Access private bindings from (sage repl)
(define execute-tool-chain (@@ (sage repl) execute-tool-chain))
(define *max-tool-iterations* (@@ (sage repl) *max-tool-iterations*))

;;; ============================================================
;;; Test: *max-tool-iterations* exists and is a positive integer
;;; ============================================================

(run-test "*max-tool-iterations* is a positive integer"
  (lambda ()
    (assert-true (integer? *max-tool-iterations*)
                 "*max-tool-iterations* must be an integer")
    (assert-true (> *max-tool-iterations* 0)
                 "*max-tool-iterations* must be positive")))

(run-test "*max-tool-iterations* is 10 (the documented default)"
  (lambda ()
    (assert-equal *max-tool-iterations* 10
                  "*max-tool-iterations* should be 10")))

;;; ============================================================
;;; Test: execute-tool-chain is callable
;;; ============================================================

(run-test "execute-tool-chain is a procedure"
  (lambda ()
    (assert-true (procedure? execute-tool-chain)
                 "execute-tool-chain must be a procedure")))

;;; ============================================================
;;; Test: empty tool_calls returns immediately
;;; ============================================================

(run-test "execute-tool-chain returns content when tool_calls is empty"
  (lambda ()
    ;; Create a fresh session so session-add-message doesn't fail
    (session-create)
    (let* ((message `(("role" . "assistant")
                      ("content" . "No tools needed.")
                      ("tool_calls" . ())))
           (result (execute-tool-chain "test-model" message "No tools needed." 42)))
      (assert-equal result "No tools needed."
                    "Should return content directly when tool_calls is empty"))))

(run-test "execute-tool-chain returns content when tool_calls is #f"
  (lambda ()
    (session-create)
    (let* ((message `(("role" . "assistant")
                      ("content" . "No tool_calls key.")))
           (result (execute-tool-chain "test-model" message "No tool_calls key." 42)))
      (assert-equal result "No tool_calls key."
                    "Should return content when tool_calls is absent (#f)"))))

;;; ============================================================
;;; Test: single tool_call (backward compat with old 1-tool path)
;;; ============================================================

;;; We mock ollama-chat-with-tools so the follow-up returns no tool calls.
;;; The tool we call is git_status which is a safe tool and returns a string.

(run-test "execute-tool-chain handles single tool_call (backward compat)"
  (lambda ()
    (session-create)
    ;; Save the real ollama-chat-with-tools and replace with a mock
    (let* ((real-ocwt (module-ref (resolve-module '(sage ollama))
                                  'ollama-chat-with-tools))
           ;; Mock: return a response with no tool_calls
           (mock-ocwt (lambda (model messages tools)
                        `(("message" . (("role" . "assistant")
                                        ("content" . "Done. Git status returned.")))
                          ("eval_count" . 10)
                          ("prompt_eval_count" . 5)))))
      (dynamic-wind
        (lambda ()
          (module-set! (resolve-module '(sage ollama))
                       'ollama-chat-with-tools mock-ocwt))
        (lambda ()
          (let* ((message `(("role" . "assistant")
                            ("content" . "Let me check git status.")
                            ("tool_calls" . #(
                              (("function" . (("name" . "git_status")
                                              ("arguments" . ()))))))))
                 (result (execute-tool-chain "test-model" message
                                             "Let me check git status." 10)))
            ;; The loop should have processed 1 tool call, then the follow-up
            ;; has no tool_calls, so it returns the follow-up content.
            (assert-equal result "Done. Git status returned."
                          "Single tool_call should be processed and follow-up returned")))
        (lambda ()
          (module-set! (resolve-module '(sage ollama))
                       'ollama-chat-with-tools real-ocwt))))))

;;; ============================================================
;;; Test: max-iterations safety cap fires
;;; ============================================================

(run-test "execute-tool-chain terminates at *max-tool-iterations* (safety cap)"
  (lambda ()
    (session-create)
    (let* ((call-count 0)
           (real-ocwt (module-ref (resolve-module '(sage ollama))
                                  'ollama-chat-with-tools))
           ;; Mock: ALWAYS return a tool_call (infinite loop without cap)
           (mock-ocwt (lambda (model messages tools)
                        (set! call-count (1+ call-count))
                        `(("message" . (("role" . "assistant")
                                        ("content" . "Calling another tool...")
                                        ("tool_calls" . #(
                                          (("function" . (("name" . "git_status")
                                                          ("arguments" . ()))))))))
                          ("eval_count" . 5)
                          ("prompt_eval_count" . 3)))))
      (dynamic-wind
        (lambda ()
          (module-set! (resolve-module '(sage ollama))
                       'ollama-chat-with-tools mock-ocwt))
        (lambda ()
          (let* ((message `(("role" . "assistant")
                            ("content" . "Starting infinite chain.")
                            ("tool_calls" . #(
                              (("function" . (("name" . "git_status")
                                              ("arguments" . ()))))))))
                 (result (execute-tool-chain "test-model" message
                                             "Starting infinite chain." 10)))
            ;; The follow-up mock always returns tool_calls, so the loop should
            ;; hit *max-tool-iterations* (10) and terminate.
            ;; Iterations 0..9 each process tool_calls and call the mock = 10 calls.
            ;; Iteration 10 sees >= 10 and returns.
            (assert-true (<= call-count *max-tool-iterations*)
                         (format #f "Follow-up calls (~a) must not exceed max (~a)"
                                 call-count *max-tool-iterations*))
            ;; The result should still be a string (the final content)
            (assert-true (string? result)
                         "Result should be a string even when cap fires")))
        (lambda ()
          (module-set! (resolve-module '(sage ollama))
                       'ollama-chat-with-tools real-ocwt))))))

;;; ============================================================
;;; Test: multi-tool single response (all tool_calls are executed)
;;; ============================================================

(run-test "execute-tool-chain processes multiple tool_calls in one response"
  (lambda ()
    (session-create)
    (let* ((real-ocwt (module-ref (resolve-module '(sage ollama))
                                  'ollama-chat-with-tools))
           (mock-ocwt (lambda (model messages tools)
                        `(("message" . (("role" . "assistant")
                                        ("content" . "Both tools ran.")))
                          ("eval_count" . 8)
                          ("prompt_eval_count" . 4)))))
      (dynamic-wind
        (lambda ()
          (module-set! (resolve-module '(sage ollama))
                       'ollama-chat-with-tools mock-ocwt))
        (lambda ()
          (let* ((message `(("role" . "assistant")
                            ("content" . "Running two tools.")
                            ("tool_calls" . #(
                              (("function" . (("name" . "git_status")
                                              ("arguments" . ()))))
                              (("function" . (("name" . "git_log")
                                              ("arguments" . ()))))))))
                 (result (execute-tool-chain "test-model" message
                                             "Running two tools." 10)))
            (assert-equal result "Both tools ran."
                          "Multiple tool_calls should all be processed")))
        (lambda ()
          (module-set! (resolve-module '(sage ollama))
                       'ollama-chat-with-tools real-ocwt))))))

;;; ============================================================
;;; Test: two-step chain (first response has tool, follow-up has another)
;;; ============================================================

(run-test "execute-tool-chain handles two-step chain (tool -> follow-up tool -> done)"
  (lambda ()
    (session-create)
    (let* ((step 0)
           (real-ocwt (module-ref (resolve-module '(sage ollama))
                                  'ollama-chat-with-tools))
           ;; Mock: first follow-up returns a tool_call, second returns none
           (mock-ocwt (lambda (model messages tools)
                        (set! step (1+ step))
                        (if (= step 1)
                            ;; First follow-up: another tool call
                            `(("message" . (("role" . "assistant")
                                            ("content" . "Now checking logs.")
                                            ("tool_calls" . #(
                                              (("function" . (("name" . "git_log")
                                                              ("arguments" . ()))))))))
                              ("eval_count" . 5)
                              ("prompt_eval_count" . 3))
                            ;; Second follow-up: done
                            `(("message" . (("role" . "assistant")
                                            ("content" . "Chain complete: status + log.")))
                              ("eval_count" . 6)
                              ("prompt_eval_count" . 4))))))
      (dynamic-wind
        (lambda ()
          (module-set! (resolve-module '(sage ollama))
                       'ollama-chat-with-tools mock-ocwt))
        (lambda ()
          (let* ((message `(("role" . "assistant")
                            ("content" . "Let me check things.")
                            ("tool_calls" . #(
                              (("function" . (("name" . "git_status")
                                              ("arguments" . ()))))))))
                 (result (execute-tool-chain "test-model" message
                                             "Let me check things." 10)))
            (assert-equal result "Chain complete: status + log."
                          "Two-step chain should complete with final content")
            (assert-equal step 2
                          "Should have made exactly 2 follow-up calls")))
        (lambda ()
          (module-set! (resolve-module '(sage ollama))
                       'ollama-chat-with-tools real-ocwt))))))

;;; ============================================================
;;; Summary
;;; ============================================================

(test-summary)

(let ((failed *tests-failed*))
  (if (> failed 0)
      (begin
        (format #t "~%~a test(s) FAILED~%" failed)
        (exit 1))
      (begin
        (format #t "All tests passed!~%")
        (exit 0))))
