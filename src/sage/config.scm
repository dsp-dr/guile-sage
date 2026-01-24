;;; config.scm --- Configuration and environment handling -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Provides configuration management for guile-sage.
;; Loads settings from environment variables and .env files.

(define-module (sage config)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:export (config-get
            config-load-dotenv
            *default-provider*
            *default-ollama-host*
            *default-model*
            ;; XDG Base Directory support
            xdg-config-home
            xdg-data-home
            xdg-cache-home
            xdg-state-home
            sage-config-dir
            sage-data-dir
            sage-cache-dir
            sage-state-dir
            sage-sessions-dir
            sage-agents-dir
            sage-projects-dir
            sage-commands-dir
            ensure-sage-dirs))

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
  (let* ((key-str (if (symbol? key) (symbol->string key) key))
         (key-upper (string-upcase key-str))
         (sage-key (string-append "SAGE_" key-upper)))
    (or (hash-ref *config* key-str)
        (hash-ref *config* key-upper)
        (hash-ref *config* sage-key)
        (getenv sage-key)
        (getenv key-upper)
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

;;; ============================================================
;;; XDG Base Directory Support
;;; ============================================================

;;; XDG Base Directories (with fallbacks)
(define (xdg-config-home)
  (or (getenv "XDG_CONFIG_HOME")
      (string-append (getenv "HOME") "/.config")))

(define (xdg-data-home)
  (or (getenv "XDG_DATA_HOME")
      (string-append (getenv "HOME") "/.local/share")))

(define (xdg-cache-home)
  (or (getenv "XDG_CACHE_HOME")
      (string-append (getenv "HOME") "/.cache")))

(define (xdg-state-home)
  (or (getenv "XDG_STATE_HOME")
      (string-append (getenv "HOME") "/.local/state")))

;;; Sage-specific directories
(define (sage-config-dir)
  (or (config-get "CONFIG_DIR")
      (string-append (xdg-config-home) "/sage")))

(define (sage-data-dir)
  (or (config-get "DATA_DIR")
      (string-append (xdg-data-home) "/sage")))

(define (sage-cache-dir)
  (or (config-get "CACHE_DIR")
      (string-append (xdg-cache-home) "/sage")))

(define (sage-state-dir)
  (or (config-get "STATE_DIR")
      (string-append (xdg-state-home) "/sage")))

;;; Sage subdirectories
(define (sage-sessions-dir)
  (string-append (sage-data-dir) "/sessions"))

(define (sage-agents-dir)
  (string-append (sage-data-dir) "/agents"))

(define (sage-projects-dir)
  (string-append (sage-data-dir) "/projects"))

(define (sage-commands-dir)
  (string-append (sage-data-dir) "/commands"))

;;; ensure-dir: Create directory if it doesn't exist
(define (ensure-dir path)
  (unless (file-exists? path)
    (system (format #f "mkdir -p '~a'" path)))
  path)

;;; ensure-sage-dirs: Create all sage directories
(define (ensure-sage-dirs)
  (ensure-dir (sage-config-dir))
  (ensure-dir (sage-data-dir))
  (ensure-dir (sage-cache-dir))
  (ensure-dir (sage-state-dir))
  (ensure-dir (sage-sessions-dir))
  (ensure-dir (sage-agents-dir))
  (ensure-dir (sage-projects-dir))
  (ensure-dir (sage-commands-dir))
  #t)
