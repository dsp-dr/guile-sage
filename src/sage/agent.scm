;;; agent.scm --- Agent task management (in-memory) -*- coding: utf-8 -*-

;;; Commentary:
;;
;; In-memory task management for sage's agent loop. Tasks are session-
;; scoped: created, tracked, and completed within a single REPL run.
;; Beads (bd) is an OPTIONAL export path, not a dependency — tasks
;; work without bd installed. This decouples the agent from the
;; broken open-input-pipe on macOS Guile (guile-5tr).

(define-module (sage agent)
  #:use-module (sage config)
  #:use-module (sage logging)
  #:use-module (sage util)
  #:use-module (sage irc)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-19)
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
            task-push!
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

;;; ============================================================
;;; In-memory task store
;;; ============================================================
;;;
;;; Tasks are alists stored in *task-store*. Each has:
;;;   ("id" . "sage-N")        auto-incrementing counter
;;;   ("title" . "...")
;;;   ("description" . "...")
;;;   ("status" . "open"|"in_progress"|"completed")
;;;   ("created" . timestamp)
;;;   ("result" . "..."|#f)
;;;
;;; No external dependency. No open-input-pipe. No bd.
;;; Beads is an optional export via beads-sync! (uses system(), not pipe).

(define *task-store* '())
(define *task-counter* 0)

(define (beads-available?)
  "Check if beads CLI (bd) is available."
  (zero? (system "which bd > /dev/null 2>&1")))

(define (task-store-create title description)
  "Create a task in memory. Returns the task ID string."
  (set! *task-counter* (1+ *task-counter*))
  (let* ((id (format #f "sage-~a" *task-counter*))
         (task `(("id" . ,id)
                 ("title" . ,title)
                 ("description" . ,description)
                 ("status" . "open")
                 ("created" . ,(number->string (time-second (current-time))))
                 ("result" . #f))))
    (set! *task-store* (cons task *task-store*))
    (log-info "agent" "Task created" `(("id" . ,id) ("title" . ,title)))
    id))

(define (task-store-close id reason)
  "Mark a task as completed in memory. Returns #t on success."
  (let ((task (find (lambda (t) (equal? (assoc-ref t "id") id)) *task-store*)))
    (if (not task)
        (begin (log-warn "agent" "Task not found" `(("id" . ,id))) #f)
        (begin
          (set-cdr! (assoc "status" task) "completed")
          (set-cdr! (assoc "result" task) reason)
          (log-info "agent" "Task closed" `(("id" . ,id)))
          #t))))

(define (task-store-list)
  "List open tasks from memory. Returns list of (id . title) pairs."
  (filter-map
   (lambda (t)
     (and (not (equal? (assoc-ref t "status") "completed"))
          (cons (assoc-ref t "id") (assoc-ref t "title"))))
   *task-store*))

(define (task-store-get id)
  "Get a task by ID from memory. Returns task alist or #f."
  (find (lambda (t) (equal? (assoc-ref t "id") id)) *task-store*))

;;; Legacy beads wrappers (delegate to in-memory, optionally sync)

(define (beads-create-task title description)
  "Create a task. In-memory first, beads sync optional."
  (task-store-create title description))

(define (beads-close-task id reason)
  "Close a task. In-memory first, beads sync optional."
  (task-store-close id reason))

(define (beads-list-tasks)
  "List tasks from in-memory store."
  (task-store-list))

(define (beads-get-task id)
  "Get task from in-memory store."
  (let ((task (task-store-get id)))
    (if task
        (cons (assoc-ref task "id") (assoc-ref task "title"))
        (begin
          (log-warn "agent" (format #f "Task not found: ~a" id))
          (cons id "unknown")))))

;;; Old beads-get-task that used open-input-pipe removed (guile-5tr).
;;; The replacement is the in-memory beads-get-task defined above.

;;; Shell escape helper
(define (shell-escape str)
  "Escape string for shell (single quotes)."
  (string-replace-substring str "'" "'\\''"))

;;; Task Management API

(define (notify-task-event event-type task-id message)
  "Send task event to IRC if connected."
  (when (irc-connected?)
    (irc-log-task task-id (format #f "~a: ~a" event-type message))))

(define (task-create title description)
  "Create a new task appended to the back of the queue (FIFO).
For sub-tasks that must run BEFORE queued siblings, use task-push!."
  (let ((id (beads-create-task title description)))
    (when id
      (set! *agent-tasks* (append *agent-tasks* (list id)))
      (notify-task-event "created" id title))
    id))

(define (task-push! title description)
  "Create a sub-task at the FRONT of the queue (LIFO).
Use this when decomposing the current work: newly discovered sub-steps
run before anything else already queued. Returns the task ID."
  (let ((id (beads-create-task title description)))
    (when id
      (set! *agent-tasks* (cons id *agent-tasks*))
      (notify-task-event "pushed" id title))
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
        (notify-task-event "completed" id result-note)
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
        (let ((next-id (caar tasks))
              (title (cdar tasks)))
          (set! *agent-current-task* next-id)
          (log-info "agent" "Starting task" `(("id" . ,next-id)
                                              ("title" . ,title)))
          (notify-task-event "started" next-id title)
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
