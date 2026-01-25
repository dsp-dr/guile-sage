;;; session.scm --- Session and conversation management -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Manages conversation history, session persistence, and context.
;; Supports saving/loading sessions and compacting conversation history.

(define-module (sage session)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:export (*session*
            session-create
            session-add-message
            session-get-messages
            session-get-context
            session-compact!
            session-clear!
            session-save
            session-load
            session-status
            session-list
            session-dir
            estimate-tokens
            format-session-status))

;;; Session State

(define *session* #f)

;;; session-dir: Get session storage directory (XDG compliant)
;;; Uses project-specific directory by default (like Claude Code)
(define* (session-dir #:key (project-local #t))
  (let ((dir (or (config-get "SESSION_DIR")
                 (if project-local
                     (sage-project-sessions-dir)
                     (sage-sessions-dir)))))
    (unless (file-exists? dir)
      (system (format #f "mkdir -p '~a'" dir)))
    dir))

;;; session-create: Create a new session
;;; Arguments:
;;;   name - Optional session name
;;; Returns: New session alist
(define* (session-create #:key (name #f) (model #f))
  (let* ((now (current-time))
         (timestamp (number->string (time-second now)))
         (session `(("name" . ,(or name (string-append "session-" timestamp)))
                    ("model" . ,(or model (config-get "MODEL") "qwen3-coder:latest"))
                    ("created" . ,timestamp)
                    ("updated" . ,timestamp)
                   ("messages" . ())
                   ("stats" . (("total_tokens" . 0)
                              ("input_tokens" . 0)
                              ("output_tokens" . 0)
                              ("request_count" . 0)
                              ("tool_calls" . 0))))))
    (set! *session* session)
    session))

;;; session-add-message: Add a message to session
;;; Arguments:
;;;   role - "user", "assistant", or "system"
;;;   content - Message content string
;;;   tokens - Optional token count
(define* (session-add-message role content #:key (tokens #f) (tool-call #f))
  (unless *session*
    (session-create))
  (let* ((msg `(("role" . ,role)
                ("content" . ,content)
                ("timestamp" . ,(number->string (time-second (current-time))))
                ("tokens" . ,(or tokens (estimate-tokens content)))))
         (messages (assoc-ref *session* "messages"))
         (stats (assoc-ref *session* "stats"))
         (token-count (or tokens (estimate-tokens content))))
    ;; Update messages
    (set! *session*
          (assoc-set! *session* "messages" (append messages (list msg))))
    ;; Update stats
    (let* ((total (+ (assoc-ref stats "total_tokens") token-count))
           (input (if (equal? role "user")
                      (+ (assoc-ref stats "input_tokens") token-count)
                      (assoc-ref stats "input_tokens")))
           (output (if (equal? role "assistant")
                       (+ (assoc-ref stats "output_tokens") token-count)
                       (assoc-ref stats "output_tokens")))
           (requests (if (equal? role "assistant")
                         (1+ (assoc-ref stats "request_count"))
                         (assoc-ref stats "request_count")))
           (tools (if tool-call
                      (1+ (assoc-ref stats "tool_calls"))
                      (assoc-ref stats "tool_calls"))))
      (set! *session*
            (assoc-set! *session* "stats"
                        `(("total_tokens" . ,total)
                          ("input_tokens" . ,input)
                          ("output_tokens" . ,output)
                          ("request_count" . ,requests)
                          ("tool_calls" . ,tools)))))
    ;; Update timestamp
    (set! *session*
          (assoc-set! *session* "updated" (number->string (time-second (current-time)))))
    msg))

;;; session-get-messages: Get all messages
(define (session-get-messages)
  (if *session*
      (assoc-ref *session* "messages")
      '()))

;;; session-get-context: Get messages formatted for API
;;; Arguments:
;;;   max-tokens - Maximum tokens to include (optional)
(define* (session-get-context #:key (max-tokens #f))
  (let ((messages (session-get-messages)))
    (if (and max-tokens (> (session-total-tokens) max-tokens))
        ;; Need to compact - keep system message + recent messages
        (let loop ((msgs (reverse messages))
                   (tokens 0)
                   (result '()))
          (if (or (null? msgs) (> tokens max-tokens))
              result
              (let* ((msg (car msgs))
                     (msg-tokens (or (assoc-ref msg "tokens") 0)))
                (loop (cdr msgs)
                      (+ tokens msg-tokens)
                      (cons `(("role" . ,(assoc-ref msg "role"))
                              ("content" . ,(assoc-ref msg "content")))
                            result)))))
        ;; Return all messages
        (map (lambda (msg)
               `(("role" . ,(assoc-ref msg "role"))
                 ("content" . ,(assoc-ref msg "content"))))
             messages))))

;;; session-total-tokens: Get total tokens in session
(define (session-total-tokens)
  (if *session*
      (assoc-ref (assoc-ref *session* "stats") "total_tokens")
      0))

;;; session-compact!: Compact conversation history
;;; Summarizes older messages to reduce token count
(define* (session-compact! #:key (keep-recent 5) (summarize #f))
  (unless *session*
    (error "No active session"))
  (let* ((messages (session-get-messages))
         (len (length messages)))
    (if (<= len keep-recent)
        (format #f "Nothing to compact (~a messages)" len)
        (let* ((to-remove (- len keep-recent))
               (old-messages (take messages to-remove))
               (new-messages (drop messages to-remove))
               (old-tokens (fold + 0 (map (lambda (m)
                                            (or (assoc-ref m "tokens") 0))
                                          old-messages))))
          ;; If summarize is provided, add summary as system message
          (when summarize
            (let ((summary-msg `(("role" . "system")
                                 ("content" . ,(format #f "[Compacted ~a messages, ~a tokens]"
                                                       to-remove old-tokens))
                                 ("timestamp" . ,(number->string (time-second (current-time))))
                                 ("tokens" . 20))))
              (set! new-messages (cons summary-msg new-messages))))
          ;; Update session
          (set! *session*
                (assoc-set! *session* "messages" new-messages))
          (format #f "Compacted ~a messages (~a tokens)" to-remove old-tokens)))))

;;; session-clear!: Clear conversation history
(define (session-clear!)
  (when *session*
    (set! *session*
          (assoc-set! *session* "messages" '()))
    (set! *session*
          (assoc-set! *session* "stats"
                      '(("total_tokens" . 0)
                        ("input_tokens" . 0)
                        ("output_tokens" . 0)
                        ("request_count" . 0)
                        ("tool_calls" . 0)))))
  "Session cleared.")

;;; session-save: Save session to file
;;; If name contains a path separator or ends in .json, treat as filepath
(define* (session-save #:key (name #f))
  (unless *session*
    (error "No active session"))
  (let* ((session-name (or name (assoc-ref *session* "name")))
         (filename (if (or (string-contains session-name "/")
                           (string-suffix? ".json" session-name))
                       (if (string-suffix? ".json" session-name)
                           session-name
                           (string-append session-name ".json"))
                       (string-append (session-dir) "/" session-name ".json")))
         (json (json-write-string *session*)))
    (call-with-output-file filename
      (lambda (port) (display json port)))
    (format #f "Saved to ~a" filename)))

;;; session-load: Load session from file
(define (session-load name)
  (let ((filename (if (string-suffix? ".json" name)
                      name
                      (string-append (session-dir) "/" name ".json"))))
    (if (file-exists? filename)
        (let ((json (call-with-input-file filename get-string-all)))
          (set! *session* (json-read-string json))
          (format #f "Loaded ~a (~a messages)"
                  (assoc-ref *session* "name")
                  (length (session-get-messages))))
        (format #f "Session not found: ~a" filename))))

;;; session-list: List available sessions
(define (session-list)
  (let* ((dir (session-dir))
         (files (if (file-exists? dir)
                    (scandir dir (lambda (f) (string-suffix? ".json" f)))
                    '())))
    (map (lambda (f) (string-drop-right f 5)) files)))  ; Remove .json

;;; session-status: Get session status
(define (session-status)
  (if *session*
      (let ((stats (assoc-ref *session* "stats")))
        `(("name" . ,(assoc-ref *session* "name"))
          ("model" . ,(assoc-ref *session* "model"))
          ("messages" . ,(length (session-get-messages)))
          ("total_tokens" . ,(assoc-ref stats "total_tokens"))
          ("input_tokens" . ,(assoc-ref stats "input_tokens"))
          ("output_tokens" . ,(assoc-ref stats "output_tokens"))
          ("requests" . ,(assoc-ref stats "request_count"))
          ("tool_calls" . ,(assoc-ref stats "tool_calls"))))
      '(("name" . "none")
        ("messages" . 0)
        ("total_tokens" . 0))))

;;; format-session-status: Format status for display
(define (format-session-status)
  (let ((status (session-status)))
    (format #f "Session: ~a
Model: ~a
Messages: ~a
Tokens: ~a (in: ~a, out: ~a)
Requests: ~a
Tool calls: ~a"
            (assoc-ref status "name")
            (or (assoc-ref status "model") "default")
            (assoc-ref status "messages")
            (assoc-ref status "total_tokens")
            (or (assoc-ref status "input_tokens") 0)
            (or (assoc-ref status "output_tokens") 0)
            (or (assoc-ref status "requests") 0)
            (or (assoc-ref status "tool_calls") 0))))

;;; estimate-tokens: Estimate token count for text
;;; Rough estimate: ~4 chars per token for English
(define (estimate-tokens text)
  (if (string? text)
      (ceiling (/ (string-length text) 4))
      0))

;;; Helper: assoc-set! that works with string keys
(define (assoc-set! alist key value)
  (cons (cons key value)
        (filter (lambda (p) (not (equal? (car p) key))) alist)))
