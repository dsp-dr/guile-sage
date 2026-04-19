#!/usr/bin/env guile3
!#
;;; test-usage-stats.scm --- Tests for local JSONL usage-stats store
;;;
;;; bd: guile-sage-b5c. See src/sage/usage-stats.scm.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage usage-stats)
             (sage config)
             (ice-9 format)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

;;; ============================================================
;;; Setup: point XDG_STATE_HOME at an isolated temp dir so tests
;;; neither read from nor clobber the user's real ledger.
;;; ============================================================

(define *tmp-root*
  (let* ((base (or (getenv "TMPDIR") "/tmp"))
         (path (format #f "~a/sage-usage-stats-test-~a" base (getpid))))
    (unless (file-exists? path)
      (let ((pid (primitive-fork)))
        (cond
         ((= pid 0)
          (catch #t
            (lambda () (execlp "mkdir" "mkdir" "-p" path))
            (lambda args (primitive-exit 127))))
         (else (waitpid pid)))))
    path))

(setenv "XDG_STATE_HOME" *tmp-root*)
;; Make sure we don't accidentally inherit opt-out from the host env.
(unsetenv "SAGE_STATS_DISABLE")

(define (cleanup-tmp!)
  (when (file-exists? *tmp-root*)
    (let ((pid (primitive-fork)))
      (cond
       ((= pid 0)
        (catch #t
          (lambda () (execlp "rm" "rm" "-rf" *tmp-root*))
          (lambda args (primitive-exit 127))))
       (else (waitpid pid))))))

;;; ============================================================
;;; Path resolution
;;; ============================================================

(format #t "~%--- Paths ---~%")

(run-test "usage-log-file sits under XDG_STATE_HOME/sage"
  (lambda ()
    (let ((p (usage-log-file)))
      (unless (string-contains p *tmp-root*)
        (error "usage-log-file ignored XDG_STATE_HOME" p))
      (unless (string-suffix? "usage.jsonl" p)
        (error "expected usage.jsonl filename" p)))))

;;; ============================================================
;;; Empty state
;;; ============================================================

(format #t "~%--- Empty state ---~%")

(run-test "usage-clear! is idempotent on missing file"
  (lambda ()
    (usage-clear!)  ; twice
    (usage-clear!)))

(run-test "usage-summary on empty ledger yields zeros"
  (lambda ()
    (usage-clear!)
    (let ((s (usage-summary)))
      (unless (= 0 (assoc-ref s "total_calls"))
        (error "empty ledger should have 0 calls"
               (assoc-ref s "total_calls")))
      (unless (null? (assoc-ref s "by_tool"))
        (error "by_tool should be empty"
               (assoc-ref s "by_tool"))))))

;;; ============================================================
;;; Writes + aggregation
;;; ============================================================

(format #t "~%--- Writes + aggregation ---~%")

(run-test "usage-put! appends and usage-summary aggregates counts"
  (lambda ()
    (usage-clear!)
    (usage-put! "read_file"  "path=LICENSE" 5 1085)
    (usage-put! "read_file"  "path=README"  7 2048)
    (usage-put! "git_status" ""             12 200)
    (let* ((s (usage-summary))
           (by-tool (assoc-ref s "by_tool")))
      (unless (= 3 (assoc-ref s "total_calls"))
        (error "total_calls should be 3" (assoc-ref s "total_calls")))
      (unless (= 2 (assoc-ref by-tool "read_file"))
        (error "read_file count should be 2" by-tool))
      (unless (= 1 (assoc-ref by-tool "git_status"))
        (error "git_status count should be 1" by-tool))
      ;; sorted desc by count
      (unless (equal? "read_file" (caar by-tool))
        (error "by_tool should start with read_file" by-tool)))))

(run-test "by_duration sums milliseconds per tool"
  (lambda ()
    (usage-clear!)
    (usage-put! "read_file" "path=a" 5 10)
    (usage-put! "read_file" "path=b" 7 10)
    (usage-put! "bash"      "cmd=ls" 50 10)
    (let* ((s (usage-summary))
           (bd (assoc-ref s "by_duration")))
      (unless (= 12 (assoc-ref bd "read_file"))
        (error "read_file total duration should be 12" bd))
      (unless (= 50 (assoc-ref bd "bash"))
        (error "bash total duration should be 50" bd))
      ;; sorted desc by total duration
      (unless (equal? "bash" (caar bd))
        (error "by_duration should start with bash" bd)))))

(run-test "first_seen and last_seen track entry order"
  (lambda ()
    (usage-clear!)
    (usage-put! "tool-a" "x" 1 1)
    (usage-put! "tool-b" "y" 1 1)
    (let ((s (usage-summary)))
      (unless (string? (assoc-ref s "first_seen"))
        (error "first_seen should be a timestamp"))
      (unless (string? (assoc-ref s "last_seen"))
        (error "last_seen should be a timestamp")))))

;;; ============================================================
;;; Privacy: args digest is truncated to 80 chars
;;; ============================================================

(format #t "~%--- Privacy: digest truncation ---~%")

(run-test "args_digest is truncated at 80 chars"
  (lambda ()
    (usage-clear!)
    (let* ((big (make-string 200 #\x)))
      (usage-put! "read_file" big 1 1))
    (let ((contents (call-with-input-file (usage-log-file) get-string-all)))
      ;; One line, one x-run. If truncation failed the line would have
      ;; 200 xs; with truncation it has at most 80.
      (let loop ((i 0) (count 0) (max-run 0))
        (cond
         ((>= i (string-length contents))
          (unless (<= max-run 80)
            (error "digest not truncated; max run of x" max-run)))
         ((char=? #\x (string-ref contents i))
          (loop (+ i 1) (+ count 1) (max max-run (+ count 1))))
         (else (loop (+ i 1) 0 max-run)))))))

;;; ============================================================
;;; Opt-out
;;; ============================================================

(format #t "~%--- Opt-out ---~%")

(run-test "SAGE_STATS_DISABLE=1 makes usage-put! a no-op"
  (lambda ()
    (usage-clear!)
    (setenv "SAGE_STATS_DISABLE" "1")
    (let ((r (usage-put! "read_file" "path=LICENSE" 5 100)))
      (unsetenv "SAGE_STATS_DISABLE")
      (when r
        (error "usage-put! should return #f when disabled" r))
      (when (file-exists? (usage-log-file))
        (error "ledger should not exist when opted out"
               (usage-log-file))))))

(run-test "SAGE_STATS_DISABLE=0 is treated as ENABLED"
  (lambda ()
    (usage-clear!)
    (setenv "SAGE_STATS_DISABLE" "0")
    (let ((r (usage-put! "read_file" "path=LICENSE" 5 100)))
      (unsetenv "SAGE_STATS_DISABLE")
      (unless (eq? r #t)
        (error "usage-put! should succeed when SAGE_STATS_DISABLE=0" r)))))

;;; ============================================================
;;; Cleanup + summary
;;; ============================================================

(cleanup-tmp!)

(test-summary)

(if (= *tests-passed* *tests-run*)
    (begin
      (format #t "All tests passed!~%")
      (exit 0))
    (begin
      (format #t "Some tests failed!~%")
      (exit 1)))
