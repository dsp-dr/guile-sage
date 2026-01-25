;;; repl.scm --- Interactive REPL with slash commands -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Interactive REPL for guile-sage with slash commands.
;; Manages conversation flow with Ollama backend.

(define-module (sage repl)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage ollama)
  #:use-module (sage session)
  #:use-module (sage tools)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (ice-9 readline)
  #:use-module (ice-9 rdelim)
  #:export (repl-start
            repl-eval
            handle-command
            *commands*))

;;; REPL State

(define *running* #t)
(define *debug* #f)

;;; Slash Commands

(define *commands*
  `(("/help"      . ,cmd-help)
    ("/exit"      . ,cmd-exit)
    ("/quit"      . ,cmd-exit)
    ("/clear"     . ,cmd-clear)
    ("/reset"     . ,cmd-reset)
    ("/status"    . ,cmd-status)
    ("/stats"     . ,cmd-status)
    ("/compact"   . ,cmd-compact)
    ("/context"   . ,cmd-context)
    ("/model"     . ,cmd-model)
    ("/models"    . ,cmd-models)
    ("/save"      . ,cmd-save)
    ("/load"      . ,cmd-load)
    ("/sessions"  . ,cmd-sessions)
    ("/tools"     . ,cmd-tools)
    ("/workspace" . ,cmd-workspace)
    ("/debug"     . ,cmd-debug)
    ("/version"   . ,cmd-version)
    ("/reload"    . ,cmd-reload)
    ("/refresh"   . ,cmd-reload)))

;;; Command Implementations

(define (cmd-help args)
  (display "Available commands:\n")
  (display "  /help           - Show this help\n")
  (display "  /exit, /quit    - Exit the REPL\n")
  (display "  /clear          - Clear screen\n")
  (display "  /reset          - Clear conversation history\n")
  (display "  /status, /stats - Show session statistics\n")
  (display "  /compact [n]    - Compact history, keep last n messages\n")
  (display "  /context        - Show conversation context\n")
  (display "  /model [name]   - Show or set model\n")
  (display "  /models         - List available models\n")
  (display "  /save [name]    - Save session\n")
  (display "  /load <name>    - Load session\n")
  (display "  /sessions       - List saved sessions\n")
  (display "  /tools          - List available tools\n")
  (display "  /workspace      - Show workspace directory\n")
  (display "  /debug          - Toggle debug mode\n")
  (display "  /version        - Show version info\n")
  (display "  /reload         - Hot-reload sage modules\n")
  #t)

(define (cmd-exit args)
  (display "Goodbye!\n")
  (set! *running* #f)
  #t)

(define (cmd-clear args)
  (display "\x1b[2J\x1b[H")  ; ANSI clear screen
  #t)

(define (cmd-reset args)
  (display (session-clear!))
  (newline)
  #t)

(define (cmd-status args)
  (display (format-session-status))
  (newline)
  #t)

(define (cmd-compact args)
  (let ((keep (if (and args (not (string-null? args)))
                  (string->number args)
                  5)))
    (display (session-compact! #:keep-recent keep #:summarize #t))
    (newline))
  #t)

(define (cmd-context args)
  (let ((messages (session-get-messages)))
    (if (null? messages)
        (display "No messages in context.\n")
        (for-each
         (lambda (msg)
           (format #t "[~a]: ~a~%"
                   (assoc-ref msg "role")
                   (let ((content (assoc-ref msg "content")))
                     (if (> (string-length content) 100)
                         (string-append (substring content 0 100) "...")
                         content))))
         messages)))
  #t)

(define (cmd-model args)
  (if (and args (not (string-null? args)))
      (begin
        (when *session*
          (set! *session*
                (cons (cons "model" args)
                      (filter (lambda (p) (not (equal? (car p) "model")))
                              *session*))))
        (format #t "Model set to: ~a~%" args))
      (format #t "Current model: ~a~%" (ollama-model)))
  #t)

(define (cmd-models args)
  (let ((models (ollama-list-models)))
    (display "Available models:\n")
    (for-each
     (lambda (m)
       (format #t "  - ~a~%" (assoc-ref m "name")))
     models))
  #t)

(define (cmd-save args)
  (let ((name (if (and args (not (string-null? args)))
                  args
                  #f)))
    (catch #t
      (lambda ()
        (display (session-save #:name name))
        (newline))
      (lambda (key . err-args)
        (format #t "Save failed: ~a ~a~%" key err-args))))
  #t)

(define (cmd-load args)
  (if (and args (not (string-null? args)))
      (begin
        (display (session-load args))
        (newline))
      (display "Usage: /load <session-name>\n"))
  #t)

(define (cmd-sessions args)
  (let ((sessions (session-list)))
    (if (null? sessions)
        (display "No saved sessions.\n")
        (begin
          (display "Saved sessions:\n")
          (for-each
           (lambda (s)
             (format #t "  - ~a~%" s))
           sessions))))
  #t)

(define (cmd-tools args)
  (let ((tools (list-tools)))
    (display "Available tools:\n")
    (for-each
     (lambda (t)
       (format #t "  - ~a ~a~%      ~a~%"
               (assoc-ref t 'name)
               (if (assoc-ref t 'safe) "[safe]" "[unsafe]")
               (or (assoc-ref t 'description) "")))
     tools))
  #t)

(define (cmd-workspace args)
  (format #t "Workspace: ~a~%" (workspace))
  #t)

(define (cmd-debug args)
  (set! *debug* (not *debug*))
  (format #t "Debug mode: ~a~%" (if *debug* "ON" "OFF"))
  #t)

(define (cmd-version args)
  (display "guile-sage v0.1.0\n")
  (format #t "Guile: ~a~%" (version))
  (format #t "Backend: Ollama (~a)~%" (ollama-host))
  #t)

(define (cmd-reload args)
  "Hot-reload sage modules without losing session state."
  (display "Reloading modules...\n")
  (catch #t
    (lambda ()
      ;; Reload core modules
      (reload-module (resolve-module '(sage util)))
      (reload-module (resolve-module '(sage config)))
      (reload-module (resolve-module '(sage ollama)))
      (reload-module (resolve-module '(sage tools)))
      (reload-module (resolve-module '(sage session)))
      ;; Don't reload repl - we're running in it!
      (display "Reloaded: util, config, ollama, tools, session\n")
      (display "Note: repl module requires restart\n"))
    (lambda (key . args)
      (format #t "Reload error: ~a ~a~%" key args)))
  #t)

;;; Command Handler

(define (handle-command input)
  "Handle a slash command. Returns #t if handled, #f if not a command."
  (if (string-prefix? "/" input)
      (let* ((parts (string-split input #\space))
             (cmd (car parts))
             (args (if (> (length parts) 1)
                       (string-join (cdr parts) " ")
                       "")))
        (let ((handler (assoc-ref *commands* cmd)))
          (if handler
              (handler args)
              (begin
                (format #t "Unknown command: ~a~%" cmd)
                (display "Type /help for available commands.\n")
                #t))))
      #f))

;;; Chat Handler

(define (handle-chat input)
  "Process a chat message and get response from Ollama."
  ;; Add user message to session
  (session-add-message "user" input)

  ;; Get context for API
  (let* ((model (if *session*
                    (or (assoc-ref *session* "model") (ollama-model))
                    (ollama-model)))
         (messages (session-get-context))
         (tools (tools-to-schema)))

    (when *debug*
      (format #t "[DEBUG] Model: ~a~%" model)
      (format #t "[DEBUG] Messages: ~a~%" (length messages))
      (format #t "[DEBUG] Tools: ~a~%" (length tools)))

    ;; Display token usage in debug mode (after response)
    (define (debug-tokens prompt-toks completion-toks)
      (when *debug*
        (format #t "[DEBUG] Tokens - prompt: ~a, completion: ~a~%"
                prompt-toks completion-toks)))

    ;; Call Ollama with tools
    (catch #t
      (lambda ()
        (let* ((response (ollama-chat-with-tools model messages tools))
               (message (assoc-ref response "message"))
               (content (assoc-ref message "content"))
               (usage (ollama-extract-token-usage response))
               (prompt-tokens (assoc-ref usage 'prompt_tokens))
               (completion-tokens (assoc-ref usage 'completion_tokens)))

          ;; Debug token usage
          (debug-tokens prompt-tokens completion-tokens)

          ;; Check for tool calls
          (let ((tool-call (ollama-parse-tool-call content)))
            (if tool-call
                (begin
                  ;; Execute tool and add result
                  (let* ((tool-name (assoc-ref tool-call "name"))
                         (tool-args (assoc-ref tool-call "arguments"))
                         (result (execute-tool tool-name tool-args)))
                    (when *debug*
                      (format #t "[DEBUG] Tool: ~a~%" tool-name)
                      (format #t "[DEBUG] Args: ~a~%" tool-args))

                    ;; Add assistant message with tool call (with actual token count)
                    (session-add-message "assistant" content
                                         #:tokens completion-tokens
                                         #:tool-call #t)

                    ;; Display tool execution
                    (format #t "~a~%" content)
                    (format #t "~%[Tool: ~a]~%" tool-name)
                    (format #t "~a~%" result)

                    ;; Add tool result and get follow-up
                    (session-add-message "user"
                                        (format #f "Tool result for ~a:\n~a"
                                                tool-name result))

                    ;; Get follow-up response
                    (let* ((follow-up (ollama-chat model (session-get-context)))
                           (follow-msg (assoc-ref follow-up "message"))
                           (follow-content (assoc-ref follow-msg "content"))
                           (follow-usage (ollama-extract-token-usage follow-up))
                           (follow-completion (assoc-ref follow-usage 'completion_tokens)))
                      (debug-tokens (assoc-ref follow-usage 'prompt_tokens)
                                    follow-completion)
                      (session-add-message "assistant" follow-content
                                           #:tokens follow-completion)
                      (format #t "~%~a~%" follow-content))))

                ;; No tool call, just display response
                (begin
                  (session-add-message "assistant" content
                                       #:tokens completion-tokens)
                  (format #t "~a~%" content))))))

      (lambda (key . args)
        (format #t "Error: ~a ~a~%" key args)))))

;;; REPL Eval

(define (repl-eval input)
  "Evaluate input - either command or chat."
  (cond
   ((string-null? (string-trim-both input))
    #t)
   ((handle-command input)
    #t)
   (else
    (handle-chat input)
    #t)))

;;; REPL Start

(define* (repl-start #:key (session-name #f) (continue? #f) (initial-prompt #f))
  "Start the interactive REPL."

  ;; Load config
  (config-load-dotenv)

  ;; Ensure XDG directories exist
  (ensure-sage-dirs)
  (ensure-project-dirs)

  ;; Initialize tools
  (init-default-tools)

  ;; Check for debug mode
  (when (config-get "DEBUG")
    (set! *debug* #t))

  ;; Create or load session
  (cond
   (continue?
    ;; Load most recent session
    (let ((sessions (session-list)))
      (if (null? sessions)
          (session-create)
          (session-load (car sessions)))))
   (session-name
    (session-load session-name))
   (else
    (session-create)))

  ;; Welcome message
  (let ((yolo? (config-get "YOLO_MODE")))
    (display "\n")
    (display "╔═══════════════════════════════════════╗\n")
    (display "║         guile-sage v0.1.0             ║\n")
    (display "║   Type /help for commands, /exit to quit  ║\n")
    (display "╚═══════════════════════════════════════╝\n")
    (format #t "Model: ~a~%" (ollama-model))
    (format #t "Host: ~a~%" (ollama-host))
    (when yolo?
      (display "Mode: YOLO (all tools enabled)\n"))
    (when *debug*
      (display "Debug: ON\n"))
    (display "\n"))

  ;; Process initial prompt if provided
  (when initial-prompt
    (format #t "sage> ~a~%" initial-prompt)
    (repl-eval initial-prompt))

  ;; Activate readline if available
  (catch #t
    (lambda ()
      (activate-readline)
      (set-readline-prompt! "sage> "))
    (lambda args #f))

  ;; Main loop
  (set! *running* #t)
  (while *running*
    (catch #t
      (lambda ()
        (let ((input (readline "sage> ")))
          (if (eof-object? input)
              (cmd-exit "")
              (begin
                (add-history input)
                (repl-eval input)))))
      (lambda (key . args)
        (if (eq? key 'quit)
            (set! *running* #f)
            (format #t "Error: ~a~%" key))))))
