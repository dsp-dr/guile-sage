;;; test-shell-injection.scm --- Shell injection regression tests -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Regression tests for bd guile-sage-9j7 / guile-sage-07f:
;;   "Shell injection via (system (format ...)) pattern in tools"
;;
;; Before the fix, tool implementations built shell commands via
;;   (system (format #f "cd ~a && git add ~a && git commit -m '~a\n...'"
;;                   workspace files msg))
;; which let any unescaped metachar in workspace paths, filenames, or
;; commit messages become arbitrary shell execution. This test pins
;; the invariant that attacker-controlled strings passed to the fixed
;; tools do NOT run as shell commands.
;;
;; Methodology: a sentinel file is written to /tmp before each hostile
;; call; if the injection worked, the sentinel would be deleted. After
;; the call we assert the sentinel still exists.

(add-to-load-path "src")

(use-modules (sage tools)
             (sage config)
             (ice-9 format)
             (ice-9 textual-ports))

;; These tools need YOLO to run at all (ADR-0003 unsafe tier).
;; We set it so we can actually reach the argv code path that is the
;; subject of this regression; the injection defence must hold
;; REGARDLESS of the permission tier.
(setenv "SAGE_YOLO_MODE" "1")

(load (string-append (dirname (current-filename)) "/test-harness.scm"))

;;; ============================================================
;;; Sentinel helpers
;;; ============================================================

(define (make-sentinel label)
  "Create a sentinel file under /tmp and return its path.
If a shell-injection succeeds the attacker payload `rm -rf` it, so
the file's continued existence after the call is proof that no
shell interpretation happened."
  (let ((path (format #f "/tmp/sage-inj-sentinel-~a-~a"
                      (getpid)
                      label)))
    (call-with-output-file path
      (lambda (p) (display "DO-NOT-DELETE" p)))
    path))

(define (sentinel-survived? path)
  "Return #t if the sentinel file still exists AND contains its
original contents."
  (and (file-exists? path)
       (string=? (call-with-input-file path
                   (lambda (p) (get-string-all p)))
                 "DO-NOT-DELETE")))

(define (cleanup-sentinel path)
  (when (file-exists? path)
    (delete-file path)))

;;; ============================================================
;;; git_commit: the canonical attack vector
;;; ============================================================
;;;
;;; Pre-fix code:
;;;   (format #f "cd ~a && git add ~a && git commit -m '~a\n\nCo-...'"
;;;           workspace file-list message coauthor)
;;; With message = "hi'; rm -rf SENTINEL; echo '", the closing '
;;; terminated the single-quoted string, ran rm, then re-opened
;;; quotes so the shell didn't complain.

(test-suite "git_commit: commit message injection"
  (lambda ()
    (test "semicolon + rm in commit message is not executed"
      (lambda ()
        (let* ((sentinel (make-sentinel "gc-semi"))
               (payload (format #f "hi'; rm -f '~a'; echo '" sentinel)))
          (execute-tool "git_commit"
                        `(("files" . ("README.md"))
                          ("message" . ,payload)))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel must still exist after commit message injection")
          (cleanup-sentinel sentinel))))

    (test "backtick in commit message is not executed"
      (lambda ()
        (let* ((sentinel (make-sentinel "gc-backtick"))
               (payload (format #f "msg `rm -f ~a`" sentinel)))
          (execute-tool "git_commit"
                        `(("files" . ("README.md"))
                          ("message" . ,payload)))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel must still exist after backtick injection")
          (cleanup-sentinel sentinel))))

    (test "$() in commit message is not executed"
      (lambda ()
        (let* ((sentinel (make-sentinel "gc-dollar"))
               (payload (format #f "msg $(rm -f ~a)" sentinel)))
          (execute-tool "git_commit"
                        `(("files" . ("README.md"))
                          ("message" . ,payload)))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel must still exist after $() injection")
          (cleanup-sentinel sentinel))))

    (test "newline + command in commit message is not executed"
      (lambda ()
        (let* ((sentinel (make-sentinel "gc-newline"))
               (payload (format #f "first line~%rm -f ~a~%third" sentinel)))
          (execute-tool "git_commit"
                        `(("files" . ("README.md"))
                          ("message" . ,payload)))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel must still exist after newline injection")
          (cleanup-sentinel sentinel))))))

(test-suite "git_commit: file-list injection"
  (lambda ()
    (test "semicolon in filename is rejected, sentinel intact"
      (lambda ()
        (let* ((sentinel (make-sentinel "gc-fl-semi"))
               (bad-file (format #f "README.md; rm -f '~a'" sentinel)))
          (let ((result (execute-tool "git_commit"
                                      `(("files" . (,bad-file))
                                        ("message" . "msg")))))
            (assert-true (sentinel-survived? sentinel)
                         "Sentinel must still exist after filename injection")
            (assert-contains result "unsafe"
                             "git_commit should reject metachar-bearing filenames"))
          (cleanup-sentinel sentinel))))

    (test "backtick in filename is rejected"
      (lambda ()
        (let* ((sentinel (make-sentinel "gc-fl-back"))
               (bad-file (format #f "`rm -f ~a`" sentinel)))
          (let ((result (execute-tool "git_commit"
                                      `(("files" . (,bad-file))
                                        ("message" . "msg")))))
            (assert-true (sentinel-survived? sentinel)
                         "Sentinel must still exist after backtick filename")
            (assert-contains result "unsafe"
                             "git_commit should reject backtick filenames"))
          (cleanup-sentinel sentinel))))))

;;; ============================================================
;;; git_add_note: message injection
;;; ============================================================

(test-suite "git_add_note: message injection"
  (lambda ()
    (test "semicolon + rm in note message is not executed"
      (lambda ()
        (let* ((sentinel (make-sentinel "gn-semi"))
               (payload (format #f "note'; rm -f '~a'; echo '" sentinel)))
          (execute-tool "git_add_note"
                        `(("message" . ,payload)))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel must still exist after note injection")
          (cleanup-sentinel sentinel))))

    (test "$() in note message is not executed"
      (lambda ()
        (let* ((sentinel (make-sentinel "gn-dollar"))
               (payload (format #f "$(rm -f ~a)" sentinel)))
          (execute-tool "git_add_note"
                        `(("message" . ,payload)))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel must still exist after $() injection")
          (cleanup-sentinel sentinel))))))

;;; ============================================================
;;; git_push: remote/branch injection
;;; ============================================================

(test-suite "git_push: remote/branch injection"
  (lambda ()
    (test "semicolon in remote name is rejected"
      (lambda ()
        (let* ((sentinel (make-sentinel "gp-remote"))
               (bad-remote (format #f "origin; rm -f '~a'" sentinel))
               (result (execute-tool "git_push"
                                     `(("remote" . ,bad-remote)))))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel must still exist after remote injection")
          (assert-contains result "unsafe"
                           "git_push should reject metachar remote names")
          (cleanup-sentinel sentinel))))

    (test "backtick in branch name is rejected"
      (lambda ()
        (let* ((sentinel (make-sentinel "gp-branch"))
               (bad-branch (format #f "main`rm -f ~a`" sentinel))
               (result (execute-tool "git_push"
                                     `(("remote" . "origin")
                                       ("branch" . ,bad-branch)))))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel must still exist after branch injection")
          (assert-contains result "unsafe"
                           "git_push should reject metachar branch names")
          (cleanup-sentinel sentinel))))))

;;; ============================================================
;;; search_files / glob_files: sentinel-based injection
;;; ============================================================

(test-suite "search_files / glob_files: sentinel-based injection"
  (lambda ()
    (test "search_files semicolon payload leaves sentinel intact"
      (lambda ()
        (let* ((sentinel (make-sentinel "sf-semi"))
               (payload (format #f "x'; rm -f '~a'; echo '" sentinel)))
          (execute-tool "search_files"
                        `(("pattern" . ,payload)))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel survives search_files injection")
          (cleanup-sentinel sentinel))))

    (test "glob_files pipe payload leaves sentinel intact"
      (lambda ()
        (let* ((sentinel (make-sentinel "gl-pipe"))
               (payload (format #f "*.scm | rm -f ~a" sentinel)))
          (execute-tool "glob_files"
                        `(("pattern" . ,payload)))
          (assert-true (sentinel-survived? sentinel)
                       "Sentinel survives glob_files pipe injection")
          (cleanup-sentinel sentinel))))))

;;; ============================================================
;;; argv-clean? / permission filter coverage (via git_commit)
;;; ============================================================

(test-suite "argv-clean?: rejects shell metacharacters"
  (lambda ()
    (test "rejects ;"
      (lambda ()
        (let ((r (execute-tool "git_commit"
                               '(("files" . ("a;b"))
                                 ("message" . "m")))))
          (assert-contains r "unsafe" "semicolon"))))

    (test "rejects |"
      (lambda ()
        (let ((r (execute-tool "git_commit"
                               '(("files" . ("a|b"))
                                 ("message" . "m")))))
          (assert-contains r "unsafe" "pipe"))))

    (test "rejects &"
      (lambda ()
        (let ((r (execute-tool "git_commit"
                               '(("files" . ("a&b"))
                                 ("message" . "m")))))
          (assert-contains r "unsafe" "ampersand"))))

    (test "rejects newline"
      (lambda ()
        (let ((r (execute-tool "git_commit"
                               `(("files" . (,(string #\a #\newline #\b)))
                                 ("message" . "m")))))
          (assert-contains r "unsafe" "newline"))))

    (test "accepts ordinary filename"
      (lambda ()
        ;; README.md should not be rejected with "unsafe"; the git
        ;; operation may fail for other reasons (clean tree / no
        ;; changes) but the argv-cleanliness check should pass.
        (let ((r (execute-tool "git_commit"
                               '(("files" . ("README.md"))
                                 ("message" . "valid message")))))
          (assert-not-contains r "unsafe path"
                               "plain filename should pass argv-clean?"))))))

(test-summary)
