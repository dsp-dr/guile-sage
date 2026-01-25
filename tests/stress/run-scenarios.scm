#!/usr/bin/env guile3
!#
;;; run-scenarios.scm --- Execute cloud stress test scenarios

(add-to-load-path "src")
(add-to-load-path "tests/stress")

(use-modules (sage config)
             (sage session)
             (sage tools)
             (sage util)
             (sage ollama)
             (sage repl)
             (stress scenarios)
             (srfi srfi-1)
             (ice-9 format)
             (ice-9 getopt-long))

;;; ============================================================
;;; Metrics Collection
;;; ============================================================

(define *metrics* '())

(define (record-metric name value)
  (set! *metrics* (cons (cons name value) *metrics*)))

(define (get-metric name)
  (assoc-ref *metrics* name))

;;; ============================================================
;;; Scenario Runner
;;; ============================================================

(define (run-scenario scenario)
  "Execute a single scenario and collect metrics."
  (format #t "~%~%")
  (format #t "╔══════════════════════════════════════════════════════════════╗~%")
  (format #t "║ SCENARIO: ~a~%" (scenario-name scenario))
  (format #t "║ ~a~%" (scenario-description scenario))
  (format #t "╚══════════════════════════════════════════════════════════════╝~%")

  (let ((start-time (current-time))
        (tool-calls 0)
        (compactions 0)
        (errors '())
        (api-calls 0))

    ;; Create fresh session
    (session-create #:name (symbol->string (scenario-id scenario)))

    ;; Execute each prompt
    (let loop ((prompts (scenario-prompts scenario))
               (turn 1))
      (unless (null? prompts)
        (let ((prompt (car prompts)))
          (format #t "~%─── Turn ~a ───────────────────────────────────────~%" turn)
          (format #t ">>> ~a~%~%" (if (> (string-length prompt) 100)
                                      (string-append (substring prompt 0 100) "...")
                                      prompt))

          ;; Get status before
          (let ((status-before (session-status)))
            (format #t "[Before] Tokens: ~a, Messages: ~a~%"
                    (or (assoc-ref status-before "estimated_tokens") "?")
                    (or (assoc-ref status-before "messages") 0)))

          ;; Execute the prompt
          (catch #t
            (lambda ()
              (set! api-calls (1+ api-calls))
              ;; Simulate what repl-eval does
              (session-add-message "user" prompt)
              (let* ((messages (session-get-context))
                     (model (ollama-model))
                     (response (ollama-chat-with-tools model messages (tools-to-schema)))
                     (message (assoc-ref response "message"))
                     (content (or (assoc-ref message "content") "")))

                ;; Check for tool call
                (let ((tool-call (ollama-parse-tool-call content)))
                  (when tool-call
                    (set! tool-calls (1+ tool-calls))
                    (let* ((tool-name (assoc-ref tool-call "name"))
                           (tool-args (assoc-ref tool-call "arguments"))
                           (result (execute-tool tool-name tool-args)))
                      (format #t "[Tool: ~a]~%" tool-name)
                      (format #t "~a~%"
                              (if (> (string-length result) 200)
                                  (string-append (substring result 0 200) "...")
                                  result)))))

                (session-add-message "assistant" content)
                (format #t "~%Response: ~a~%"
                        (if (> (string-length content) 300)
                            (string-append (substring content 0 300) "...")
                            content))))

            (lambda (key . args)
              (set! errors (cons (cons key args) errors))
              (format #t "[ERROR] ~a: ~a~%" key args)))

          ;; Get status after
          (let ((status-after (session-status)))
            (format #t "[After] Tokens: ~a, Messages: ~a~%"
                    (or (assoc-ref status-after "estimated_tokens") "?")
                    (or (assoc-ref status-after "messages") 0))

            ;; Check if compaction needed (80% threshold)
            (let ((tokens (or (assoc-ref status-after "estimated_tokens") 0))
                  (limit (get-token-limit (ollama-model))))
              (when (> (/ tokens limit) 0.8)
                (format #t "~%[COMPACTION] At ~a% of limit~%"
                        (inexact->exact (round (* 100 (/ tokens limit)))))
                (session-compact! #:keep-recent 10)
                (set! compactions (1+ compactions)))))

          (loop (cdr prompts) (1+ turn)))))

    ;; Summary
    (let ((end-time (current-time))
          (final-status (session-status)))
      (format #t "~%═══ SCENARIO COMPLETE ═════════════════════════════════════════~%")
      (format #t "Duration: ~a seconds~%" (- end-time start-time))
      (format #t "API calls: ~a~%" api-calls)
      (format #t "Tool calls: ~a~%" tool-calls)
      (format #t "Compactions: ~a~%" compactions)
      (format #t "Errors: ~a~%" (length errors))
      (format #t "Final tokens: ~a~%" (assoc-ref final-status "estimated_tokens"))
      (format #t "Final messages: ~a~%" (assoc-ref final-status "messages"))

      ;; Validation
      (let ((passed #t))
        (when (and (scenario-min-tool-calls scenario)
                   (< tool-calls (scenario-min-tool-calls scenario)))
          (format #t "⚠ Expected at least ~a tool calls, got ~a~%"
                  (scenario-min-tool-calls scenario) tool-calls)
          (set! passed #f))

        (when (and (scenario-expect-compaction scenario)
                   (= compactions 0))
          (format #t "⚠ Expected compaction but none occurred~%")
          (set! passed #f))

        (when (> (length errors) 0)
          (format #t "⚠ Errors occurred during execution~%")
          (for-each (lambda (e)
                      (format #t "  - ~a: ~a~%" (car e) (cdr e)))
                    errors))

        (if passed
            (format #t "~%✓ SCENARIO PASSED~%")
            (format #t "~%✗ SCENARIO FAILED~%"))

        passed))))

;;; ============================================================
;;; Main
;;; ============================================================

(define (main args)
  (format #t "~%")
  (format #t "╔══════════════════════════════════════════════════════════════╗~%")
  (format #t "║         guile-sage v0.2 Cloud Stress Tests                   ║~%")
  (format #t "╚══════════════════════════════════════════════════════════════╝~%")

  ;; Load config
  (config-load-dotenv)

  ;; Show configuration
  (format #t "~%Configuration:~%")
  (format #t "  Host: ~a~%" (ollama-host))
  (format #t "  Model: ~a~%" (ollama-model))
  (format #t "  Token Limit: ~a~%" (get-token-limit (ollama-model)))
  (format #t "  Local?: ~a~%" (if (is-local-provider?) "yes" "no"))

  ;; Initialize tools
  (init-default-tools)

  ;; Parse arguments
  (let* ((option-spec '((scenario (single-char #\s) (value #t))
                        (list (single-char #\l) (value #f))
                        (all (single-char #\a) (value #f))
                        (help (single-char #\h) (value #f))))
         (options (getopt-long args option-spec))
         (help? (option-ref options 'help #f))
         (list? (option-ref options 'list #f))
         (all? (option-ref options 'all #f))
         (scenario-id (option-ref options 'scenario #f)))

    (cond
     (help?
      (format #t "~%Usage: run-scenarios.scm [options]~%")
      (format #t "  -l, --list       List available scenarios~%")
      (format #t "  -s, --scenario   Run specific scenario by ID~%")
      (format #t "  -a, --all        Run all scenarios~%")
      (format #t "  -h, --help       Show this help~%"))

     (list?
      (format #t "~%Available scenarios:~%")
      (for-each (lambda (s)
                  (format #t "  ~a - ~a~%"
                          (scenario-id s)
                          (scenario-name s)))
                *scenarios*))

     (scenario-id
      (let ((scenario (get-scenario (string->symbol scenario-id))))
        (if scenario
            (run-scenario scenario)
            (format #t "Unknown scenario: ~a~%" scenario-id))))

     (all?
      (let ((results (map run-scenario *scenarios*)))
        (format #t "~%~%")
        (format #t "╔══════════════════════════════════════════════════════════════╗~%")
        (format #t "║                    FINAL SUMMARY                             ║~%")
        (format #t "╚══════════════════════════════════════════════════════════════╝~%")
        (format #t "Passed: ~a / ~a~%"
                (count identity results)
                (length results))))

     (else
      (format #t "~%No scenario specified. Use --help for options.~%")
      (format #t "Quick start: ./run-scenarios.scm --list~%")))))

;; Run if executed directly
(main (command-line))
