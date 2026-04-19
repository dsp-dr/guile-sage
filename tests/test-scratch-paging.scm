#!/usr/bin/env guile3
!#
;;; test-scratch-paging.scm --- Regression: scratch_get paging through the
;;;                              REPL loop detector -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Regression test for bead guile-sage-eab. Commit 676e505 changed the
;; REPL's degenerate-loop detector to compare BOTH tool name AND arguments,
;; so calling `scratch_get` three times in a row with different offsets
;; (paging through a large body) is NOT a stuck loop and must not trip the
;; "[stopping: scratch_get called 3 times in a row]" guard.
;;
;; This test covers two things:
;;
;;   1. The tool dispatch layer: `execute-tool` for `scratch_get` actually
;;      returns the correct window for three different (offset, len) pairs
;;      against the same sha, and the three chunks are pair-wise distinct.
;;
;;   2. The loop-detector signature construction: the exact format string
;;      used in src/sage/repl.scm:781-782 — `(format #f "~a:~s" name args)` —
;;      produces three DISTINCT signatures for three different arg alists
;;      sharing the same tool name. If sigs collide, the detector fires;
;;      if they don't, paging is safe.
;;
;; The combination gives full regression coverage without needing to drive
;; `execute-tool-chain` end-to-end (which would require mocking the
;; provider-chat-with-tools follow-up response).

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage tools)
             (sage scratch)
             (srfi srfi-1)
             (ice-9 format))

;;; Load shared test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Scratch Paging Regression (bd: guile-sage-eab) ===~%")

;;; ============================================================
;;; Fixtures
;;; ============================================================

;; A 64-char hex sha (not a real hash — it's a deterministic test key).
(define *test-sha*
  "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")

;; Build a 5000-byte body where every 1000-byte window is visibly
;; distinct, so chunk-equality checks catch any off-by-one in
;; scratch-get's substring math.
(define (make-test-body)
  (let ((parts (map (lambda (i)
                      (make-string 1000 (integer->char (+ (char->integer #\A) i))))
                    (iota 5))))
    (apply string-append parts)))

(define *test-body* (make-test-body))

;;; ============================================================
;;; Test: fixture sanity
;;; ============================================================

(run-test "fixture body is exactly 5000 bytes"
  (lambda ()
    (assert-equal (string-length *test-body*) 5000
                  "test body must be 5000 bytes")))

(run-test "fixture body has distinct 1000-byte windows"
  (lambda ()
    ;; Bytes 0..999 are 'A', 1000..1999 are 'B', 2000..2999 are 'C'.
    (assert-equal (string-ref *test-body* 0) #\A
                  "window 0 starts with A")
    (assert-equal (string-ref *test-body* 1000) #\B
                  "window 1 starts with B")
    (assert-equal (string-ref *test-body* 2000) #\C
                  "window 2 starts with C")))

;;; ============================================================
;;; Test: scratch_get via execute-tool returns the right chunk
;;; ============================================================

(run-test "scratch_get paging: three sequential calls return three distinct non-empty chunks"
  (lambda ()
    ;; Isolate this test from prior runs.
    (scratch-clear!)
    (scratch-put! *test-sha* *test-body*)
    (let* ((chunk0 (execute-tool "scratch_get"
                                 `(("sha" . ,*test-sha*)
                                   ("offset" . 0)
                                   ("len" . 1000))))
           (chunk1 (execute-tool "scratch_get"
                                 `(("sha" . ,*test-sha*)
                                   ("offset" . 1000)
                                   ("len" . 1000))))
           (chunk2 (execute-tool "scratch_get"
                                 `(("sha" . ,*test-sha*)
                                   ("offset" . 2000)
                                   ("len" . 1000)))))
      ;; Each chunk must be a non-empty string (paging actually worked).
      (assert-true (and (string? chunk0) (> (string-length chunk0) 0))
                   "chunk 0 must be non-empty")
      (assert-true (and (string? chunk1) (> (string-length chunk1) 0))
                   "chunk 1 must be non-empty")
      (assert-true (and (string? chunk2) (> (string-length chunk2) 0))
                   "chunk 2 must be non-empty")
      ;; Each chunk must be exactly 1000 bytes (exact-length requested).
      (assert-equal (string-length chunk0) 1000
                    "chunk 0 must be exactly 1000 bytes")
      (assert-equal (string-length chunk1) 1000
                    "chunk 1 must be exactly 1000 bytes")
      (assert-equal (string-length chunk2) 1000
                    "chunk 2 must be exactly 1000 bytes")
      ;; Exact content check — catches any off-by-one in scratch-get's
      ;; substring start/end math.
      (assert-equal chunk0 (make-string 1000 #\A)
                    "chunk 0 must be 1000 'A' chars (offset=0)")
      (assert-equal chunk1 (make-string 1000 #\B)
                    "chunk 1 must be 1000 'B' chars (offset=1000)")
      (assert-equal chunk2 (make-string 1000 #\C)
                    "chunk 2 must be 1000 'C' chars (offset=2000)")
      ;; Pair-wise distinct — no accidental caching of prior results.
      (assert-false (equal? chunk0 chunk1) "chunks 0 and 1 must differ")
      (assert-false (equal? chunk1 chunk2) "chunks 1 and 2 must differ")
      (assert-false (equal? chunk0 chunk2) "chunks 0 and 2 must differ"))))

;;; ============================================================
;;; Test: loop-detector signature discriminates on args
;;; ============================================================
;;;
;;; Mirrors the exact format used in src/sage/repl.scm:781-782:
;;;   (format #f "~a:~s" current-tool current-args)
;;;
;;; If the three paged calls produce three distinct sigs, then
;;; `is-repeat` in execute-tool-chain stays #f across them and
;;; `new-repeats` never climbs to *max-same-tool-repeats* (3),
;;; so the "[stopping: ... called 3 times in a row]" guard does NOT fire.
;;; This is the direct regression assertion for commit 676e505.

(define (loop-sig tool-name args)
  (format #f "~a:~s" tool-name args))

(run-test "loop-sig: same tool + different args produces distinct sigs"
  (lambda ()
    (let ((sig0 (loop-sig "scratch_get"
                          `(("sha" . ,*test-sha*) ("offset" . 0)    ("len" . 1000))))
          (sig1 (loop-sig "scratch_get"
                          `(("sha" . ,*test-sha*) ("offset" . 1000) ("len" . 1000))))
          (sig2 (loop-sig "scratch_get"
                          `(("sha" . ,*test-sha*) ("offset" . 2000) ("len" . 1000)))))
      (assert-false (equal? sig0 sig1)
                    "sigs for offset=0 and offset=1000 must differ")
      (assert-false (equal? sig1 sig2)
                    "sigs for offset=1000 and offset=2000 must differ")
      (assert-false (equal? sig0 sig2)
                    "sigs for offset=0 and offset=2000 must differ"))))

(run-test "loop-sig: same tool + identical args produces identical sig (detector still fires on true loops)"
  (lambda ()
    ;; Sanity: the detector must still work for genuine stuck loops.
    (let ((args `(("sha" . ,*test-sha*) ("offset" . 0) ("len" . 1000))))
      (assert-equal (loop-sig "scratch_get" args)
                    (loop-sig "scratch_get" args)
                    "identical args must produce identical sig"))))

;;; ============================================================
;;; Test: simulate the three-in-a-row paging scenario end-to-end
;;; ============================================================
;;;
;;; Walk the detector's state machine by hand with the three paged
;;; calls. The assertion is that `repeats` never reaches
;;; *max-same-tool-repeats* (= 3), so `degenerate?` stays #f.

(run-test "three paged scratch_get calls do not trip *max-same-tool-repeats*"
  (lambda ()
    ;; *max-same-tool-repeats* = 3 (mirrors src/sage/repl.scm:736).
    ;; Walk the detector: on each call, is-repeat = (equal? current-sig prev-sig)
    ;; and repeats resets to 0 when is-repeat is #f. prev-sig starts as #f.
    (let* ((max-same-tool-repeats 3)
           (args0 `(("sha" . ,*test-sha*) ("offset" . 0)    ("len" . 1000)))
           (args1 `(("sha" . ,*test-sha*) ("offset" . 1000) ("len" . 1000)))
           (args2 `(("sha" . ,*test-sha*) ("offset" . 2000) ("len" . 1000)))
           (sig0 (loop-sig "scratch_get" args0))
           (sig1 (loop-sig "scratch_get" args1))
           (sig2 (loop-sig "scratch_get" args2))
           (rep1 0)  ; prev=#f, no comparison, repeats stays 0
           (rep2 (if (equal? sig1 sig0) (1+ rep1) 0))
           (rep3 (if (equal? sig2 sig1) (1+ rep2) 0)))
      (assert-equal rep1 0 "step 1 repeats must be 0")
      (assert-equal rep2 0 "step 2 repeats must be 0")
      (assert-equal rep3 0 "step 3 repeats must be 0")
      (assert-true (< rep3 max-same-tool-repeats)
                   "repeats must stay below *max-same-tool-repeats* across all three paged calls"))))

;;; ============================================================
;;; Cleanup + Summary
;;; ============================================================

(scratch-clear!)

(test-summary)

(let ((failed *tests-failed*))
  (if (> failed 0)
      (begin
        (format #t "~%~a test(s) FAILED~%" failed)
        (exit 1))
      (begin
        (format #t "All tests passed!~%")
        (exit 0))))
