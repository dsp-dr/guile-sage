#!/usr/bin/env guile3
!#
;;; test-http-debug.scm --- Tests for SAGE_DEBUG_HTTP request/response logging

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage util)
             (ice-9 format)
             (ice-9 textual-ports))

(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== HTTP Debug Logging ===~%")

;;; All tests use a sandbox log dir under /tmp so we don't pollute
;;; the project's .logs/ directory or interfere with the running REPL.
(define test-dir "/tmp/sage-test-http-debug")

(define (reset-test-dir)
  (system (format #f "rm -rf '~a'" test-dir))
  (system (format #f "mkdir -p '~a'" test-dir))
  (setenv "SAGE_LOG_DIR" test-dir))

(define (read-log-lines)
  "Return list of log lines from the test http.jsonl, or '() if missing."
  (let ((path (string-append test-dir "/http.jsonl")))
    (if (file-exists? path)
        (call-with-input-file path
          (lambda (port)
            (let loop ((line (get-line port)) (acc '()))
              (if (eof-object? line)
                  (reverse acc)
                  (loop (get-line port) (cons line acc))))))
        '())))

;;; ----- Toggle behavior -----

(format #t "~%--- Toggle ---~%")

(run-test "http-debug-enabled? returns #f when env unset"
  (lambda ()
    (unsetenv "SAGE_DEBUG_HTTP")
    (when (http-debug-enabled?)
      (error "should be disabled when SAGE_DEBUG_HTTP unset"))))

(run-test "http-debug-enabled? returns #t when env set"
  (lambda ()
    (setenv "SAGE_DEBUG_HTTP" "1")
    (unless (http-debug-enabled?)
      (error "should be enabled when SAGE_DEBUG_HTTP=1"))))

;;; ----- Log file location -----

(format #t "~%--- Log file location ---~%")

(run-test "log file path uses SAGE_LOG_DIR override"
  (lambda ()
    (setenv "SAGE_LOG_DIR" "/tmp/custom-sage-logs")
    (unless (equal? (http-debug-log-file) "/tmp/custom-sage-logs/http.jsonl")
      (error "wrong path" (http-debug-log-file)))))

(run-test "log file path defaults to cwd/.logs"
  (lambda ()
    (unsetenv "SAGE_LOG_DIR")
    (unless (string-suffix? "/.logs/http.jsonl" (http-debug-log-file))
      (error "should default to cwd/.logs" (http-debug-log-file)))))

;;; ----- No-op when disabled -----

(format #t "~%--- No-op when disabled ---~%")

(run-test "http-debug-log! is a no-op when disabled"
  (lambda ()
    (reset-test-dir)
    (unsetenv "SAGE_DEBUG_HTTP")
    (http-debug-log! '(("type" . "test")))
    (let ((lines (read-log-lines)))
      (unless (null? lines)
        (error "should not write when disabled" lines)))))

(run-test "http-debug-log! writes JSONL when enabled"
  (lambda ()
    (reset-test-dir)
    (setenv "SAGE_DEBUG_HTTP" "1")
    (http-debug-log! '(("type" . "test") ("url" . "http://example.com")))
    (let ((lines (read-log-lines)))
      (unless (= (length lines) 1)
        (error "expected 1 line" (length lines)))
      ;; Each line should be valid JSON we can parse back
      (let ((parsed (json-read-string (car lines))))
        (unless (equal? (assoc-ref parsed "type") "test")
          (error "wrong type field" parsed))
        (unless (equal? (assoc-ref parsed "url") "http://example.com")
          (error "wrong url field" parsed))))))

;;; ----- Real HTTP capture against localhost -----
;;; These hit a real Ollama instance if one is running on :11434.
;;; Skip if not reachable.

(define (ollama-up?)
  (catch #t
    (lambda ()
      (let ((r (http-get "http://localhost:11434/api/version")))
        (and (pair? r) (= (car r) 200))))
    (lambda args #f)))

(format #t "~%--- Real HTTP capture ---~%")

(if (not (ollama-up?))
    (format #t "SKIP: ollama not reachable on localhost:11434~%")
    (begin
      (run-test "http-post-with-timeout logs request and response"
        (lambda ()
          (reset-test-dir)
          (setenv "SAGE_DEBUG_HTTP" "1")
          ;; Send a POST that produces a deterministic 405 (no real model load)
          (http-post-with-timeout
           "http://localhost:11434/api/version" "" 5)
          (let ((lines (read-log-lines)))
            (unless (= (length lines) 2)
              (error "expected 2 lines (req+resp)" (length lines)))
            (let ((req (json-read-string (car lines)))
                  (resp (json-read-string (cadr lines))))
              (unless (equal? (assoc-ref req "type") "request")
                (error "first line should be request"))
              (unless (equal? (assoc-ref resp "type") "response")
                (error "second line should be response"))
              (unless (equal? (assoc-ref req "method") "POST")
                (error "method should be POST"))
              (unless (number? (assoc-ref resp "code"))
                (error "response should have numeric code"))
              (unless (number? (assoc-ref resp "elapsed_ms"))
                (error "response should have elapsed_ms"))))))))

;;; ----- Authorization header redaction -----

(format #t "~%--- Authorization redaction ---~%")

(run-test "Authorization header is redacted in log"
  (lambda ()
    (reset-test-dir)
    (setenv "SAGE_DEBUG_HTTP" "1")
    (when (ollama-up?)
      (http-post-with-timeout
       "http://localhost:11434/api/version"
       ""
       5
       #:headers '(("Authorization" . "Bearer SECRET-TOKEN-XYZ")
                   ("X-Other" . "visible"))))
    (let ((lines (read-log-lines)))
      (when (and (not (null? lines))
                 (string-contains (car lines) "SECRET-TOKEN-XYZ"))
        (error "secret bearer token leaked into log"))
      (when (and (not (null? lines))
                 (not (string-contains (car lines) "<redacted>")))
        (error "Authorization header should show <redacted>")))))

;;; ----- http-post-with-headers-captured (new openai-compat path) -----

(format #t "~%--- http-post-with-headers-captured ---~%")

(run-test "http-post-with-headers-captured logs req+resp"
  (lambda ()
    (reset-test-dir)
    (setenv "SAGE_DEBUG_HTTP" "1")
    (when (ollama-up?)
      (http-post-with-headers-captured
       "http://localhost:11434/api/version"
       ""
       #:timeout 5))
    (let ((lines (read-log-lines)))
      ;; Only assert if the local ollama was reachable; skip otherwise.
      (when (>= (length lines) 2)
        (let ((req (json-read-string (car lines)))
              (resp (json-read-string (cadr lines))))
          (unless (equal? (assoc-ref req "type") "request")
            (error "first line should be request"))
          (unless (equal? (assoc-ref resp "type") "response")
            (error "second line should be response"))
          (unless (number? (assoc-ref resp "code"))
            (error "response should have numeric code")))))))

(run-test "http-post-with-headers-captured returns 3-tuple"
  (lambda ()
    (reset-test-dir)
    (setenv "SAGE_DEBUG_HTTP" "1")
    (when (ollama-up?)
      (let ((result (http-post-with-headers-captured
                     "http://localhost:11434/api/version"
                     ""
                     #:timeout 5)))
        (unless (and (list? result) (= (length result) 3))
          (error "expected (code body headers) triple" result))
        (unless (number? (car result))
          (error "first element should be numeric code"))
        (unless (string? (cadr result))
          (error "second element should be string body"))
        (unless (list? (caddr result))
          (error "third element should be header alist"))))))

;;; ----- cf-aig-authorization redaction -----

(format #t "~%--- cf-aig-authorization redaction ---~%")

(run-test "cf-aig-authorization header is redacted in log"
  (lambda ()
    (reset-test-dir)
    (setenv "SAGE_DEBUG_HTTP" "1")
    ;; Log a synthetic entry directly to avoid needing a reachable gateway.
    (http-debug-log!
     `(("type" . "request")
       ("headers"
        . ,(list->vector
            (map (lambda (h)
                   (let ((k (car h)) (v (cdr h)))
                     (if (http-debug-sensitive-header? k)
                         (format #f "~a: <redacted>" k)
                         (format #f "~a: ~a" k v))))
                 '(("cf-aig-authorization" . "Bearer cfut_SECRET_XYZ")
                   ("X-Other" . "visible")))))))
    (let ((lines (read-log-lines)))
      (when (null? lines)
        (error "log should not be empty"))
      (when (string-contains (car lines) "cfut_SECRET_XYZ")
        (error "cf-aig gateway token leaked into log"))
      (unless (string-contains (car lines) "<redacted>")
        (error "cf-aig-authorization should show <redacted>")))))

(run-test "http-debug-sensitive-header? covers Authorization, cf-aig, x-api-key"
  (lambda ()
    (unless (http-debug-sensitive-header? "Authorization")
      (error "Authorization should be sensitive"))
    (unless (http-debug-sensitive-header? "authorization")
      (error "case-insensitive check"))
    (unless (http-debug-sensitive-header? "cf-aig-authorization")
      (error "cf-aig-authorization should be sensitive"))
    (unless (http-debug-sensitive-header? "CF-AIG-AUTHORIZATION")
      (error "cf-aig case-insensitive"))
    (unless (http-debug-sensitive-header? "x-api-key")
      (error "x-api-key should be sensitive"))
    (when (http-debug-sensitive-header? "Content-Type")
      (error "Content-Type should not be sensitive"))))

;;; Cleanup
(unsetenv "SAGE_DEBUG_HTTP")
(unsetenv "SAGE_LOG_DIR")
(system (format #f "rm -rf '~a'" test-dir))

(test-summary)
