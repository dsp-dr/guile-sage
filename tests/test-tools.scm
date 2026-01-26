#!/usr/bin/env guile3
!#
;;; test-tools.scm --- Tests for tool system

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage tools)
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

(format #t "~%=== Tool System Tests ===~%")

;; Initialize tools
(init-default-tools)

;;; Tool Registration Tests

(format #t "~%--- Registration Tests ---~%")

(run-test "default tools registered"
  (lambda ()
    (let ((tools (list-tools)))
      (unless (> (length tools) 0)
        (error "no tools registered")))))

(run-test "read_file tool exists"
  (lambda ()
    (let ((tool (get-tool "read_file")))
      (unless tool
        (error "read_file not found")))))

(run-test "list_files tool exists"
  (lambda ()
    (let ((tool (get-tool "list_files")))
      (unless tool
        (error "list_files not found")))))

(run-test "git_status tool exists"
  (lambda ()
    (let ((tool (get-tool "git_status")))
      (unless tool
        (error "git_status not found")))))

(run-test "unknown tool returns #f"
  (lambda ()
    (let ((tool (get-tool "nonexistent_tool")))
      (when tool
        (error "should return #f for unknown tool")))))

;;; Permission Tests

(format #t "~%--- Permission Tests ---~%")

(run-test "read_file is safe"
  (lambda ()
    (unless (check-permission "read_file" '())
      (error "read_file should be safe"))))

(run-test "list_files is safe"
  (lambda ()
    (unless (check-permission "list_files" '())
      (error "list_files should be safe"))))

(run-test "git_status is safe"
  (lambda ()
    (unless (check-permission "git_status" '())
      (error "git_status should be safe"))))

(run-test "write_file is safe (dev mode)"
  (lambda ()
    (unless (check-permission "write_file" '())
      (error "write_file should be safe in dev mode"))))

(run-test "eval_scheme is unsafe"
  (lambda ()
    (when (check-permission "eval_scheme" '())
      (error "eval_scheme should be unsafe"))))

;;; Path Safety Tests

(format #t "~%--- Path Safety Tests ---~%")

(run-test "simple path is safe"
  (lambda ()
    (unless (safe-path? "test.txt")
      (error "test.txt should be safe"))))

(run-test "subdirectory path is safe"
  (lambda ()
    (unless (safe-path? "src/test.scm")
      (error "src/test.scm should be safe"))))

(run-test "parent traversal is unsafe"
  (lambda ()
    (when (safe-path? "../etc/passwd")
      (error "../etc/passwd should be unsafe"))))

(run-test ".env is unsafe"
  (lambda ()
    (when (safe-path? ".env")
      (error ".env should be unsafe"))))

(run-test ".git directory is unsafe"
  (lambda ()
    (when (safe-path? ".git/config")
      (error ".git/config should be unsafe"))))

;;; Tool Execution Tests

(format #t "~%--- Execution Tests ---~%")

(run-test "execute unknown tool returns error"
  (lambda ()
    (let ((result (execute-tool "nonexistent" '())))
      (unless (string-contains result "Unknown tool")
        (error "should return unknown tool error" result)))))

(run-test "execute git_status works"
  (lambda ()
    (let ((result (execute-tool "git_status" '())))
      (unless (string? result)
        (error "git_status should return string" result)))))

(run-test "execute list_files works"
  (lambda ()
    (let ((result (execute-tool "list_files" '(("path" . ".")))))
      (unless (string? result)
        (error "list_files should return string" result)))))

(run-test "read_file on missing file returns error"
  (lambda ()
    (let ((result (execute-tool "read_file" '(("path" . "nonexistent.txt")))))
      (unless (string-contains result "not found")
        (error "should report file not found" result)))))

(run-test "read_file with unsafe path returns error"
  (lambda ()
    (let ((result (execute-tool "read_file" '(("path" . "../../../etc/passwd")))))
      (unless (string-contains result "Unsafe")
        (error "should report unsafe path" result)))))

;;; Schema Generation Tests

(format #t "~%--- Schema Tests ---~%")

(run-test "tools-to-schema returns list"
  (lambda ()
    (let ((schema (tools-to-schema)))
      (unless (list? schema)
        (error "should return list" schema)))))

(run-test "schema has required fields"
  (lambda ()
    (let ((schema (tools-to-schema)))
      (for-each
       (lambda (tool)
         (unless (and (assoc-ref tool "name")
                      (assoc-ref tool "description")
                      (assoc-ref tool "parameters"))
           (error "missing required field" tool)))
       schema))))

;;; Custom Tool Registration

(format #t "~%--- Custom Tool Tests ---~%")

(run-test "register unsafe custom tool"
  (lambda ()
    (register-tool
     "test_unsafe"
     "An unsafe test tool"
     '(("type" . "object") ("properties" . ()) ("required" . #()))
     (lambda (args) "unsafe result"))
    (let ((tool (get-tool "test_unsafe")))
      (unless tool
        (error "custom tool not registered")))))

(run-test "execute unsafe custom tool denied"
  (lambda ()
    (let ((result (execute-tool "test_unsafe" '())))
      (unless (string-contains result "Permission denied")
        (error "should deny unsafe tool" result)))))

(run-test "register safe custom tool"
  (lambda ()
    (register-safe-tool
     "test_safe"
     "A safe test tool"
     '(("type" . "object") ("properties" . ()) ("required" . #()))
     (lambda (args) "safe result"))
    (let ((tool (get-tool "test_safe")))
      (unless tool
        (error "safe tool not registered")))))

(run-test "execute safe custom tool"
  (lambda ()
    (let ((result (execute-tool "test_safe" '())))
      (unless (equal? result "safe result")
        (error "unexpected result" result)))))

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
