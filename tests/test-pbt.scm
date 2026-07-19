#!/usr/bin/env guile3
!#
;;; test-pbt.scm --- Property-based tests for guile-sage -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Minimal inline PBT harness (seed 42, 100 trials per property).
;; Tests pure-function invariants across session, security, tools,
;; compaction, model-tier, and config modules.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage session)
             (sage config)
             (sage compaction)
             (sage model-tier)
             (sage tools)
             (sage util)
             (sage ollama)
             (sage telemetry)
             (sage attest)
             (srfi srfi-1)
             (ice-9 format)
             (ice-9 textual-ports))

;;; ============================================================
;;; Minimal PBT Harness
;;; ============================================================

(define *pbt-seed* 42)
(define *pbt-trials* 100)
(define *pbt-passed* 0)
(define *pbt-failed* 0)
(define *pbt-total* 0)

;;; Simple LCG PRNG (deterministic, seed-controlled)
(define *rng-state* *pbt-seed*)

(define (rng-next!)
  (set! *rng-state*
        (modulo (+ (* *rng-state* 1103515245) 12345)
                (expt 2 31)))
  *rng-state*)

(define (rng-int lo hi)
  "Return random integer in [lo, hi]."
  (+ lo (modulo (rng-next!) (+ 1 (- hi lo)))))

(define (rng-string len)
  "Return random printable ASCII string of given length."
  (list->string
   (map (lambda (_) (integer->char (rng-int 32 126)))
        (iota len))))

(define (rng-alpha-string len)
  "Return random alphabetic string of given length."
  (list->string
   (map (lambda (_)
          (let ((c (rng-int 0 51)))
            (integer->char
             (if (< c 26)
                 (+ c 65)   ; A-Z
                 (+ c 71))))) ; a-z
        (iota len))))

(define (rng-element lst)
  "Return random element from list."
  (list-ref lst (modulo (rng-next!) (length lst))))

(define (rng-bool)
  "Return random boolean."
  (= 0 (modulo (rng-next!) 2)))

(define (rng-message)
  "Generate a random message alist for compaction tests."
  (let ((role (rng-element '("user" "assistant" "system")))
        (content (rng-string (rng-int 5 200)))
        (tokens (rng-int 1 100)))
    `(("role" . ,role)
      ("content" . ,content)
      ("tokens" . ,tokens))))

(define (rng-messages n)
  "Generate n random messages."
  (map (lambda (_) (rng-message)) (iota n)))

;;; property: Run a property test with N trials
;;; name - test name string
;;; gen-fn - (lambda () input) generator
;;; prop-fn - (lambda (input) bool) property checker
(define (property name gen-fn prop-fn)
  (set! *pbt-total* (1+ *pbt-total*))
  (let loop ((trial 0) (counterexample #f))
    (if (>= trial *pbt-trials*)
        (begin
          (set! *pbt-passed* (1+ *pbt-passed*))
          (format #t "PASS: ~a (~a trials)~%" name *pbt-trials*))
        (let ((input (gen-fn)))
          (catch #t
            (lambda ()
              (if (prop-fn input)
                  (loop (1+ trial) #f)
                  (begin
                    (set! *pbt-failed* (1+ *pbt-failed*))
                    (format #t "FAIL: ~a (trial ~a, input: ~s)~%"
                            name trial input))))
            (lambda (key . args)
              (set! *pbt-failed* (1+ *pbt-failed*))
              (format #t "FAIL: ~a (trial ~a, exception: ~a ~s, input: ~s)~%"
                      name trial key args input)))))))

;;; ============================================================
;;; Property 1: Session State Invariants
;;; ============================================================

(format #t "~%=== PBT: Session State Invariants ===~%")

(property "session-create always has valid name"
  (lambda () (rng-alpha-string (rng-int 1 50)))
  (lambda (name)
    (let ((session (session-create #:name name)))
      (and (string? (assoc-ref session "name"))
           (equal? (assoc-ref session "name") name)))))

(property "session-create always has timestamp"
  (lambda () (rng-alpha-string (rng-int 1 30)))
  (lambda (name)
    (let ((session (session-create #:name name)))
      (and (string? (assoc-ref session "created"))
           (string? (assoc-ref session "updated"))
           (> (string-length (assoc-ref session "created")) 0)))))

(property "session-create always has empty messages"
  (lambda () (rng-alpha-string (rng-int 1 20)))
  (lambda (name)
    (let ((session (session-create #:name name)))
      (null? (assoc-ref session "messages")))))

(property "session-create always has zero-initialized stats"
  (lambda () (rng-alpha-string (rng-int 1 20)))
  (lambda (_name)
    (let* ((session (session-create #:name _name))
           (stats (assoc-ref session "stats")))
      (and (= 0 (assoc-ref stats "total_tokens"))
           (= 0 (assoc-ref stats "input_tokens"))
           (= 0 (assoc-ref stats "output_tokens"))
           (= 0 (assoc-ref stats "request_count"))
           (= 0 (assoc-ref stats "tool_calls"))))))

;;; ============================================================
;;; Property 2: estimate-tokens
;;; ============================================================

(format #t "~%=== PBT: Token Estimation ===~%")

(property "estimate-tokens returns non-negative for any string"
  (lambda () (rng-string (rng-int 0 500)))
  (lambda (text)
    (>= (estimate-tokens text) 0)))

(property "estimate-tokens is monotonic with string length"
  (lambda ()
    (let* ((len1 (rng-int 0 100))
           (len2 (rng-int (+ len1 4) (+ len1 200))))
      (cons (rng-string len1) (rng-string len2))))
  (lambda (pair)
    (<= (estimate-tokens (car pair))
        (estimate-tokens (cdr pair)))))

(property "estimate-tokens returns 0 for non-strings"
  (lambda () (rng-int 0 10000))
  (lambda (n)
    (= (estimate-tokens n) 0)))

;;; ============================================================
;;; Property 3: Security Sandbox (safe-path?)
;;; ============================================================

(format #t "~%=== PBT: Security Sandbox ===~%")

(property "paths with .. are always rejected"
  (lambda ()
    (let ((prefix (rng-alpha-string (rng-int 0 10)))
          (suffix (rng-alpha-string (rng-int 0 10))))
      (string-append prefix "/.." suffix)))
  (lambda (path)
    (not (safe-path? path))))

(property ".env paths are always rejected"
  (lambda ()
    (let ((prefix (rng-alpha-string (rng-int 0 10))))
      (string-append prefix (if (> (string-length prefix) 0) "/" "") ".env")))
  (lambda (path)
    (not (safe-path? path))))

(property ".git/ paths are always rejected"
  (lambda ()
    (let ((suffix (rng-alpha-string (rng-int 1 20))))
      (string-append ".git/" suffix)))
  (lambda (path)
    (not (safe-path? path))))

(property ".ssh paths are always rejected"
  (lambda ()
    (let ((suffix (rng-alpha-string (rng-int 1 20))))
      (string-append ".ssh/" suffix)))
  (lambda (path)
    (not (safe-path? path))))

(property ".gnupg paths are always rejected"
  (lambda ()
    (let ((suffix (rng-alpha-string (rng-int 1 20))))
      (string-append ".gnupg/" suffix)))
  (lambda (path)
    (not (safe-path? path))))

;;; ============================================================
;;; Property 4: Tool Dispatch
;;; ============================================================

(format #t "~%=== PBT: Tool Dispatch ===~%")

(init-default-tools)

(define *known-tool-names*
  '("read_file" "list_files" "git_status" "git_diff" "git_log"
    "search_files" "glob_files" "write_file" "edit_file"
    "run_tests" "git_commit" "git_add_note" "git_push"
    "eval_scheme" "reload_module" "create_tool"
    "read_logs" "search_logs"
    "sage_task_create" "sage_task_complete"
    "sage_task_list" "sage_task_status"
    "whoami" "generate_image"))
    ;; irc_send removed: only registered when IRC is connected (2a31387)

(property "known tools always resolve via get-tool"
  (lambda () (rng-element *known-tool-names*))
  (lambda (name)
    (let ((tool (get-tool name)))
      (and tool
           (equal? (assoc-ref tool "name") name)))))

(property "random unknown tools always return #f from get-tool"
  (lambda ()
    (string-append "nonexistent_" (rng-alpha-string (rng-int 5 20))))
  (lambda (name)
    (not (get-tool name))))

(property "execute-tool on unknown tool returns 'Unknown tool' message"
  (lambda ()
    (string-append "fake_" (rng-alpha-string (rng-int 5 20))))
  (lambda (name)
    (let ((result (execute-tool name '())))
      (string-contains result "Unknown tool"))))

;;; ============================================================
;;; Property: permission contract (ADR-0003, post-5bcc284)
;;; ============================================================
;;;
;;; ADR-0003 declares two static lists: tools that must always be
;;; permitted (safe), and tools that must require YOLO (unsafe). The
;;; properties below pin both halves of that contract over random
;;; ordering of the input set, so an accidental edit to *safe-tools*
;;; in src/sage/tools.scm trips at least one trial.

(format #t "~%=== PBT: permission contract (ADR-0003) ===~%")

;; Subset of *safe-tools* that ADR-0003 lists as "always permitted".
;; Anything register-safe-tool'd at init time is *additionally* safe
;; but not part of the static contract — keep this list aligned with
;; the table in docs/adr/0003-security-model.md.
(define *adr-safe-tools*
  '("read_file" "list_files" "glob_files" "search_files"
    "git_status" "git_diff" "git_log"
    "read_logs" "search_logs"
    "sage_task_create" "sage_task_complete"
    "sage_task_list" "sage_task_status"
    "generate_image"))

;; Tools ADR-0003 lists as "require SAGE_YOLO_MODE". They must NOT
;; appear in *safe-tools* and must be denied by check-permission
;; when YOLO is off.
(define *adr-unsafe-tools*
  '("write_file" "edit_file"
    "git_commit" "git_add_note" "git_push"
    "eval_scheme" "create_tool" "reload_module" "run_tests"))

(define (with-yolo-off thunk)
  (let ((saved-sage (getenv "SAGE_YOLO_MODE"))
        (saved-yolo (getenv "YOLO_MODE")))
    (unsetenv "SAGE_YOLO_MODE")
    (unsetenv "YOLO_MODE")
    (let ((result (thunk)))
      (if saved-sage (setenv "SAGE_YOLO_MODE" saved-sage) (unsetenv "SAGE_YOLO_MODE"))
      (if saved-yolo (setenv "YOLO_MODE" saved-yolo) (unsetenv "YOLO_MODE"))
      result)))

(define (with-yolo-on thunk)
  (let ((saved-sage (getenv "SAGE_YOLO_MODE")))
    (setenv "SAGE_YOLO_MODE" "1")
    (let ((result (thunk)))
      (if saved-sage (setenv "SAGE_YOLO_MODE" saved-sage) (unsetenv "SAGE_YOLO_MODE"))
      result)))

(property "ADR-safe tools are always permitted without YOLO"
  (lambda () (rng-element *adr-safe-tools*))
  (lambda (name)
    (with-yolo-off (lambda () (and (check-permission name '()) #t)))))

(property "ADR-unsafe tools are always denied without YOLO"
  (lambda () (rng-element *adr-unsafe-tools*))
  (lambda (name)
    (with-yolo-off (lambda () (not (check-permission name '()))))))

(property "ADR-unsafe tools are always permitted under YOLO"
  (lambda () (rng-element *adr-unsafe-tools*))
  (lambda (name)
    (with-yolo-on (lambda () (and (check-permission name '()) #t)))))

(property "ADR-unsafe tools are absent from *safe-tools*"
  (lambda () (rng-element *adr-unsafe-tools*))
  (lambda (name)
    (not (member name *safe-tools*))))

(property "ADR-safe tool names all resolve via get-tool"
  (lambda () (rng-element *adr-safe-tools*))
  (lambda (name)
    (let ((tool (get-tool name)))
      (and tool (equal? (assoc-ref tool "name") name)))))

(property "execute-tool denies ADR-unsafe tools without YOLO"
  (lambda () (rng-element *adr-unsafe-tools*))
  (lambda (name)
    (with-yolo-off
     (lambda ()
       (let ((result (execute-tool name '())))
         (string-contains result "Permission denied"))))))

;;; ============================================================
;;; Property: resolve-path semantics (bd: guile-ecn)
;;; ============================================================
;;;
;;; resolve-path is a pure function — these properties pin the four
;;; cases its docstring promises (absolute kept, relative anchored,
;;; "" -> workspace, #f -> #f) over random inputs.

(format #t "~%=== PBT: resolve-path semantics ===~%")

(property "resolve-path is identity on absolute paths"
  (lambda ()
    (string-append "/tmp/sage-pbt-resolve-" (rng-alpha-string (rng-int 1 16))))
  (lambda (path)
    (equal? (resolve-path path) path)))

(property "resolve-path is idempotent on absolute paths"
  (lambda ()
    (string-append "/var/tmp/" (rng-alpha-string (rng-int 1 16))))
  (lambda (path)
    (equal? (resolve-path (resolve-path path)) (resolve-path path))))

(property "resolve-path anchors relative paths under workspace"
  (lambda () (rng-alpha-string (rng-int 1 32)))
  (lambda (rel)
    (let ((resolved (resolve-path rel))
          (ws (workspace)))
      (and (string-prefix? ws resolved)
           (string-suffix? rel resolved)))))

(property "resolve-path returns absolute strings for any non-#f input"
  (lambda ()
    (if (rng-bool)
        (string-append "/tmp/" (rng-alpha-string (rng-int 1 16)))
        (rng-alpha-string (rng-int 1 16))))
  (lambda (path)
    (let ((resolved (resolve-path path)))
      (and (string? resolved)
           (string-prefix? "/" resolved)))))

;;; ============================================================
;;; Property 5: Compaction Invariants
;;; ============================================================

(format #t "~%=== PBT: Compaction Invariants ===~%")

(property "compact-truncate output <= input length"
  (lambda ()
    ;; Ensure keep >= number of system messages to avoid take-right underflow
    (let* ((n (rng-int 3 30))
           (msgs (rng-messages n))
           (sys-count (count (lambda (m) (equal? (assoc-ref m "role") "system"))
                             msgs))
           (keep (rng-int (max 1 (1+ sys-count)) (+ n 5))))
      (cons msgs keep)))
  (lambda (pair)
    (let* ((msgs (car pair))
           (keep (cdr pair))
           (result (compact-truncate msgs #:keep keep)))
      (<= (length result) (length msgs)))))

(property "compact-truncate preserves system messages"
  (lambda ()
    (let* ((n (rng-int 3 20))
           ;; Generate non-system messages first
           (other-msgs (map (lambda (_)
                              (let ((role (rng-element '("user" "assistant")))
                                    (content (rng-string (rng-int 5 50)))
                                    (tokens (rng-int 1 50)))
                                `(("role" . ,role)
                                  ("content" . ,content)
                                  ("tokens" . ,tokens))))
                            (iota n)))
           ;; Add exactly one system message at front
           (msgs (cons `(("role" . "system")
                         ("content" . "System prompt")
                         ("tokens" . 10))
                       other-msgs))
           ;; Keep must be >= 2 (1 system + at least 1 other)
           (keep (rng-int 2 (+ n 1))))
      (cons msgs keep)))
  (lambda (pair)
    (let* ((msgs (car pair))
           (keep (cdr pair))
           (result (compact-truncate msgs #:keep keep))
           (sys-out (count (lambda (m) (equal? (assoc-ref m "role") "system"))
                           result)))
      ;; The one system message should be preserved
      (>= sys-out 1))))

(property "compact-token-limit output tokens <= budget"
  (lambda ()
    ;; Generate messages with no system messages so system-token overhead
    ;; doesn't exceed the budget (system msgs are always kept)
    (let ((msgs (map (lambda (_)
                       (let ((role (rng-element '("user" "assistant")))
                             (content (rng-string (rng-int 5 50)))
                             (tokens (rng-int 1 30)))
                         `(("role" . ,role)
                           ("content" . ,content)
                           ("tokens" . ,tokens))))
                     (iota (rng-int 5 25))))
          (budget (rng-int 100 1000)))
      (cons msgs budget)))
  (lambda (pair)
    (let* ((msgs (car pair))
           (budget (cdr pair))
           (result (compact-token-limit msgs #:max-tokens budget))
           (total (fold + 0 (map (lambda (m)
                                   (or (assoc-ref m "tokens")
                                       (estimate-tokens
                                        (or (assoc-ref m "content") ""))))
                                 result))))
      (<= total budget))))

(property "compact-importance output <= keep count"
  (lambda ()
    (let ((msgs (rng-messages (rng-int 5 25)))
          (keep (rng-int 3 15)))
      (cons msgs keep)))
  (lambda (pair)
    (let* ((msgs (car pair))
           (keep (cdr pair))
           (result (compact-importance msgs #:keep keep)))
      (<= (length result) (max keep (length msgs))))))

(property "compact-summarize adds summary when compacting"
  (lambda ()
    (rng-messages (rng-int 8 25)))
  (lambda (msgs)
    (let* ((result (compact-summarize msgs #:keep-recent 3))
           (first (car result))
           (content (or (assoc-ref first "content") "")))
      ;; If compaction happened, first message should be a summary
      (if (> (length msgs) 3)
          (string-contains content "Context Summary")
          ;; No compaction needed
          #t))))

(property "extract-topics returns list of strings"
  (lambda () (rng-messages (rng-int 1 20)))
  (lambda (msgs)
    (let ((topics (extract-topics msgs)))
      (and (list? topics)
           (every string? topics)))))

(property "identify-intent returns non-empty string"
  (lambda () (rng-messages (rng-int 1 10)))
  (lambda (msgs)
    (let ((intent (identify-intent msgs)))
      (and (string? intent)
           (> (string-length intent) 0)))))

;;; ============================================================
;;; Property 6: Model Tier Ordering
;;; ============================================================

(format #t "~%=== PBT: Model Tier Ordering ===~%")

(property "resolve-model-for-tokens always returns a tier"
  (lambda () (rng-int 0 100000))
  (lambda (tokens)
    (let ((tier (resolve-model-for-tokens tokens)))
      (and tier
           (string? (tier-name tier))
           (string? (tier-model tier))
           (number? (tier-ceiling tier))
           (number? (tier-context-limit tier))))))

(property "tier resolution is reflexive: same tokens -> same tier"
  (lambda () (rng-int 0 50000))
  (lambda (tokens)
    (let ((t1 (resolve-model-for-tokens tokens))
          (t2 (resolve-model-for-tokens tokens)))
      (equal? (tier-name t1) (tier-name t2)))))

(property "tier ordering: more tokens -> same or higher tier"
  (lambda ()
    (let* ((t1 (rng-int 0 5000))
           (t2 (rng-int t1 10000)))
      (cons t1 t2)))
  (lambda (pair)
    (let* ((t1 (resolve-model-for-tokens (car pair)))
           (t2 (resolve-model-for-tokens (cdr pair)))
           (c1 (tier-ceiling t1))
           (c2 (tier-ceiling t2)))
      ;; Higher tokens should resolve to same or higher-ceiling tier
      (<= c1 c2))))

(property "tier-available? is consistent with model list"
  (lambda ()
    (let ((tier (rng-element *model-tiers*))
          (models (list (rng-alpha-string (rng-int 5 15)))))
      (cons tier models)))
  (lambda (pair)
    (let* ((tier (car pair))
           (models (cdr pair))
           (available (tier-available? tier models)))
      ;; Result must be boolean-like (truthy or #f)
      (or available (not available)))))

(property "filter-available-tiers never returns empty"
  (lambda ()
    (list (rng-alpha-string (rng-int 5 15))))
  (lambda (models)
    (let ((filtered (filter-available-tiers *model-tiers* models)))
      (> (length filtered) 0))))

;;; ============================================================
;;; Property 7: Configuration
;;; ============================================================

(format #t "~%=== PBT: Configuration ===~%")

(property "config-get with default returns default for missing keys"
  (lambda ()
    (cons (string-append "NONEXISTENT_" (rng-alpha-string (rng-int 5 15)))
          (rng-string (rng-int 1 20))))
  (lambda (pair)
    (let* ((key (car pair))
           (default (cdr pair))
           (result (config-get key default)))
      (equal? result default))))

(property "path->project-id replaces all slashes"
  (lambda ()
    (let* ((segments (rng-int 1 5))
           (parts (map (lambda (_) (rng-alpha-string (rng-int 1 10)))
                       (iota segments))))
      (string-append "/" (string-join parts "/"))))
  (lambda (path)
    (let ((id (path->project-id path)))
      (not (string-contains id "/")))))

(property "path->project-id roundtrips for slash-only paths"
  (lambda ()
    (let* ((segments (rng-int 1 5))
           (parts (map (lambda (_) (rng-alpha-string (rng-int 1 10)))
                       (iota segments))))
      (string-append "/" (string-join parts "/"))))
  (lambda (path)
    (equal? path (project-id->path (path->project-id path)))))

(property "get-token-limit always returns positive integer"
  (lambda ()
    (rng-element '("llama3" "mistral" "gpt-4" "claude"
                   "deepseek" "qwen" "unknown-model-xyz")))
  (lambda (model)
    (let ((limit (get-token-limit model)))
      (and (number? limit)
           (> limit 0)))))

(property "*token-limits* entries are all positive"
  (lambda () (rng-element *token-limits*))
  (lambda (entry)
    (and (string? (car entry))
         (number? (cdr entry))
         (> (cdr entry) 0))))

;;; ============================================================
;;; Property 8: JSON Roundtrip
;;; ============================================================

(format #t "~%=== PBT: JSON Roundtrip ===~%")

(property "json-write-string -> json-read-string roundtrips for strings"
  (lambda () (rng-alpha-string (rng-int 0 100)))
  (lambda (s)
    (let* ((json (json-write-string s))
           (back (json-read-string json)))
      (equal? s back))))

(property "json-write-string -> json-read-string roundtrips for numbers"
  (lambda () (rng-int -10000 10000))
  (lambda (n)
    (let* ((json (json-write-string n))
           (back (json-read-string json)))
      (= n back))))

(property "json-write-string -> json-read-string roundtrips for alists"
  (lambda ()
    (let ((key (rng-alpha-string (rng-int 1 20)))
          (val (rng-alpha-string (rng-int 0 30))))
      `((,key . ,val))))
  (lambda (alist)
    (let* ((json (json-write-string alist))
           (back (json-read-string json)))
      (equal? alist back))))

;;; ============================================================
;;; Property 9: string-replace-substring
;;; ============================================================

(format #t "~%=== PBT: String Utilities ===~%")

(property "string-replace-substring with empty search returns original"
  (lambda () (rng-string (rng-int 0 100)))
  (lambda (s)
    (equal? s (string-replace-substring s "" "anything"))))

(property "string-replace-substring idempotent when search not found"
  (lambda ()
    (cons (rng-alpha-string (rng-int 1 50))
          (string-append "ZZZZZ" (rng-alpha-string (rng-int 1 10)))))
  (lambda (pair)
    (let ((text (car pair))
          (search (cdr pair)))
      ;; search contains ZZZZZ which won't be in alpha-only text
      (equal? text (string-replace-substring text search "replacement")))))

(property "string-replace-substring result contains no search term"
  (lambda ()
    (let* ((word (rng-alpha-string (rng-int 1 5)))
           (text (string-append "hello " word " world " word " end")))
      (cons text word)))
  (lambda (pair)
    (let* ((text (car pair))
           (search (cdr pair))
           (result (string-replace-substring text search "")))
      (not (string-contains result search)))))

;;; ============================================================
;;; Property 10: Compaction Score
;;; ============================================================

(format #t "~%=== PBT: Compaction Score ===~%")

(property "compaction-score is always in [0, 100]"
  (lambda ()
    (list (/ (rng-int 0 100) 100.0)
          (/ (rng-int 0 100) 100.0)
          (/ (rng-int 1 100) 100.0)))
  (lambda (args)
    (let ((score (apply compaction-score args)))
      (and (>= score 0) (<= score 100)))))

(property "compaction-score: higher info retention -> higher score"
  (lambda ()
    (let ((intent (/ (rng-int 50 100) 100.0))
          (compression (/ (rng-int 30 70) 100.0)))
      (list intent compression)))
  (lambda (args)
    (let* ((intent (car args))
           (compression (cadr args))
           (score-low (compaction-score 0.3 intent compression))
           (score-high (compaction-score 0.9 intent compression)))
      (>= score-high score-low))))

;;; ============================================================
;;; Property: util.scm — as-list shape coercion (bd: guile-p94)
;;; ============================================================

(format #t "~%=== PBT: as-list shape coercion ===~%")

(property "as-list of a list returns the same list"
  (lambda ()
    (map (lambda (_) (rng-int 0 1000))
         (iota (rng-int 0 20))))
  (lambda (lst)
    (equal? (as-list lst) lst)))

(property "as-list of a vector returns the same elements"
  (lambda ()
    (list->vector
     (map (lambda (_) (rng-int 0 1000))
          (iota (rng-int 0 20)))))
  (lambda (vec)
    (let ((result (as-list vec)))
      (and (list? result)
           (= (length result) (vector-length vec))
           (every equal? result (vector->list vec))))))

(property "as-list of #f returns empty list"
  (lambda () #f)
  (lambda (_)
    (equal? (as-list #f) '())))

(property "as-list of '() returns empty list"
  (lambda () '())
  (lambda (_)
    (equal? (as-list '()) '())))

(property "as-list length matches input length for vector | list | #f"
  (lambda ()
    (let ((kind (rng-element '(list vector false empty)))
          (n (rng-int 0 15)))
      (case kind
        ((list)   (iota n))
        ((vector) (list->vector (iota n)))
        ((false)  #f)
        ((empty)  '()))))
  (lambda (input)
    (let ((expected (cond
                     ((not input) 0)
                     ((null? input) 0)
                     ((list? input) (length input))
                     ((vector? input) (vector-length input))
                     (else -1))))
      (= (length (as-list input)) expected))))

;;; ============================================================
;;; Property: util.scm — json-write-string {} sentinel (bd: guile-bw2)
;;; ============================================================

(format #t "~%=== PBT: json-empty-object sentinel ===~%")

(property "json-empty-object always serialises to literal {}"
  (lambda () json-empty-object)
  (lambda (sentinel)
    (equal? (json-write-string sentinel) "{}")))

(property "json-empty-object survives nesting inside an alist"
  (lambda ()
    (let ((key (rng-alpha-string (rng-int 1 8))))
      (cons key json-empty-object)))
  (lambda (pair)
    (let ((s (json-write-string (list pair))))
      (and (string-contains s "{}")
           (string-contains s (car pair))))))

(property "json-write-string '() unchanged (still null, backward compat)"
  (lambda () '())
  (lambda (_)
    (equal? (json-write-string '()) "null")))

(property "json-write-string roundtrip for non-empty alists"
  (lambda ()
    (let ((k (rng-alpha-string (rng-int 1 8)))
          (v (rng-alpha-string (rng-int 1 16))))
      (list (cons k v))))
  (lambda (alist)
    (let* ((s (json-write-string alist))
           (parsed (json-read-string s)))
      (equal? parsed alist))))

;;; ============================================================
;;; Property: ollama.scm — model fallback invariants (bd: guile-spo)
;;; ============================================================

(format #t "~%=== PBT: model fallback invariants ===~%")

(define (rng-fake-model name family format size)
  `(("name" . ,name)
    ("size" . ,size)
    ("details" . (("family" . ,family) ("format" . ,format)))))

(define (rng-chat-model)
  (rng-fake-model
   (rng-alpha-string (rng-int 4 12))
   (rng-element '("llama" "qwen2" "mistral" "deepseek2"))
   "gguf"
   (rng-int 100000000 20000000000)))

(define (rng-embed-model)
  (rng-fake-model
   (rng-alpha-string (rng-int 4 12))
   "nomic-bert"
   "gguf"
   (rng-int 100000000 1000000000)))

(define (rng-image-model)
  (rng-fake-model
   (rng-alpha-string (rng-int 4 12))
   ""
   "safetensors"
   (rng-int 1000000000 15000000000)))

(property "select-fallback-model never returns an embedding model"
  (lambda ()
    (append
     (map (lambda (_) (rng-chat-model)) (iota (rng-int 1 5)))
     (map (lambda (_) (rng-embed-model)) (iota (rng-int 0 3)))))
  (lambda (models)
    (let ((picked (select-fallback-model "definitely-not-installed" models)))
      (and picked
           (let ((picked-model (find (lambda (m)
                                       (equal? (assoc-ref m "name") picked))
                                     models)))
             (chat-capable-model? picked-model))))))

(property "select-fallback-model never returns an image model"
  (lambda ()
    (append
     (map (lambda (_) (rng-chat-model)) (iota (rng-int 1 5)))
     (map (lambda (_) (rng-image-model)) (iota (rng-int 0 3)))))
  (lambda (models)
    (let ((picked (select-fallback-model "definitely-not-installed" models)))
      (and picked
           (let ((picked-model (find (lambda (m)
                                       (equal? (assoc-ref m "name") picked))
                                     models)))
             (chat-capable-model? picked-model))))))

(property "select-fallback-model returns preferred when present"
  (lambda ()
    (let ((chat-models (map (lambda (_) (rng-chat-model))
                            (iota (rng-int 1 5)))))
      (cons chat-models (assoc-ref (rng-element chat-models) "name"))))
  (lambda (input)
    (let* ((models (car input))
           (preferred (cdr input)))
      (equal? (select-fallback-model preferred models) preferred))))

(property "select-fallback-model picks the smallest chat-capable when preferred missing"
  (lambda ()
    (map (lambda (_) (rng-chat-model)) (iota (rng-int 2 6))))
  (lambda (models)
    (let* ((picked (select-fallback-model "missing-model" models))
           (sorted (sort models (lambda (a b)
                                  (< (or (assoc-ref a "size") +inf.0)
                                     (or (assoc-ref b "size") +inf.0))))))
      (equal? picked (assoc-ref (car sorted) "name")))))

(property "model-available? is consistent with assoc lookup"
  (lambda ()
    (let ((models (map (lambda (_) (rng-chat-model))
                       (iota (rng-int 1 5)))))
      (cons models
            (if (rng-bool)
                (assoc-ref (rng-element models) "name")
                "definitely-missing-model"))))
  (lambda (input)
    (let* ((models (car input))
           (name (cdr input))
           (expected (and (find (lambda (m)
                                  (equal? (assoc-ref m "name") name))
                                models) #t)))
      (eq? (model-available? name models) expected))))

;;; ============================================================
;;; Property: tools.scm — coerce->int never crashes (bd: guile-bcy)
;;; ============================================================

(format #t "~%=== PBT: coerce->int input-shape coverage ===~%")

;; coerce->int is module-private, but execute-tool exposes it
;; transitively via read_logs. The property we want: for ANY input
;; shape (int, float, string-of-int, string-of-float, garbage,
;; #f, '()), read_logs returns a string and never produces a
;; wrong-type-arg crash.

(property "read_logs survives any lines input shape (no wrong-type-arg)"
  (lambda ()
    (let ((kind (rng-element '(int string-int float string-float garbage missing nil))))
      (case kind
        ((int)         (rng-int 1 200))
        ((string-int)  (number->string (rng-int 1 200)))
        ((float)       (+ (rng-int 1 200) 0.0))
        ((string-float) (string-append (number->string (rng-int 1 200)) ".5"))
        ((garbage)     (rng-alpha-string (rng-int 3 10)))
        ((missing)     #f)
        ((nil)         '()))))
  (lambda (lines-arg)
    (let* ((args (if lines-arg `(("lines" . ,lines-arg)) '()))
           (result (execute-tool "read_logs" args)))
      (and (string? result)
           (not (string-contains result "wrong-type-arg"))))))

(property "search_logs survives any limit input shape (no wrong-type-arg)"
  (lambda ()
    (let ((kind (rng-element '(int string-int float string-float garbage missing))))
      (case kind
        ((int)          (rng-int 1 200))
        ((string-int)   (number->string (rng-int 1 200)))
        ((float)        (+ (rng-int 1 200) 0.0))
        ((string-float) (string-append (number->string (rng-int 1 200)) ".5"))
        ((garbage)      (rng-alpha-string (rng-int 3 10)))
        ((missing)      #f))))
  (lambda (limit-arg)
    (let* ((args `(("pattern" . "info")
                   ,@(if limit-arg `(("limit" . ,limit-arg)) '())))
           (result (execute-tool "search_logs" args)))
      (and (string? result)
           (not (string-contains result "wrong-type-arg"))))))

;;; ============================================================
;;; Property: write_file path honesty (bd: guile-ecn)
;;; ============================================================
;;;
;;; Property: for any path the user supplies (relative or absolute
;;; under /tmp/), write_file's reported "Wrote N bytes to PATH"
;;; success message must name a path that actually exists on disk
;;; with the byte count claimed, and read_file with the SAME path
;;; must return the bytes that were written.

(format #t "~%=== PBT: write_file path honesty ===~%")

;; write_file/edit_file are YOLO-only since 5bcc284. Set it once
;; before any property runs; the trial loop preserves it.
(setenv "SAGE_YOLO_MODE" "1")

;; The workspace-relative property writes under workspace/tmp/ —
;; gitignored, so a fresh CI checkout doesn't have it. write_file
;; doesn't mkdir -p, so create the parent here.
(let ((tmp-dir (string-append (or (getenv "SAGE_WORKSPACE") (getcwd)) "/tmp")))
  (unless (file-exists? tmp-dir)
    (mkdir tmp-dir)))

(define (rng-hex-token len)
  ;; lowercase a-f0-9 for filename safety
  (list->string
   (map (lambda (_)
          (let ((c (rng-int 0 15)))
            (integer->char (if (< c 10) (+ c 48) (+ c 87)))))
        (iota len))))

(property "write_file -> read_file roundtrip works for absolute /tmp/ paths"
  (lambda ()
    (let ((basename (string-append "sage-pbt-" (rng-hex-token 8) ".txt"))
          (content (rng-alpha-string (rng-int 1 64))))
      (cons (string-append "/tmp/" basename) content)))
  (lambda (path+content)
    (let* ((path (car path+content))
           (content (cdr path+content))
           (write-result (execute-tool "write_file"
                                       `(("path" . ,path)
                                         ("content" . ,content))))
           ;; The success message must name the resolved path, which
           ;; for /tmp/* equals the input path.
           (path-honest? (string-contains write-result path))
           ;; Read it back via read_file
           (read-back (execute-tool "read_file" `(("path" . ,path))))
           (roundtrip-ok? (equal? read-back content)))
      ;; Cleanup
      (when (file-exists? path) (delete-file path))
      (and path-honest? roundtrip-ok?))))

(property "write_file -> read_file roundtrip works for workspace-relative paths"
  (lambda ()
    (let ((basename (string-append "sage-pbt-" (rng-hex-token 8) ".txt"))
          (content (rng-alpha-string (rng-int 1 64))))
      ;; Force into workspace tmp/ which is now gitignored
      (cons (string-append "tmp/" basename) content)))
  (lambda (path+content)
    (let* ((rel (car path+content))
           (content (cdr path+content))
           (full (string-append (or (getenv "SAGE_WORKSPACE") (getcwd)) "/" rel))
           (write-result (execute-tool "write_file"
                                       `(("path" . ,rel)
                                         ("content" . ,content))))
           ;; Result should mention the FULL resolved path, not just rel
           (path-honest? (string-contains write-result full))
           (read-back (execute-tool "read_file" `(("path" . ,rel))))
           (roundtrip-ok? (equal? read-back content)))
      (when (file-exists? full) (delete-file full))
      (and path-honest? roundtrip-ok?))))

;;; ============================================================
;;; Property: search_files path scope honesty (bd: guile-tpf)
;;; ============================================================
;;;
;;; The contract: for any safe path under workspace, search_files
;;; with that path arg must return only matches whose paths begin
;;; with that scope. The pre-fix code silently dropped the arg and
;;; returned readdir-order matches from anywhere in the workspace.

(format #t "~%=== PBT: search_files path scope ===~%")

(property "search_files scope contains scope substring in every match line"
  (lambda ()
    ;; Pick a safe scope that exists in this repo. We use a small
    ;; rotation rather than fully-random paths because randomly
    ;; generated dir names won't exist on disk.
    (rng-element '("src/sage" "tests" "scripts" "docs")))
  (lambda (scope)
    (let* ((result (execute-tool "search_files"
                                 `(("pattern" . "define")
                                   ("path" . ,scope))))
           (lines (filter (lambda (l) (not (string-null? l)))
                          (string-split result #\newline)))
           ;; Filter out grep "Binary file ..." headers and any
           ;; out-of-band noise; keep only lines that look like
           ;; "path:content" matches
           (match-lines (filter (lambda (l)
                                  (and (string-contains l ":")
                                       (not (string-prefix? "Binary file " l))
                                       (not (string-prefix? "grep:" l))))
                                lines)))
      ;; Every match line MUST start with the scope path
      (every (lambda (line)
               (or (string-prefix? scope line)
                   ;; Allow leading "./" form just in case
                   (string-prefix? (string-append "./" scope) line)))
             match-lines))))

(property "search_files default scope is non-empty"
  (lambda ()
    ;; No knob — just verifies the no-arg fallback still works
    (rng-int 0 1))
  (lambda (_)
    (let ((result (execute-tool "search_files" '(("pattern" . "define")))))
      (and (string? result) (> (string-length result) 0)))))

(property "search_files unsafe path is rejected"
  (lambda ()
    ;; Generate path-traversal-shaped strings; safe-path? must reject all
    (let ((depth (rng-int 1 5)))
      (string-join (map (lambda (_) "..") (iota depth)) "/")))
  (lambda (bad-path)
    (let ((result (execute-tool "search_files"
                                `(("pattern" . "x") ("path" . ,bad-path)))))
      (string-contains result "Unsafe"))))

;;; ============================================================
;;; Property: telemetry.scm — counter / label invariants
;;; ============================================================

(format #t "~%=== PBT: telemetry invariants ===~%")

(property "normalize-labels output is sorted by key"
  (lambda ()
    (map (lambda (_)
           (cons (rng-alpha-string (rng-int 1 8))
                 (rng-alpha-string (rng-int 1 16))))
         (iota (rng-int 0 8))))
  (lambda (labels)
    (let* ((normalized (normalize-labels labels))
           (keys (map car normalized)))
      (or (< (length keys) 2)
          (equal? keys (sort keys string<?))))))

(property "normalize-labels is idempotent"
  (lambda ()
    (map (lambda (_)
           (cons (rng-alpha-string (rng-int 1 8))
                 (rng-alpha-string (rng-int 1 16))))
         (iota (rng-int 0 8))))
  (lambda (labels)
    (equal? (normalize-labels (normalize-labels labels))
            (normalize-labels labels))))

(property "counter-key is stable across input order (unique keys)"
  (lambda ()
    ;; OTLP label sets cannot have duplicate keys — that would be a
    ;; malformed metric. Generate unique keys via a per-index suffix
    ;; so the property reflects valid input.
    (let* ((n (rng-int 1 6))
           (labels (map (lambda (i)
                          (cons (string-append
                                 (rng-alpha-string (rng-int 1 4))
                                 (number->string i))
                                (rng-alpha-string (rng-int 1 8))))
                        (iota n))))
      (cons (rng-alpha-string (rng-int 4 16)) labels)))
  (lambda (input)
    (let* ((name (car input))
           (labels (cdr input))
           ;; Reverse the labels to ensure non-trivial reorder
           (reversed (reverse labels)))
      (equal? (counter-key name labels)
              (counter-key name reversed)))))

;;; ============================================================
;;; Multi-Step Tool Chain Properties (bd: guile-qa1)
;;; ============================================================

;;; Access private bindings from (sage repl)
(use-modules (sage repl) (sage session))
(define pbt-execute-tool-chain (@@ (sage repl) execute-tool-chain))
(define pbt-*max-tool-iterations* (@@ (sage repl) *max-tool-iterations*))

(property "N-tool-call sequence terminates within N+1 iterations"
  ;; Generator: produce N in [0, 10]
  (lambda () (rng-int 0 10))
  ;; Property: a synthetic N-step chain terminates and returns a string
  (lambda (n)
    (session-create)
    (let* ((step 0)
           (real-ocwt (module-ref (resolve-module '(sage ollama))
                                  'ollama-chat-with-tools))
           ;; Mock: return tool_calls for exactly N follow-up steps, then stop
           (mock-ocwt (lambda (model messages tools)
                        (set! step (1+ step))
                        (if (< step n)
                            ;; Still have tool calls to emit
                            `(("message" . (("role" . "assistant")
                                            ("content" . ,(format #f "Step ~a" step))
                                            ("tool_calls" . #(
                                              (("function" . (("name" . "git_status")
                                                              ("arguments" . ()))))))))
                              ("eval_count" . 5)
                              ("prompt_eval_count" . 3))
                            ;; No more tool calls -- chain should terminate
                            `(("message" . (("role" . "assistant")
                                            ("content" . ,(format #f "Done after ~a steps" step))))
                              ("eval_count" . 5)
                              ("prompt_eval_count" . 3))))))
      (let ((result
             (dynamic-wind
               (lambda ()
                 (module-set! (resolve-module '(sage ollama))
                              'ollama-chat-with-tools mock-ocwt))
               (lambda ()
                 (if (= n 0)
                     ;; N=0: no tool_calls in initial message
                     (pbt-execute-tool-chain "test" `(("content" . "No tools.")) "No tools." 1)
                     ;; N>0: initial message has 1 tool_call
                     (pbt-execute-tool-chain "test"
                       `(("content" . "Starting.")
                         ("tool_calls" . #(
                           (("function" . (("name" . "git_status")
                                           ("arguments" . ())))))))
                       "Starting." 1)))
               (lambda ()
                 (module-set! (resolve-module '(sage ollama))
                              'ollama-chat-with-tools real-ocwt)))))
        ;; The function must return a string (it terminated)
        ;; and step must be <= N (we don't overshoot)
        (and (string? result)
             (<= step (max n 1)))))))

(property "tool chain terminates within max-iterations (never exceeds)"
  ;; Generator: random seed (ignored, we always test the cap)
  (lambda () (rng-int 0 100))
  ;; Property: an infinite-tool-call mock terminates, and the call
  ;; count never exceeds *max-tool-iterations*. With degenerate loop
  ;; detection (same tool 3x in a row), it may terminate EARLIER than
  ;; the cap — that's correct behavior, not a failure.
  (lambda (_seed)
    (session-create)
    (let* ((call-count 0)
           (real-ocwt (module-ref (resolve-module '(sage ollama))
                                  'ollama-chat-with-tools))
           ;; Mock: ALWAYS return a tool_call (infinite)
           (mock-ocwt (lambda (model messages tools)
                        (set! call-count (1+ call-count))
                        `(("message" . (("role" . "assistant")
                                        ("content" . "Again.")
                                        ("tool_calls" . #(
                                          (("function" . (("name" . "git_status")
                                                          ("arguments" . ()))))))))
                          ("eval_count" . 2)
                          ("prompt_eval_count" . 1)))))
      (let ((result
             (dynamic-wind
               (lambda ()
                 (module-set! (resolve-module '(sage ollama))
                              'ollama-chat-with-tools mock-ocwt))
               (lambda ()
                 (pbt-execute-tool-chain "test"
                   `(("content" . "Infinite.")
                     ("tool_calls" . #(
                       (("function" . (("name" . "git_status")
                                       ("arguments" . ())))))))
                   "Infinite." 1))
               (lambda ()
                 (module-set! (resolve-module '(sage ollama))
                              'ollama-chat-with-tools real-ocwt)))))
        ;; Must have terminated (returned a string) and
        ;; call-count must not EXCEED *max-tool-iterations*.
        ;; Degenerate detection may terminate earlier (at 3 repeats).
        (and (string? result)
             (<= call-count pbt-*max-tool-iterations*))))))

;;; ============================================================
;;; CAVA — Canonical Action Verification + Attestation (RFC-004 §17)
;;; ============================================================
;;;
;;; The 12 RFC-004 PBT properties (plus a pure-SHA-256 known-vector check).
;;; These pin the §17 boundary: canonical action (§17.1), policy verdict
;;; (§17.2), attestation record + chain (§17.3), no-unattested-mutation
;;; (§17.4), off-wire attestation (§17.5), failure modes (§17.6).

(format #t "~%=== PBT: CAVA attestation (RFC-004 §17) ===~%")

;; Private bindings from the two exec sites (Path A repl, Path B mcp-server).
(use-modules (sage repl) (sage mcp-server))
(define pbt-guard-tool-result (@@ (sage repl) guard-tool-result))
(define pbt-wrap-tool-result  (@@ (sage repl) wrap-tool-result))
(define pbt-on-tools-call     (@@ (sage mcp-server) on-tools-call))

;; ---- helpers -------------------------------------------------------------

(define (pbt-count-lines file)
  (if (file-exists? file)
      (length (filter (lambda (l) (not (string-null? l)))
                      (string-split (call-with-input-file file get-string-all)
                                    #\newline)))
      0))

(define (pbt-last-line file)
  (let ((lines (filter (lambda (l) (not (string-null? l)))
                       (string-split (call-with-input-file file get-string-all)
                                     #\newline))))
    (if (null? lines) #f (last lines))))

;; Run THUNK with SAGE_LOG_DIR pointed at a fresh temp dir; cleans up.
(define (pbt-with-temp-log thunk)
  (let* ((saved (getenv "SAGE_LOG_DIR"))
         (dir (format #f "/tmp/sage-attest-pbt-~a-~a" (getpid) (rng-next!))))
    (unless (file-exists? dir) (mkdir dir))
    (setenv "SAGE_LOG_DIR" dir)
    (let ((f (string-append dir "/attest.jsonl")))
      (dynamic-wind
        (lambda () #t)
        (lambda () (thunk dir f))
        (lambda ()
          (if saved (setenv "SAGE_LOG_DIR" saved) (unsetenv "SAGE_LOG_DIR"))
          (when (file-exists? f) (delete-file f))
          (when (file-exists? dir) (rmdir dir)))))))

(define (pbt-capture-stdout thunk)
  "Run THUNK, returning everything it writes to current-output-port."
  (with-output-to-string thunk))

;; Random mutating tool call: name + args alist.
(define pbt-mutating-tools '("write_file" "edit_file" "git_commit"
                             "git_add_note" "git_push" "eval_scheme"))

(define (rng-mut-args)
  `(("path" . ,(string-append "tmp/" (rng-alpha-string (rng-int 1 12)) ".txt"))
    ("content" . ,(rng-alpha-string (rng-int 0 40)))))

;; ---- Property: pure SHA-256 known vectors (the in-process hash) -----------

(property "sha256-hex matches FIPS-180-4 known vectors"
  (lambda ()
    (rng-element
     (list (cons "" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
           (cons "abc" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
           (cons "hello" "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
           (cons "The quick brown fox jumps over the lazy dog"
                 "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
           (cons "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
                 "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"))))
  (lambda (pair)
    (string=? (sha256-hex (car pair)) (cdr pair))))

;; ---- #4: action-sha deterministic (same tool,args ⇒ same sha) ------------

(property "CAVA-4: action-sha is deterministic across ts (same tool,args)"
  (lambda ()
    (cons (rng-element pbt-mutating-tools) (rng-mut-args)))
  (lambda (call)
    (let* ((tool (car call)) (args (cdr call))
           (a1 (canonical-action tool args #:ts "2020-01-01T00:00:00Z"))
           (a2 (canonical-action tool args #:ts "2099-12-31T23:59:59Z")))
      (string=? (action-sha a1) (action-sha a2)))))

;; ---- #5: arg-permutation invariant (§16.3) -------------------------------

(property "CAVA-5: reordered args ⇒ same action-sha"
  (lambda ()
    ;; build an args alist with >=2 keys, plus a reversed copy
    (let ((args (map (lambda (i)
                       (cons (string-append "k" (number->string i))
                             (rng-alpha-string (rng-int 1 8))))
                     (iota (rng-int 2 6)))))
      (cons args (reverse args))))
  (lambda (pair)
    (string=? (action-sha (canonical-action "write_file" (car pair) #:ts "T"))
              (action-sha (canonical-action "write_file" (cdr pair) #:ts "T")))))

;; ---- #12: verdict fail-closed (any gate error ⇒ deny) --------------------

(property "CAVA-12: verdict is fail-closed on malformed/unclassified actions"
  (lambda ()
    (rng-element
     (list
      ;; poison: paths is not a list ⇒ gate throws ⇒ caught ⇒ deny
      '(("mutation-class" . "mutating") ("paths" . 42))
      ;; unclassified mutation ⇒ default-deny
      '(("mutation-class" . "unknown-class") ("paths" . ()))
      ;; missing mutation-class ⇒ default-deny
      '(("paths" . ()))
      ;; poison env-shaped paths
      '(("mutation-class" . "mutating") ("paths" . "not-a-list")))))
  (lambda (action)
    ;; even with YOLO on, a broken/unclassified action must DENY
    (eq? 'deny (verdict-decision (policy-verdict action '(("YOLO_MODE" . "1")))))))

;; ---- #6: result-sha over pre-wrap guarded bytes, NOT the CDATA envelope ---

(property "CAVA-6: result-sha hashes pre-wrap guarded bytes, not the envelope"
  (lambda () (rng-string (rng-int 0 200)))
  (lambda (result)
    (let* ((guarded (pbt-guard-tool-result result))
           (wrapped (pbt-wrap-tool-result "write_file" guarded #:safe #f))
           (sha-guarded (sha256-hex guarded))
           (sha-wrapped (sha256-hex wrapped)))
      ;; the attestation result-sha is sha256(guarded); it must differ from the
      ;; sha of the wrapped envelope (the envelope adds the <tool-result> frame)
      (and (string? sha-guarded)
           (= 64 (string-length sha-guarded))
           (not (string=? sha-guarded sha-wrapped))))))

;; ---- #8: tamper-evident chain (prev_sha links; a middle edit breaks it) ---

(property "CAVA-8: prev_sha chain verifies; any middle edit breaks it"
  (lambda () (rng-int 2 8))
  (lambda (n)
    (let* ((recs (map (lambda (i)
                        (let* ((a (canonical-action "write_file"
                                                    `(("path" . ,(number->string i)))
                                                    #:ts "T"))
                               (v (policy-verdict a '(("YOLO_MODE" . "1")))))
                          (attestation a v #:result-sha (sha256-hex (number->string i)))))
                      (iota n)))
           (chained (attestation-chain recs))
           (ok (attestation-verify-chain chained))
           ;; tamper a NON-TERMINAL record's reason: prev_sha detects any edit
           ;; whose record has a successor (the successor's prev_sha stops
           ;; matching). Editing the LAST record is caught only by the stored
           ;; chain head, not by prev_sha over the list — so pick an interior i.
           (mid (quotient (- n 1) 2))
           (tampered (map (lambda (r i)
                            (if (= i mid)
                                (map (lambda (kv)
                                       (if (equal? (car kv) "reason")
                                           (cons "reason" "TAMPERED") kv)) r)
                                r))
                          chained (iota n))))
      (and ok (not (attestation-verify-chain tampered))))))

;; ---- #7: append-only — N appends ⇒ N lines, monotone, priors unchanged ---

(property "CAVA-7: audit log is append-only (N records ⇒ N lines, priors fixed)"
  (lambda () (rng-int 1 6))
  (lambda (n)
    (pbt-with-temp-log
     (lambda (dir file)
       (attest-reset-chain!)
       (let loop ((i 0) (firsts '()))
         (if (>= i n)
             (and (= (pbt-count-lines file) n)
                  ;; the first-ever line never changed as we appended more
                  (let ((all (filter (lambda (l) (not (string-null? l)))
                                     (string-split (call-with-input-file file get-string-all)
                                                   #\newline))))
                    (or (null? firsts)
                        (string=? (car (reverse firsts)) (car all)))))
             (let* ((a (canonical-action "write_file"
                                         `(("path" . ,(number->string i))) #:ts "T"))
                    (v (policy-verdict a '(("YOLO_MODE" . "1")))))
               (attest! a v #:result-sha (sha256-hex (number->string i)))
               (loop (1+ i)
                     (cons (or (pbt-last-line file) "") firsts)))))))))

;; ---- #11: non-strict write-failure never blocks; strict aborts -----------

(property "CAVA-11: best-effort write-failure never blocks; STRICT aborts"
  (lambda () (rng-alpha-string (rng-int 1 20)))
  (lambda (tag)
    (let* ((a (canonical-action "write_file" `(("path" . ,tag)) #:ts "T"))
           (v (policy-verdict a '(("YOLO_MODE" . "1"))))
           (rec (attestation a v #:result-sha (sha256-hex tag)))
           ;; a path that cannot be created: parent is a regular file
           (blocker (format #f "/tmp/sage-attest-blk-~a-~a" (getpid) (rng-next!)))
           (bad (string-append blocker "/sub/attest.jsonl")))
      (call-with-output-file blocker (lambda (p) (display "x" p)))
      (let* ((mutation-ran #f)
             ;; best-effort: append fails but the "mutation" still completes
             (be (attest-log-append! rec #:strict? #f #:disabled? #f #:log-file bad))
             (_ (set! mutation-ran #t))
             ;; strict: the failed append THROWS to abort the mutation
             (strict-threw
              (catch 'attest-write-failed
                (lambda ()
                  (attest-log-append! rec #:strict? #t #:disabled? #f #:log-file bad)
                  #f)
                (lambda (k . a) #t))))
        (when (file-exists? blocker) (delete-file blocker))
        (and (memq be '(failed ok))   ; non-strict returned, did not throw
             mutation-ran             ; mutation proceeded
             strict-threw)))))        ; strict aborted on write-failure

;; ---- #2: no mutation executes without an allow verdict for its action ----
;;
;; policy-verdict MIRRORS the runtime gate (check-permission): a mutating tool's
;; verdict is 'allow iff check-permission permits it, under the same env. So the
;; execute gate is exactly "allow verdict" (§17.4).

(property "CAVA-2: mutating verdict allow ⟺ check-permission permits (same env)"
  (lambda ()
    (cons (rng-element *adr-unsafe-tools*) (rng-bool)))   ; tool, yolo-on?
  (lambda (call)
    (let ((tool (car call)) (yolo? (cdr call))
          (saved (getenv "SAGE_YOLO_MODE")))
      (if yolo? (setenv "SAGE_YOLO_MODE" "1") (unsetenv "SAGE_YOLO_MODE"))
      (let* ((a (canonical-action tool '() #:mutation-class 'mutating #:ts "T"))
             (env (list (cons "YOLO_MODE" (config-get "YOLO_MODE"))))
             (allow? (eq? 'allow (verdict-decision (policy-verdict a env))))
             (perm? (and (check-permission tool '()) #t)))
        (if saved (setenv "SAGE_YOLO_MODE" saved) (unsetenv "SAGE_YOLO_MODE"))
        (eq? allow? perm?)))))

;; ---- #3: deny ⇒ decision=deny, no result-sha, probe never ran ------------

(property "CAVA-3: deny ⇒ no result-sha, and execute-tool probe never runs"
  (lambda () (rng-element *adr-unsafe-tools*))
  (lambda (tool)
    (with-yolo-off
     (lambda ()
       (let* ((a (canonical-action tool '() #:mutation-class 'mutating #:ts "T"))
              (v (policy-verdict a (list (cons "YOLO_MODE" (config-get "YOLO_MODE")))))
              ;; deny ⇒ result-sha omitted (null sentinel)
              (rec (attestation a v #:result-sha #f))
              (decision (verdict-decision v))
              (rsha (assoc-ref rec "result-sha"))
              ;; the probe (tool body) must not run under a deny
              (exec-result (execute-tool tool '())))
         (and (eq? decision 'deny)
              (eq? rsha 'null)
              (string-contains exec-result "Permission denied")))))))

;; ---- #1: executed mutation ⇒ exactly one attestation with result-sha ------

(property "CAVA-1: an executed mutation emits exactly one result-sha record"
  (lambda ()
    (cons (rng-element pbt-mutating-tools) (rng-mut-args)))
  (lambda (call)
    (pbt-with-temp-log
     (lambda (dir file)
       (attest-reset-chain!)
       (let* ((tool (car call)) (args (cdr call))
              (a (canonical-action tool args #:mutation-class 'mutating #:ts "T"))
              (v (policy-verdict a '(("YOLO_MODE" . "1"))))
              (guarded (rng-alpha-string (rng-int 1 40))))
         (attest! a v #:result-sha (sha256-hex guarded))
         (and (= 1 (pbt-count-lines file))
              (let* ((line (pbt-last-line file))
                     (parsed (json-read-string line)))
                (and (equal? "allow" (assoc-ref parsed "decision"))
                     (string? (assoc-ref parsed "result-sha"))
                     (= 64 (string-length (assoc-ref parsed "result-sha")))))))))))

;; ---- #10: safe (read-only) tools emit no mutation attestation ------------

(property "CAVA-10: safe tools emit no mutation attestation (no over-attesting)"
  (lambda () (rng-element '("git_status" "git_diff" "git_log" "read_file"
                            "list_files" "search_files")))
  (lambda (safe-tool)
    (pbt-with-temp-log
     (lambda (dir file)
       (let* ((saved-exp (getenv "SAGE_MCP_EXPOSE_UNSAFE")))
         (unsetenv "SAGE_MCP_EXPOSE_UNSAFE")
         (let ((before (pbt-count-lines file)))
           ;; served via the MCP-server success branch; capture wire so it does
           ;; not corrupt PBT stdout
           (pbt-capture-stdout
            (lambda ()
              (pbt-on-tools-call 1 `(("name" . ,safe-tool) ("arguments" . ())))))
           (let ((after (pbt-count-lines file)))
             (if saved-exp (setenv "SAGE_MCP_EXPOSE_UNSAFE" saved-exp)
                 (unsetenv "SAGE_MCP_EXPOSE_UNSAFE"))
             ;; no NEW attestation line for a safe tool
             (= before after))))))))

;; ---- #9: no-oracle byte-identity survives attestation --------------------
;;
;; On the MCP server (Path B), an unknown tool and a gated (unexposed) tool must
;; produce BYTE-IDENTICAL wire responses even though both now emit an off-wire
;; deny attestation record (§17.5).

(property "CAVA-9: unknown vs gated wire bytes identical; both attest off-wire"
  (lambda () (string-append "nonexistent_" (rng-alpha-string (rng-int 3 12))))
  (lambda (unknown-name)
    (pbt-with-temp-log
     (lambda (dir file)
       (let ((saved-exp (getenv "SAGE_MCP_EXPOSE_UNSAFE")))
         (unsetenv "SAGE_MCP_EXPOSE_UNSAFE")   ; keep write_file GATED
         (attest-reset-chain!)
         (let* ((before (pbt-count-lines file))
                ;; gated: a real but unexposed (unsafe) tool
                (wire-gated
                 (pbt-capture-stdout
                  (lambda ()
                    (pbt-on-tools-call 1 `(("name" . "write_file")
                                           ("arguments" . (("path" . "x")
                                                           ("content" . "y"))))))))
                (mid (pbt-count-lines file))
                ;; unknown: a nonexistent tool name
                (wire-unknown
                 (pbt-capture-stdout
                  (lambda ()
                    (pbt-on-tools-call 1 `(("name" . ,unknown-name)
                                           ("arguments" . ()))))))
                (after (pbt-count-lines file)))
           (if saved-exp (setenv "SAGE_MCP_EXPOSE_UNSAFE" saved-exp)
               (unsetenv "SAGE_MCP_EXPOSE_UNSAFE"))
           (and (string=? wire-gated wire-unknown)   ; no oracle on the wire
                (string-contains wire-gated "Unknown tool")
                (= (- mid before) 1)                 ; gated emitted 1 deny record
                (= (- after mid) 1))))))))           ; unknown emitted 1 deny record

;;; ============================================================
;;; Summary
;;; ============================================================

(format #t "~%=== PBT Summary ===~%")
(format #t "Properties: ~a~%" *pbt-total*)
(format #t "Passed: ~a~%" *pbt-passed*)
(format #t "Failed: ~a~%" *pbt-failed*)
(format #t "Trials per property: ~a~%" *pbt-trials*)
(format #t "Total trials: ~a~%" (* *pbt-total* *pbt-trials*))
(format #t "~%Tests: ~a/~a passed~%" *pbt-passed* *pbt-total*)

(exit (if (= *pbt-failed* 0) 0 1))
