#!/usr/bin/env guile3
!#
;;; main.scm --- Main entry point for guile-sage -*- coding: utf-8 -*-

;;; Commentary:
;;
;; CLI entry point for guile-sage.

(define-module (sage main)
  #:use-module (sage config)
  #:use-module (sage repl)
  #:use-module (sage version)
  #:use-module (ice-9 getopt-long)
  #:use-module (ice-9 format)
  #:export (main))

(define option-spec
  '((help       (single-char #\h) (value #f))
    (version    (single-char #\v) (value #f))
    (model      (single-char #\m) (value #t))
    (session    (single-char #\s) (value #t))
    (continue   (single-char #\c) (value #f))    ; Continue last session
    (check      (value #f))                       ; Check config (no short flag)
    (yolo       (single-char #\y) (value #f))
    (workspace  (single-char #\w) (value #t))
    (prompt     (single-char #\p) (value #t))    ; Initial prompt
    (debug      (single-char #\d) (value #f))))

(define (show-help)
  (display "guile-sage - AI REPL with tool calling\n\n")
  (display "Usage: sage [options] [prompt]\n\n")
  (display "Options:\n")
  (display "  -h, --help       Show this help\n")
  (display "  -v, --version    Show version\n")
  (display "  -m, --model      Set model name\n")
  (display "  -s, --session    Load session by name\n")
  (display "  -c, --continue   Continue last session\n")
  (display "  -y, --yolo       Enable YOLO mode (allow all tools)\n")
  (display "  -w, --workspace  Set workspace directory\n")
  (display "  -p, --prompt     Initial prompt to send\n")
  (display "  -d, --debug      Enable debug mode\n")
  (display "      --check      Check configuration and exit\n"))

(define (show-version)
  (format #t "guile-sage v~a~%" (version-string))
  (format #t "Guile ~a~%" (version)))

(define (main args)
  (let* ((options (getopt-long args option-spec))
         (help? (option-ref options 'help #f))
         (version? (option-ref options 'version #f))
         (model (option-ref options 'model #f))
         (session-name (option-ref options 'session #f))
         (continue? (option-ref options 'continue #f))
         (check? (option-ref options 'check #f))
         (yolo? (option-ref options 'yolo #f))
         (workspace (option-ref options 'workspace #f))
         (prompt (option-ref options 'prompt #f))
         (debug? (option-ref options 'debug #f))
         (rest-args (option-ref options '() '())))

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
      ;; Set YOLO mode
      (when yolo?
        (setenv "SAGE_YOLO_MODE" "1"))
      ;; Set workspace
      (when workspace
        (setenv "SAGE_WORKSPACE" workspace))
      ;; Set debug
      (when debug?
        (setenv "SAGE_DEBUG" "1"))
      ;; Combine prompt from -p and remaining args
      (let ((initial-prompt (or prompt
                                (if (null? rest-args)
                                    #f
                                    (string-join rest-args " ")))))
        ;; Start REPL
        (repl-start #:session-name session-name
                    #:continue? continue?
                    #:initial-prompt initial-prompt))))))

;; Run if executed directly
(when (equal? (current-filename) (car (command-line)))
  (main (command-line)))
