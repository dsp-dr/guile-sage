;;; problems.scm --- Competitive programming eval problems -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Defines algorithmic problems for evaluating LLM code generation.
;; Each problem has a spec, test cases, and rubric.

(define-module (eval problems)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:export (make-problem
            problem?
            problem-id
            problem-name
            problem-spec
            problem-signature
            problem-test-cases
            problem-rubric
            *problems*
            get-problem))

;;; Problem Record

(define-record-type <problem>
  (make-problem id name spec signature test-cases rubric)
  problem?
  (id problem-id)
  (name problem-name)
  (spec problem-spec)
  (signature problem-signature)
  (test-cases problem-test-cases)
  (rubric problem-rubric))

;;; ============================================================
;;; Problem A: Interval Consolidation
;;; ============================================================

(define problem-interval-consolidation
  (make-problem
   'interval-consolidation
   "Interval Consolidation"
   "Given a list of intervals (potentially overlapping), merge them into the
minimal set of non-overlapping intervals that cover the same points.

Intervals may be open or closed at either end:
  - [a, b] includes both endpoints
  - (a, b) excludes both endpoints
  - [a, b) includes a, excludes b
  - (a, b] excludes a, includes b

Adjacent intervals with matching boundary types should merge:
  - [1,2] and [2,3] -> [1,3]
  - [1,2) and [2,3] -> [1,3]
  - [1,2) and (2,3] -> remain separate (gap at 2)

Input: List of intervals as (left-type left-val right-val right-type)
       where type is 'open or 'closed
Output: Sorted list of merged intervals in same format"

   "(define (consolidate-intervals intervals) ...)"

   ;; Test cases: ((input-args...) expected-output)
   `(;; Basic overlapping
     ((((closed 1 3 closed) (closed 2 4 closed)))
      ((closed 1 4 closed)))

     ;; Adjacent closed intervals
     ((((closed 1 2 closed) (closed 2 3 closed)))
      ((closed 1 3 closed)))

     ;; Gap between intervals
     ((((closed 1 2 closed) (closed 4 5 closed)))
      ((closed 1 2 closed) (closed 4 5 closed)))

     ;; Open/closed boundary handling
     ((((closed 1 2 open) (closed 2 3 closed)))
      ((closed 1 3 closed)))

     ;; Open boundaries don't merge at same point
     ((((closed 1 2 open) (open 2 3 closed)))
      ((closed 1 2 open) (open 2 3 closed)))

     ;; Multiple overlapping
     ((((closed 1 4 closed) (closed 2 5 closed) (closed 3 6 closed)))
      ((closed 1 6 closed)))

     ;; Empty input
     ((())
      ())

     ;; Single interval
     ((((open 0 10 open)))
      ((open 0 10 open)))

     ;; Contained interval
     ((((closed 1 10 closed) (closed 3 5 closed)))
      ((closed 1 10 closed)))

     ;; Mixed boundary types in overlap
     ((((closed 1 5 open) (open 3 7 closed)))
      ((closed 1 7 closed))))

   ;; Rubric
   '((correctness . 40)
     (boundary-handling . 25)
     (efficiency . 15)
     (edge-cases . 10)
     (code-quality . 10))))

;;; ============================================================
;;; Problem B: Semantic Version Ordering
;;; ============================================================

(define problem-semver-ordering
  (make-problem
   'semver-ordering
   "Semantic Version Ordering"
   "Sort a list of semantic version strings according to SemVer 2.0.0 spec.

Version format: MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]
  - MAJOR, MINOR, PATCH are non-negative integers
  - PRERELEASE is dot-separated identifiers (alphanumeric and hyphen)
  - BUILD metadata is ignored for precedence

Precedence rules:
  1. Compare MAJOR, MINOR, PATCH numerically left to right
  2. Version with prerelease has LOWER precedence than normal version
     (1.0.0-alpha < 1.0.0)
  3. Prerelease identifiers compared left to right:
     - Numeric identifiers compared as integers
     - Alphanumeric compared lexically (ASCII sort)
     - Numeric < alphanumeric
     - Shorter prerelease < longer (if all prior equal)

Input: List of version strings
Output: Sorted list (ascending order)"

   "(define (sort-semver versions) ...)"

   ;; Test cases
   `(;; Basic numeric ordering
     ((("1.0.0" "2.0.0" "1.1.0" "1.0.1"))
      ("1.0.0" "1.0.1" "1.1.0" "2.0.0"))

     ;; Prerelease ordering
     ((("1.0.0" "1.0.0-alpha" "1.0.0-alpha.1" "1.0.0-beta"))
      ("1.0.0-alpha" "1.0.0-alpha.1" "1.0.0-beta" "1.0.0"))

     ;; Numeric vs alphanumeric in prerelease
     ((("1.0.0-1" "1.0.0-alpha" "1.0.0-2"))
      ("1.0.0-1" "1.0.0-2" "1.0.0-alpha"))

     ;; Complex prerelease comparison
     ((("1.0.0-alpha.1" "1.0.0-alpha.beta" "1.0.0-beta" "1.0.0-beta.2" "1.0.0-beta.11" "1.0.0-rc.1" "1.0.0"))
      ("1.0.0-alpha.1" "1.0.0-alpha.beta" "1.0.0-beta" "1.0.0-beta.2" "1.0.0-beta.11" "1.0.0-rc.1" "1.0.0"))

     ;; Empty list
     ((())
      ())

     ;; Single element
     ((("1.0.0"))
      ("1.0.0"))

     ;; All same version
     ((("1.0.0" "1.0.0" "1.0.0"))
      ("1.0.0" "1.0.0" "1.0.0")))

   ;; Rubric
   '((correctness . 35)
     (prerelease-logic . 25)
     (spec-compliance . 20)
     (edge-cases . 10)
     (code-quality . 10))))

;;; ============================================================
;;; Problem C: Cron Schedule Enumeration
;;; ============================================================

(define problem-cron-enumeration
  (make-problem
   'cron-enumeration
   "Cron Schedule Enumeration"
   "Given a cron expression and time range, enumerate all trigger times.

Cron format: minute hour day-of-month month day-of-week
  - minute: 0-59
  - hour: 0-23
  - day-of-month: 1-31
  - month: 1-12
  - day-of-week: 0-6 (0=Sunday)

Field syntax:
  - * : any value
  - n : specific value
  - n-m : range (inclusive)
  - */n : every n (step)
  - n,m,o : list

Day-of-month and day-of-week: trigger if EITHER matches (union semantics).

DST handling:
  - Spring forward: 2:30 AM doesn't exist, skip
  - Fall back: 1:30 AM occurs twice, trigger both

Input: (cron-expr start-time end-time timezone)
Output: List of trigger times as Unix timestamps"

   "(define (enumerate-cron expr start end tz) ...)"

   ;; Test cases (times as Unix timestamps, UTC)
   `(;; Every minute for 5 minutes
     (("* * * * *" 0 300 "UTC")
      (0 60 120 180 240 300))

     ;; Every hour on the hour
     (("0 * * * *" 0 7200 "UTC")
      (0 3600 7200))

     ;; Specific time (14:30)
     (("30 14 * * *" 0 172800 "UTC")
      (52200 138600))

     ;; Day of week filter (Monday=1, Jan 1 1970 was Thursday)
     (("0 0 * * 1" 0 604800 "UTC")
      (345600))

     ;; Range syntax (9am-5pm)
     (("0 9-17 * * *" 0 86400 "UTC")
      (32400 36000 39600 43200 46800 50400 54000 57600 61200))

     ;; Step syntax (every 15 min)
     (("*/15 * * * *" 0 3600 "UTC")
      (0 900 1800 2700 3600))

     ;; Empty range (no midnight in 100-200 seconds)
     (("0 0 * * *" 100 200 "UTC")
      ())

     ;; List syntax (1st and 15th)
     (("0 0 1,15 * *" 0 2592000 "UTC")
      (0 1209600)))

   ;; Rubric
   '((correctness . 30)
     (field-syntax . 20)
     (dow-dom-union . 15)
     (dst-handling . 15)
     (efficiency . 10)
     (code-quality . 10))))

;;; ============================================================
;;; Problem Registry
;;; ============================================================

(define *problems*
  (list problem-interval-consolidation
        problem-semver-ordering
        problem-cron-enumeration))

(define (get-problem id)
  (find (lambda (p) (eq? (problem-id p) id)) *problems*))
