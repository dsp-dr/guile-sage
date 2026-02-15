;;; compaction.scm --- Context compaction strategies -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Multiple approaches to context window compaction with evaluation support.
;; Strategies range from simple truncation to intent-preserving summarization.

(define-module (sage compaction)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage session)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:export (;; Compaction strategies
            compact-truncate
            compact-token-limit
            compact-importance
            compact-summarize
            compact-intent
            ;; Strategy selection
            compact-auto
            *compaction-strategies*
            ;; Evaluation
            evaluate-compaction
            compaction-score
            run-compaction-eval
            ;; Utilities (for testing/session)
            extract-topics
            identify-intent
            message-tokens))

;;; ============================================================
;;; Message Importance Scoring
;;; ============================================================

;;; Keywords that indicate important content
(define *importance-keywords*
  '(;; Decisions and actions
    "decided" "will" "should" "must" "agreed" "confirmed"
    ;; Technical markers
    "error" "bug" "fix" "issue" "problem" "solution"
    ;; Tool interactions
    "tool" "execute" "result" "output"
    ;; Questions (usually important context)
    "?" "how" "what" "why" "where" "when"
    ;; Code references
    "function" "module" "file" "class" "variable"))

;;; score-message-importance: Score a message's importance (0-100)
(define (score-message-importance msg)
  (let* ((content (or (assoc-ref msg "content") ""))
         (role (or (assoc-ref msg "role") "user"))
         (has-tool-call (assoc-ref msg "tool_call"))
         (content-lower (string-downcase content))
         (len (string-length content)))
    (+
     ;; Base score by role
     (cond
      ((equal? role "system") 90)  ; System messages are critical
      ((equal? role "user") 50)    ; User messages are important
      ((equal? role "assistant") 40)
      (else 30))
     ;; Tool calls are important
     (if has-tool-call 20 0)
     ;; Keyword bonus
     (* 2 (count (lambda (kw) (string-contains content-lower kw))
                 *importance-keywords*))
     ;; Length penalty for very long messages (likely verbose)
     (if (> len 2000) -10 0)
     ;; Recent bonus (handled separately in strategies)
     0)))

;;; ============================================================
;;; Strategy 1: Simple Truncation (baseline)
;;; ============================================================

;;; compact-truncate: Keep N most recent messages
;;; Arguments:
;;;   messages - List of messages
;;;   keep - Number of messages to keep
;;; Returns: Compacted message list
(define* (compact-truncate messages #:key (keep 10))
  (let ((len (length messages)))
    (if (<= len keep)
        messages
        (let ((system-msgs (filter (lambda (m)
                                     (equal? (assoc-ref m "role") "system"))
                                   messages))
              (other-msgs (filter (lambda (m)
                                    (not (equal? (assoc-ref m "role") "system")))
                                  messages)))
          ;; Keep system messages + recent others
          (append system-msgs
                  (take-right other-msgs (- keep (length system-msgs))))))))

;;; ============================================================
;;; Strategy 2: Token-based Compaction
;;; ============================================================

;;; compact-token-limit: Keep messages within token budget
;;; Arguments:
;;;   messages - List of messages
;;;   max-tokens - Maximum total tokens
;;; Returns: Compacted message list
(define* (compact-token-limit messages #:key (max-tokens 4000))
  (let ((system-msgs (filter (lambda (m)
                               (equal? (assoc-ref m "role") "system"))
                             messages))
        (other-msgs (filter (lambda (m)
                              (not (equal? (assoc-ref m "role") "system")))
                            messages)))
    (let* ((system-tokens (fold + 0 (map message-tokens system-msgs)))
           (budget (- max-tokens system-tokens)))
      (append system-msgs
              (select-within-budget (reverse other-msgs) budget)))))

(define (message-tokens msg)
  (or (assoc-ref msg "tokens")
      (estimate-tokens (or (assoc-ref msg "content") ""))))

(define (select-within-budget messages budget)
  (let loop ((msgs messages) (tokens 0) (result '()))
    (if (or (null? msgs) (> tokens budget))
        (reverse result)
        (let ((msg-tokens (message-tokens (car msgs))))
          (if (> (+ tokens msg-tokens) budget)
              (reverse result)
              (loop (cdr msgs)
                    (+ tokens msg-tokens)
                    (cons (car msgs) result)))))))

;;; ============================================================
;;; Strategy 3: Importance-based Compaction
;;; ============================================================

;;; compact-importance: Keep most important messages
;;; Arguments:
;;;   messages - List of messages
;;;   keep - Target number of messages
;;;   recency-weight - Weight for recent messages (0-1)
;;; Returns: Compacted message list
(define* (compact-importance messages #:key (keep 10) (recency-weight 0.3))
  (let* ((len (length messages))
         (indexed (map cons (iota len) messages))
         (scored (map (lambda (pair)
                        (let* ((idx (car pair))
                               (msg (cdr pair))
                               (importance (score-message-importance msg))
                               (recency (* 100 recency-weight (/ idx len)))
                               (total (+ importance recency)))
                          (cons total pair)))
                      indexed))
         (sorted (sort scored (lambda (a b) (> (car a) (car b)))))
         (selected (take sorted (min keep (length sorted))))
         ;; Re-sort by original index to preserve order
         (reordered (sort (map cdr selected)
                          (lambda (a b) (< (car a) (car b))))))
    (map cdr reordered)))

;;; ============================================================
;;; Strategy 4: LLM-based Summarization
;;; ============================================================

;;; compact-summarize: Summarize older messages using LLM
;;; Arguments:
;;;   messages - List of messages
;;;   keep-recent - Number of recent messages to keep verbatim
;;;   summarize-fn - Function to generate summary (optional)
;;; Returns: Compacted message list with summary
(define* (compact-summarize messages
                            #:key
                            (keep-recent 5)
                            (summarize-fn #f))
  (let ((len (length messages)))
    (if (<= len keep-recent)
        messages
        (let* ((to-summarize (take messages (- len keep-recent)))
               (to-keep (take-right messages keep-recent))
               (summary (if summarize-fn
                            (summarize-fn to-summarize)
                            (generate-summary to-summarize))))
          (cons `(("role" . "system")
                  ("content" . ,(format #f "[Context Summary]\n~a" summary))
                  ("tokens" . ,(estimate-tokens summary))
                  ("compacted" . #t))
                to-keep)))))

;;; generate-summary: Generate a summary of messages (simple version)
(define (generate-summary messages)
  (let* ((user-msgs (filter (lambda (m) (equal? (assoc-ref m "role") "user"))
                            messages))
         (tool-calls (filter (lambda (m) (assoc-ref m "tool_call")) messages))
         (topics (extract-topics messages)))
    (format #f "Previous conversation (~a messages):
- User requests: ~a
- Tool calls: ~a
- Key topics: ~a"
            (length messages)
            (length user-msgs)
            (length tool-calls)
            (string-join topics ", "))))

;;; extract-topics: Extract key topics from messages
(define (extract-topics messages)
  (let* ((all-content (string-join
                       (map (lambda (m) (or (assoc-ref m "content") ""))
                            messages)
                       " "))
         (words (string-split (string-downcase all-content) #\space))
         (filtered (filter (lambda (w) (> (string-length w) 5)) words))
         (counts (fold (lambda (w acc)
                         (let ((existing (assoc w acc)))
                           (if existing
                               (assoc-set acc w (1+ (cdr existing)))
                               (cons (cons w 1) acc))))
                       '()
                       filtered))
         (sorted (sort counts (lambda (a b) (> (cdr a) (cdr b))))))
    (map car (take sorted (min 5 (length sorted))))))

(define (assoc-set alist key val)
  (cons (cons key val)
        (filter (lambda (p) (not (equal? (car p) key))) alist)))

;;; ============================================================
;;; Strategy 5: Intent-preserving Compaction
;;; ============================================================

;;; compact-intent: Preserve conversation intent while compacting
;;; Identifies the main goal and keeps relevant context
(define* (compact-intent messages #:key (max-tokens 4000))
  (let* ((intent (identify-intent messages))
         (relevant (filter-by-relevance messages intent))
         (system-msgs (filter (lambda (m)
                                (equal? (assoc-ref m "role") "system"))
                              messages)))
    ;; Add intent marker + relevant messages within budget
    (let ((intent-msg `(("role" . "system")
                        ("content" . ,(format #f "[Conversation Intent: ~a]" intent))
                        ("tokens" . 20))))
      (append (list intent-msg)
              system-msgs
              (select-within-budget
               (reverse relevant)
               (- max-tokens 20 (fold + 0 (map message-tokens system-msgs))))))))

;;; identify-intent: Identify main conversation intent
;;; Returns a safe description without exposing secrets
(define (identify-intent messages)
  (let* ((user-msgs (filter (lambda (m) (equal? (assoc-ref m "role") "user"))
                            messages))
         (first-user (if (null? user-msgs) ""
                         (or (assoc-ref (car user-msgs) "content") "")))
         (first-lower (string-downcase first-user)))
    ;; Extract intent category - never include raw user content
    (cond
     ((string-contains first-lower "fix")
      "Bug fixing / troubleshooting")
     ((string-contains first-lower "create")
      "Creating new functionality")
     ((string-contains first-lower "explain")
      "Understanding / learning")
     ((string-contains first-lower "test")
      "Testing / verification")
     ((string-contains first-lower "review")
      "Code review / analysis")
     ((string-contains first-lower "set up")
      "Configuration / setup")
     ((string-contains first-lower "help")
      "General assistance")
     ((string-contains first-lower "api")
      "API integration")
     ((string-contains first-lower "debug")
      "Debugging")
     (else
      ;; Generic fallback - extract first few safe words only
      (let* ((words (string-split first-lower #\space))
             (safe-words (filter (lambda (w)
                                   (and (< (string-length w) 15)
                                        (not (string-contains w "_"))
                                        (not (string-contains w "="))))
                                 words))
             (preview (string-join (take safe-words (min 5 (length safe-words))) " ")))
        (format #f "Task: ~a..." preview))))))

;;; filter-by-relevance: Filter messages by relevance to intent
(define (filter-by-relevance messages intent)
  (let ((intent-words (string-split (string-downcase intent) #\space)))
    (filter (lambda (m)
              (let ((content (string-downcase (or (assoc-ref m "content") ""))))
                (or (equal? (assoc-ref m "role") "system")
                    (any (lambda (w) (string-contains content w)) intent-words)
                    (assoc-ref m "tool_call")
                    ;; Always keep recent messages
                    #t)))
            messages)))

;;; ============================================================
;;; Auto Strategy Selection
;;; ============================================================

(define *compaction-strategies*
  '(("truncate" . compact-truncate)
    ("token-limit" . compact-token-limit)
    ("importance" . compact-importance)
    ("summarize" . compact-summarize)
    ("intent" . compact-intent)))

;;; compact-auto: Automatically select best strategy
(define* (compact-auto messages #:key (target-tokens 4000))
  (let* ((current-tokens (fold + 0 (map message-tokens messages)))
         (ratio (/ current-tokens target-tokens)))
    (cond
     ;; No compaction needed
     ((<= ratio 1.0) messages)
     ;; Light compaction - use truncation
     ((< ratio 1.5) (compact-truncate messages #:keep 15))
     ;; Medium compaction - use importance
     ((< ratio 2.0) (compact-importance messages #:keep 10))
     ;; Heavy compaction - use intent + summarize
     (else (compact-intent
            (compact-summarize messages #:keep-recent 5)
            #:max-tokens target-tokens)))))

;;; ============================================================
;;; Evaluation Framework
;;; ============================================================

;;; evaluate-compaction: Evaluate compaction quality
;;; Arguments:
;;;   original - Original messages
;;;   compacted - Compacted messages
;;;   eval-fn - Optional evaluation function (uses LLM if not provided)
;;; Returns: Evaluation result alist
(define* (evaluate-compaction original compacted #:key (eval-fn #f))
  (let* ((orig-tokens (fold + 0 (map message-tokens original)))
         (comp-tokens (fold + 0 (map message-tokens compacted)))
         (compression-ratio (if (> orig-tokens 0)
                                (/ comp-tokens orig-tokens)
                                1.0))
         (orig-msg-count (length original))
         (comp-msg-count (length compacted))
         ;; Measure information preservation
         (key-info-score (measure-key-info-retention original compacted))
         ;; Measure intent preservation
         (intent-score (measure-intent-preservation original compacted)))
    `(("original_tokens" . ,orig-tokens)
      ("compacted_tokens" . ,comp-tokens)
      ("compression_ratio" . ,compression-ratio)
      ("original_messages" . ,orig-msg-count)
      ("compacted_messages" . ,comp-msg-count)
      ("key_info_retention" . ,key-info-score)
      ("intent_preservation" . ,intent-score)
      ("overall_score" . ,(compaction-score key-info-score
                                            intent-score
                                            compression-ratio)))))

;;; measure-key-info-retention: Measure retention of key information
(define (measure-key-info-retention original compacted)
  (let* ((orig-keywords (extract-keywords original))
         (comp-keywords (extract-keywords compacted))
         (retained (length (filter (lambda (k) (member k comp-keywords))
                                   orig-keywords)))
         (total (length orig-keywords)))
    (if (> total 0) (/ retained total) 1.0)))

;;; extract-keywords: Extract important keywords from messages
(define (extract-keywords messages)
  (let* ((content (string-join
                   (map (lambda (m) (or (assoc-ref m "content") ""))
                        messages)
                   " "))
         (words (string-split (string-downcase content) #\space))
         (significant (filter (lambda (w)
                                (and (> (string-length w) 4)
                                     (not (member w '("the" "and" "that" "this"
                                                      "with" "from" "have")))))
                              words)))
    (delete-duplicates significant)))

;;; measure-intent-preservation: Check if conversation intent is preserved
(define (measure-intent-preservation original compacted)
  (let ((orig-intent (identify-intent original))
        (comp-intent (identify-intent compacted)))
    (if (equal? orig-intent comp-intent) 1.0 0.5)))

;;; compaction-score: Calculate overall compaction quality score
;;; Higher is better (0-100)
(define (compaction-score key-info intent compression)
  (let* ((info-weight 0.4)
         (intent-weight 0.4)
         (compression-weight 0.2)
         ;; Compression bonus: more compression = better, but not too aggressive
         (compression-score (cond
                              ((< compression 0.3) 0.5)  ; Too aggressive
                              ((< compression 0.5) 0.9)  ; Good
                              ((< compression 0.7) 0.8)  ; Okay
                              (else 0.6))))              ; Light compression
    (* 100 (+ (* info-weight key-info)
              (* intent-weight intent)
              (* compression-weight compression-score)))))

;;; ============================================================
;;; Evaluation Runner
;;; ============================================================

;;; run-compaction-eval: Run evaluation across all strategies
;;; Arguments:
;;;   messages - Test messages
;;;   target-tokens - Target token count
;;; Returns: List of (strategy . evaluation) pairs
(define* (run-compaction-eval messages #:key (target-tokens 2000))
  (map (lambda (strategy-pair)
         (let* ((name (car strategy-pair))
                (compacted (case (string->symbol name)
                             ((truncate) (compact-truncate messages #:keep 10))
                             ((token-limit) (compact-token-limit messages #:max-tokens target-tokens))
                             ((importance) (compact-importance messages #:keep 10))
                             ((summarize) (compact-summarize messages #:keep-recent 5))
                             ((intent) (compact-intent messages #:max-tokens target-tokens))))
                (eval-result (evaluate-compaction messages compacted)))
           (cons name eval-result)))
       *compaction-strategies*))
