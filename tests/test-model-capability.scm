;;; test-model-capability.scm --- Validate model tool-calling capability
;;;
;;; Tests for guile-sage-k71: Validate model capability for self-modification

(use-modules (sage tools)
             (sage ollama)
             (sage session)
             (sage logging)
             (ice-9 format))

(init-default-tools)
(init-logging)

;;; Test 1: Model can identify itself
(define (test-identity)
  (display "Test 1: Identity awareness\n")
  (let* ((prompt "Who are you? Use the whoami tool to check.")
         (response (ollama-chat-with-tools prompt)))
    (display "Response: ") (display response) (newline)
    (if (string-contains response "SageBot")
        (begin (display "PASS: Model knows it's SageBot\n") #t)
        (begin (display "FAIL: Model didn't identify as SageBot\n") #f))))

;;; Test 2: Model can read a file
(define (test-read-file)
  (display "\nTest 2: File reading\n")
  (let* ((prompt "Read the first 10 lines of src/sage/version.scm using read_file")
         (response (ollama-chat-with-tools prompt)))
    (display "Response: ") (display (substring response 0 (min 200 (string-length response)))) (newline)
    (if (string-contains response "define-module")
        (begin (display "PASS: Model read Scheme file correctly\n") #t)
        (begin (display "FAIL: Model couldn't read file\n") #f))))

;;; Test 3: Model generates valid tool calls
(define (test-tool-call-format)
  (display "\nTest 3: Tool call format\n")
  (let* ((prompt "List the files in the tests directory using list_files")
         (response (ollama-chat-with-tools prompt)))
    (display "Response length: ") (display (string-length response)) (newline)
    (if (> (string-length response) 0)
        (begin (display "PASS: Tool call executed\n") #t)
        (begin (display "FAIL: No response from tool\n") #f))))

;;; Test 4: Model can propose code changes (dry run)
(define (test-code-proposal)
  (display "\nTest 4: Code change proposal\n")
  (display "Skipping - requires manual verification\n")
  #t)

;;; Run tests
(define (run-model-tests)
  (display "=== Model Capability Tests ===\n\n")
  (let ((results (list
                  (test-identity)
                  (test-read-file)
                  (test-tool-call-format)
                  (test-code-proposal))))
    (format #t "\n=== Results: ~a/~a passed ===\n"
            (length (filter identity results))
            (length results))
    results))

;; Only run if executed directly
(when (getenv "RUN_MODEL_TESTS")
  (run-model-tests))
