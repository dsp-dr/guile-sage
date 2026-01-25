;;; runner.scm --- Eval problem runner -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Runs evaluation problems and scores solutions.
;; Usage: guile3 -L src -L tests tests/eval/runner.scm <problem-id> <solution.scm>

(add-to-load-path "src")
(add-to-load-path "tests")

(use-modules (eval problems)
             (ice-9 format)
             (ice-9 match)
             (ice-9 pretty-print)
             (srfi srfi-1))

;;; Eval Framework

(define *verbose* #f)

(define (log-verbose fmt . args)
  (when *verbose*
    (apply format #t fmt args)
    (newline)))

(define (run-test-case proc test-case)
  "Run a single test case, return (pass? actual expected)"
  (match test-case
    ((input expected)
     (catch #t
       (lambda ()
         (let ((actual (apply proc input)))
           (list (equal? actual expected) actual expected)))
       (lambda (key . args)
         (list #f `(error ,key ,@args) expected))))))

(define (score-solution problem proc)
  "Score a solution against a problem's test cases."
  (let* ((test-cases (problem-test-cases problem))
         (results (map (lambda (tc) (run-test-case proc tc)) test-cases))
         (passed (count (lambda (r) (car r)) results))
         (total (length test-cases))
         (rubric (problem-rubric problem))
         (correctness-weight (assoc-ref rubric 'correctness)))

    (format #t "~%=== ~a ===~%" (problem-name problem))
    (format #t "Test Cases: ~a/~a passed~%" passed total)

    ;; Show failed cases
    (for-each
     (lambda (tc result idx)
       (match result
         ((#f actual expected)
          (format #t "~%FAIL Case ~a:~%" idx)
          (format #t "  Input:    ~s~%" (car tc))
          (format #t "  Expected: ~s~%" expected)
          (format #t "  Actual:   ~s~%" actual))
         ((#t _ _)
          (log-verbose "PASS Case ~a" idx))))
     test-cases results (iota (length test-cases)))

    ;; Calculate score
    (let ((base-score (* 100 (/ passed total))))
      (format #t "~%Base Score: ~a% (~a points for correctness)~%"
              (inexact->exact (round base-score))
              correctness-weight)

      ;; Return results for detailed analysis
      `((passed . ,passed)
        (total . ,total)
        (score . ,base-score)
        (results . ,results)))))

(define (load-solution file)
  "Load a solution file and return the main procedure."
  (catch #t
    (lambda ()
      (load file)
      ;; Try common function names
      (or (and (defined? 'solution) solution)
          (and (defined? 'solve) solve)
          (and (defined? 'consolidate-intervals) consolidate-intervals)
          (and (defined? 'sort-semver) sort-semver)
          (and (defined? 'enumerate-cron) enumerate-cron)))
    (lambda (key . args)
      (format #t "Error loading solution: ~a ~a~%" key args)
      #f)))

(define (print-problem problem)
  "Print problem specification."
  (format #t "~%╔══════════════════════════════════════════════════════════════╗~%")
  (format #t "║ Problem: ~a~%" (problem-name problem))
  (format #t "╚══════════════════════════════════════════════════════════════╝~%")
  (format #t "~%~a~%" (problem-spec problem))
  (format #t "~%Signature: ~a~%" (problem-signature problem))
  (format #t "~%Rubric:~%")
  (for-each
   (lambda (item)
     (format #t "  ~a: ~a points~%" (car item) (cdr item)))
   (problem-rubric problem))
  (format #t "~%Test Cases: ~a~%" (length (problem-test-cases problem))))

(define (list-problems)
  "List all available problems."
  (format #t "~%Available Evaluation Problems:~%")
  (format #t "─────────────────────────────~%")
  (for-each
   (lambda (p)
     (format #t "  ~a - ~a (~a test cases)~%"
             (problem-id p)
             (problem-name p)
             (length (problem-test-cases p))))
   *problems*))

(define (main args)
  (match args
    ((_ "list")
     (list-problems))

    ((_ "show" id-str)
     (let ((problem (get-problem (string->symbol id-str))))
       (if problem
           (print-problem problem)
           (format #t "Unknown problem: ~a~%" id-str))))

    ((_ "run" id-str solution-file)
     (let ((problem (get-problem (string->symbol id-str))))
       (if problem
           (let ((proc (load-solution solution-file)))
             (if proc
                 (score-solution problem proc)
                 (format #t "Could not load solution from ~a~%" solution-file)))
           (format #t "Unknown problem: ~a~%" id-str))))

    ((_ "-v" . rest)
     (set! *verbose* #t)
     (main (cons (car args) rest)))

    (_
     (format #t "Usage:~%")
     (format #t "  runner.scm list                    - List problems~%")
     (format #t "  runner.scm show <problem-id>       - Show problem spec~%")
     (format #t "  runner.scm run <problem-id> <file> - Run solution~%")
     (format #t "  runner.scm -v ...                  - Verbose output~%"))))

(main (command-line))
