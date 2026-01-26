;;; context.scm --- Context preloading for sage -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Loads AGENTS.md into session context on startup.
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
(define *agents-loaded?* #f)

;;; workspace-or-cwd: Get workspace or current directory
(define (workspace-or-cwd)
  (or (config-get "WORKSPACE")
      (config-get "SAGE_WORKSPACE")
      (getcwd)))

;;; load-agents-context: Load AGENTS.md into session
(define (load-agents-context)
  "Load AGENTS.md and add to session as system message."
  (let ((path (string-append (workspace-or-cwd) "/AGENTS.md")))
    (if (file-exists? path)
        (catch #t
          (lambda ()
            (let ((content (call-with-input-file path get-string-all)))
              (session-add-message "system"
                                   (string-append
                                    "=== AGENTS.md ===\n"
                                    content))
              (set! *agents-loaded?* #t)
              (log-info "context" "Loaded AGENTS.md"
                        `(("chars" . ,(string-length content))))
              #t))
          (lambda (key . args)
            (log-warn "context" "Failed to read AGENTS.md"
                      `(("error" . ,(format #f "~a" key))))
            #f))
        (begin
          (log-debug "context" "No AGENTS.md found")
          #f))))

;;; Backward compatibility alias
(define load-context-files load-agents-context)

;;; context-status: Show context status
(define (context-status)
  "Return status of loaded context."
  (if *agents-loaded?*
      "AGENTS.md loaded into context."
      "No AGENTS.md loaded."))
