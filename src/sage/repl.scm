;;; repl.scm --- Interactive REPL with slash commands -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Interactive REPL for guile-sage with slash commands.
;; Manages conversation flow with Ollama backend.

(define-module (sage repl)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (sage ollama)
  #:use-module (sage session)
  #:use-module (sage tools)
  #:use-module (sage version)
  #:use-module (sage agent)
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

;;; Dynamic Prompt

(define (endpoint-label host)
  "Convert host URL to short label."
  (cond
   ((string-contains host "ollama.com") "cloud")
   ((string-contains host "localhost") "local")
   ((string-contains host "127.0.0.1") "local")
   (else
    ;; Extract hostname from URL
    (let ((start (if (string-contains host "://")
                     (+ 3 (string-contains host "://"))
                     0)))
      (let ((end (or (string-index host #\: start)
                     (string-index host #\/ start)
                     (string-length host))))
        (substring host start end))))))

(define (format-tokens tokens)
  "Format token count for display (e.g., 12345 -> 12.3k)."
  (cond
   ((< tokens 1000) (number->string tokens))
   ((< tokens 1000000) (format #f "~,1fk" (/ tokens 1000.0)))
   (else (format #f "~,1fM" (/ tokens 1000000.0)))))

(define (extract-repo-name path)
  "Extract repo name from ghq-style path (github.com/owner/repo)."
  (let ((gh-match (string-contains path "github.com/")))
    (if gh-match
        (let* ((start (+ gh-match 11))  ; length of "github.com/"
               (rest (substring path start))
               (parts (string-split rest #\/)))
          (if (>= (length parts) 2)
              (format #f "~a/~a" (car parts) (cadr parts))
              #f))
        #f)))

(define (short-hostname)
  "Get short hostname (before first dot)."
  (let* ((full (gethostname))
         (dot (string-index full #\.)))
    (if dot (substring full 0 dot) full)))

(define (make-prompt)
  "Generate dynamic prompt with user, host, repo, model, endpoint, and tokens."
  (let* ((user (or (getenv "USER") (passwd:name (getpwuid (getuid)))))
         (host (short-hostname))
         (ws (workspace))
         (repo (and ws (extract-repo-name ws)))
         (model (ollama-model))
         (api-host (ollama-host))
         (label (endpoint-label api-host))
         (status (session-status))
         (tokens (or (assoc-ref status "total_tokens") 0))
         ;; Extract short model name (before colon if present)
         (short-model (let ((idx (string-index model #\:)))
                        (if idx (substring model 0 idx) model)))
         ;; Build context string
         (context (if repo
                      (format #f "~a@~a:~a" user host repo)
                      (format #f "~a@~a" user host))))
    (if (> tokens 0)
        (format #f "~a sage[~a@~a|~a]> " context short-model label (format-tokens tokens))
        (format #f "~a sage[~a@~a]> " context short-model label))))

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
    ("/refresh"   . ,cmd-reload)
    ("/logs"      . ,cmd-logs)
    ("/agent"     . ,cmd-agent)
    ("/tasks"     . ,cmd-tasks)
    ("/pause"     . ,cmd-pause)
    ("/continue"  . ,cmd-continue)))

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
  (display "  /logs [n] [lvl] - Show recent log entries\n")
  (display "\nAgent commands:\n")
  (display "  /agent [mode]   - Show/set agent mode (interactive|autonomous|yolo)\n")
  (display "  /tasks          - List pending agent tasks\n")
  (display "  /pause          - Pause agent loop\n")
  (display "  /continue       - Continue agent loop\n")
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
  (format #t "guile-sage v~a~%" (version-string))
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
      (reload-module (resolve-module '(sage logging)))
      (reload-module (resolve-module '(sage ollama)))
      (reload-module (resolve-module '(sage tools)))
      (reload-module (resolve-module '(sage session)))
      ;; Don't reload repl - we're running in it!
      (display "Reloaded: util, config, logging, ollama, tools, session\n")
      (display "Note: repl module requires restart\n"))
    (lambda (key . args)
      (format #t "Reload error: ~a ~a~%" key args)))
  #t)

(define (cmd-logs args)
  "Show recent log entries."
  (let* ((parts (string-split args #\space))
         (lines (if (and (not (null? parts))
                         (not (string-null? (car parts))))
                    (string->number (car parts))
                    20))
         (level (if (> (length parts) 1)
                    (cadr parts)
                    #f)))
    (display (read-recent-logs #:lines (or lines 20)
                               #:level level))
    (newline))
  #t)

(define (cmd-agent args)
  "Show or set agent mode."
  (if (string-null? (string-trim-both args))
      ;; Show current mode
      (begin
        (display (format-task-status))
        (newline))
      ;; Set mode
      (let ((mode (string->symbol (string-trim-both args))))
        (if (set-agent-mode! mode)
            (format #t "Agent mode set to: ~a~%" mode)
            (display "Invalid mode. Use: interactive, autonomous, or yolo\n"))))
  #t)

(define (cmd-tasks args)
  "List pending agent tasks."
  (let ((tasks (task-list)))
    (if (null? tasks)
        (display "No pending tasks.\n")
        (begin
          (display "Pending tasks:\n")
          (for-each
           (lambda (t)
             (format #t "  ~a: ~a~%" (car t) (cdr t)))
           tasks))))
  #t)

(define (cmd-pause args)
  "Pause agent loop."
  (agent-pause)
  (display "Agent paused.\n")
  #t)

(define (cmd-continue args)
  "Continue agent loop."
  (agent-continue)
  (if (has-pending-tasks?)
      (begin
        (display "Continuing with pending tasks...\n")
        (run-agent-loop))
      (display "No pending tasks to continue.\n"))
  #t)

;;; Agent Loop

(define (run-agent-loop)
  "Run the agent loop to process pending tasks."
  (agent-start)
  (let loop ()
    (let ((status (agent-status)))
      (when (and (assoc-ref status "running")
                 (has-pending-tasks?)
                 (< (assoc-ref status "iteration") (assoc-ref status "max_iterations")))
        (let ((task-id (task-next)))
          (when task-id
            (let ((task (task-get task-id)))
              (format #t "~%[sage] Working on: ~a~%"
                      (or (and task (assoc-ref task "title")) task-id))
              ;; Send continuation prompt to model
              (handle-task-continuation task-id task)
              ;; Increment iteration
              (agent-increment-iteration!)
              ;; Check if we should pause (interactive mode)
              (when (eq? (agent-mode) 'interactive)
                (display "[sage] Task step complete. Type /continue to proceed or send new input.\n")
                (agent-pause))
              (loop)))))))
  (unless (has-pending-tasks?)
    (display "[sage] All tasks complete.\n")))

(define (handle-task-continuation task-id task)
  "Send a continuation prompt to the model for the given task."
  (let* ((title (and task (assoc-ref task "title")))
         (desc (and task (assoc-ref task "description")))
         (prompt (format #f "Continue working on task ~a: ~a~%~%Description: ~a~%~%Use sage_task_complete when done, or sage_task_create for subtasks."
                         task-id
                         (or title "unknown")
                         (or desc "No description"))))
    (handle-chat prompt)))

;;; Command Handler

(define (handle-command input)
  "Handle a slash command. Returns #t if handled, #f if not a command."
  (if (string-prefix? "/" input)
      (let* ((parts (string-split input #\space))
             (cmd (car parts))
             (args (if (> (length parts) 1)
                       (string-join (cdr parts) " ")
                       "")))
        (log-debug "repl" (format #f "Command: ~a" cmd)
                   `(("args" . ,args)))
        (let ((handler (assoc-ref *commands* cmd)))
          (if handler
              (handler args)
              (begin
                (log-warn "repl" "Unknown command" `(("cmd" . ,cmd)))
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

  ;; Initialize logging
  (init-logging)
  (log-info "repl" "REPL starting"
            `(("version" . ,(version-string))
              ("model" . ,(ollama-model))
              ("host" . ,(ollama-host))
              ("workspace" . ,(getcwd))))

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
  (let* ((yolo? (config-get "YOLO_MODE"))
         (ver-str (format #f "guile-sage v~a" (version-string)))
         (box-width 44)
         (pad-len (quotient (- box-width (string-length ver-str)) 2))
         (ver-line (format #f "║~a~a~a║"
                           (make-string pad-len #\space)
                           ver-str
                           (make-string (- box-width pad-len (string-length ver-str)) #\space))))
    (display "\n")
    (display "╔════════════════════════════════════════════╗\n")
    (display ver-line) (newline)
    (display "║   Type /help for commands, /exit to quit   ║\n")
    (display "╚════════════════════════════════════════════╝\n")
    (format #t "Model: ~a~%" (ollama-model))
    (format #t "Host: ~a~%" (ollama-host))
    (when yolo?
      (display "Mode: YOLO (all tools enabled)\n"))
    (when *debug*
      (display "Debug: ON\n"))
    (display "\n"))

  ;; Process initial prompt if provided
  (when initial-prompt
    (format #t "~a~a~%" (make-prompt) initial-prompt)
    (repl-eval initial-prompt))

  ;; Activate readline if available
  (catch #t
    (lambda ()
      (activate-readline))
    (lambda args #f))

  ;; Main loop
  (set! *running* #t)
  (while *running*
    (catch #t
      (lambda ()
        (let ((input (readline (make-prompt))))
          (if (eof-object? input)
              (cmd-exit "")
              (begin
                (add-history input)
                (repl-eval input)))))
      (lambda (key . args)
        (if (eq? key 'quit)
            (set! *running* #f)
            (format #t "Error: ~a~%" key))))))
