;;; agent.scm --- Agent task management with beads persistence -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Manages agent task loop with beads as persistent memory.
;; Enables sage to "grind through" multi-step tasks without forgetting.

(define-module (sage agent)
  #:use-module (sage config)
  #:use-module (sage logging)
  #:use-module (sage util)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:export (*agent-mode*
            *agent-tasks*
            *agent-iteration*
            *agent-running*
            agent-mode
            set-agent-mode!
            agent-status
            agent-start
            agent-pause
            agent-continue
            agent-increment-iteration!
            task-create
            task-complete
            task-list
            task-current
            task-get
            task-next
            has-pending-tasks?
            format-task-status
            beads-available?))

;;; Agent State

(define *agent-mode* 'interactive)  ; interactive | autonomous | yolo
(define *agent-tasks* '())          ; List of task IDs currently being worked on
(define *agent-current-task* #f)    ; Current task ID
(define *agent-iteration* 0)        ; Current iteration count
(define *agent-running* #f)         ; Is agent loop active?
(define *max-iterations* 10)        ; Safety limit

;;; Agent Mode

(define (agent-mode)
  "Get current agent mode."
  *agent-mode*)

(define (set-agent-mode! mode)
  "Set agent mode: interactive, autonomous, or yolo."
  (case mode
    ((interactive autonomous yolo)
     (set! *agent-mode* mode)
     (log-info "agent" "Mode changed" `(("mode" . ,(symbol->string mode))))
     mode)
    (else
     (log-warn "agent" "Invalid mode" `(("mode" . ,(format #f "~a" mode))))
     #f)))

;;; Beads Integration

(define (beads-available?)
  "Check if beads CLI (bd) is available."
  (zero? (system "which bd > /dev/null 2>&1")))

(define (beads-create-task title description)
  "Create a task in beads. Returns task ID or #f."
  (if (not (beads-available?))
      (begin
        (log-warn "agent" "Beads not available")
        #f)
      (let* ((cmd (format #f "bd create '~a' -t task --prefix sage- -d '~a' --silent 2>/dev/null"
                          (shell-escape title)
                          (shell-escape description)))
             (port (open-input-pipe cmd))
             (output (get-string-all port)))
        (close-pipe port)
        (let ((id (string-trim-both output)))
          (if (string-null? id)
              (begin
                (log-error "agent" "Failed to create beads task"
                           `(("title" . ,title)))
                #f)
              (begin
                (log-info "agent" "Task created" `(("id" . ,id) ("title" . ,title)))
                id))))))

(define (beads-close-task id reason)
  "Close a beads task. Returns #t on success."
  (if (not (beads-available?))
      #f
      (let ((result (system (format #f "bd close '~a' --reason '~a' 2>/dev/null"
                                    (shell-escape id)
                                    (shell-escape reason)))))
        (if (zero? result)
            (begin
              (log-info "agent" "Task closed" `(("id" . ,id)))
              #t)
            (begin
              (log-error "agent" "Failed to close task" `(("id" . ,id)))
              #f)))))

(define (beads-list-tasks)
  "List open sage tasks from beads. Returns list of (id . title) pairs."
  (if (not (beads-available?))
      '()
      (let* ((cmd "bd list --prefix sage- --status open --json 2>/dev/null")
             (port (open-input-pipe cmd))
             (output (get-string-all port)))
        (close-pipe port)
        (catch #t
          (lambda ()
            (let ((tasks (json-read-string output)))
              (if (list? tasks)
                  (map (lambda (t)
                         (cons (assoc-ref t "id")
                               (assoc-ref t "title")))
                       tasks)
                  '())))
          (lambda (key . args)
            (log-warn "agent" "Failed to parse beads tasks" `(("error" . ,(format #f "~a" key))))
            '())))))

(define (beads-get-task id)
  "Get task details from beads. Returns alist or #f."
  (if (not (beads-available?))
      #f
      (let* ((cmd (format #f "bd get '~a' --json 2>/dev/null" (shell-escape id)))
             (port (open-input-pipe cmd))
             (output (get-string-all port)))
        (close-pipe port)
        (catch #t
          (lambda ()
            (json-read-string output))
          (lambda (key . args)
            #f)))))

;;; Shell escape helper
(define (shell-escape str)
  "Escape string for shell (single quotes)."
  (string-replace-substring str "'" "'\\''"))

;;; Task Management API

(define (task-create title description)
  "Create a new task. Returns task ID."
  (let ((id (beads-create-task title description)))
    (when id
      (set! *agent-tasks* (append *agent-tasks* (list id))))
    id))

(define (task-complete result-note)
  "Complete the current task with result note."
  (if (not *agent-current-task*)
      (begin
        (log-warn "agent" "No current task to complete")
        #f)
      (let ((id *agent-current-task*))
        (beads-close-task id result-note)
        (set! *agent-tasks* (delete id *agent-tasks* equal?))
        (set! *agent-current-task* #f)
        id)))

(define (task-list)
  "List all pending sage tasks."
  (beads-list-tasks))

(define (task-get id)
  "Get task details by ID."
  (beads-get-task id))

(define (task-current)
  "Get current task ID."
  *agent-current-task*)

(define (task-next)
  "Get and set the next pending task as current. Returns task ID or #f."
  (let ((tasks (task-list)))
    (if (null? tasks)
        (begin
          (set! *agent-current-task* #f)
          #f)
        (let ((next-id (caar tasks)))
          (set! *agent-current-task* next-id)
          (log-info "agent" "Starting task" `(("id" . ,next-id)
                                              ("title" . ,(cdar tasks))))
          next-id))))

(define (has-pending-tasks?)
  "Check if there are pending tasks."
  (not (null? (task-list))))

;;; Agent Loop Control

(define (agent-start)
  "Start the agent loop."
  (set! *agent-running* #t)
  (set! *agent-iteration* 0)
  (log-info "agent" "Agent loop started" `(("mode" . ,(symbol->string *agent-mode*))))
  #t)

(define (agent-pause)
  "Pause the agent loop."
  (set! *agent-running* #f)
  (log-info "agent" "Agent loop paused")
  #t)

(define (agent-continue)
  "Continue the agent loop."
  (set! *agent-running* #t)
  (log-info "agent" "Agent loop continued")
  #t)

(define (agent-increment-iteration!)
  "Increment the iteration counter."
  (set! *agent-iteration* (1+ *agent-iteration*))
  *agent-iteration*)

(define (agent-status)
  "Get agent status alist."
  `(("mode" . ,(symbol->string *agent-mode*))
    ("running" . ,*agent-running*)
    ("iteration" . ,*agent-iteration*)
    ("max_iterations" . ,*max-iterations*)
    ("current_task" . ,*agent-current-task*)
    ("pending_tasks" . ,(length (task-list)))
    ("beads_available" . ,(beads-available?))))

(define (format-task-status)
  "Format task status for display."
  (let* ((tasks (task-list))
         (current *agent-current-task*)
         (status (agent-status)))
    (string-append
     (format #f "Agent Mode: ~a~%" (assoc-ref status "mode"))
     (format #f "Status: ~a~%" (if *agent-running* "running" "paused"))
     (format #f "Iteration: ~a/~a~%" *agent-iteration* *max-iterations*)
     (format #f "Current Task: ~a~%" (or current "none"))
     (format #f "Pending Tasks: ~a~%" (length tasks))
     (if (null? tasks)
         ""
         (string-append
          "Tasks:\n"
          (string-join
           (map (lambda (t)
                  (format #f "  ~a: ~a" (car t) (cdr t)))
                tasks)
           "\n"))))))

;;; Max iterations config
(define (init-agent-config)
  "Initialize agent config from environment."
  (let ((max-iter (config-get "SAGE_MAX_ITERATIONS")))
    (when max-iter
      (let ((n (string->number max-iter)))
        (when (and n (> n 0))
          (set! *max-iterations* n))))))

;; Initialize on module load
(init-agent-config)
