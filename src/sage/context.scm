;;; context.scm --- Context preloading for sage -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Loads system prompt into session context on startup.
;; Prefers SAGE.md (lean, tool-focused) over AGENTS.md (full agent docs).
;; Pure Guile - no shell calls.

(define-module (sage context)
  #:use-module (sage config)
  #:use-module (sage logging)
  #:use-module (sage session)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:export (load-agents-context
            load-context-files  ; backward compat alias
            context-status))

;;; State
(define *context-source* #f)

;;; workspace-or-cwd: Get workspace or current directory
(define (workspace-or-cwd)
  (or (config-get "WORKSPACE")
      (config-get "SAGE_WORKSPACE")
      (getcwd)))

;;; load-context-file: Load a single context file into session
(define (load-context-file path label)
  "Load a context file and add to session as system message.
Returns #t on success, #f on failure."
  (if (file-exists? path)
      (catch #t
        (lambda ()
          (let ((content (call-with-input-file path get-string-all)))
            (session-add-message "system"
                                 (string-append
                                  "=== " label " ===\n"
                                  content))
            (set! *context-source* label)
            (log-info "context" (format #f "Loaded ~a" label)
                      `(("chars" . ,(string-length content))
                        ("path" . ,path)))
            #t))
        (lambda (key . args)
          (log-warn "context" (format #f "Failed to read ~a" label)
                    `(("error" . ,(format #f "~a" key))))
          #f))
      #f))

;;; load-agents-context: Load SAGE.md into session
(define (load-agents-context)
  "Load SAGE.md into session as system message."
  (let ((base (workspace-or-cwd)))
    (or (load-context-file (string-append base "/SAGE.md") "SAGE.md")
        (begin
          (log-debug "context" "No SAGE.md found")
          #f))))

;;; Backward compatibility alias
(define load-context-files load-agents-context)

;;; context-status: Show context status
(define (context-status)
  "Return status of loaded context."
  (if *context-source*
      (format #f "~a loaded into context." *context-source*)
      "No context loaded."))
