;;; config.scm --- Configuration and environment handling -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Provides configuration management for guile-sage.
;; Loads settings from environment variables and .env files.
;;
;;; reload-contract: destroys *config* hash (all dotenv entries); --hard must re-run config-load-dotenv.

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
            ensure-sage-dirs
            ;; Project directory encoding
            path->project-id
            project-id->path
            current-project-id
            sage-project-dir
            sage-project-sessions-dir
            ensure-project-dirs
            ;; AGENTS.md support
            find-agents-md
            load-agents-md
            ;; Token limits
            *token-limits*
            get-token-limit
            is-local-provider?
            ;; Logging configuration
            sage-log-dir
            sage-log-level
            sage-log-max-size
            sage-log-keep
            ;; Guardrail visibility
            guardrail-proxy-url
            guardrail-check-provider
            ;; Reload sentinel
            *config-loaded*))

;;; Constants

(define *default-provider* 'ollama)
(define *default-ollama-host* "http://localhost:11434")
(define *default-model* #f)  ; Use provider default

;;; Token limits by provider/model
;;; Conservative defaults to avoid hitting limits
;;; Sources:
;;;   - https://docs.ollama.com/context-length
;;;   - https://ollama.com/library/glm-4.7:cloud
;;;   - https://unsloth.ai/docs/models/glm-4.7
(define *token-limits*
  '(;; GLM-4.x family (Ollama Cloud) - check specific first
    ("glm-4.7" . 128000)   ; 128K context window
    ("glm-4.6" . 200000)   ; 200K context window
    ;; Qwen models
    ("qwen3-coder" . 32000)
    ("qwen" . 32000)
    ;; Llama models
    ("llama3" . 8000)
    ("llama" . 4096)
    ;; Other models
    ("mistral" . 8000)
    ("deepseek" . 64000)
    ;; Cloud API providers (check gpt-4o before gpt-4)
    ("gpt-4o" . 128000)
    ("gpt-4" . 8000)
    ("claude" . 200000)
    ;; Gemini family — check specific variants before the fallback.
    ;; Real context windows per Google docs (2026-04):
    ;;   gemini-2.5-pro       2_000_000   (2M)
    ;;   gemini-2.5-flash     1_000_000   (1M)
    ;;   gemini-2.5-flash-lite  1_000_000 (1M)
    ;;   gemini-1.5-pro       2_000_000
    ;;   gemini-1.5-flash       128_000
    ("gemini-2.5-pro" . 2000000)
    ("gemini-2.5-flash-lite" . 1000000)
    ("gemini-2.5-flash" . 1000000)
    ("gemini-1.5-pro" . 2000000)
    ("gemini-1.5-flash" . 128000)
    ("gemini" . 128000)
    ;; Fallback categories (checked last)
    ("local" . 8000)
    ("cloud" . 64000)))

;;; Internal state

(define *config* (make-hash-table))
;;; *config-loaded*: #f until config-load-dotenv succeeds at least once.
;;; Resets to #f on module reload; --hard reload must call config-load-dotenv
;;; to restore it to #t and repopulate *config*.
(define *config-loaded* #f)

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
  (let ((result (if (file-exists? path)
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
                    0)))
    (set! *config-loaded* #t)
    result))

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
;;; bd: guile-sage-9j7/07f — argv-based mkdir via primitive-fork +
;;; execlp; dodges shell injection and macOS Guile's spawn+bad-FD bug.
(define (ensure-dir path)
  (unless (file-exists? path)
    (let ((pid (primitive-fork)))
      (cond
       ((= pid 0)
        (catch #t
          (lambda () (execlp "mkdir" "mkdir" "-p" path))
          (lambda args (primitive-exit 127))))
       (else (waitpid pid)))))
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

;;; ============================================================
;;; Project Directory Encoding (Claude-style)
;;; ============================================================

;;; path->project-id: Encode a path to project directory name
;;; Replaces "/" with "-" (like Claude Code does)
;;; /home/user/project -> -home-user-project
(define (path->project-id path)
  (string-map (lambda (c) (if (char=? c #\/) #\- c)) path))

;;; project-id->path: Decode project directory name back to path
;;; -home-user-project -> /home/user/project
(define (project-id->path project-id)
  (if (string-prefix? "-" project-id)
      (string-map (lambda (c) (if (char=? c #\-) #\/ c)) project-id)
      project-id))

;;; current-project-id: Get encoded project ID for current directory
(define (current-project-id)
  (path->project-id (getcwd)))

;;; sage-project-dir: Get project-specific data directory
;;; Uses current working directory encoded as project ID
(define (sage-project-dir)
  (string-append (sage-projects-dir) "/" (current-project-id)))

;;; sage-project-sessions-dir: Get project-specific sessions directory
(define (sage-project-sessions-dir)
  (string-append (sage-project-dir) "/sessions"))

;;; ensure-project-dirs: Create project-specific directories
(define (ensure-project-dirs)
  (ensure-dir (sage-project-dir))
  (ensure-dir (sage-project-sessions-dir))
  #t)

;;; ============================================================
;;; AGENTS.md Support (open standard: https://agentskills.io)
;;; ============================================================

;;; find-agents-md: Find AGENTS.md files in order of precedence
;;; Returns: List of paths to AGENTS.md files found
(define (find-agents-md)
  (let ((candidates (list
                     ;; 1. Current directory
                     (string-append (getcwd) "/AGENTS.md")
                     ;; 2. Project-specific in XDG
                     (string-append (sage-project-dir) "/AGENTS.md")
                     ;; 3. Global in XDG config
                     (string-append (sage-config-dir) "/AGENTS.md")
                     ;; 4. Global in XDG data
                     (string-append (sage-data-dir) "/AGENTS.md")
                     ;; 5. Home directory (fallback)
                     (string-append (getenv "HOME") "/.sage/AGENTS.md"))))
    (filter file-exists? candidates)))

;;; load-agents-md: Load and concatenate all AGENTS.md files
;;; Returns: Combined content string or #f if none found
(define (load-agents-md)
  (let ((files (find-agents-md)))
    (if (null? files)
        #f
        (string-join
         (map (lambda (f)
                (format #f "# From: ~a\n~a"
                        f
                        (call-with-input-file f get-string-all)))
              files)
         "\n\n"))))

;;; ============================================================
;;; Token Limit Management
;;; ============================================================

;;; is-local-provider?: Check if using local Ollama instance
(define (is-local-provider?)
  (let ((host (or (config-get "OLLAMA_HOST") *default-ollama-host*)))
    (or (string-contains host "localhost")
        (string-contains host "127.0.0.1")
        (string-contains host ".local")
        (string-contains host ".lan"))))

;;; get-token-limit: Get appropriate token limit for current config
;;; Arguments:
;;;   model - Optional model name to check specific limits
;;; Returns: Token limit integer
;;;
;;; Priority: model-specific lookup > TOKEN_LIMIT override > provider default > 4000.
;;; TOKEN_LIMIT is intentionally checked AFTER model lookup so that a stale
;;; .env entry (e.g. TOKEN_LIMIT=8000 left over from Ollama setup) does not
;;; shadow the correct 1M limit for gemini-2.5-flash or other cloud models.
(define* (get-token-limit #:optional (model #f))
  (let* ((model-limit
          (and model
               (let loop ((limits *token-limits*))
                 (if (null? limits)
                     #f
                     (if (string-contains (string-downcase model)
                                          (car (car limits)))
                         (cdr (car limits))
                         (loop (cdr limits)))))))
         (explicit
          (and (not model-limit)
               (let ((v (config-get "TOKEN_LIMIT")))
                 (and v (string->number v)))))
         (provider-default
          (and (not model-limit) (not explicit)
               (if (is-local-provider?)
                   (assoc-ref *token-limits* "local")
                   (assoc-ref *token-limits* "cloud"))))
         (limit (or model-limit explicit provider-default 4000))
         (source (cond (model-limit      "model-match")
                       (explicit         "explicit-override")
                       (provider-default "provider-default")
                       (else             "ultimate-fallback"))))
    ;; Late-bound log call avoids circular import: logging.scm uses config.scm.
    (catch #t
      (lambda ()
        ((module-ref (resolve-module '(sage logging)) 'log-info)
         "config"
         (format #f "get-token-limit: ~a tokens" limit)
         `(("model"  . ,(or model "none"))
           ("limit"  . ,limit)
           ("source" . ,source))))
      (lambda _ #f))
    limit))

;;; ============================================================
;;; Logging Configuration
;;; ============================================================

;;; sage-log-dir: Get log directory (project-local .logs/)
(define (sage-log-dir)
  (or (config-get "LOG_DIR")
      (string-append (getcwd) "/.logs")))

;;; sage-log-level: Get log level (debug, info, warn, error)
(define (sage-log-level)
  (let ((level (config-get "LOG_LEVEL")))
    (if level
        (string->symbol level)
        'info)))

;;; sage-log-max-size: Get max log file size in bytes
(define (sage-log-max-size)
  (let ((size (config-get "LOG_MAX_SIZE")))
    (if size
        (string->number size)
        10485760)))  ; 10MB default

;;; sage-log-keep: Get number of rotated logs to keep
(define (sage-log-keep)
  (let ((keep (config-get "LOG_KEEP")))
    (if keep
        (string->number keep)
        5)))

;;; ============================================================
;;; Guardrail visibility (observability only — no filtering in sage)
;;; ============================================================

;;; guardrail-proxy-url: Returns SAGE_GUARDRAIL_PROXY if set, #f otherwise.
(define (guardrail-proxy-url)
  (config-get "GUARDRAIL_PROXY"))

;;; guardrail-check-provider: Warn if provider isn't routed through proxy.
;;; Returns a warning string or #f if guardrails are not configured or OK.
(define (guardrail-check-provider provider-name provider-host)
  (let ((proxy (guardrail-proxy-url)))
    (if (not proxy)
        #f  ; No guardrail proxy configured — nothing to check
        (if (string-contains provider-host proxy)
            #f  ; Provider is routed through the proxy — OK
            (format #f "Provider ~a (~a) is NOT routed through guardrail proxy ~a"
                    provider-name provider-host proxy)))))
