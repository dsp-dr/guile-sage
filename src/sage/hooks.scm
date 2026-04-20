;;; hooks.scm --- Minimal lifecycle hook system -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Implements the PreToolUse + PostToolUse hook pair from
;; docs/HOOKS-CONTRACT.org (invariants H02, H03, H05-H07, H09, H12-H15).
;;
;; Minimal scope intentionally: no SessionStart, no UserPromptSubmit, no
;; shell-type hooks, no config-file loading, no scopes. Just two events,
;; Scheme-callable handlers, error isolation, and PreToolUse veto.
;;
;; Public API:
;;   (hook-register event name handler)  ; event = 'PreToolUse or 'PostToolUse
;;   (hook-unregister event name)
;;   (hook-list [event])
;;   (hook-clear!)
;;   (hook-fire-pre-tool tool-name args)   ; returns #t to allow, #f to veto
;;   (hook-fire-post-tool tool-name args result)
;;
;; A handler is a procedure (lambda (ctx) ...) where ctx is an alist:
;;   PreToolUse  ctx: (("event" . "PreToolUse") ("tool" . name) ("args" . args))
;;   PostToolUse ctx: (("event" . "PostToolUse") ("tool" . name)
;;                     ("args" . args) ("result" . result))
;;
;; PreToolUse handlers return #t/truthy to allow, #f to veto. The first
;; #f wins; remaining handlers don't run. PostToolUse handlers run for
;; observation only -- their return values are ignored (H13).
;;
;;; reload-contract: destroys *hooks* (all registered handlers); --hard must re-run hooks-reinit!.

(define-module (sage hooks)
  #:use-module (sage logging)
  #:use-module (srfi srfi-1)
  #:export (hook-register
            hook-unregister
            hook-list
            hook-clear!
            hook-fire-pre-tool
            hook-fire-post-tool
            hooks-reinit!))

;;; Registry: alist of (event . list-of-(name . handler))
;;; Insertion order preserved (H15: FIFO).
(define *hooks* '((PreToolUse . ())
                  (PostToolUse . ())))

(define (valid-event? event)
  (memq event '(PreToolUse PostToolUse)))

;;; hook-register: Register a handler for an event.
;;; H06: duplicate name replaces the existing hook.
;;; H15: hooks fire in registration order; re-registering moves to end.
(define (hook-register event name handler)
  (unless (valid-event? event)
    (error "unknown hook event (expected PreToolUse or PostToolUse):" event))
  (unless (procedure? handler)
    (error "hook handler must be a procedure:" handler))
  (let* ((bucket (assq-ref *hooks* event))
         (without (filter (lambda (entry)
                            (not (equal? (car entry) name)))
                          bucket))
         (updated (append without (list (cons name handler)))))
    (set! *hooks*
          (map (lambda (slot)
                 (if (eq? (car slot) event)
                     (cons event updated)
                     slot))
               *hooks*))
    name))

;;; hook-unregister: H07. No-op if the hook is absent.
(define (hook-unregister event name)
  (when (valid-event? event)
    (let ((bucket (assq-ref *hooks* event)))
      (set! *hooks*
            (map (lambda (slot)
                   (if (eq? (car slot) event)
                       (cons event
                             (filter (lambda (entry)
                                       (not (equal? (car entry) name)))
                                     bucket))
                       slot))
                 *hooks*))))
  #t)

;;; hook-list: Return registered hook names for an event, or all if omitted.
(define* (hook-list #:optional event)
  (cond ((not event)
         (map (lambda (slot)
                (cons (car slot)
                      (map car (cdr slot))))
              *hooks*))
        ((valid-event? event)
         (map car (assq-ref *hooks* event)))
        (else '())))

;;; hook-clear!: Remove all hooks (primarily for tests).
(define (hook-clear!)
  (set! *hooks* '((PreToolUse . ())
                  (PostToolUse . ())))
  #t)

;;; hooks-reinit!: Re-initialize hook registry after a --hard reload.
;;; Hooks are registered dynamically at runtime, so reinit simply clears
;;; the stale registry; callers re-register their hooks after --hard reload.
(define (hooks-reinit!)
  (hook-clear!))

;;; call-handler-safely: Error isolation (H14). Exceptions are logged
;;; and swallowed; the REPL never crashes because of a misbehaving hook.
;;; For PreToolUse: exception counts as allow (fail-open) to avoid
;;; bricking the REPL via a broken hook. For PostToolUse: return value
;;; doesn't matter (H13).
(define (call-handler-safely name handler ctx default-on-error)
  (catch #t
    (lambda () (handler ctx))
    (lambda (key . rest)
      (log-warn "hooks"
                (format #f "hook ~s threw: ~a ~a" name key rest)
                `(("hook" . ,(format #f "~s" name))))
      default-on-error)))

;;; hook-fire-pre-tool: H02, H12, H15.
;;; Runs each registered PreToolUse handler in order. Returns:
;;;   #t                 -- all handlers allowed; tool may execute
;;;   (#f . reason-str)  -- a handler vetoed; short-circuit
(define (hook-fire-pre-tool tool-name args)
  (let ((ctx `(("event" . "PreToolUse")
               ("tool" . ,tool-name)
               ("args" . ,args))))
    (let loop ((remaining (assq-ref *hooks* 'PreToolUse)))
      (if (null? remaining)
          #t
          (let* ((entry (car remaining))
                 (name (car entry))
                 (handler (cdr entry))
                 (result (call-handler-safely name handler ctx #t)))
            (cond
             ;; Handler can return a pair (#f . reason) for descriptive vetoes
             ((and (pair? result) (not (car result)))
              (log-info "hooks"
                        (format #f "PreToolUse veto by ~s: ~a"
                                name (cdr result))
                        `(("hook" . ,(format #f "~s" name))
                          ("tool" . ,tool-name)))
              result)
             ;; Plain #f is also a veto
             ((not result)
              (log-info "hooks"
                        (format #f "PreToolUse veto by ~s" name)
                        `(("hook" . ,(format #f "~s" name))
                          ("tool" . ,tool-name)))
              (cons #f (format #f "vetoed by ~s" name)))
             (else
              (loop (cdr remaining)))))))))

;;; hook-fire-post-tool: H03, H13, H15.
;;; Runs every handler, ignores return values, isolates exceptions.
(define (hook-fire-post-tool tool-name args result)
  (let ((ctx `(("event" . "PostToolUse")
               ("tool" . ,tool-name)
               ("args" . ,args)
               ("result" . ,result))))
    (for-each
     (lambda (entry)
       (call-handler-safely (car entry) (cdr entry) ctx #t))
     (assq-ref *hooks* 'PostToolUse)))
  #t)
