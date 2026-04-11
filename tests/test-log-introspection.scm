#!/usr/bin/env guile3
!#
;;; test-log-introspection.scm --- Tests for log introspection tools

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage tools)
             (sage config)
             (sage logging)
             (ice-9 format))

;;; Load shared SRFI-64 test harness (also calls init-default-tools)
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Log Introspection Tests ===~%")

;;; ============================================================
;;; Log Line Parsing Tests
;;; ============================================================

(format #t "~%--- Parsing Tests ---~%")

(run-test "parse-log-line parses valid line"
  (lambda ()
    (let ((entry ((@@ (sage logging) parse-log-line)
                  "[2026-01-25T17:35:01] [INFO] [tools] Tool executed: git_status tool=git_status duration_ms=683")))
      (unless entry
        (error "should parse valid log line"))
      (assert-equal (assoc-ref entry "level") "INFO" "level")
      (assert-equal (assoc-ref entry "module") "tools" "module")
      (assert-contains (assoc-ref entry "message") "Tool executed" "message"))))

(run-test "parse-log-line returns #f for invalid line"
  (lambda ()
    (let ((entry ((@@ (sage logging) parse-log-line) "not a log line")))
      (when entry
        (error "should return #f for invalid line")))))

(run-test "parse-log-line extracts context key=value pairs"
  (lambda ()
    (let ((entry ((@@ (sage logging) parse-log-line)
                  "[2026-01-25T17:35:01] [ERROR] [tools] Tool failed: foo error=something tool=bar")))
      (unless entry
        (error "should parse line"))
      (let ((ctx (assoc-ref entry "context")))
        (assert-equal (assoc-ref ctx "tool") "bar" "tool context")
        (assert-equal (assoc-ref ctx "error") "something" "error context")))))

(run-test "parse-log-line handles line with no context"
  (lambda ()
    (let ((entry ((@@ (sage logging) parse-log-line)
                  "[2026-01-25T17:35:01] [DEBUG] [session] Simple message")))
      (unless entry
        (error "should parse line"))
      (assert-equal (assoc-ref entry "message") "Simple message" "message")
      (assert-true (null? (assoc-ref entry "context")) "context should be empty"))))

;;; ============================================================
;;; Tool Registration Tests
;;; ============================================================

(format #t "~%--- Tool Registration Tests ---~%")

(run-test "log_stats tool exists"
  (lambda ()
    (unless (get-tool "log_stats")
      (error "log_stats not found"))))

(run-test "log_errors tool exists"
  (lambda ()
    (unless (get-tool "log_errors")
      (error "log_errors not found"))))

(run-test "log_timeline tool exists"
  (lambda ()
    (unless (get-tool "log_timeline")
      (error "log_timeline not found"))))

(run-test "log_search_advanced tool exists"
  (lambda ()
    (unless (get-tool "log_search_advanced")
      (error "log_search_advanced not found"))))

(run-test "log_stats is safe"
  (lambda ()
    (unless (check-permission "log_stats" '())
      (error "log_stats should be safe"))))

(run-test "log_errors is safe"
  (lambda ()
    (unless (check-permission "log_errors" '())
      (error "log_errors should be safe"))))

(run-test "log_timeline is safe"
  (lambda ()
    (unless (check-permission "log_timeline" '())
      (error "log_timeline should be safe"))))

(run-test "log_search_advanced is safe"
  (lambda ()
    (unless (check-permission "log_search_advanced" '())
      (error "log_search_advanced should be safe"))))

;;; ============================================================
;;; Tool Execution Tests (with real log data)
;;; ============================================================

(format #t "~%--- Execution Tests ---~%")

;; Initialize logging so there is a log file
(init-logging)
;; Write some test entries to have data
(log-info "test" "Test info message")
(log-warn "test" "Test warning message")
(log-error "test" "Test error message" '(("error" . "test-error")))
(log-tool-call "test_tool" '() #:result "ok" #:duration 42)

(run-test "log_stats returns statistics"
  (lambda ()
    (let ((result (execute-tool "log_stats" '())))
      (assert-contains result "Log Statistics" "should contain header")
      (assert-contains result "Total entries" "should contain total")
      (assert-contains result "Error rate" "should contain error rate")
      (assert-contains result "Top tool calls" "should contain tool section"))))

(run-test "log_errors returns error entries"
  (lambda ()
    (let ((result (execute-tool "log_errors" '(("count" . 5)))))
      (assert-contains result "Error" "should contain error info"))))

(run-test "log_timeline returns timeline"
  (lambda ()
    (let ((result (execute-tool "log_timeline" '(("count" . 10)))))
      (assert-contains result "Timeline" "should contain timeline header"))))

(run-test "log_timeline with module filter"
  (lambda ()
    (let ((result (execute-tool "log_timeline" '(("count" . 5) ("module" . "test")))))
      (assert-contains result "Timeline" "should contain timeline header"))))

(run-test "log_search_advanced by level"
  (lambda ()
    (let ((result (execute-tool "log_search_advanced" '(("level" . "error") ("limit" . 5)))))
      (unless (or (string-contains result "ERROR")
                  (string-contains result "No matching"))
        (error "should find errors or say none found")))))

(run-test "log_search_advanced by module"
  (lambda ()
    (let ((result (execute-tool "log_search_advanced" '(("module" . "test") ("limit" . 5)))))
      (unless (or (string-contains result "test")
                  (string-contains result "No matching"))
        (error "should find test module entries or say none found")))))

(run-test "log_search_advanced by message pattern"
  (lambda ()
    (let ((result (execute-tool "log_search_advanced"
                                '(("message_pattern" . "warning") ("limit" . 5)))))
      (unless (or (string-contains result "warning")
                  (string-contains result "No matching"))
        (error "should find matching entries or say none found")))))

(run-test "log_search_advanced with time range"
  (lambda ()
    (let ((result (execute-tool "log_search_advanced"
                                '(("from_time" . "2026-01-01") ("to_time" . "2099-12-31") ("limit" . 3)))))
      (unless (string? result)
        (error "should return string result")))))

;;; ============================================================
;;; Edge Cases
;;; ============================================================

(format #t "~%--- Edge Case Tests ---~%")

(run-test "log_errors with count=0"
  (lambda ()
    (let ((result (execute-tool "log_errors" '(("count" . 0)))))
      (unless (string? result)
        (error "should handle count=0 gracefully")))))

(run-test "log_timeline with count=1"
  (lambda ()
    (let ((result (execute-tool "log_timeline" '(("count" . 1)))))
      (assert-contains result "Timeline" "should work with count=1"))))

(run-test "log_search_advanced with no criteria returns entries"
  (lambda ()
    (let ((result (execute-tool "log_search_advanced" '())))
      (assert-contains result "Search Results" "should return results with no filters"))))

;;; Summary

(test-summary)

(if (= *tests-passed* *tests-run*)
    (begin
      (format #t "All tests passed!~%")
      (exit 0))
    (begin
      (format #t "Some tests failed!~%")
      (exit 1)))
