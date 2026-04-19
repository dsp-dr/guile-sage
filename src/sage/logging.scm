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
            log-stats
            log-errors
            log-timeline
            log-search-advanced
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
    ;; bd: guile-sage-9j7/07f — argv-based mkdir via primitive-fork +
    ;; execlp; dodges shell injection and macOS Guile's spawn+bad-FD bug.
    (unless (file-exists? dir)
      (let ((pid (primitive-fork)))
        (cond
         ((= pid 0)
          (catch #t
            (lambda () (execlp "mkdir" "mkdir" "-p" dir))
            (lambda args (primitive-exit 127))))
         (else (waitpid pid))))))

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
;;; Log Parsing Helpers
;;; ============================================================

;;; parse-log-line: Parse a log line into an alist
;;; Format: [timestamp] [LEVEL] [module] message key=value...
;;; Returns: alist with keys "timestamp" "level" "module" "message" "context"
;;;          or #f if line cannot be parsed
(define (parse-log-line line)
  (let ((rx (make-regexp "^\\[([^]]+)\\] \\[([^]]+)\\] \\[([^]]+)\\] (.*)")))
    (let ((m (regexp-exec rx line)))
      (if m
          (let* ((timestamp (match:substring m 1))
                 (level (match:substring m 2))
                 (module (match:substring m 3))
                 (rest (match:substring m 4))
                 ;; Split rest into message and context key=value pairs
                 (parts (split-message-context rest)))
            `(("timestamp" . ,timestamp)
              ("level" . ,level)
              ("module" . ,module)
              ("message" . ,(car parts))
              ("context" . ,(cdr parts))))
          #f))))

;;; split-message-context: Split "message key=val key2=val2" into (message . context-alist)
(define (split-message-context str)
  (let ((kv-rx (make-regexp "([a-zA-Z_]+)=([^ ]+)")))
    ;; Find all key=value pairs
    (let loop ((pos 0) (kvs '()))
      (let ((m (regexp-exec kv-rx str pos)))
        (if m
            (loop (match:end m)
                  (cons (cons (match:substring m 1) (match:substring m 2))
                        kvs))
            ;; The message is everything before the first key=value
            (let ((first-kv (regexp-exec kv-rx str)))
              (if first-kv
                  (cons (string-trim-both (substring str 0 (match:start first-kv)))
                        (reverse kvs))
                  (cons (string-trim-both str) '()))))))))

;;; read-all-log-lines: Read all lines from the current log file
;;; Returns: list of strings
(define (read-all-log-lines)
  (unless *log-file*
    (init-logging))
  (if (and *log-file* (file-exists? *log-file*))
      (call-with-input-file *log-file*
        (lambda (port)
          (let loop ((line (get-line port))
                     (acc '()))
            (if (eof-object? line)
                (reverse acc)
                (loop (get-line port) (cons line acc))))))
      '()))

;;; ============================================================
;;; Log Introspection Functions
;;; ============================================================

;;; log-stats: Compute statistics from log entries
;;; Returns: Formatted string with counts by level, error rate,
;;;          most common tool calls, total entries
(define (log-stats)
  (let* ((lines (read-all-log-lines))
         (parsed (filter identity (map parse-log-line lines)))
         (total (length parsed))
         ;; Count by level
         (level-counts
          (let ((tbl '()))
            (for-each
             (lambda (entry)
               (let* ((lvl (assoc-ref entry "level"))
                      (cur (assoc-ref tbl lvl)))
                 (set! tbl
                       (cons (cons lvl (1+ (or cur 0)))
                             (filter (lambda (p) (not (equal? (car p) lvl))) tbl)))))
             parsed)
            tbl))
         ;; Count tool calls
         (tool-calls
          (let ((tbl '()))
            (for-each
             (lambda (entry)
               (let ((tool (assoc-ref (assoc-ref entry "context") "tool")))
                 (when tool
                   (let ((cur (assoc-ref tbl tool)))
                     (set! tbl
                           (cons (cons tool (1+ (or cur 0)))
                                 (filter (lambda (p) (not (equal? (car p) tool))) tbl)))))))
             parsed)
            ;; Sort by count descending
            (sort tbl (lambda (a b) (> (cdr a) (cdr b))))))
         ;; Error rate
         (error-count (or (assoc-ref level-counts "ERROR") 0))
         (warn-count (or (assoc-ref level-counts "WARN") 0))
         (error-rate (if (> total 0)
                         (* 100.0 (/ error-count total))
                         0)))
    (string-append
     (format #f "=== Log Statistics ===~%")
     (format #f "Total entries: ~a~%" total)
     (format #f "~%Counts by level:~%")
     (apply string-append
            (map (lambda (p) (format #f "  ~a: ~a~%" (car p) (cdr p)))
                 (sort level-counts (lambda (a b) (string<? (car a) (car b))))))
     (format #f "~%Error rate: ~,1f%~%" error-rate)
     (format #f "Warning+Error rate: ~,1f%~%"
             (if (> total 0) (* 100.0 (/ (+ error-count warn-count) total)) 0))
     (format #f "~%Top tool calls:~%")
     (apply string-append
            (map (lambda (p) (format #f "  ~a: ~a~%" (car p) (cdr p)))
                 (take tool-calls (min 10 (length tool-calls))))))))

;;; log-errors: Extract recent errors with surrounding context
;;; Arguments:
;;;   count - Number of recent errors to show (default 10)
;;; Returns: Formatted string of error entries
(define* (log-errors #:key (count 10))
  (let* ((lines (read-all-log-lines))
         (parsed (filter identity (map parse-log-line lines)))
         (errors (filter (lambda (entry)
                           (equal? (assoc-ref entry "level") "ERROR"))
                         parsed))
         (recent (take (reverse errors) (min count (length errors)))))
    (if (null? recent)
        "No errors found in log."
        (string-append
         (format #f "=== Recent Errors (~a of ~a total) ===~%~%"
                 (length recent) (length errors))
         (apply string-append
                (map (lambda (entry)
                       (let ((ctx (assoc-ref entry "context")))
                         (string-append
                          (format #f "[~a] [~a] ~a~%"
                                  (assoc-ref entry "timestamp")
                                  (assoc-ref entry "module")
                                  (assoc-ref entry "message"))
                          (if (null? ctx) ""
                              (string-append
                               (apply string-append
                                      (map (lambda (p)
                                             (format #f "  ~a = ~a~%" (car p) (cdr p)))
                                           ctx))
                               "\n")))))
                     (reverse recent)))))))

;;; log-timeline: Show a timeline of events in the log
;;; Arguments:
;;;   count - Number of recent entries to show (default 50)
;;;   module-filter - Show only entries from this module (optional)
;;; Returns: Formatted timeline string
(define* (log-timeline #:key (count 50) (module-filter #f))
  (let* ((lines (read-all-log-lines))
         (parsed (filter identity (map parse-log-line lines)))
         (filtered (if module-filter
                       (filter (lambda (entry)
                                 (equal? (assoc-ref entry "module") module-filter))
                               parsed)
                       parsed))
         (recent (take (reverse filtered) (min count (length filtered)))))
    (if (null? recent)
        "No entries found."
        (string-append
         (format #f "=== Event Timeline (~a entries) ===~%~%" (length recent))
         (apply string-append
                (map (lambda (entry)
                       (let* ((lvl (assoc-ref entry "level"))
                              (marker (cond
                                       ((equal? lvl "ERROR") "!!!")
                                       ((equal? lvl "WARN")  " ! ")
                                       ((equal? lvl "DEBUG") " . ")
                                       (else                 " - ")))
                              (tool (assoc-ref (assoc-ref entry "context") "tool"))
                              (duration (assoc-ref (assoc-ref entry "context") "duration_ms")))
                         (format #f "~a ~a [~a] ~a~a~%"
                                 (assoc-ref entry "timestamp")
                                 marker
                                 (assoc-ref entry "module")
                                 (assoc-ref entry "message")
                                 (cond
                                  ((and tool duration)
                                   (format #f " (tool=~a, ~ams)" tool duration))
                                  (tool (format #f " (tool=~a)" tool))
                                  (else "")))))
                     (reverse recent)))))))

;;; log-search-advanced: Search logs with multiple criteria
;;; Arguments:
;;;   level - Filter by log level (optional)
;;;   module - Filter by module name (optional)
;;;   message-pattern - Regex pattern for message text (optional)
;;;   tool - Filter by tool name in context (optional)
;;;   from-time - Start timestamp string (optional, ISO prefix match)
;;;   to-time - End timestamp string (optional, ISO prefix match)
;;;   limit - Max results (default 100)
;;; Returns: Formatted string of matching entries
(define* (log-search-advanced #:key (level #f) (module #f)
                              (message-pattern #f) (tool #f)
                              (from-time #f) (to-time #f)
                              (limit 100))
  (let* ((lines (read-all-log-lines))
         (parsed (filter identity (map parse-log-line lines)))
         ;; Apply filters
         (filtered
          (filter
           (lambda (entry)
             (and
              ;; Level filter
              (or (not level)
                  (equal? (string-upcase level)
                          (assoc-ref entry "level")))
              ;; Module filter
              (or (not module)
                  (equal? module (assoc-ref entry "module")))
              ;; Message pattern filter
              (or (not message-pattern)
                  (let ((rx (make-regexp message-pattern regexp/icase)))
                    (regexp-exec rx (assoc-ref entry "message"))))
              ;; Tool filter
              (or (not tool)
                  (equal? tool
                          (assoc-ref (assoc-ref entry "context") "tool")))
              ;; Time range filters (simple string comparison on ISO timestamps)
              (or (not from-time)
                  (string>=? (assoc-ref entry "timestamp") from-time))
              (or (not to-time)
                  (string<=? (assoc-ref entry "timestamp") to-time))))
           parsed))
         (limited (take filtered (min limit (length filtered)))))
    (if (null? limited)
        "No matching entries found."
        (string-append
         (format #f "=== Advanced Search Results (~a of ~a matching) ===~%~%"
                 (length limited) (length filtered))
         (apply string-append
                (map (lambda (entry)
                       (let ((ctx (assoc-ref entry "context")))
                         (string-append
                          (format #f "[~a] [~a] [~a] ~a~%"
                                  (assoc-ref entry "timestamp")
                                  (assoc-ref entry "level")
                                  (assoc-ref entry "module")
                                  (assoc-ref entry "message"))
                          (if (null? ctx) ""
                              (apply string-append
                                     (map (lambda (p)
                                            (format #f "  ~a = ~a~%" (car p) (cdr p)))
                                          ctx))))))
                     limited))))))

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
