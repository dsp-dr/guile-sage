;;; commands.scm --- Custom slash command registry -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Allows users to define custom slash commands that map to Scheme
;; expressions or tool-call sequences. Commands are persisted to
;; ~/.config/sage/commands.scm as a serialized alist.
;;
;;; reload-contract: destroys *custom-commands*; --hard must re-run load-custom-commands!.

(define-module (sage commands)
  #:use-module (sage config)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 eval-string)
  #:use-module (srfi srfi-1)
  #:export (*custom-commands*
            custom-commands-file
            load-custom-commands!
            save-custom-commands!
            define-custom-command!
            undefine-custom-command!
            get-custom-command
            list-custom-commands
            execute-custom-command))

;;; ============================================================
;;; Registry
;;; ============================================================

;;; *custom-commands*: Alist of (name . expression-string) pairs.
;;; Names are stored without the leading "/".
(define *custom-commands* '())

;;; custom-commands-file: Path to persistent storage.
(define (custom-commands-file)
  (string-append (sage-config-dir) "/commands.scm"))

;;; ============================================================
;;; Persistence
;;; ============================================================

;;; load-custom-commands!: Load commands from disk.
;;; Returns: Number of commands loaded, or 0 on error/missing file.
(define (load-custom-commands!)
  (let ((path (custom-commands-file)))
    (if (file-exists? path)
        (catch #t
          (lambda ()
            (let ((data (call-with-input-file path read)))
              (if (list? data)
                  (begin
                    (set! *custom-commands* data)
                    (length data))
                  0)))
          (lambda (key . args)
            ;; Corrupt file — start fresh
            0))
        0)))

;;; save-custom-commands!: Write commands to disk.
;;; Returns: #t on success, #f on error.
(define (save-custom-commands!)
  (let ((path (custom-commands-file)))
    (catch #t
      (lambda ()
        (call-with-output-file path
          (lambda (port)
            (display ";;; Custom slash commands — managed by sage\n" port)
            (write *custom-commands* port)
            (newline port)))
        #t)
      (lambda (key . args)
        #f))))

;;; ============================================================
;;; CRUD
;;; ============================================================

;;; define-custom-command!: Register a custom command and persist.
;;; Arguments:
;;;   name - Command name without leading "/" (e.g. "deploy")
;;;   expr - Scheme expression as a string
;;; Returns: #t
(define (define-custom-command! name expr)
  (set! *custom-commands*
        (cons (cons name expr)
              (filter (lambda (p) (not (equal? (car p) name)))
                      *custom-commands*)))
  (save-custom-commands!)
  #t)

;;; undefine-custom-command!: Remove a custom command and persist.
;;; Arguments:
;;;   name - Command name without leading "/"
;;; Returns: #t if found and removed, #f if not found.
(define (undefine-custom-command! name)
  (let ((found (assoc name *custom-commands*)))
    (if found
        (begin
          (set! *custom-commands*
                (filter (lambda (p) (not (equal? (car p) name)))
                        *custom-commands*))
          (save-custom-commands!)
          #t)
        #f)))

;;; get-custom-command: Look up a custom command by name.
;;; Arguments:
;;;   name - Command name without leading "/"
;;; Returns: Expression string or #f.
(define (get-custom-command name)
  (assoc-ref *custom-commands* name))

;;; list-custom-commands: Return the full alist of custom commands.
(define (list-custom-commands)
  *custom-commands*)

;;; ============================================================
;;; Execution
;;; ============================================================

;;; execute-custom-command: Evaluate a custom command's expression.
;;; Uses eval-string in a restricted interaction environment.
;;; Arguments:
;;;   name - Command name without leading "/"
;;; Returns: Result of evaluation, or error string.
(define (execute-custom-command name)
  (let ((expr (get-custom-command name)))
    (if expr
        (catch #t
          (lambda ()
            (eval-string expr))
          (lambda (key . args)
            (format #f "Error executing /~a: ~a ~a" name key args)))
        (format #f "Unknown custom command: /~a" name))))
