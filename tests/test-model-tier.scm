;;; test-model-tier.scm --- Tests for dynamic model tier selection -*- coding: utf-8 -*-

(add-to-load-path "src")

(use-modules (sage model-tier)
             (sage config)
             (srfi srfi-1)
             (ice-9 format))

;;; Inline test framework
(define *tests-run* 0)
(define *tests-passed* 0)
(define *tests-failed* 0)

(define (test name thunk)
  (set! *tests-run* (1+ *tests-run*))
  (catch #t
    (lambda ()
      (thunk)
      (set! *tests-passed* (1+ *tests-passed*))
      (format #t "PASS: ~a~%" name))
    (lambda (key . args)
      (set! *tests-failed* (1+ *tests-failed*))
      (format #t "FAIL: ~a (~a: ~a)~%" name key args))))

(define (assert-true val msg)
  (unless val (error msg)))

(define (assert-equal actual expected msg)
  (unless (equal? actual expected)
    (error (format #f "~a: got ~s, expected ~s" msg actual expected))))

;;; ============================================================
;;; Tests
;;; ============================================================

(format #t "~%=== Model Tier Selection ===~%")

(test "default tiers are defined"
  (lambda ()
    (assert-true (pair? *model-tiers*) "tiers should be a list")
    (assert-equal (length *model-tiers*) 2 "should have 2 default tiers")))

(test "tier accessors work"
  (lambda ()
    (let ((fast (car *model-tiers*)))
      (assert-equal (tier-name fast) "fast" "name")
      (assert-equal (tier-model fast) "llama3.2:latest" "model")
      (assert-equal (tier-ceiling fast) 4000 "ceiling")
      (assert-equal (tier-context-limit fast) 8000 "context-limit")
      ;; llama3.2 supports tool calling natively
      (assert-true (tier-supports-tools? fast) "fast supports tools"))))

(test "standard tier supports tools"
  (lambda ()
    (let ((standard (cadr *model-tiers*)))
      (assert-equal (tier-name standard) "standard" "name")
      (assert-equal (tier-model standard) "llama3.2:latest" "model")
      (assert-true (tier-supports-tools? standard) "standard has tools"))))

(test "low tokens resolve to fast tier"
  (lambda ()
    (let ((tier (resolve-model-for-tokens 500)))
      (assert-equal (tier-name tier) "fast" "500 tokens -> fast"))))

(test "medium tokens resolve to standard tier"
  (lambda ()
    ;; With fast ceiling at 4000, 5000 tokens should hit standard
    (let ((tier (resolve-model-for-tokens 5000)))
      (assert-equal (tier-name tier) "standard" "5000 tokens -> standard"))))

(test "high tokens resolve to last tier"
  (lambda ()
    (let ((tier (resolve-model-for-tokens 7000)))
      (assert-equal (tier-name tier) "standard" "7000 tokens -> standard (last)"))))

(test "zero tokens resolve to fast tier"
  (lambda ()
    (let ((tier (resolve-model-for-tokens 0)))
      (assert-equal (tier-name tier) "fast" "0 tokens -> fast"))))

(test "boundary: exactly at ceiling resolves to next tier"
  (lambda ()
    ;; Fast ceiling is now 4000; exactly 4000 should resolve to standard
    (let ((tier (resolve-model-for-tokens 4000)))
      (assert-equal (tier-name tier) "standard" "4000 tokens -> standard"))))

(test "boundary: one below ceiling stays in current tier"
  (lambda ()
    (let ((tier (resolve-model-for-tokens 3999)))
      (assert-equal (tier-name tier) "fast" "3999 tokens -> fast"))))

(test "custom tiers work"
  (lambda ()
    (let* ((custom-tiers `((("name" . "tiny")
                            ("model" . "phi:latest")
                            ("ceiling" . 500)
                            ("context-limit" . 4000)
                            ("tools?" . #f))
                           (("name" . "big")
                            ("model" . "mixtral:latest")
                            ("ceiling" . 10000)
                            ("context-limit" . 32000)
                            ("tools?" . #t))))
           (tier (resolve-model-for-tokens 200 custom-tiers)))
      (assert-equal (tier-name tier) "tiny" "200 tokens with custom -> tiny"))))

(test "tier-available? matches substring"
  (lambda ()
    (let ((tier (car *model-tiers*)))
      (assert-true (tier-available? tier '("llama3.2:latest" "qwen2.5-coder:7b"))
                   "llama3.2 should be available")
      (assert-true (not (tier-available? tier '("qwen2.5-coder:7b")))
                   "llama3.2 should not match qwen2.5-coder only"))))

(test "filter-available-tiers keeps matching tiers"
  (lambda ()
    ;; Both default tiers now use llama3.2:latest (guile-28p), so
    ;; filtering on that name keeps both.
    (let ((filtered (filter-available-tiers *model-tiers* '("llama3.2:latest"))))
      (assert-equal (length filtered) 2 "both tiers match llama3.2")
      (assert-equal (tier-name (car filtered)) "fast" "fast tier"))))

(test "filter-available-tiers returns defaults when nothing matches"
  (lambda ()
    (let ((filtered (filter-available-tiers *model-tiers* '("nonexistent:latest"))))
      (assert-equal (length filtered) 2 "falls back to all tiers"))))

;;; Summary
(format #t "~%Results: ~a/~a passed~%" *tests-passed* *tests-run*)
(when (> *tests-failed* 0)
  (format #t "FAILURES: ~a~%" *tests-failed*))
(exit (if (= *tests-failed* 0) 0 1))
