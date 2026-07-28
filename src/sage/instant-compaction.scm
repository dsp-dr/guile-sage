;;; instant-compaction.scm --- Proactive "instant" session-memory compaction -*- coding: utf-8 -*-

;;; Commentary:
;;
;; A Guile port of Anthropic's "session memory compaction" cookbook
;; (https://platform.claude.com/cookbook/misc-session-memory-compaction).
;;
;; Contrast with (sage compaction), which is *reactive*: it runs a
;; summarize/truncate/importance pass at the moment the context window is
;; already full, and the user waits for it. This module is *proactive*:
;;
;;   - soft threshold (min-tokens-to-init, default 7500):
;;       kick off building a structured session-memory summary in the
;;       BACKGROUND, before it is needed.
;;   - update threshold (min-tokens-between-updates, default 2000):
;;       refresh that summary in the background as new turns accrue.
;;   - hard threshold (context-limit, default 12000):
;;       when the next turn would overflow, swap in the pre-built summary
;;       INSTANTLY (no synchronous summarize -> no 40s stall).
;;
;; The summary and the swap are both pluggable:
;;   - chat-fn      : (system messages) -> (values content-str out-tokens)
;;   - summarize-fn : (messages) -> summary-string
;; The defaults are deterministic so this runs in CI with no network. Swap
;; in `provider-chat` and an LLM summarizer for the live behaviour.
;;
;; Background updates run on a real thread guarded by a mutex, mirroring the
;; cookbook's threading.Lock + daemon thread. `ics-await-background!` joins
;; it so tests observe settled state.

(define-module (sage instant-compaction)
  #:use-module (sage session)          ; estimate-tokens
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:export (;; Construction
            make-ics
            ics?
            ;; Driving the conversation
            ics-chat!
            ics-compact!
            ics-await-background!
            ;; Inspection
            ics-messages
            ics-message-count
            ics-memory
            ics-window-tokens
            ics-events
            ics-last-event
            ;; Pieces (for live wiring / testing)
            *session-memory-prompt*
            default-structured-summarizer
            ;; Turn-result accessors
            turn-content
            turn-background-status
            turn-window-tokens
            turn-compacted?))

;;; ============================================================
;;; The session-memory instruction (verbatim shape from the cookbook)
;;; ============================================================

(define *session-memory-prompt*
  "Compress the conversation into a structured summary that preserves all
information needed to continue work seamlessly.

<summary-format>
## User Intent
## Completed Work
## Errors & Corrections
## Active Work
## Pending Tasks
## Key References
</summary-format>

<preserve-rules>
Always preserve exact identifiers, error messages verbatim, user
corrections and negative feedback, and the precise state of in-progress
work. Weight recent messages heavily; omit pleasantries.
</preserve-rules>")

;;; ============================================================
;;; Session record (mutable fields; guarded by `mutex` where shared)
;;; ============================================================

(define-record-type <ics>
  (%make-ics system context-limit min-init min-between
             messages memory last-index window tokens-at-update
             chat-fn summarize-fn mutex thread events)
  ics?
  (system          ics-system)
  (context-limit   ics-context-limit)
  (min-init        ics-min-init)
  (min-between     ics-min-between)
  (messages        ics-messages        set-ics-messages!)
  (memory          ics-memory          set-ics-memory!)
  (last-index      ics-last-index       set-ics-last-index!)
  (window          ics-window-tokens   set-ics-window!)
  (tokens-at-update ics-tokens-at-update set-ics-tokens-at-update!)
  (chat-fn         ics-chat-fn)
  (summarize-fn    ics-summarize-fn)
  (mutex           ics-mutex)
  (thread          ics-thread          set-ics-thread!)
  (events          ics-events          set-ics-events!))

;;; make-ics: keyword constructor.
(define* (make-ics #:key
                   (system "You are a helpful creative-writing assistant.")
                   (context-limit 12000)
                   (min-tokens-to-init 7500)
                   (min-tokens-between-updates 2000)
                   (chat-fn #f)
                   (summarize-fn default-structured-summarizer))
  (let ((ics (%make-ics system context-limit
                        min-tokens-to-init min-tokens-between-updates
                        '()          ; messages
                        #f           ; memory
                        0            ; last-index
                        0            ; window
                        0            ; tokens-at-update
                        (or chat-fn (error "make-ics: #:chat-fn is required"))
                        summarize-fn
                        (make-mutex)
                        #f           ; thread
                        '())))       ; events
    ;; seed the system message into the window
    (when (and (string? system) (> (string-length system) 0))
      (set-ics-messages! ics (list (msg "system" system (estimate-tokens system))))
      (recompute-window! ics))
    ics))

;;; ============================================================
;;; Message helpers
;;; ============================================================

(define (msg role content tokens)
  `(("role" . ,role) ("content" . ,content) ("tokens" . ,tokens)))

(define (msg-tokens m) (or (assoc-ref m "tokens") 0))

(define (recompute-window! ics)
  (set-ics-window! ics (fold + 0 (map msg-tokens (ics-messages ics)))))

(define (ics-message-count ics) (length (ics-messages ics)))

(define (append-msg! ics role content tokens)
  (set-ics-messages! ics (append (ics-messages ics)
                                 (list (msg role content tokens)))))

(define (record-event! ics type . fields)
  (set-ics-events! ics
    (append (ics-events ics)
            (list (cons (cons "type" type) fields)))))

(define (ics-last-event ics)
  (let ((evs (ics-events ics)))
    (if (null? evs) #f (last evs))))

;;; ============================================================
;;; Turn result (opaque alist + accessors)
;;; ============================================================

(define (make-turn content status window compacted?)
  `(("content" . ,content) ("background_status" . ,status)
    ("window" . ,window)   ("compacted" . ,compacted?)))
(define (turn-content t)            (assoc-ref t "content"))
(define (turn-background-status t)  (assoc-ref t "background_status"))
(define (turn-window-tokens t)      (assoc-ref t "window"))
(define (turn-compacted? t)         (assoc-ref t "compacted"))

;;; ============================================================
;;; Threshold predicates (cookbook parity)
;;; ============================================================

(define (should-init? ics)
  (and (not (ics-memory ics))
       (>= (ics-window-tokens ics) (ics-min-init ics))))

(define (should-update? ics)
  (and (ics-memory ics)
       (>= (- (ics-window-tokens ics) (ics-tokens-at-update ics))
           (ics-min-between ics))))

;;; ============================================================
;;; Background memory build (real thread + mutex)
;;; ============================================================

;;; trigger-background-update!: start ONE background summariser.
;;; Returns "initializing" | "updating" | #f.
(define (trigger-background-update! ics)
  ;; only one at a time (cookbook: skip if thread still alive)
  (if (let ((t (ics-thread ics))) (and t (not (thread-exited? t))))
      #f
      (let* ((initializing? (not (ics-memory ics)))
             (snapshot (ics-messages ics))
             (snap-index (length snapshot))
             (window (ics-window-tokens ics))
             (thunk
              (lambda ()
                (let ((new-memory
                       (if initializing?
                           ((ics-summarize-fn ics) snapshot)
                           ;; update: re-summarise the whole snapshot. (The
                           ;; cookbook folds only the delta; folding the full
                           ;; snapshot is simpler and equally correct here.)
                           ((ics-summarize-fn ics) snapshot))))
                  (with-mutex (ics-mutex ics)
                    (set-ics-memory! ics new-memory)
                    (set-ics-last-index! ics snap-index)
                    (set-ics-tokens-at-update! ics window))))))
        (set-ics-thread! ics (call-with-new-thread thunk))
        (record-event! ics (if initializing? "init" "update")
                       (cons "at_window" window)
                       (cons "snapshot_index" snap-index))
        (if initializing? "initializing" "updating"))))

;;; ics-await-background!: block until the in-flight background update ends.
;;; Returns #t if a build was pending, #f otherwise. (Guile's join-thread
;;; timeout is an ABSOLUTE time, so we omit it and block fully.)
(define (ics-await-background! ics)
  (let ((t (ics-thread ics)))
    (if (and t (not (thread-exited? t)))
        (begin (join-thread t) #t)
        #f)))

;;; ============================================================
;;; Instant compaction: swap in the pre-built summary
;;; ============================================================

;;; ics-compact!: replace history with [summary] + unsummarized tail.
;;; INSTANT when memory was pre-built; only synchronous as a fallback.
(define (ics-compact! ics)
  (let ((prev (ics-message-count ics))
        (built-synchronously? #f))
    ;; Ensure memory exists (cookbook: wait on background, else build now).
    (when (not (ics-memory ics))
      (ics-await-background! ics))
    (when (not (ics-memory ics))
      (set! built-synchronously? #t)
      (set-ics-memory! ics ((ics-summarize-fn ics) (ics-messages ics)))
      (set-ics-last-index! ics (ics-message-count ics)))
    (with-mutex (ics-mutex ics)
      (let* ((all (ics-messages ics))
             (idx (min (ics-last-index ics) (length all)))
             (unsummarized (drop all idx))
             (summary-content
              (format #f
                "This session is being continued from a previous conversation.~%~
                 Here is the session memory:~%~a~%Continue from where we left off."
                (ics-memory ics)))
             (summary-msg (msg "user" summary-content
                               (estimate-tokens summary-content))))
        (set-ics-messages! ics (cons summary-msg unsummarized))
        (set-ics-last-index! ics 1)
        (recompute-window! ics)))
    (record-event! ics "compact"
                   (cons "from_messages" prev)
                   (cons "to_messages" (ics-message-count ics))
                   (cons "instant" (not built-synchronously?)))
    (not built-synchronously?)))

;;; ============================================================
;;; The main chat turn (cookbook `chat`)
;;; ============================================================

;;; ics-chat!: run one user turn. Returns a turn-result alist.
(define (ics-chat! ics user-message)
  ;; 1. hard-limit pre-check -> INSTANT compaction if the next turn overflows
  (let* ((incoming (estimate-tokens user-message))
         (predicted (+ (ics-window-tokens ics) incoming))
         (compacted? (>= predicted (ics-context-limit ics))))
    (when compacted? (ics-compact! ics))
    ;; 2. append the user message
    (append-msg! ics "user" user-message incoming)
    (recompute-window! ics)
    ;; 3. get the assistant response
    (call-with-values
        (lambda () ((ics-chat-fn ics) (ics-system ics) (ics-messages ics)))
      (lambda (content out-tokens)
        ;; 4. append assistant response, recompute window
        (append-msg! ics "assistant" content
                     (or out-tokens (estimate-tokens content)))
        (recompute-window! ics)
        ;; 5. proactively (background) init/update memory if thresholds met
        (let ((status (cond ((should-init? ics)   (trigger-background-update! ics))
                            ((should-update? ics) (trigger-background-update! ics))
                            (else #f))))
          (make-turn content status (ics-window-tokens ics) compacted?))))))

;;; ============================================================
;;; Default deterministic summariser (structured, no network)
;;; ============================================================

;;; Produces the cookbook's section format from the transcript, preserving
;;; proper-noun "key references" so identity/state survives compaction.
(define (default-structured-summarizer messages)
  (let* ((non-system (filter (lambda (m)
                               (not (equal? (assoc-ref m "role") "system")))
                             messages))
         (users (filter (lambda (m) (equal? (assoc-ref m "role") "user")) non-system))
         (assistants (filter (lambda (m) (equal? (assoc-ref m "role") "assistant")) non-system))
         (intent (if (null? users) "(none)"
                     (clip (assoc-ref (car users) "content") 200)))
         (active (if (null? assistants) "(none)"
                     (clip (assoc-ref (last assistants) "content") 200)))
         (refs (proper-nouns non-system)))
    (format #f
      "## User Intent~%~a~%~%~
       ## Completed Work~%~a assistant turn(s), ~a user turn(s).~%~%~
       ## Errors & Corrections~%~a~%~%~
       ## Active Work~%~a~%~%~
       ## Pending Tasks~%Continue the in-progress work above.~%~%~
       ## Key References~%~a~%"
      intent
      (length assistants) (length users)
      (corrections users)
      active
      (if (null? refs) "(none)" (string-join refs ", ")))))

(define (clip s n)
  (let ((s (if (string? s) s "")))
    (if (> (string-length s) n)
        (string-append (substring s 0 n) "...")
        s)))

;;; corrections: surface user pushback verbatim (preserve-rule).
(define (corrections users)
  (let ((neg (filter (lambda (m)
                       (let ((c (string-downcase (or (assoc-ref m "content") ""))))
                         (or (string-contains c "don't like")
                             (string-contains c "instead")
                             (string-contains c "no ")
                             (string-contains c "not ")
                             (string-contains c "wrong"))))
                     users)))
    (if (null? neg) "(none)"
        (string-join (map (lambda (m) (string-append "- " (clip (assoc-ref m "content") 120)))
                          neg)
                     "\n"))))

;;; proper-nouns: capitalised multi-letter tokens, deduped, first 8.
(define (proper-nouns messages)
  (let* ((text (string-join (map (lambda (m) (or (assoc-ref m "content") "")) messages) " "))
         (matches (list-matches "[A-Z][a-z]{2,}[A-Za-z]*" text))
         (words (map match:substring matches))
         (skip '("The" "This" "That" "Here" "Continue" "User" "Chapter"
                 "Make" "Generate" "Can" "You" "Ok" "Now"))
         (kept (filter (lambda (w) (not (member w skip))) words)))
    (let ((seen (delete-duplicates kept)))
      (if (> (length seen) 8) (take seen 8) seen))))
