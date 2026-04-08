;;; test-security.scm --- Red Team Security Tests -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Adversarial security tests for guile-sage.
;; Tests for sandbox escapes, injection attacks, and permission bypasses.

(add-to-load-path "src")

(use-modules (sage tools)
             (sage config)
             (ice-9 format)
             (ice-9 regex))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

;;; ============================================================
;;; PATH TRAVERSAL ATTACKS
;;; ============================================================

(test-suite "Path Traversal Attacks"
  (lambda ()
    (test "reject ../ traversal"
      (lambda ()
        (assert-false (safe-path? "../etc/passwd")
                      "Should reject ../ traversal")))

    (test "reject ../../ traversal"
      (lambda ()
        (assert-false (safe-path? "../../etc/passwd")
                      "Should reject deep traversal")))

    (test "reject hidden ../ in path"
      (lambda ()
        (assert-false (safe-path? "foo/../../../etc/passwd")
                      "Should reject hidden traversal")))

    (test "reject ../ at end"
      (lambda ()
        (assert-false (safe-path? "subdir/..")
                      "Should reject trailing ..")))

    (test "handle null byte in path"
      (lambda ()
        (let ((result (execute-tool "read_file"
                        `(("path" . ,(string-append "test.txt" (string #\nul) "../../etc/passwd"))))))
          (assert-not-contains result "root:"
                               "Should not leak /etc/passwd via null byte"))))

    (test "reject absolute path escape"
      (lambda ()
        (assert-false (safe-path? "/etc/passwd")
                      "Should reject absolute paths outside workspace")))))

;;; ============================================================
;;; SENSITIVE FILE PROTECTION
;;; ============================================================

(test-suite "Sensitive File Protection"
  (lambda ()
    (test "block .env access"
      (lambda ()
        (assert-false (safe-path? ".env")
                      "Should block .env")))

    (test "block nested .env access"
      (lambda ()
        (assert-false (safe-path? "config/.env")
                      "Should block nested .env")))

    (test "block .env.local"
      (lambda ()
        (assert-false (safe-path? ".env.local")
                      "Should block .env.local")))

    (test "block .git directory"
      (lambda ()
        (assert-false (safe-path? ".git/config")
                      "Should block .git/")))

    (test "block .git/hooks"
      (lambda ()
        (assert-false (safe-path? ".git/hooks/pre-commit")
                      "Should block .git/hooks")))

    (test "block .ssh directory"
      (lambda ()
        (assert-false (safe-path? ".ssh/id_rsa")
                      "Should block .ssh")))

    (test "block .gnupg directory"
      (lambda ()
        (assert-false (safe-path? ".gnupg/private-keys-v1.d")
                      "Should block .gnupg")))))

;;; ============================================================
;;; COMMAND INJECTION
;;; ============================================================

(test-suite "Command Injection Attacks"
  (lambda ()
    (test "search_files: semicolon injection"
      (lambda ()
        (let ((result (execute-tool "search_files"
                        '(("pattern" . "'; cat /etc/passwd #")))))
          (assert-not-contains result "root:"
                               "Should not execute injected command"))))

    (test "search_files: backtick injection"
      (lambda ()
        (let ((result (execute-tool "search_files"
                        '(("pattern" . "`cat /etc/passwd`")))))
          (assert-not-contains result "root:"
                               "Should not execute backtick command"))))

    (test "search_files: $() injection"
      (lambda ()
        (let ((result (execute-tool "search_files"
                        '(("pattern" . "$(cat /etc/passwd)")))))
          (assert-not-contains result "root:"
                               "Should not execute $() command"))))

    (test "glob_files: command injection"
      (lambda ()
        (let ((result (execute-tool "glob_files"
                        '(("pattern" . "*.scm; cat /etc/passwd")))))
          (assert-not-contains result "root:"
                               "Should not execute via glob"))))

    (test "search_files: pipe injection"
      (lambda ()
        (let ((result (execute-tool "search_files"
                        '(("pattern" . "test | cat /etc/passwd")))))
          (assert-not-contains result "root:"
                               "Should not execute pipe command"))))

    (test "search_files: && injection"
      (lambda ()
        (let ((result (execute-tool "search_files"
                        '(("pattern" . "test && cat /etc/passwd")))))
          (assert-not-contains result "root:"
                               "Should not execute && command"))))))

;;; ============================================================
;;; PERMISSION BYPASS
;;; ============================================================

(test-suite "Permission Bypass Attempts"
  (lambda ()
    (test "write_file denied without YOLO"
      (lambda ()
        (let ((result (execute-tool "write_file"
                        '(("path" . "pwned.txt")
                          ("content" . "pwned")))))
          (assert-contains result "Permission denied"
                           "write_file should be denied"))))

    (test "edit_file denied without YOLO"
      (lambda ()
        (let ((result (execute-tool "edit_file"
                        '(("path" . "test.txt")
                          ("search" . "foo")
                          ("replace" . "bar")))))
          (assert-contains result "Permission denied"
                           "edit_file should be denied"))))

    (test "eval_scheme denied without YOLO"
      (lambda ()
        (let ((result (execute-tool "eval_scheme"
                        '(("code" . "(system \"id\")")))))
          (assert-contains result "Permission denied"
                           "eval_scheme should be denied"))))

    (test "create_tool denied without YOLO"
      (lambda ()
        (let ((result (execute-tool "create_tool"
                        '(("name" . "backdoor")
                          ("description" . "evil")
                          ("code" . "(lambda (args) (system \"id\"))")))))
          (assert-contains result "Permission denied"
                           "create_tool should be denied"))))

    (test "git_commit denied without YOLO"
      (lambda ()
        (let ((result (execute-tool "git_commit"
                        '(("files" . ("README.md"))
                          ("message" . "malicious commit")))))
          (assert-contains result "Permission denied"
                           "git_commit should be denied"))))

    (test "reload_module denied without YOLO"
      (lambda ()
        (let ((result (execute-tool "reload_module"
                        '(("module" . "sage tools")))))
          (assert-contains result "Permission denied"
                           "reload_module should be denied"))))))

;;; ============================================================
;;; TEMP FILE SECURITY
;;; ============================================================

(test-suite "Temp File Security"
  (lambda ()
    (test "git_status cleans temp file"
      (lambda ()
        (let* ((result (execute-tool "git_status" '()))
               (tmp-file (format #f "/tmp/sage-git-~a" (getpid))))
          (assert-false (file-exists? tmp-file)
                        "Temp file should be cleaned up"))))

    (test "search_files cleans temp file"
      (lambda ()
        (let* ((result (execute-tool "search_files" '(("pattern" . "test"))))
               (tmp-file (format #f "/tmp/sage-grep-~a" (getpid))))
          (assert-false (file-exists? tmp-file)
                        "Temp file should be cleaned up"))))))

;;; ============================================================
;;; RESOURCE LIMITS
;;; ============================================================

(test-suite "Resource Exhaustion Protection"
  (lambda ()
    (test "handle very long path"
      (lambda ()
        (let ((long-path (make-string 10000 #\a)))
          (assert-true (boolean? (safe-path? long-path))
                       "Should handle long paths without crash"))))

    (test "handle deeply nested path"
      (lambda ()
        (let ((deep-path (string-join (make-list 100 "dir") "/")))
          (assert-true (boolean? (safe-path? deep-path))
                       "Should handle deep paths without crash"))))

    (test "glob_files limits output"
      (lambda ()
        ;; The tool uses head -100 to limit results
        (let ((result (execute-tool "glob_files" '(("pattern" . "*")))))
          (assert-true (string? result)
                       "Should return without hanging"))))

    (test "search_files limits output"
      (lambda ()
        ;; The tool uses head -50 to limit results
        (let ((result (execute-tool "search_files" '(("pattern" . ".")))))
          (assert-true (string? result)
                       "Should return without hanging"))))))

;;; ============================================================
;;; SPECIAL CHARACTER HANDLING
;;; ============================================================

(test-suite "Special Character Handling"
  (lambda ()
    (test "handle newline in search pattern"
      (lambda ()
        (let ((result (execute-tool "search_files"
                        `(("pattern" . ,(string-append "test" (string #\newline) "cat /etc/passwd"))))))
          (assert-not-contains result "root:"
                               "Should not execute via newline"))))

    (test "handle quotes in pattern"
      (lambda ()
        (let ((result (execute-tool "search_files"
                        '(("pattern" . "test\"'; cat /etc/passwd")))))
          (assert-not-contains result "root:"
                               "Should not execute via quote escape"))))

    (test "handle backslash in pattern"
      (lambda ()
        (let ((result (execute-tool "search_files"
                        '(("pattern" . "test\\'; cat /etc/passwd")))))
          (assert-not-contains result "root:"
                               "Should not execute via backslash escape"))))))

;;; ============================================================
;;; SESSION NESTING GUARD
;;; ============================================================

(test-suite "Session Nesting Guard"
  (lambda ()
    (test "SAGE_SESSION_ACTIVE not set in test env"
      (lambda ()
        ;; Tests run outside the REPL, so this should be unset
        (assert-false (getenv "SAGE_SESSION_ACTIVE")
                      "SAGE_SESSION_ACTIVE should not leak into tests")))

    (test "nested sage would be detected"
      (lambda ()
        ;; Simulate what main.scm checks
        (setenv "SAGE_SESSION_ACTIVE" "12345")
        (assert-true (string? (getenv "SAGE_SESSION_ACTIVE"))
                     "Guard should detect active session")
        ;; Clean up
        (setenv "SAGE_SESSION_ACTIVE" "")))

    (test "guard stores PID for debugging"
      (lambda ()
        (let ((pid-str (number->string (getpid))))
          (setenv "SAGE_SESSION_ACTIVE" pid-str)
          (assert-true (equal? (getenv "SAGE_SESSION_ACTIVE") pid-str)
                       "Should store parent PID as string")
          ;; Clean up
          (setenv "SAGE_SESSION_ACTIVE" ""))))))

;;; ============================================================
;;; RUN TESTS
;;; ============================================================

(test-summary)

;; Exit with failure if any tests failed
(exit (if (> *tests-failed* 0) 1 0))
