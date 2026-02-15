#!/usr/bin/env guile3
!#
;;; test-ollama.scm --- Tests for Ollama client

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage config)
             (sage util)
             (sage ollama)
             (ice-9 format))

;;; Test helpers

(define (test-assert name condition)
  (if condition
      (format #t "PASS: ~a~%" name)
      (begin
        (format #t "FAIL: ~a~%" name)
        (exit 1))))

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

;;; JSON Tests

(format #t "~%=== JSON Parser Tests ===~%")

(run-test "parse simple string"
  (lambda ()
    (let ((result (json-read-string "\"hello\"")))
      (unless (equal? result "hello")
        (error "expected hello" result)))))

(run-test "parse number"
  (lambda ()
    (let ((result (json-read-string "42")))
      (unless (= result 42)
        (error "expected 42" result)))))

(run-test "parse boolean true"
  (lambda ()
    (let ((result (json-read-string "true")))
      (unless (eq? result #t)
        (error "expected #t" result)))))

(run-test "parse boolean false"
  (lambda ()
    (let ((result (json-read-string "false")))
      (unless (eq? result #f)
        (error "expected #f" result)))))

(run-test "parse null"
  (lambda ()
    (let ((result (json-read-string "null")))
      (unless (eq? result 'null)
        (error "expected null symbol" result)))))

(run-test "parse array"
  (lambda ()
    (let ((result (json-read-string "[1, 2, 3]")))
      (unless (equal? result '(1 2 3))
        (error "expected (1 2 3)" result)))))

(run-test "parse object"
  (lambda ()
    (let ((result (json-read-string "{\"key\": \"value\"}")))
      (unless (equal? (assoc-ref result "key") "value")
        (error "expected key=value" result)))))

(run-test "parse nested object"
  (lambda ()
    (let ((result (json-read-string "{\"outer\": {\"inner\": 42}}")))
      (let ((inner (assoc-ref (assoc-ref result "outer") "inner")))
        (unless (= inner 42)
          (error "expected inner=42" inner))))))

;;; JSON Writer Tests

(format #t "~%=== JSON Writer Tests ===~%")

(run-test "write string"
  (lambda ()
    (let ((result (json-write-string "hello")))
      (unless (equal? result "\"hello\"")
        (error "expected \"hello\"" result)))))

(run-test "write number"
  (lambda ()
    (let ((result (json-write-string 42)))
      (unless (equal? result "42")
        (error "expected 42" result)))))

(run-test "write object"
  (lambda ()
    (let ((result (json-write-string '(("key" . "value")))))
      (unless (equal? result "{\"key\":\"value\"}")
        (error "expected object JSON" result)))))

(run-test "write array"
  (lambda ()
    (let ((result (json-write-string '#(1 2 3))))
      (unless (equal? result "[1,2,3]")
        (error "expected array JSON" result)))))

;;; Configuration Tests

(format #t "~%=== Configuration Tests ===~%")

;; Load .env file
(let ((loaded (config-load-dotenv)))
  (format #t "Loaded ~a variables from .env~%" loaded))

(run-test "ollama-host returns configured value"
  (lambda ()
    (let ((host (ollama-host)))
      (unless (string? host)
        (error "expected string" host))
      (format #t "  Host: ~a~%" host))))

;;; Ollama API Tests (requires running ollama server)

(format #t "~%=== Ollama API Tests ===~%")

(run-test "ollama-list-models returns list"
  (lambda ()
    (let ((models (ollama-list-models)))
      (unless (list? models)
        (error "expected list" models))
      (format #t "  Found ~a models~%" (length models))
      (for-each (lambda (m)
                  (format #t "    - ~a~%" (assoc-ref m "name")))
                models))))

;;; Tool API Format Tests

(format #t "~%=== Tool API Tests ===~%")

(run-test "tools-to-api-format wraps correctly"
  (lambda ()
    (let* ((tools `((("name" . "read_file")
                     ("description" . "Read contents of a file")
                     ("parameters" . (("type" . "object")
                                      ("properties" . (("path" . (("type" . "string")))))
                                      ("required" . #("path")))))))
           (api-tools (ollama-tools-to-api-format tools))
           (first-tool (car api-tools))
           (fn (assoc-ref first-tool "function")))
      (unless (equal? (assoc-ref first-tool "type") "function")
        (error "expected type=function"))
      (unless (equal? (assoc-ref fn "name") "read_file")
        (error "expected name=read_file")))))

(run-test "parse native tool call"
  (lambda ()
    (let* ((message `(("role" . "assistant")
                      ("content" . "")
                      ("tool_calls" . #((("function" .
                                          (("name" . "write_file")
                                           ("arguments" . (("path" . "test.txt")
                                                           ("content" . "hello"))))))))))
           (parsed (ollama-parse-tool-call message)))
      (unless parsed
        (error "expected parsed tool call"))
      (unless (equal? (assoc-ref parsed "name") "write_file")
        (error "expected write_file" (assoc-ref parsed "name")))
      (unless (equal? (assoc-ref (assoc-ref parsed "arguments") "path") "test.txt")
        (error "expected test.txt path")))))

(run-test "parse content fallback tool call"
  (lambda ()
    (let* ((message `(("role" . "assistant")
                      ("content" . "Let me read that.\n\n```tool\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"test.txt\"}}\n```")))
           (parsed (ollama-parse-tool-call message)))
      (unless parsed
        (error "expected parsed tool call from content"))
      (unless (equal? (assoc-ref parsed "name") "read_file")
        (error "expected read_file")))))

(run-test "parse no tool call"
  (lambda ()
    (let* ((message `(("role" . "assistant")
                      ("content" . "Just a regular response.")))
           (parsed (ollama-parse-tool-call message)))
      (when parsed
        (error "expected #f for no tool call" parsed)))))

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
