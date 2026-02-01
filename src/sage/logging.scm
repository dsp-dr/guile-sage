;;; logging.scm --- Centralized logging infrastructure -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Provides structured logging for guile-sage.
;; - Log levels: debug, info, warn, error
;; - Project-local storage in .logs/ directory
;; - Session-aware logging with context
;; - Self-inspection via read/search functions

(define-module (sage logging)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 rdelim)
  #:use-module (sage config)
  #:export (*log-level*
            *log-file*
            *log-dir*
            log-debug
            log-info
            log-warn
            log-error
            log-tool-call
            log-api-request
            log-api-response
            read-recent-logs
            search-logs
            init-logging
            with-logging
            set-log-level!
            get-log-level
            rotate-logs))

;;; ============================================================
;;; Configuration
;;; ============================================================

;;; Log levels (higher = more important)
(define *log-levels*
  '((debug . 0)
    (info . 1)
    (warn . 2)
    (error . 3)))

;;; Current log level (default: info)
(define *log-level* 'info)

;;; Log directory (project-local)
(define *log-dir* #f)

;;; Log file path
(define *log-file* #f)

;;; Max log file size in bytes (default: 10MB)
(define *log-max-size* 10485760)

;;; Number of rotated logs to keep
(define *log-keep* 5)

;;; ============================================================
;;; Initialization
;;; ============================================================

;;; init-logging: Initialize logging system
;;; Arguments:
;;;   log-dir - Directory for log files (default: .logs)
;;;   level - Minimum log level (default: info)
;;; Returns: #t on success
(define* (init-logging #:key (log-dir #f) (level #f))
  ;; Set log level from parameter, config, or environment
  (let ((cfg-level (or (config-get "LOG_LEVEL")
                       (getenv "SAGE_LOG_LEVEL"))))
    (set-log-level! (or level
                        (and cfg-level (string->symbol cfg-level))
                        'info)))

  ;; Set log directory from parameter, config, or default
  (let ((dir (or log-dir
                 (config-get "LOG_DIR")
                 (getenv "SAGE_LOG_DIR")
                 (string-append (getcwd) "/.logs"))))
    (set! *log-dir* dir)
    ;; Create directory if needed
    (unless (file-exists? dir)
      (system (format #f "mkdir -p '~a'" dir))))

  ;; Set log file path
  (set! *log-file* (string-append *log-dir* "/sage.log"))

  ;; Set max size from config or environment
  (let ((cfg-size (or (config-get "LOG_MAX_SIZE")
                      (getenv "SAGE_LOG_MAX_SIZE"))))
    (when cfg-size
      (let ((size (string->number cfg-size)))
        (when size (set! *log-max-size* size)))))

  ;; Set keep count from config or environment
  (let ((cfg-keep (or (config-get "LOG_KEEP")
                      (getenv "SAGE_LOG_KEEP"))))
    (when cfg-keep
      (let ((keep (string->number cfg-keep)))
        (when keep (set! *log-keep* keep)))))

  ;; Log initialization
  (log-info "logging" "Logging initialized" `(("dir" . ,*log-dir*)
                                               ("level" . ,*log-level*)))
  #t)

;;; set-log-level!: Set minimum log level
(define (set-log-level! level)
  (when (assoc level *log-levels*)
    (set! *log-level* level)))

;;; get-log-level: Get current log level
(define (get-log-level)
  *log-level*)

;;; ============================================================
;;; Core Logging Functions
;;; ============================================================

;;; level-value: Get numeric value for log level
(define (level-value level)
  (or (assoc-ref *log-levels* level) 1))

;;; should-log?: Check if message at given level should be logged
(define (should-log? level)
  (>= (level-value level) (level-value *log-level*)))

;;; format-timestamp: Format current time as ISO 8601
(define (format-timestamp)
  (let ((now (current-time)))
    (date->string (time-utc->date now) "~Y-~m-~dT~H:~M:~S")))

;;; format-level: Format log level as uppercase string
(define (format-level level)
  (string-upcase (symbol->string level)))

;;; format-context: Format context alist as string
(define (format-context context)
  (if (null? context)
      ""
      (string-append " "
                     (string-join
                      (map (lambda (pair)
                             (format #f "~a=~a" (car pair) (cdr pair)))
                           context)
                      " "))))

;;; write-log: Write a log entry
(define (write-log level module message context)
  (when (should-log? level)
    ;; Ensure logging is initialized
    (unless *log-file*
      (init-logging))

    ;; Check for rotation
    (maybe-rotate-logs)

    ;; Format and write entry
    (let ((entry (format #f "[~a] [~a] [~a] ~a~a~%"
                         (format-timestamp)
                         (format-level level)
                         module
                         message
                         (format-context context))))
      (catch #t
        (lambda ()
          (let ((port (open-file *log-file* "a")))
            (display entry port)
            (close-port port)))
        (lambda (key . args)
          ;; Fallback to stderr if file write fails
          (display entry (current-error-port)))))))

;;; log-debug: Log debug message
(define* (log-debug module message #:optional (context '()))
  (write-log 'debug module message context))

;;; log-info: Log info message
(define* (log-info module message #:optional (context '()))
  (write-log 'info module message context))

;;; log-warn: Log warning message
(define* (log-warn module message #:optional (context '()))
  (write-log 'warn module message context))

;;; log-error: Log error message
(define* (log-error module message #:optional (context '()))
  (write-log 'error module message context))

;;; ============================================================
;;; Specialized Logging Functions
;;; ============================================================

;;; log-tool-call: Log tool execution
;;; Arguments:
;;;   tool-name - Name of tool being called
;;;   args - Arguments to tool
;;;   result - Result of execution (optional)
;;;   duration - Execution time in ms (optional)
(define* (log-tool-call tool-name args #:key (result #f) (duration #f))
  (let ((context `(("tool" . ,tool-name)
                   ,@(if duration `(("duration_ms" . ,duration)) '()))))
    (if result
        (log-info "tools" (format #f "Tool executed: ~a" tool-name) context)
        (log-debug "tools" (format #f "Tool called: ~a" tool-name)
                   (cons (cons "args" (truncate-string (format #f "~a" args) 200))
                         context)))))

;;; log-api-request: Log API request
;;; Arguments:
;;;   model - Model name
;;;   endpoint - API endpoint
;;;   tokens - Token count (optional)
(define* (log-api-request model endpoint #:key (tokens #f))
  (log-info "ollama"
            (format #f "API request: ~a" endpoint)
            `(("model" . ,model)
              ,@(if tokens `(("tokens" . ,tokens)) '()))))

;;; log-api-response: Log API response
;;; Arguments:
;;;   status - HTTP status code
;;;   tokens - Token usage (optional)
;;;   error - Error message if any (optional)
(define* (log-api-response status #:key (tokens #f) (error #f))
  (if error
      (log-error "ollama"
                 (format #f "API error: ~a" error)
                 `(("status" . ,status)))
      (log-info "ollama"
                "API response received"
                `(("status" . ,status)
                  ,@(if tokens `(("tokens" . ,tokens)) '())))))

;;; truncate-string: Truncate string to max length
(define (truncate-string str max-len)
  (if (> (string-length str) max-len)
      (string-append (substring str 0 max-len) "...")
      str))

;;; ============================================================
;;; Log Rotation
;;; ============================================================

;;; get-file-size: Get size of file in bytes
(define (get-file-size path)
  (catch #t
    (lambda ()
      (let ((s (stat path)))
        (stat:size s)))
    (lambda args 0)))

;;; maybe-rotate-logs: Rotate logs if size exceeds limit
(define (maybe-rotate-logs)
  (when (and *log-file* (file-exists? *log-file*))
    (when (> (get-file-size *log-file*) *log-max-size*)
      (rotate-logs))))

;;; rotate-logs: Rotate log files
(define (rotate-logs)
  (when *log-file*
    ;; Delete oldest if we have too many
    (let ((oldest (string-append *log-file* "." (number->string *log-keep*))))
      (when (file-exists? oldest)
        (delete-file oldest)))

    ;; Shift existing logs
    (let loop ((n (1- *log-keep*)))
      (when (> n 0)
        (let ((from (if (= n 1)
                        *log-file*
                        (string-append *log-file* "." (number->string (1- n)))))
              (to (string-append *log-file* "." (number->string n))))
          (when (file-exists? from)
            (rename-file from to)))
        (loop (1- n))))))

;;; ============================================================
;;; Log Reading and Searching
;;; ============================================================

;;; read-recent-logs: Read recent log entries
;;; Arguments:
;;;   lines - Number of lines to read (default 50)
;;;   level - Filter by level (optional)
;;; Returns: String of log entries
(define* (read-recent-logs #:key (lines 50) (level #f))
  (unless *log-file*
    (init-logging))
  (if (file-exists? *log-file*)
      (let* ((all-lines (call-with-input-file *log-file*
                          (lambda (port)
                            (let loop ((line (get-line port))
                                       (acc '()))
                              (if (eof-object? line)
                                  (reverse acc)
                                  (loop (get-line port) (cons line acc)))))))
             (filtered (if level
                           (filter (lambda (line)
                                     (string-contains line
                                                     (format #f "[~a]"
                                                             (string-upcase
                                                              (if (string? level)
                                                                  level
                                                                  (symbol->string level))))))
                                   all-lines)
                           all-lines))
             (recent (take (reverse filtered) (min lines (length filtered)))))
        (string-join (reverse recent) "\n"))
      "No log file found."))

;;; search-logs: Search logs for pattern
;;; Arguments:
;;;   pattern - Search pattern (string)
;;;   level - Filter by level (optional)
;;;   limit - Max results (default 100)
;;; Returns: String of matching entries
(define* (search-logs pattern #:key (level #f) (limit 100))
  (unless *log-file*
    (init-logging))
  (if (file-exists? *log-file*)
      (let* ((rx (make-regexp pattern regexp/icase))
             (all-lines (call-with-input-file *log-file*
                          (lambda (port)
                            (let loop ((line (get-line port))
                                       (acc '()))
                              (if (eof-object? line)
                                  (reverse acc)
                                  (loop (get-line port) (cons line acc)))))))
             (level-filtered (if level
                                 (filter (lambda (line)
                                           (string-contains line
                                                           (format #f "[~a]"
                                                                   (string-upcase
                                                                    (if (string? level)
                                                                        level
                                                                        (symbol->string level))))))
                                         all-lines)
                                 all-lines))
             (pattern-filtered (filter (lambda (line)
                                         (regexp-exec rx line))
                                       level-filtered))
             (limited (take pattern-filtered (min limit (length pattern-filtered)))))
        (if (null? limited)
            "No matching entries found."
            (string-join limited "\n")))
      "No log file found."))

;;; ============================================================
;;; Convenience Macros
;;; ============================================================

;;; with-logging: Execute thunk with logging of entry/exit
;;; Arguments:
;;;   module - Module name for logging
;;;   operation - Operation name
;;;   thunk - Function to execute
;;; Returns: Result of thunk
(define (with-logging module operation thunk)
  (log-debug module (format #f "Starting: ~a" operation))
  (let ((start-time (current-time)))
    (catch #t
      (lambda ()
        (let ((result (thunk)))
          (let* ((end-time (current-time))
                 (duration (- (time-second end-time) (time-second start-time))))
            (log-debug module (format #f "Completed: ~a" operation)
                       `(("duration_s" . ,duration))))
          result))
      (lambda (key . args)
        (log-error module (format #f "Failed: ~a" operation)
                   `(("error" . ,(format #f "~a ~a" key args))))
        (apply throw key args)))))
