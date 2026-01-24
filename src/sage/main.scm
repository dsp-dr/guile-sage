#!/usr/bin/env guile3
!#
;;; main.scm --- Main entry point for guile-sage -*- coding: utf-8 -*-

;;; Commentary:
;;
;; CLI entry point for guile-sage.

(define-module (sage main)
  #:use-module (sage config)
  #:use-module (sage repl)
  #:use-module (ice-9 getopt-long)
  #:use-module (ice-9 format)
  #:export (main))

(define option-spec
  '((help       (single-char #\h) (value #f))
    (version    (single-char #\v) (value #f))
    (model      (single-char #\m) (value #t))
    (session    (single-char #\s) (value #t))
    (check      (single-char #\c) (value #f))))

(define (show-help)
  (display "guile-sage - AI REPL with tool calling\n\n")
  (display "Usage: sage [options]\n\n")
  (display "Options:\n")
  (display "  -h, --help       Show this help\n")
  (display "  -v, --version    Show version\n")
  (display "  -m, --model      Set model name\n")
  (display "  -s, --session    Load session by name\n")
  (display "  -c, --check      Check configuration and exit\n"))

(define (show-version)
  (display "guile-sage v0.1.0\n"))

(define (main args)
  (let* ((options (getopt-long args option-spec))
         (help? (option-ref options 'help #f))
         (version? (option-ref options 'version #f))
         (model (option-ref options 'model #f))
         (session-name (option-ref options 'session #f))
         (check? (option-ref options 'check #f)))

    (cond
     (help?
      (show-help))
     (version?
      (show-version))
     (check?
      (system "sh scripts/check-config.sh"))
     (else
      ;; Set model if provided
      (when model
        (setenv "SAGE_MODEL" model))
      ;; Start REPL
      (repl-start #:session-name session-name)))))

;; Run if executed directly
(when (equal? (current-filename) (car (command-line)))
  (main (command-line)))
