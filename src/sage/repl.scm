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
  #:use-module (sage context)
  #:use-module (sage compaction)
  #:use-module (sage model-tier)
  #:use-module (sage status)
  #:use-module (sage commands)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
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
(define *streaming* (not (equal? "0" (or (getenv "SAGE_STREAMING") ""))))
(define *available-tiers* '())

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
  (display "  /tier           - Show model tier status\n")
  (display "  /stream         - Toggle streaming mode\n")
  (display "  /doctor         - Check dependencies and connections\n")
  (display "  /reload         - Hot-reload sage modules\n")
  (display "  /logs [n] [lvl] - Show recent log entries\n")
  (display "\nCustom commands:\n")
  (display "  /commands       - List all commands (built-in + custom)\n")
  (display "  /define-command - Define custom command: /define-command <name> <expr>\n")
  (display "  /undefine-command - Remove custom command\n")
  (display "\nAgent commands:\n")
  (display "  /agent [mode]   - Show/set agent mode (interactive|autonomous|yolo)\n")
  (display "  /tasks          - List pending agent tasks\n")
  (display "  /pause          - Pause agent loop\n")
  (display "  /continue       - Continue agent loop\n")
  (display "  /prefetch       - Show/reload SAGE.md context\n")
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
  ;; Reset context warnings after clearing session
  (reset-fired-thresholds!)
  #t)

(define (cmd-status args)
  (display (format-session-status))
  (newline)
  ;; Show context window usage
  (let ((model (and *session* (assoc-ref *session* "model"))))
    (display (context-window-status model))
    (newline))
  #t)

(define (cmd-compact args)
  (let ((keep (if (and args (not (string-null? args)))
                  (string->number args)
                  5)))
    (display (session-compact! #:keep-recent keep #:summarize #t))
    (newline)
    ;; Reset context warnings so they can re-fire if usage grows again
    (reset-fired-thresholds!))
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

(define (cmd-stream args)
  (set! *streaming* (not *streaming*))
  (format #t "Streaming: ~a~%" (if *streaming* "ON" "OFF"))
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

(define (cmd-prefetch args)
  "Show or reload SAGE.md context."
  (if (string=? (string-trim-both args) "reload")
      (begin
        (load-agents-context)
        (display "SAGE.md reloaded.\n"))
      (display (context-status)))
  (newline)
  #t)

(define (cmd-tier args)
  "Show current model tier, thresholds, and available models."
  (let* ((tokens (session-total-tokens))
         (current-tier (resolve-model-for-tokens tokens *available-tiers*)))
    (format #t "Current tokens: ~a~%" tokens)
    (format #t "Active tier: ~a (~a)~%"
            (tier-name current-tier) (tier-model current-tier))
    (format #t "Context limit: ~a~%"
            (tier-context-limit current-tier))
    (format #t "Tool calling: ~a~%~%"
            (if (tier-supports-tools? current-tier) "yes" "no"))
    (display "Available tiers:\n")
    (for-each
     (lambda (tier)
       (format #t "  ~a: ~a (ceiling: ~a, context: ~a, tools: ~a)~a~%"
               (tier-name tier)
               (tier-model tier)
               (tier-ceiling tier)
               (tier-context-limit tier)
               (if (tier-supports-tools? tier) "yes" "no")
               (if (equal? (tier-name tier) (tier-name current-tier))
                   " <-- active"
                   "")))
     *available-tiers*))
  #t)

(define (cmd-doctor args)
  "Check core dependencies and connections."
  (define (check label thunk)
    (catch #t
      (lambda ()
        (let ((result (thunk)))
          (if result
              (format #t "  ✓ ~a: ~a~%" label result)
              (format #t "  ✗ ~a: FAIL~%" label))
          result))
      (lambda (key . err)
        (format #t "  ✗ ~a: ~a~%" label key)
        #f)))

  (let ((host (ollama-host))
        (model (ollama-model))
        (pass-count 0)
        (fail-count 0))

    (display "=== sage doctor ===\n\n")

    ;; Config
    (display "Config:\n")
    (check "SAGE_OLLAMA_HOST" (lambda () host))
    (check "SAGE_MODEL" (lambda () model))
    (check ".env loaded" (lambda ()
      (if (config-get "OLLAMA_HOST") "yes" "no .env (using defaults)")))
    (check "workspace" (lambda () (workspace)))

    ;; Connectivity
    (display "\nConnectivity:\n")
    (let ((reachable (check "Ollama API" (lambda ()
            (let* ((url (string-append host "/api/tags"))
                   (result (http-get url))
                   (code (if (pair? result) (car result) 0)))
              (if (= code 200) "reachable" #f))))))
      (when reachable
        ;; Models
        (display "\nModels:\n")
        (catch #t
          (lambda ()
            (let ((models (ollama-list-models)))
              (for-each
               (lambda (m)
                 (let ((name (assoc-ref m "name")))
                   (format #t "  ~a ~a~%"
                           (if (equal? name model) "→" " ")
                           name)))
               models)
              (format #t "  (~a models available)~%" (length models))))
          (lambda (key . err)
            (format #t "  ✗ Could not list models~%")))))

    ;; Tiers
    (display "\nModel tiers:\n")
    (if (null? *available-tiers*)
        (display "  ✗ No tiers configured\n")
        (for-each
         (lambda (tier)
           (format #t "  ~a: ~a (ceiling: ~a)~%"
                   (tier-name tier) (tier-model tier) (tier-ceiling tier)))
         *available-tiers*))

    ;; Filesystem
    (display "\nFilesystem:\n")
    (check "log dir" (lambda ()
      (let ((dir (string-append (workspace) "/.logs")))
        (if (file-exists? dir) dir #f))))
    (check "session dir" (lambda ()
      (let ((dir (session-dir)))
        (if (file-exists? dir) dir "not yet created"))))
    (check "SAGE.md" (lambda ()
      (let ((path (string-append (getcwd) "/SAGE.md")))
        (if (file-exists? path)
            (format #f "~a chars" (stat:size (stat path)))
            "not found"))))

    ;; Tools
    (display "\nTools:\n")
    (check "registered tools" (lambda ()
      (let ((tools (tools-to-schema)))
        (format #f "~a tools" (length tools)))))

    (display "\n=== done ===\n"))
  #t)

;;; Custom Command Handlers

(define (cmd-define-command args)
  "Define a custom slash command: /define-command <name> <scheme-expr>"
  (let* ((trimmed (string-trim-both args))
         (space (string-index trimmed #\space)))
    (if space
        (let ((name (substring trimmed 0 space))
              (expr (string-trim-both (substring trimmed space))))
          (define-custom-command! name expr)
          (format #t "Defined custom command: /~a~%" name))
        (display "Usage: /define-command <name> <scheme-expression>\n")))
  #t)

(define (cmd-undefine-command args)
  "Remove a custom slash command: /undefine-command <name>"
  (let ((name (string-trim-both args)))
    (if (string-null? name)
        (display "Usage: /undefine-command <name>\n")
        (if (undefine-custom-command! name)
            (format #t "Removed custom command: /~a~%" name)
            (format #t "No custom command named: /~a~%" name))))
  #t)

(define (cmd-commands args)
  "List all commands (built-in + custom)."
  (display "Built-in commands:\n")
  (for-each
   (lambda (cmd-pair)
     (format #t "  ~a~%" (car cmd-pair)))
   *commands*)
  (let ((custom (list-custom-commands)))
    (if (null? custom)
        (display "\nNo custom commands defined.\n")
        (begin
          (display "\nCustom commands:\n")
          (for-each
           (lambda (pair)
             (format #t "  /~a => ~a~%" (car pair) (cdr pair)))
           custom))))
  #t)

;;; Slash Commands (defined after all cmd-* functions to avoid forward references)

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
    ("/stream"    . ,cmd-stream)
    ("/version"   . ,cmd-version)
    ("/reload"    . ,cmd-reload)
    ("/refresh"   . ,cmd-reload)
    ("/logs"      . ,cmd-logs)
    ("/agent"     . ,cmd-agent)
    ("/tasks"     . ,cmd-tasks)
    ("/pause"     . ,cmd-pause)
    ("/continue"  . ,cmd-continue)
    ("/prefetch"  . ,cmd-prefetch)
    ("/tier"      . ,cmd-tier)
    ("/tiers"     . ,cmd-tier)
    ("/doctor"    . ,cmd-doctor)
    ("/define-command"   . ,cmd-define-command)
    ("/undefine-command" . ,cmd-undefine-command)
    ("/commands"  . ,cmd-commands)))

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
              ;; Try custom commands (strip leading /)
              (let* ((custom-name (substring cmd 1))
                     (custom-expr (get-custom-command custom-name)))
                (if custom-expr
                    (begin
                      (log-debug "repl" (format #f "Custom command: ~a" cmd))
                      (let ((result (execute-custom-command custom-name)))
                        (when (string? result)
                          (display result)
                          (newline)))
                      #t)
                    (begin
                      (log-warn "repl" "Unknown command" `(("cmd" . ,cmd)))
                      (format #t "Unknown command: ~a~%" cmd)
                      (display "Type /help for available commands.\n")
                      #t))))))
      #f))

;;; Chat Handler

(define (handle-chat input)
  "Process a chat message and get response from Ollama."
  ;; Add user message to session
  (session-add-message "user" input)

  ;; Resolve model tier based on current token count
  ;; Only switch to tiers that support tool calling (REPL always uses tools)
  (let* ((tokens (session-total-tokens))
         (tier (resolve-model-for-tokens tokens *available-tiers*))
         (current-model (if *session*
                            (or (assoc-ref *session* "model") (ollama-model))
                            (ollama-model)))
         (tier-model-name (if (tier-supports-tools? tier)
                              (tier-model tier)
                              current-model)))

    ;; Switch model if tier changed and tier supports tools
    (when (and (not (equal? tier-model-name current-model))
               (tier-supports-tools? tier))
      (format #t "\x1b[2m[model: ~a -> ~a (~a tier, ~a tokens)]\x1b[0m~%"
              current-model tier-model-name (tier-name tier) tokens)
      (when *session*
        (set! *session*
              (cons (cons "model" tier-model-name)
                    (filter (lambda (p) (not (equal? (car p) "model")))
                            *session*)))))

    ;; Auto-compact if approaching context limit
    (let ((compact-result (session-maybe-compact!
                           (tier-context-limit tier)
                           compact-auto
                           message-tokens)))
      (when compact-result
        (format #t "\x1b[2m[~a]\x1b[0m~%" compact-result))

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

    ;; Call Ollama - streaming or non-streaming
    (catch #t
      (lambda ()
        (if *streaming*
            ;; --- Streaming path ---
            (let ((start-time (current-time)))
              (status-stream-start model)
              (let* ((response (ollama-chat-streaming
                                model messages
                                status-stream-token
                                #:tools tools))
                     (elapsed (- (time-second (current-time))
                                 (time-second start-time)))
                     (message (assoc-ref response "message"))
                     (content (or (assoc-ref message "content") ""))
                     (usage (ollama-extract-token-usage response))
                     (prompt-tokens (assoc-ref usage 'prompt_tokens))
                     (completion-tokens (assoc-ref usage 'completion_tokens)))

                (status-stream-end completion-tokens elapsed)
                (debug-tokens prompt-tokens completion-tokens)

                ;; Check for tool calls in streamed response
                (let ((tool-call (ollama-parse-tool-call message)))
                  (if tool-call
                      ;; Tool call found -- execute and do non-streaming follow-up
                      (let* ((tool-name (assoc-ref tool-call "name"))
                             (tool-args (assoc-ref tool-call "arguments"))
                             (result (execute-tool tool-name tool-args)))
                        (when *debug*
                          (format #t "[DEBUG] Tool: ~a~%" tool-name)
                          (format #t "[DEBUG] Args: ~a~%" tool-args))

                        (session-add-message "assistant" content
                                             #:tokens completion-tokens
                                             #:tool-call #t)

                        (format #t "~%[Tool: ~a]~%" tool-name)
                        (format #t "~a~%" result)

                        (session-add-message "user"
                                            (format #f "Tool result for ~a:\n~a"
                                                    tool-name result))

                        ;; Non-streaming follow-up after tool execution
                        (let* ((follow-up (ollama-chat model (session-get-context)))
                               (follow-msg (assoc-ref follow-up "message"))
                               (follow-content (assoc-ref follow-msg "content"))
                               (follow-usage (ollama-extract-token-usage follow-up))
                               (follow-completion (assoc-ref follow-usage 'completion_tokens)))
                          (debug-tokens (assoc-ref follow-usage 'prompt_tokens)
                                        follow-completion)
                          (session-add-message "assistant" follow-content
                                               #:tokens follow-completion)
                          (format #t "~%~a~%" follow-content)))

                      ;; No tool call -- content already displayed via streaming
                      (session-add-message "assistant" content
                                           #:tokens completion-tokens)))))

            ;; --- Non-streaming path (existing behavior) ---
            (let* ((response (ollama-chat-with-tools model messages tools))
                   (message (assoc-ref response "message"))
                   (content (or (assoc-ref message "content") ""))
                   (usage (ollama-extract-token-usage response))
                   (prompt-tokens (assoc-ref usage 'prompt_tokens))
                   (completion-tokens (assoc-ref usage 'completion_tokens)))

              (debug-tokens prompt-tokens completion-tokens)

              (let ((tool-call (ollama-parse-tool-call message)))
                (if tool-call
                    (begin
                      (let* ((tool-name (assoc-ref tool-call "name"))
                             (tool-args (assoc-ref tool-call "arguments"))
                             (result (execute-tool tool-name tool-args)))
                        (when *debug*
                          (format #t "[DEBUG] Tool: ~a~%" tool-name)
                          (format #t "[DEBUG] Args: ~a~%" tool-args))

                        (session-add-message "assistant" content
                                             #:tokens completion-tokens
                                             #:tool-call #t)

                        (format #t "~a~%" content)
                        (format #t "~%[Tool: ~a]~%" tool-name)
                        (format #t "~a~%" result)

                        (session-add-message "user"
                                            (format #f "Tool result for ~a:\n~a"
                                                    tool-name result))

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

                    (begin
                      (session-add-message "assistant" content
                                           #:tokens completion-tokens)
                      (format #t "~a~%" content)))))))

      (lambda (key . args)
        (format #t "Error: ~a ~a~%" key args)))

    ;; Check context window thresholds after response
    (let ((warning-text (context-format-warnings
                          (if *session*
                              (assoc-ref *session* "model")
                              #f))))
      (unless (string-null? warning-text)
        (display warning-text)
        (newline)))))))

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

  ;; Load custom commands
  (let ((n (load-custom-commands!)))
    (when (> n 0)
      (log-info "repl" (format #f "Loaded ~a custom command~a" n
                                (if (= n 1) "" "s")))))

  ;; Probe available models and configure tiers
  (catch #t
    (lambda ()
      (let* ((models (ollama-list-models))
             (model-names (map (lambda (m) (assoc-ref m "name")) models)))
        (set! *available-tiers* (load-model-tiers model-names))
        (log-info "repl" "Model tiers loaded"
                  `(("tiers" . ,(length *available-tiers*))
                    ("models" . ,(length models))))))
    (lambda (key . args)
      (set! *available-tiers* *model-tiers*)
      (log-warn "repl" "Failed to probe models, using defaults"
                `(("error" . ,(format #f "~a" key))))))

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

  ;; Load SAGE.md into session context
  (load-agents-context)

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
