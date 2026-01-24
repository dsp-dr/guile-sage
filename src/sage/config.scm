;;; config.scm --- Configuration and environment handling -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Provides configuration management for guile-sage.
;; Loads settings from environment variables and .env files.

(define-module (sage config)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 match)
  #:export (config-get
            config-load-dotenv
            *default-provider*
            *default-ollama-host*
            *default-model*))

;;; Constants

(define *default-provider* 'ollama)
(define *default-ollama-host* "http://localhost:11434")
(define *default-model* #f)  ; Use provider default

;;; Internal state

(define *config* (make-hash-table))

;;; config-get: Get configuration value
;;; Arguments:
;;;   key - Symbol or string key name
;;;   default - Default value if not found (optional)
;;; Returns: Configuration value or default
(define* (config-get key #:optional (default #f))
  (let ((key-str (if (symbol? key) (symbol->string key) key)))
    (or (hash-ref *config* key-str)
        (getenv (string-upcase (string-append "SAGE_" key-str)))
        (getenv (string-upcase key-str))
        default)))

;;; parse-dotenv-line: Parse a single .env line
;;; Arguments:
;;;   line - String line from .env file
;;; Returns: (key . value) pair or #f if not a valid assignment
(define (parse-dotenv-line line)
  (let ((trimmed (string-trim-both line)))
    (cond
     ;; Skip empty lines and comments
     ((or (string-null? trimmed)
          (string-prefix? "#" trimmed))
      #f)
     ;; Parse KEY=value
     ((string-match "^([A-Za-z_][A-Za-z0-9_]*)=(.*)$" trimmed)
      => (lambda (m)
           (cons (match:substring m 1)
                 (string-trim-both (match:substring m 2) #\"))))
     (else #f))))

;;; config-load-dotenv: Load configuration from .env file
;;; Arguments:
;;;   path - Path to .env file (optional, defaults to ".env")
;;; Returns: Number of variables loaded
(define* (config-load-dotenv #:optional (path ".env"))
  (if (file-exists? path)
      (call-with-input-file path
        (lambda (port)
          (let loop ((line (get-line port))
                     (count 0))
            (if (eof-object? line)
                count
                (let ((parsed (parse-dotenv-line line)))
                  (when parsed
                    (hash-set! *config* (car parsed) (cdr parsed)))
                  (loop (get-line port)
                        (if parsed (1+ count) count)))))))
      0))
