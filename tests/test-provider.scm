#!/usr/bin/env guile3
!#
;;; test-provider.scm --- Tests for multi-provider dispatch

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage provider)
             (sage ollama)
             (sage openai)
             (sage gemini)
             (sage util)
             (sage config)
             (ice-9 format))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Multi-Provider Tests ===~%")

;;; ============================================================
;;; Provider Resolution Tests
;;; ============================================================

(format #t "~%--- Provider Resolution ---~%")

(run-test "default provider is ollama"
  (lambda ()
    ;; Without SAGE_PROVIDER set, should default to ollama
    (let ((prev (getenv "SAGE_PROVIDER")))
      (unsetenv "SAGE_PROVIDER")
      (let ((result (current-provider)))
        (when prev (setenv "SAGE_PROVIDER" prev))
        (assert-equal result 'ollama "default provider should be ollama")))))

(run-test "SAGE_PROVIDER=gemini resolves to gemini"
  (lambda ()
    (let ((prev (getenv "SAGE_PROVIDER")))
      (setenv "SAGE_PROVIDER" "gemini")
      (let ((result (current-provider)))
        (if prev (setenv "SAGE_PROVIDER" prev) (unsetenv "SAGE_PROVIDER"))
        (assert-equal result 'gemini "gemini provider")))))

(run-test "SAGE_PROVIDER=openai resolves to openai"
  (lambda ()
    (let ((prev (getenv "SAGE_PROVIDER")))
      (setenv "SAGE_PROVIDER" "openai")
      (let ((result (current-provider)))
        (if prev (setenv "SAGE_PROVIDER" prev) (unsetenv "SAGE_PROVIDER"))
        (assert-equal result 'openai "openai provider")))))

(run-test "SAGE_PROVIDER=litellm resolves to openai (alias)"
  (lambda ()
    (let ((prev (getenv "SAGE_PROVIDER")))
      (setenv "SAGE_PROVIDER" "litellm")
      (let ((result (current-provider)))
        (if prev (setenv "SAGE_PROVIDER" prev) (unsetenv "SAGE_PROVIDER"))
        (assert-equal result 'openai "litellm should alias to openai")))))

(run-test "unknown provider falls back to ollama"
  (lambda ()
    (let ((prev (getenv "SAGE_PROVIDER")))
      (setenv "SAGE_PROVIDER" "nonexistent")
      (let ((result (current-provider)))
        (if prev (setenv "SAGE_PROVIDER" prev) (unsetenv "SAGE_PROVIDER"))
        (assert-equal result 'ollama "unknown should fall back to ollama")))))

;;; ============================================================
;;; Provider Configuration Tests
;;; ============================================================

(format #t "~%--- Provider Configuration ---~%")

(run-test "ollama-host returns configured host"
  (lambda ()
    (let ((host (ollama-host)))
      (assert-true (string? host) "host should be a string")
      (assert-true (> (string-length host) 0) "host should be non-empty"))))

(run-test "ollama-model returns configured model"
  (lambda ()
    (let ((model (ollama-model)))
      (assert-true (string? model) "model should be a string")
      (assert-true (> (string-length model) 0) "model should be non-empty"))))

(run-test "openai-host returns configured host"
  (lambda ()
    (let ((host (openai-host)))
      (assert-true (string? host) "host should be a string")
      (assert-contains host "/" "host should be a URL"))))

(run-test "openai-model returns configured model"
  (lambda ()
    (let ((model (openai-model)))
      (assert-true (string? model) "model should be a string"))))

(run-test "gemini-host returns configured host"
  (lambda ()
    (let ((host (gemini-host)))
      (assert-true (string? host) "host should be a string")
      (assert-contains host "googleapis" "host should point to googleapis"))))

(run-test "gemini-model returns configured model"
  (lambda ()
    (let ((model (gemini-model)))
      (assert-true (string? model) "model should be a string"))))

;;; ============================================================
;;; OpenAI Response Normalisation Tests
;;; ============================================================

(format #t "~%--- OpenAI Response Normalisation ---~%")

(run-test "openai-extract-token-usage from normalised response"
  (lambda ()
    (let* ((response '(("message" . (("role" . "assistant")
                                      ("content" . "Hello")))
                       ("done" . #t)
                       ("prompt_eval_count" . 10)
                       ("eval_count" . 5)))
           (usage (openai-extract-token-usage response)))
      (assert-equal (assoc-ref usage 'prompt_tokens) 10
                    "prompt tokens")
      (assert-equal (assoc-ref usage 'completion_tokens) 5
                    "completion tokens"))))

(run-test "openai-extract-token-usage handles missing fields"
  (lambda ()
    (let ((usage (openai-extract-token-usage '())))
      (assert-equal (assoc-ref usage 'prompt_tokens) 0
                    "prompt tokens default 0")
      (assert-equal (assoc-ref usage 'completion_tokens) 0
                    "completion tokens default 0"))))

(run-test "openai-parse-tool-call extracts tool from normalised message"
  (lambda ()
    (let* ((message '(("role" . "assistant")
                      ("content" . "")
                      ("tool_calls" . ((("function" . (("name" . "read_file")
                                                        ("arguments" . (("path" . "/tmp/test"))))))))))
           (tc (openai-parse-tool-call message)))
      (assert-true tc "should extract tool call")
      (assert-equal (assoc-ref tc "name") "read_file" "tool name")
      (let ((args (assoc-ref tc "arguments")))
        (assert-equal (assoc-ref args "path") "/tmp/test" "tool arg")))))

(run-test "openai-parse-tool-call returns #f for no tool calls"
  (lambda ()
    (let* ((message '(("role" . "assistant")
                      ("content" . "Just text")))
           (tc (openai-parse-tool-call message)))
      (assert-false tc "no tool call should return #f"))))

(run-test "openai-tools-to-api-format produces correct structure"
  (lambda ()
    (let* ((tools (list '(("name" . "read_file")
                          ("description" . "Read a file")
                          ("parameters" . (("type" . "object")
                                           ("properties" . (("path" . (("type" . "string"))))))))))
           (formatted (openai-tools-to-api-format tools)))
      (assert-equal (length formatted) 1 "one tool")
      (let ((first (car formatted)))
        (assert-equal (assoc-ref first "type") "function" "type is function")
        (let ((fn (assoc-ref first "function")))
          (assert-equal (assoc-ref fn "name") "read_file" "function name"))))))

;;; ============================================================
;;; OpenAI Response-Header Extraction Tests
;;; ============================================================

(format #t "~%--- OpenAI Response-Header Extraction ---~%")

(run-test "openai-find-header finds guardrail header (exact case)"
  (lambda ()
    (let ((headers '(("content-type" . "application/json")
                     ("x-litellm-applied-guardrails" . "redact-email")
                     ("x-request-id" . "abc123"))))
      (assert-equal (openai-find-header headers "x-litellm-applied-guardrails")
                    "redact-email"
                    "should extract guardrail value"))))

(run-test "openai-find-header is case-insensitive"
  (lambda ()
    (let ((headers '(("Content-Type" . "application/json")
                     ("X-LiteLLM-Applied-Guardrails" . "redact-pii"))))
      (assert-equal (openai-find-header headers "x-litellm-applied-guardrails")
                    "redact-pii"
                    "should find header regardless of case"))))

(run-test "openai-find-header returns #f when missing"
  (lambda ()
    (let ((headers '(("content-type" . "application/json"))))
      (assert-false (openai-find-header headers "x-litellm-applied-guardrails")
                    "should return #f when header absent"))))

(run-test "openai-find-header handles empty alist"
  (lambda ()
    (assert-false (openai-find-header '() "anything")
                  "empty alist returns #f")))

(run-test "parse-curl-header-dump extracts guardrail header"
  (lambda ()
    ;; Simulate curl -D output
    (let* ((dump "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nx-litellm-applied-guardrails: redact-email\r\nx-request-id: abc\r\n\r\n")
           (headers (parse-curl-header-dump dump))
           (guardrails (openai-find-header headers
                                           "x-litellm-applied-guardrails")))
      (assert-equal guardrails "redact-email"
                    "curl-dumped header should parse into alist"))))

;;; ============================================================
;;; Gemini Message Conversion Tests
;;; ============================================================

(format #t "~%--- Gemini Message Conversion ---~%")

(run-test "gemini-tools-to-api-format produces functionDeclarations"
  (lambda ()
    (let* ((tools (list '(("name" . "list_files")
                          ("description" . "List files")
                          ("parameters" . (("type" . "object")
                                           ("properties" . ()))))))
           (formatted (gemini-tools-to-api-format tools)))
      (assert-equal (length formatted) 1 "one tool group")
      (let* ((group (car formatted))
             (decls (assoc-ref group "functionDeclarations")))
        (assert-true (vector? decls) "declarations is a vector")
        (assert-equal (vector-length decls) 1 "one declaration")
        (let ((decl (vector-ref decls 0)))
          (assert-equal (assoc-ref decl "name") "list_files" "function name"))))))

(run-test "gemini-extract-token-usage from normalised response"
  (lambda ()
    (let* ((response '(("message" . (("role" . "assistant")
                                      ("content" . "Hi")))
                       ("done" . #t)
                       ("prompt_eval_count" . 20)
                       ("eval_count" . 8)))
           (usage (gemini-extract-token-usage response)))
      (assert-equal (assoc-ref usage 'prompt_tokens) 20
                    "prompt tokens")
      (assert-equal (assoc-ref usage 'completion_tokens) 8
                    "completion tokens"))))

(run-test "gemini-parse-tool-call extracts from normalised message"
  (lambda ()
    (let* ((message '(("role" . "assistant")
                      ("content" . "")
                      ("tool_calls" . ((("function" . (("name" . "list_files")
                                                        ("arguments" . (("dir" . "/tmp"))))))))))
           (tc (gemini-parse-tool-call message)))
      (assert-true tc "should extract tool call")
      (assert-equal (assoc-ref tc "name") "list_files" "tool name"))))

(run-test "gemini-parse-tool-call returns #f for no calls"
  (lambda ()
    (let* ((message '(("role" . "assistant")
                      ("content" . "No tools")))
           (tc (gemini-parse-tool-call message)))
      (assert-false tc "no tool call"))))

;;; ============================================================
;;; Provider Dispatch Tests
;;; ============================================================

(format #t "~%--- Provider Dispatch ---~%")

(run-test "provider-model dispatches to ollama by default"
  (lambda ()
    (let ((prev (getenv "SAGE_PROVIDER")))
      (unsetenv "SAGE_PROVIDER")
      (let ((model (provider-model)))
        (when prev (setenv "SAGE_PROVIDER" prev))
        (assert-true (string? model) "model should be a string")
        ;; Should match ollama-model since default provider is ollama
        (assert-equal model (ollama-model) "should match ollama-model")))))

(run-test "provider-host dispatches to ollama by default"
  (lambda ()
    (let ((prev (getenv "SAGE_PROVIDER")))
      (unsetenv "SAGE_PROVIDER")
      (let ((host (provider-host)))
        (when prev (setenv "SAGE_PROVIDER" prev))
        (assert-equal host (ollama-host) "should match ollama-host")))))

(run-test "provider-model dispatches to gemini when configured"
  (lambda ()
    (let ((prev (getenv "SAGE_PROVIDER")))
      (setenv "SAGE_PROVIDER" "gemini")
      (let ((model (provider-model)))
        (if prev (setenv "SAGE_PROVIDER" prev) (unsetenv "SAGE_PROVIDER"))
        (assert-equal model (gemini-model) "should match gemini-model")))))

(run-test "provider-host dispatches to openai when configured"
  (lambda ()
    (let ((prev (getenv "SAGE_PROVIDER")))
      (setenv "SAGE_PROVIDER" "openai")
      (let ((host (provider-host)))
        (if prev (setenv "SAGE_PROVIDER" prev) (unsetenv "SAGE_PROVIDER"))
        (assert-equal host (openai-host) "should match openai-host")))))

;;; ============================================================
;;; Cross-Provider Token Usage Shape Tests
;;; ============================================================

(format #t "~%--- Token Usage Shape ---~%")

(run-test "all providers return same token usage shape"
  (lambda ()
    (let ((dummy-response '(("message" . (("role" . "assistant")
                                           ("content" . "test")))
                            ("done" . #t)
                            ("prompt_eval_count" . 15)
                            ("eval_count" . 7))))
      ;; All three extract functions should produce the same shape
      (let ((ollama-u (ollama-extract-token-usage dummy-response))
            (openai-u (openai-extract-token-usage dummy-response))
            (gemini-u (gemini-extract-token-usage dummy-response)))
        (assert-equal (assoc-ref ollama-u 'prompt_tokens)
                      (assoc-ref openai-u 'prompt_tokens)
                      "ollama/openai prompt_tokens match")
        (assert-equal (assoc-ref openai-u 'prompt_tokens)
                      (assoc-ref gemini-u 'prompt_tokens)
                      "openai/gemini prompt_tokens match")
        (assert-equal (assoc-ref ollama-u 'completion_tokens)
                      (assoc-ref gemini-u 'completion_tokens)
                      "ollama/gemini completion_tokens match")))))

;;; ============================================================
;;; Summary
;;; ============================================================

(test-summary)
