;;; tools.scm --- Tool registration and execution -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Tool system for guile-sage.
;; Provides tool registration, permission checking, and execution.

(define-module (sage tools)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (sage agent)
  #:use-module (sage irc)
  #:use-module (sage ollama)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 eval-string)
  #:export (*tools*
            *safe-tools*
            *workspace*
            workspace
            register-tool
            register-safe-tool
            get-tool
            list-tools
            execute-tool
            check-permission
            safe-path?
            init-default-tools
            tools-to-schema))

;;; Tool Registry

(define *tools* '())
(define *safe-tools* '("read_file" "list_files" "git_status" "git_diff"
                       "git_log" "glob_files" "search_files"
                       "write_file" "edit_file"
                       "git_commit" "git_add_note" "git_push"
                       "read_logs" "search_logs"
                       "sage_task_create" "sage_task_complete"
                       "sage_task_list" "sage_task_status"
                       "generate_image"))  ;; Full dev + agent
(define *workspace* #f)

;;; workspace: Get current workspace directory
(define (workspace)
  (or *workspace*
      (config-get "WORKSPACE")
      (config-get "SAGE_WORKSPACE")
      (getcwd)))

;;; set-workspace!: Set workspace directory
(define (set-workspace! path)
  (set! *workspace* path))

;;; safe-path?: Check if path is within workspace
(define (safe-path? path)
  (let ((ws (workspace))
        (expanded (if (string-prefix? "/" path)
                      path
                      (string-append (workspace) "/" path))))
    ;; Allow /tmp for temporary files, otherwise check workspace containment
    (or (string-prefix? "/tmp/" expanded)
        (and (not (string-contains path ".."))
             (string-prefix? ws (canonicalize-path-safe expanded))
             (not (regexp-exec (make-regexp "(\\.env|\\.git/|\\.ssh|\\.gnupg)") path))))))

;;; canonicalize-path-safe: Safe path canonicalization
(define (canonicalize-path-safe path)
  (catch #t
    (lambda () (canonicalize-path path))
    (lambda args path)))

;;; register-tool: Register a new tool
;;; Arguments:
;;;   name - Tool name string
;;;   description - Description string
;;;   parameters - JSON schema for parameters
;;;   execute-fn - Function (args) -> result-string
;;;   safe - Whether tool is safe (default #f)
(define* (register-tool name description parameters execute-fn #:key (safe #f))
  (set! *tools*
        (cons `(("name" . ,name)
                ("description" . ,description)
                ("parameters" . ,parameters)
                ("execute" . ,execute-fn))
              (filter (lambda (t) (not (equal? (assoc-ref t "name") name)))
                      *tools*)))
  (when safe
    (set! *safe-tools* (cons name *safe-tools*)))
  (log-debug "tools" (format #f "Registered tool: ~a" name)
             `(("safe" . ,(if safe "yes" "no")))))

;;; register-safe-tool: Register a safe tool
(define (register-safe-tool name description parameters execute-fn)
  (register-tool name description parameters execute-fn #:safe #t))

;;; get-tool: Get tool by name
(define (get-tool name)
  (find (lambda (t) (equal? (assoc-ref t "name") name)) *tools*))

;;; list-tools: List all registered tools
(define (list-tools)
  (map (lambda (t)
         `((name . ,(assoc-ref t "name"))
           (description . ,(assoc-ref t "description"))
           (safe . ,(member (assoc-ref t "name") *safe-tools*))))
       *tools*))

;;; check-permission: Check if tool execution is allowed
;;; Arguments:
;;;   tool-name - Name of tool
;;;   args - Arguments to tool
;;; Returns: #t if allowed
(define (check-permission tool-name args)
  (or (member tool-name *safe-tools*)
      (config-get "YOLO_MODE")
      ;; In non-interactive mode, deny unsafe tools by default
      #f))

;;; execute-tool: Execute a tool by name
;;; Arguments:
;;;   name - Tool name
;;;   args - Alist of arguments
;;; Returns: Result string or error
(define (execute-tool name args)
  (let ((tool (get-tool name)))
    (if tool
        (if (check-permission name args)
            (begin
              (log-tool-call name args)
              (let ((start-time (get-internal-real-time)))
                (catch #t
                  (lambda ()
                    (let* ((result ((assoc-ref tool "execute") args))
                           (end-time (get-internal-real-time))
                           (duration-ms (/ (- end-time start-time)
                                           (/ internal-time-units-per-second 1000))))
                      (log-tool-call name args #:result result #:duration duration-ms)
                      result))
                  (lambda (key . rest)
                    (log-error "tools" (format #f "Tool execution failed: ~a" name)
                               `(("error" . ,(format #f "~a ~a" key rest))))
                    (format #f "Tool error: ~a ~a" key rest)))))
            (begin
              (log-warn "tools" (format #f "Permission denied: ~a" name)
                        `(("tool" . ,name)))
              (format #f "Permission denied for tool: ~a" name)))
        (begin
          (log-warn "tools" (format #f "Unknown tool: ~a" name))
          (format #f "Unknown tool: ~a" name)))))

;;; tools-to-schema: Convert tools to JSON schema for LLM
(define (tools-to-schema)
  (map (lambda (t)
         `(("name" . ,(assoc-ref t "name"))
           ("description" . ,(assoc-ref t "description"))
           ("parameters" . ,(assoc-ref t "parameters"))))
       *tools*))

;;; ============================================================
;;; Built-in Tools
;;; ============================================================

(define (init-default-tools)
  ;; read_file
  (register-tool
   "read_file"
   "Read contents of a file within workspace"
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "File path relative to workspace")))))
     ("required" . #("path")))
   (lambda (args)
     (let ((path (assoc-ref args "path")))
       (if (safe-path? path)
           (let ((full-path (string-append (workspace) "/" path)))
             (if (file-exists? full-path)
                 (call-with-input-file full-path get-string-all)
                 (format #f "File not found: ~a" path)))
           (format #f "Unsafe path: ~a" path)))))

  ;; list_files
  (register-tool
   "list_files"
   "List files in a directory within workspace"
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "Directory path relative to workspace")))
                      ("pattern" . (("type" . "string")
                                   ("description" . "Optional glob pattern")))))
     ("required" . #("path")))
   (lambda (args)
     (let ((path (or (assoc-ref args "path") "."))
           (pattern (or (assoc-ref args "pattern") "*")))
       (if (safe-path? path)
           (let ((full-path (string-append (workspace) "/" path)))
             (if (file-exists? full-path)
                 (string-join
                  (scandir full-path
                           (lambda (f) (not (string-prefix? "." f))))
                  "\n")
                 (format #f "Directory not found: ~a" path)))
           (format #f "Unsafe path: ~a" path)))))

  ;; write_file
  (register-tool
   "write_file"
   "Write content to a file within workspace"
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "File path relative to workspace")))
                      ("content" . (("type" . "string")
                                   ("description" . "Content to write")))))
     ("required" . #("path" "content")))
   (lambda (args)
     (let ((path (assoc-ref args "path"))
           (content (assoc-ref args "content")))
       (if (safe-path? path)
           (let ((full-path (string-append (workspace) "/" path)))
             (call-with-output-file full-path
               (lambda (port) (display content port)))
             (format #f "Wrote ~a bytes to ~a" (string-length content) path))
           (format #f "Unsafe path: ~a" path)))))

  ;; git_status
  (register-tool
   "git_status"
   "Get git status of workspace"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (let ((cmd (format #f "cd ~a && git status --porcelain 2>&1" (workspace))))
       (let* ((tmp (format #f "/tmp/sage-git-~a" (getpid))))
         (system (string-append cmd " > " tmp))
         (let ((result (call-with-input-file tmp get-string-all)))
           (delete-file tmp)
           result)))))

  ;; git_diff
  (register-tool
   "git_diff"
   "Get git diff of workspace"
   '(("type" . "object")
     ("properties" . (("staged" . (("type" . "boolean")
                                   ("description" . "Show staged changes only")))))
     ("required" . #()))
   (lambda (args)
     (let* ((staged (assoc-ref args "staged"))
            (cmd (format #f "cd ~a && git diff ~a 2>&1"
                         (workspace)
                         (if staged "--staged" ""))))
       (let* ((tmp (format #f "/tmp/sage-git-~a" (getpid))))
         (system (string-append cmd " > " tmp))
         (let ((result (call-with-input-file tmp get-string-all)))
           (delete-file tmp)
           result)))))

  ;; git_log
  (register-tool
   "git_log"
   "Get git log of workspace"
   '(("type" . "object")
     ("properties" . (("count" . (("type" . "integer")
                                  ("description" . "Number of commits to show")))))
     ("required" . #()))
   (lambda (args)
     (let* ((count (or (assoc-ref args "count") 10))
            (cmd (format #f "cd ~a && git log --oneline -n ~a 2>&1"
                         (workspace) count)))
       (let* ((tmp (format #f "/tmp/sage-git-~a" (getpid))))
         (system (string-append cmd " > " tmp))
         (let ((result (call-with-input-file tmp get-string-all)))
           (delete-file tmp)
           result)))))

  ;; search_files
  (register-tool
   "search_files"
   "Search for pattern in files"
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Search pattern (literal string)")))
                      ("file_pattern" . (("type" . "string")
                                        ("description" . "File glob pattern")))
                      ("regex" . (("type" . "boolean")
                                  ("description" . "Treat pattern as regex (default: false)")))))
     ("required" . #("pattern")))
   (lambda (args)
     (let* ((pattern (assoc-ref args "pattern"))
            (file-pattern (or (assoc-ref args "file_pattern") "*"))
            (use-regex (assoc-ref args "regex"))
            ;; Use -F for fixed strings by default to avoid escaping issues
            (grep-flag (if use-regex "-r" "-rF"))
            (cmd (format #f "cd ~a && grep ~a '~a' --include='~a' . 2>&1 | head -50"
                         (workspace) grep-flag pattern file-pattern)))
       (let* ((tmp (format #f "/tmp/sage-grep-~a" (getpid))))
         (system (string-append cmd " > " tmp))
         (let ((result (call-with-input-file tmp get-string-all)))
           (delete-file tmp)
           result)))))

  ;; glob_files
  (register-tool
   "glob_files"
   "Find files matching glob pattern"
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Glob pattern (e.g. **/*.scm)")))))
     ("required" . #("pattern")))
   (lambda (args)
     (let* ((pattern (assoc-ref args "pattern"))
            ;; Split pattern into directory and filename parts for find
            ;; This fixes issues where patterns like "src/*.scm" fail
            (dir-part (dirname pattern))
            (name-part (basename pattern))
            (search-path (if (equal? dir-part ".") "." dir-part))
            (cmd (format #f "cd ~a && find ~a -name '~a' 2>&1 | head -100"
                         (workspace) search-path name-part)))
       (let* ((tmp (format #f "/tmp/sage-find-~a" (getpid))))
         (system (string-append cmd " > " tmp))
         (let ((result (call-with-input-file tmp get-string-all)))
           (delete-file tmp)
           result)))))

  ;; ============================================================
  ;; Self-Modification Tools
  ;; ============================================================

  ;; edit_file - Edit existing files with search/replace
  (register-tool
   "edit_file"
   "Edit a file by replacing text (search and replace)"
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "File path relative to workspace")))
                      ("search" . (("type" . "string")
                                   ("description" . "Text to search for")))
                      ("replace" . (("type" . "string")
                                    ("description" . "Text to replace with")))))
     ("required" . #("path" "search" "replace")))
   (lambda (args)
     (let ((path (assoc-ref args "path"))
           (search (assoc-ref args "search"))
           (replace (assoc-ref args "replace")))
       (if (safe-path? path)
           (let ((full-path (string-append (workspace) "/" path)))
             (if (file-exists? full-path)
                 (let* ((content (call-with-input-file full-path get-string-all))
                        (new-content (string-replace-substring content search replace)))
                   (if (equal? content new-content)
                       (format #f "No match found for search text in ~a" path)
                       (begin
                         (call-with-output-file full-path
                           (lambda (port) (display new-content port)))
                         (format #f "Replaced text in ~a" path))))
                 (format #f "File not found: ~a" path)))
           (format #f "Unsafe path: ~a" path)))))

  ;; run_tests - Execute test suite
  (register-tool
   "run_tests"
   "Run the test suite"
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Test file pattern (default: test-*.scm)")))))
     ("required" . #()))
   (lambda (args)
     (let* ((pattern (or (assoc-ref args "pattern") "test-*.scm"))
            (cmd (format #f "cd ~a && for test in tests/~a; do guile3 -L src $test 2>&1; done"
                         (workspace) pattern))
            (tmp (format #f "/tmp/sage-test-~a" (getpid))))
       (system (string-append cmd " > " tmp " 2>&1"))
       (let ((result (call-with-input-file tmp get-string-all)))
         (delete-file tmp)
         result))))

  ;; git_commit - Make atomic commits
  (register-tool
   "git_commit"
   "Stage files and create a git commit"
   '(("type" . "object")
     ("properties" . (("files" . (("type" . "array")
                                  ("items" . (("type" . "string")))
                                  ("description" . "Files to stage")))
                      ("message" . (("type" . "string")
                                    ("description" . "Commit message")))))
     ("required" . #("files" "message")))
   (lambda (args)
     (let* ((files (assoc-ref args "files"))
            (message (assoc-ref args "message"))
            (file-list (if (list? files)
                           (string-join files " ")
                           files))
            (tmp (format #f "/tmp/sage-commit-~a" (getpid)))
            (cmd (format #f "cd ~a && git add ~a && git commit -m '~a\n\nCo-Authored-By: Sage <sage@host.lan>'"
                         (workspace) file-list message)))
       (system (string-append cmd " > " tmp " 2>&1"))
       (let ((result (call-with-input-file tmp get-string-all)))
         (delete-file tmp)
         result))))

  ;; git_add_note - Add git notes for documentation
  (register-tool
   "git_add_note"
   "Add a git note to the current HEAD commit"
   '(("type" . "object")
     ("properties" . (("message" . (("type" . "string")
                                    ("description" . "Note message")))))
     ("required" . #("message")))
   (lambda (args)
     (let* ((message (assoc-ref args "message"))
            (tmp (format #f "/tmp/sage-note-~a" (getpid)))
            (cmd (format #f "cd ~a && git notes add -f -m '~a'"
                         (workspace) message)))
       (system (string-append cmd " > " tmp " 2>&1"))
       (let ((result (call-with-input-file tmp get-string-all)))
         (delete-file tmp)
         (if (string-null? (string-trim-both result))
             "Note added successfully"
             result)))))

  ;; git_push - Push commits to remote
  (register-tool
   "git_push"
   "Push commits to the remote repository"
   '(("type" . "object")
     ("properties" . (("remote" . (("type" . "string")
                                   ("description" . "Remote name (default: origin)")))
                      ("branch" . (("type" . "string")
                                   ("description" . "Branch to push (default: current branch)")))))
     ("required" . #()))
   (lambda (args)
     (let* ((remote (or (assoc-ref args "remote") "origin"))
            (branch (assoc-ref args "branch"))
            (tmp (format #f "/tmp/sage-push-~a" (getpid)))
            (cmd (if branch
                     (format #f "cd ~a && git push ~a ~a"
                             (workspace) remote branch)
                     (format #f "cd ~a && git push ~a"
                             (workspace) remote))))
       (system (string-append cmd " > " tmp " 2>&1"))
       (let ((result (call-with-input-file tmp get-string-all)))
         (delete-file tmp)
         (if (string-null? (string-trim-both result))
             "Push completed (no output)"
             result)))))

  ;; eval_scheme - Evaluate scheme code dynamically
  (register-tool
   "eval_scheme"
   "Evaluate Scheme code and return result"
   '(("type" . "object")
     ("properties" . (("code" . (("type" . "string")
                                 ("description" . "Scheme code to evaluate")))))
     ("required" . #("code")))
   (lambda (args)
     (let ((code (assoc-ref args "code")))
       (catch #t
         (lambda ()
           (let ((result (eval-string code)))
             (format #f "~s" result)))
         (lambda (key . rest)
           (format #f "Evaluation error: ~a ~a" key rest))))))

  ;; reload_module - Reload a guile module
  (register-tool
   "reload_module"
   "Reload a Guile module to pick up changes"
   '(("type" . "object")
     ("properties" . (("module" . (("type" . "string")
                                   ("description" . "Module name (e.g. sage tools)")))))
     ("required" . #("module")))
   (lambda (args)
     (let ((module-str (assoc-ref args "module")))
       (catch #t
         (lambda ()
           (let* ((module-name (map string->symbol (string-split module-str #\space)))
                  (mod (resolve-module module-name)))
             (reload-module mod)
             (format #f "Reloaded module: ~a" module-name)))
         (lambda (key . rest)
           (format #f "Reload error: ~a ~a" key rest))))))

  ;; create_tool - Dynamically register a new tool
  (register-tool
   "create_tool"
   "Create and register a new tool dynamically"
   '(("type" . "object")
     ("properties" . (("name" . (("type" . "string")
                                 ("description" . "Tool name")))
                      ("description" . (("type" . "string")
                                        ("description" . "Tool description")))
                      ("code" . (("type" . "string")
                                 ("description" . "Scheme code for tool execution function (lambda (args) ...)")))))
     ("required" . #("name" "description" "code")))
   (lambda (args)
     (let ((name (assoc-ref args "name"))
           (desc (assoc-ref args "description"))
           (code (assoc-ref args "code")))
       (catch #t
         (lambda ()
           (let ((fn (eval-string code)))
             (register-tool name desc
                           '(("type" . "object")
                             ("properties" . ())
                             ("required" . #()))
                           fn)
             (format #f "Created tool: ~a" name)))
         (lambda (key . rest)
           (format #f "Error creating tool: ~a ~a" key rest))))))

  ;; ============================================================
  ;; Self-Inspection Tools (Logging)
  ;; ============================================================

  ;; read_logs - Read recent log entries
  (register-tool
   "read_logs"
   "Read recent log entries for self-inspection and debugging"
   '(("type" . "object")
     ("properties" . (("lines" . (("type" . "integer")
                                  ("description" . "Number of lines to read (default 50)")))
                      ("level" . (("type" . "string")
                                  ("description" . "Filter by level: debug|info|warn|error")))))
     ("required" . #()))
   (lambda (args)
     (let ((lines (or (assoc-ref args "lines") 50))
           (level (assoc-ref args "level")))
       (read-recent-logs #:lines lines
                         #:level (and level (string->symbol level))))))

  ;; search_logs - Search logs for pattern
  (register-tool
   "search_logs"
   "Search logs for a pattern to diagnose issues"
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Search pattern (case-insensitive)")))
                      ("level" . (("type" . "string")
                                  ("description" . "Filter by level: debug|info|warn|error")))
                      ("limit" . (("type" . "integer")
                                  ("description" . "Max results (default 100)")))))
     ("required" . #("pattern")))
   (lambda (args)
     (let ((pattern (assoc-ref args "pattern"))
           (level (assoc-ref args "level"))
           (limit (or (assoc-ref args "limit") 100)))
       (search-logs pattern
                    #:level (and level (string->symbol level))
                    #:limit limit))))

  ;; ============================================================
  ;; Agent Task Tools
  ;; ============================================================

  ;; sage_task_create - Create a task for the agent
  (register-tool
   "sage_task_create"
   "Create a task for the sage agent to work on. Use this to break down complex requests into manageable steps."
   '(("type" . "object")
     ("properties" . (("title" . (("type" . "string")
                                  ("description" . "Brief task title")))
                      ("description" . (("type" . "string")
                                        ("description" . "Detailed task description")))))
     ("required" . #("title" "description")))
   (lambda (args)
     (let ((title (assoc-ref args "title"))
           (desc (assoc-ref args "description")))
       (let ((id (task-create title desc)))
         (if id
             (format #f "Task created: ~a - ~a" id title)
             "Failed to create task (is beads available?)")))))

  ;; sage_task_complete - Mark current task complete
  (register-tool
   "sage_task_complete"
   "Mark the current task as complete with a result note"
   '(("type" . "object")
     ("properties" . (("result" . (("type" . "string")
                                   ("description" . "Result or completion note")))))
     ("required" . #("result")))
   (lambda (args)
     (let ((result (assoc-ref args "result")))
       (let ((id (task-complete result)))
         (if id
             (format #f "Task completed: ~a" id)
             "No current task to complete")))))

  ;; sage_task_list - List pending tasks
  (register-tool
   "sage_task_list"
   "List all pending sage agent tasks"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (let ((tasks (task-list)))
       (if (null? tasks)
           "No pending tasks"
           (string-join
            (map (lambda (t)
                   (format #f "~a: ~a" (car t) (cdr t)))
                 tasks)
            "\n")))))

  ;; sage_task_status - Get agent status
  (register-tool
   "sage_task_status"
   "Get current agent status including mode, tasks, and iteration count"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (format-task-status)))

  ;; ============================================================
  ;; Identity Tools
  ;; ============================================================

  ;; whoami - Agent identity introspection
  (register-safe-tool
   "whoami"
   "Return agent identity and capabilities for self-awareness"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (string-append
      "Name: Sage\n"
      "System: guile-sage (Guile Scheme AI agent framework)\n"
      "Role: Autonomous software engineering agent\n"
      "Contact: sage@host.lan\n"
      "IRC: SageNet (#sage-agents, #sage-tasks, #sage-debug)\n"
      "Workspace: " (workspace) "\n"
      "Tools: " (number->string (length *tools*)) " registered\n"
      "Mode: " (symbol->string (agent-mode)))))

  ;; irc_send - Send message to IRC channel
  (register-safe-tool
   "irc_send"
   "Send a message to an IRC channel on SageNet"
   '(("type" . "object")
     ("properties" . (("channel" . (("type" . "string")
                                    ("description" . "Channel name (e.g. #sage-agents)")))
                      ("message" . (("type" . "string")
                                    ("description" . "Message to send")))))
     ("required" . #("channel" "message")))
   (lambda (args)
     (let ((channel (assoc-ref args "channel"))
           (message (assoc-ref args "message")))
       (if (not (irc-connected?))
           "Not connected to IRC. Use SAGE_IRC_ENABLED=1 to enable."
           (begin
             (irc-send channel message)
             (format #f "Sent to ~a: ~a" channel message))))))

  ;; ============================================================
  ;; Image Generation Tools
  ;; ============================================================

  ;; generate_image - Generate image via Ollama
  (register-safe-tool
   "generate_image"
   "Generate an image from a text prompt using Ollama image model"
   '(("type" . "object")
     ("properties" . (("prompt" . (("type" . "string")
                                   ("description" . "Text description of the image to generate")))
                      ("filename" . (("type" . "string")
                                     ("description" . "Output filename without extension (defaults to timestamp)")))))
     ("required" . #("prompt")))
   (lambda (args)
     (let* ((prompt (assoc-ref args "prompt"))
            (filename (or (assoc-ref args "filename")
                          (format #f "image-~a" (car (gettimeofday)))))
            (output-dir (string-append (workspace) "/output"))
            (output-path (string-append output-dir "/" filename ".png")))
       ;; Ensure output directory exists
       (unless (file-exists? output-dir)
         (mkdir output-dir))
       (catch #t
         (lambda ()
           (ollama-generate-image prompt output-path)
           (format #f "Saved to output/~a.png" filename))
         (lambda (key . rest)
           (format #f "Image generation error: ~a ~a" key rest)))))))
