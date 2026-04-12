#!/usr/bin/env guile3
!#
;;; test-tools.scm --- Tests for tool system

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage tools)
             (sage config)
             (ice-9 format))

;;; Load shared SRFI-64 test harness (also calls init-default-tools)
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Tool System Tests ===~%")

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

(run-test "write_file requires YOLO"
  (lambda ()
    (unsetenv "SAGE_YOLO_MODE")
    (unsetenv "YOLO_MODE")
    (when (check-permission "write_file" '())
      (error "write_file should be denied without YOLO"))
    (setenv "SAGE_YOLO_MODE" "1")
    (unless (check-permission "write_file" '())
      (error "write_file should be allowed under YOLO"))
    (unsetenv "SAGE_YOLO_MODE")))

(run-test "eval_scheme is unsafe"
  (lambda ()
    (unsetenv "SAGE_YOLO_MODE")
    (unsetenv "YOLO_MODE")
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

;;; ============================================================
;;; coerce->int / read_logs int-arg robustness  (bd: guile-bcy)
;;; ============================================================
;;;
;;; Regression coverage for the read_logs crash where the model emitted
;;; "lines": "20" (string) and the underlying (min N other) blew up
;;; with wrong-type-arg. The tool wrapper now coerces every JSON int
;;; argument through coerce->int. These tests pin the boundary.

(format #t "~%--- read_logs int-arg coercion ---~%")

(run-test "read_logs accepts integer lines"
  (lambda ()
    (let ((result (execute-tool "read_logs" '(("lines" . 5)))))
      (unless (string? result)
        (error "expected string result" result))
      (when (string-contains result "wrong-type-arg")
        (error "should not crash on integer lines" result)))))

(run-test "read_logs accepts string-int lines (the original bug)"
  (lambda ()
    (let ((result (execute-tool "read_logs" '(("lines" . "5")))))
      (unless (string? result)
        (error "expected string result" result))
      (when (string-contains result "wrong-type-arg")
        (error "should not crash on string-int lines" result)))))

(run-test "read_logs accepts inexact-integer (20.0) lines"
  (lambda ()
    ;; Some models emit numbers as floats. (integer? 20.0) is #t in
    ;; Guile, so a naive coerce that fast-paths on integer? would
    ;; pass 20.0 through unchanged and downstream math would fail.
    (let ((result (execute-tool "read_logs" '(("lines" . 20.0)))))
      (when (string-contains result "wrong-type-arg")
        (error "should not crash on inexact integer lines" result)))))

(run-test "read_logs accepts unparseable string lines (falls back to default)"
  (lambda ()
    (let ((result (execute-tool "read_logs" '(("lines" . "garbage")))))
      (unless (string? result)
        (error "expected string result" result))
      (when (string-contains result "wrong-type-arg")
        (error "should not crash on garbage lines" result)))))

(run-test "read_logs accepts missing lines arg (uses default)"
  (lambda ()
    (let ((result (execute-tool "read_logs" '())))
      (unless (string? result)
        (error "expected string result" result))
      (when (string-contains result "wrong-type-arg")
        (error "should not crash without lines" result)))))

(run-test "search_logs accepts string-int limit"
  (lambda ()
    (let ((result (execute-tool "search_logs"
                                '(("pattern" . "info")
                                  ("limit" . "10")))))
      (when (string-contains result "wrong-type-arg")
        (error "search_logs should not crash on string limit" result)))))

;;; ============================================================
;;; resolve-path / write_file path honesty  (bd: guile-ecn)
;;; ============================================================
;;;
;;; Pre-fix bug: write_file with /tmp/foo wrote to <workspace>/tmp/foo
;;; (silently anchored to workspace) but reported "Wrote N bytes to
;;; /tmp/foo" — a confident lie about where the file went. Fix
;;; introduces (resolve-path path) which honours absolute prefixes
;;; and is used by every file-writing tool, plus the success messages
;;; now echo the resolved path verbatim.

(format #t "~%--- write_file path resolution ---~%")

(run-test "write_file absolute path lands at the absolute location"
  (lambda ()
    ;; write_file is YOLO-only since 5bcc284. Earlier "write_file
    ;; requires YOLO" test leaks an unset state, so we restore here.
    (setenv "SAGE_YOLO_MODE" "1")
    (let ((tmp-path "/tmp/sage-write-test-abs.txt"))
      ;; Cleanup before test
      (when (file-exists? tmp-path)
        (delete-file tmp-path))
      (let ((result (execute-tool "write_file"
                                  `(("path" . ,tmp-path)
                                    ("content" . "abs content")))))
        ;; Result should mention the resolved (absolute) path
        (unless (string-contains result tmp-path)
          (error "result must echo resolved path" result))
        ;; File must actually exist at the absolute location
        (unless (file-exists? tmp-path)
          (error "absolute path file did not land at /tmp/" result))
        ;; Cleanup
        (delete-file tmp-path)))))

(run-test "write_file relative path lands under workspace"
  (lambda ()
    (setenv "SAGE_YOLO_MODE" "1")
    (let ((rel "tmp/sage-write-test-rel.txt"))
      ;; Cleanup before test
      (let ((full (string-append (workspace) "/" rel)))
        (when (file-exists? full)
          (delete-file full)))
      (let ((result (execute-tool "write_file"
                                  `(("path" . ,rel)
                                    ("content" . "rel content")))))
        ;; Result should mention workspace-anchored path, not bare rel
        (unless (string-contains result (workspace))
          (error "result should report workspace-anchored path" result))
        ;; File must exist under workspace
        (let ((full (string-append (workspace) "/" rel)))
          (unless (file-exists? full)
            (error "relative path file did not land in workspace" full))
          (delete-file full))))))

(run-test "read_file File-not-found error reports the resolved path"
  (lambda ()
    (let ((result (execute-tool "read_file"
                                '(("path" . "/tmp/sage-does-not-exist-xyzzy")))))
      ;; Should NOT find the file but the error should NAME the
      ;; absolute path the user asked for, not silently substitute
      ;; a workspace-anchored one.
      (unless (string-contains result "/tmp/sage-does-not-exist-xyzzy")
        (error "error must echo the absolute path" result))
      (unless (string-contains result "not found")
        (error "should report not-found" result)))))

(run-test "edit_file File-not-found echoes the resolved path"
  (lambda ()
    (setenv "SAGE_YOLO_MODE" "1")
    (let ((result (execute-tool "edit_file"
                                '(("path" . "/tmp/sage-does-not-exist-xyzzy")
                                  ("search" . "x")
                                  ("replace" . "y")))))
      (unless (string-contains result "/tmp/sage-does-not-exist-xyzzy")
        (error "edit_file error must echo the absolute path" result))
      (unless (string-contains result "not found")
        (error "should report not-found" result)))))

;;; Summary

(test-summary)

(if (= *tests-passed* *tests-run*)
    (begin
      (format #t "All tests passed!~%")
      (exit 0))
    (begin
      (format #t "Some tests failed!~%")
      (exit 1)))
