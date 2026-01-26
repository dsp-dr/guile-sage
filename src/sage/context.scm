;;; context.scm --- Context preloading for sage -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Loads project context files (AGENTS.md, etc.) into the session.
;; Files are loaded on startup and added as system messages.

(define-module (sage context)
  #:use-module (sage config)
  #:use-module (sage logging)
  #:use-module (sage session)
  #:use-module (sage util)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 format)
  #:export (*context-files*
            load-context-files
            prefetch-context
            context-status))

;;; Context Files to Load

;; List of files to automatically load into context on startup
;; Paths are relative to workspace root
(define *context-files*
  '("AGENTS.md"
    "CLAUDE.md"
    "CONTRIBUTING.org"
    ".claude/settings.json"))

;; Loaded context cache
(define *loaded-context* '())
(define *loaded-tasks* '())

;;; file-exists-in-workspace?: Check if file exists in workspace
(define (file-exists-in-workspace? filename)
  "Check if filename exists relative to workspace."
  (let ((path (string-append (workspace-or-cwd) "/" filename)))
    (file-exists? path)))

;;; workspace-or-cwd: Get workspace or current directory
(define (workspace-or-cwd)
  (or (config-get "WORKSPACE")
      (config-get "SAGE_WORKSPACE")
      (getcwd)))

;;; read-context-file: Read a context file
(define (read-context-file filename)
  "Read file content from workspace. Returns content string or #f."
  (let ((path (string-append (workspace-or-cwd) "/" filename)))
    (if (file-exists? path)
        (catch #t
          (lambda ()
            (call-with-input-file path get-string-all))
          (lambda (key . args)
            (log-warn "context" "Failed to read file"
                      `(("file" . ,filename)
                        ("error" . ,(format #f "~a" key))))
            #f))
        #f)))

;;; load-context-files: Load all context files into session
(define (load-context-files)
  "Load context files and add to session as system message."
  (set! *loaded-context* '())
  (let ((loaded-content '()))
    ;; Try to load each context file
    (for-each
     (lambda (filename)
       (let ((content (read-context-file filename)))
         (when content
           (log-info "context" "Loaded context file" `(("file" . ,filename)))
           (set! *loaded-context* (cons filename *loaded-context*))
           (set! loaded-content
                 (cons (format #f "=== ~a ===\n~a\n" filename content)
                       loaded-content)))))
     *context-files*)

    ;; Try to load beads tasks
    (let ((tasks-content (load-beads-tasks)))
      (when tasks-content
        (set! loaded-content (cons tasks-content loaded-content))))

    ;; Add combined context as system message if anything loaded
    (when (not (null? loaded-content))
      (let ((combined (string-join (reverse loaded-content) "\n")))
        (session-add-message "system"
                             (string-append
                              "Project context loaded on startup:\n\n"
                              combined))
        (log-info "context" "Context added to session"
                  `(("files" . ,(length *loaded-context*))
                    ("tasks" . ,(length *loaded-tasks*))
                    ("chars" . ,(string-length combined))))))))

;;; prefetch-context: Alias for load-context-files
(define (prefetch-context)
  "Prefetch context files into session. Alias for load-context-files."
  (load-context-files))

;;; load-beads-tasks: Load open tasks from beads
;;; Note: Currently disabled due to segfault issues with pipes
(define (load-beads-tasks)
  "Load open tasks from beads and return formatted string."
  ;; Temporarily disabled - pipe handling causing segfaults
  #f)

;;; context-status: Show what context files are loaded
(define (context-status)
  "Return status of loaded context files."
  (string-append
   (if (null? *loaded-context*)
       "No context files loaded.\n"
       (string-append
        "Loaded context files:\n"
        (string-join
         (map (lambda (f) (format #f "  - ~a" f))
              (reverse *loaded-context*))
         "\n")
        "\n"))
   (if (null? *loaded-tasks*)
       ""
       (format #f "\nOpen beads tasks: ~a\n" (length *loaded-tasks*)))))
