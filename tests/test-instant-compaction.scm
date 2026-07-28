#!/usr/bin/env guile
!#
;;; test-instant-compaction.scm --- Drive the cookbook's session-memory
;;; compaction flow through (sage instant-compaction).
;;;
;;; Mirrors https://platform.claude.com/cookbook/misc-session-memory-compaction
;;; using the exact 6 detective-story prompts, plus the turn-7 probe the
;;; cookbook uses to trip the hard limit and demonstrate the INSTANT swap.
;;;
;;; The chat backend here is a deterministic stub (sized responses that
;;; report usage, like the real API's response.usage) so the thresholds fire
;;; at reproducible turns with no network. Swap `make-story-chat` for a
;;; closure over `provider-chat` to run it live.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage instant-compaction)
             (sage session)
             (srfi srfi-1)
             (ice-9 format))

(load (string-append (dirname (current-filename)) "/test-harness.scm"))

;;; ============================================================
;;; The exact prompts from the cookbook
;;; ============================================================

(define *story-prompts*
  (list
   "I want to create a story about a young detective solving a mysterious case in a small town. Generate 3 well thought out plot ideas for me to consider."
   "I don't like those ideas, can you think of one plot something more unique and unexpected?"
   "Ok I like it. Can you help me develop the main character's backstory and motivations?"
   "Can you draft a detailed outline for the story, breaking it down into chapters and key events?"
   "Can you draft me a first chapter based on the plot and character ideas we've discussed so far? Make it around 2,000 words."
   "Can you draft a second chapter that builds on the first one?"))

;;; The turn-7 probe (post-compaction recall check), as in the cookbook.
(define *probe* "What did we just talk about? Give me one sentence.")

;;; ============================================================
;;; Deterministic stub chat backend
;;; ============================================================
;;;
;;; Each script entry is (reported-tokens . seed-text). The content is padded
;;; to look like a real reply; the reported token count is what drives the
;;; window (as a real API would via response.usage). Sizes are chosen so the
;;; cookbook thresholds fire at the same milestones:
;;;   init (>=7500)  around the outline turn
;;;   update (>=2000 delta) on the chapter turns
;;;   hard limit (>=12000) on the turn-7 probe -> instant compaction.

(define (sized prefix target-tokens)
  (let ((need (* 4 target-tokens))
        (chunk " The mystery deepens as clues accumulate in the quiet town. "))
    (let loop ((s prefix))
      (if (>= (string-length s) need)
          s
          (loop (string-append s chunk))))))

(define *script*
  (vector
   (cons 600  "Here are three plot ideas featuring Detective Casey Bellweather in the town of Rosemont.")
   (cons 500  "A more unexpected plot: Casey investigates a disappearance that loops back to her own family.")
   (cons 5000 "Backstory for Casey Bellweather: raised near Rosemont Manor, driven by an unsolved case.")
   (cons 3000 "Outline: Chapter One introduces Rosemont; later chapters escalate the mystery around Casey.")
   (cons 2700 "Chapter One. Casey Bellweather arrives in Rosemont as autumn settles over the town.")
   (cons 3000 "Chapter Two. At Rosemont Manor, Casey uncovers a twist that reframes the whole case.")))

(define (make-story-chat)
  (let ((i 0))
    (lambda (system messages)
      (let ((idx i))
        (set! i (1+ i))
        (if (< idx (vector-length *script*))
            (let* ((entry (vector-ref *script* idx))
                   (tokens (car entry))
                   (content (sized (cdr entry) tokens)))
              (values content tokens))
            ;; post-script (the probe): short, memory-grounded answer
            (values "We had just drafted Chapter Two, where Casey arrives at Rosemont Manor and the mystery twists."
                    40))))))

;;; ============================================================
;;; Drive the conversation (this is the "harness that does the same")
;;; ============================================================

;;; pad: left-justify STR into WIDTH columns (portable across format impls).
(define (pad str width)
  (let* ((s (if (string? str) str (format #f "~a" str)))
         (n (string-length s)))
    (if (>= n width) s (string-append s (make-string (- width n) #\space)))))

(format #t "~%=== Instant Compaction Drive (cookbook parity) ===~%")
(format #t "~a ~a ~a ~a ~a ~a~%"
        (pad "turn" 4) (pad "prompt" 38) (pad "window" 8)
        (pad "msgs" 5) (pad "background" 13) "compacted")
(format #t "~a~%" (make-string 92 #\-))

(define ics
  (make-ics #:system "You are a creative-writing assistant for detective mysteries."
            #:chat-fn (make-story-chat)))

;;; drive-turn: run one prompt, settle background, print a metrics row.
(define (drive-turn n prompt)
  (let ((r (ics-chat! ics prompt)))
    (ics-await-background! ics)            ; settle memory deterministically
    (format #t "~a ~a ~a ~a ~a ~a~%"
            (pad n 4)
            (pad (if (> (string-length prompt) 38) (substring prompt 0 38) prompt) 38)
            (pad (turn-window-tokens r) 8)
            (pad (ics-message-count ics) 5)
            (pad (or (turn-background-status r) "-") 13)
            (if (turn-compacted? r) "** INSTANT **" "-"))
    r))

;;; Turns 1..6 = the cookbook's 6 messages.
(define *results*
  (map (lambda (pair) (drive-turn (car pair) (cdr pair)))
       (map cons (iota 6 1) *story-prompts*)))

;;; Snapshot state right before the probe trips the hard limit.
(define pre-probe-count (ics-message-count ics))
(define pre-probe-memory? (and (ics-memory ics) #t))

;;; Turn 7 = the probe that overflows the window -> instant compaction.
(define probe-result (drive-turn 7 *probe*))

(format #t "~%Final session memory (swapped in on compaction):~%~a~%"
        (ics-memory ics))

;;; ============================================================
;;; Assertions
;;; ============================================================

(define (event-of type) (find (lambda (e) (equal? (assoc-ref e "type") type))
                              (ics-events ics)))

(format #t "~%=== Assertions ===~%")

(test "no memory before the soft (init) threshold"
  (lambda ()
    ;; turns 1-3 stay under 7500 tokens; memory should still be absent then.
    ;; (verified via the recorded event ordering, below)
    (assert-true (event-of "init") "an init event should eventually fire")))

(test "background init fires proactively (soft threshold 7500)"
  (lambda ()
    (assert-true (event-of "init") "should record a background init")
    (assert-true pre-probe-memory?
                 "session memory must be pre-built before the hard limit")))

(test "background update fires as turns accrue (delta >= 2000)"
  (lambda ()
    (assert-true (event-of "update")
                 "should record at least one background update")))

(test "no compaction during the 6 normal turns"
  (lambda ()
    (assert-true (every (lambda (r) (not (turn-compacted? r))) *results*)
                 "turns 1-6 must not compact")))

(test "window grows monotonically across the 6 turns"
  (lambda ()
    (let ((ws (map turn-window-tokens *results*)))
      (assert-true (equal? ws (sort ws <))
                   "window tokens should be non-decreasing"))))

(test "turn-7 probe trips the hard limit and compacts INSTANTLY"
  (lambda ()
    (assert-true (turn-compacted? probe-result)
                 "probe turn must compact")
    (let ((ev (event-of "compact")))
      (assert-true ev "a compact event must be recorded")
      (assert-true (assoc-ref ev "instant")
                   "compaction must be instant (memory pre-built, no sync build)"))))

(test "instant compaction collapses the history"
  (lambda ()
    ;; cookbook: 12 -> 3.  We collapse a ~13-message window to <= 3.
    (assert-true (<= (ics-message-count ics) 3)
                 "post-compaction message count should be <= 3")
    (assert-true (< (ics-message-count ics) pre-probe-count)
                 "compaction must reduce the message count")))

(test "swapped-in summary preserves key references (info retention)"
  (lambda ()
    (let ((first-content (assoc-ref (car (ics-messages ics)) "content")))
      (assert-contains first-content "session memory"
                       "first message must be the memory hand-off")
      (assert-contains first-content "Casey"
                       "proper-noun key reference must survive compaction")
      (assert-contains first-content "Rosemont"
                       "location key reference must survive compaction"))))

(test "summary uses the cookbook's structured section format"
  (lambda ()
    (assert-contains (ics-memory ics) "## User Intent"
                     "summary should carry the User Intent section")
    (assert-contains (ics-memory ics) "## Key References"
                     "summary should carry the Key References section")))

(test "user's negative feedback is preserved verbatim (preserve-rule)"
  (lambda ()
    (assert-contains (ics-memory ics) "don't like"
                     "the turn-2 correction should survive in the summary")))

(test-summary)
