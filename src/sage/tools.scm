;;; tools.scm --- Tool registration and execution -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Tool system for guile-sage.
;; Provides tool registration, permission checking, and execution.

(define-module (sage tools)
  #:use-module (sage config)
  #:use-module (sage util)
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
                       "git_log" "glob_files" "search_files"))
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
    (and (not (string-contains path ".."))
         (string-prefix? ws (canonicalize-path-safe expanded))
         (not (regexp-exec (make-regexp "(\\.env|\\.git/|\\.ssh|\\.gnupg)") path)))))

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
    (set! *safe-tools* (cons name *safe-tools*))))

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
            (catch #t
              (lambda ()
                ((assoc-ref tool "execute") args))
              (lambda (key . rest)
                (format #f "Tool error: ~a ~a" key rest)))
            (format #f "Permission denied for tool: ~a" name))
        (format #f "Unknown tool: ~a" name))))

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
                                    ("description" . "Search pattern (regex)")))
                      ("file_pattern" . (("type" . "string")
                                        ("description" . "File glob pattern")))))
     ("required" . #("pattern")))
   (lambda (args)
     (let* ((pattern (assoc-ref args "pattern"))
            (file-pattern (or (assoc-ref args "file_pattern") "*"))
            (cmd (format #f "cd ~a && grep -r '~a' --include='~a' . 2>&1 | head -50"
                         (workspace) pattern file-pattern)))
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
            (cmd (format #f "cd ~a && find . -name '~a' 2>&1 | head -100"
                         (workspace) pattern)))
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
            (cmd (format #f "cd ~a && git add ~a && git commit -m '~a\n\nCo-Authored-By: Claude <noreply@anthropic.com>'"
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
           (format #f "Error creating tool: ~a ~a" key rest)))))))
