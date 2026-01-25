;;; scenarios.scm --- Cloud stress test scenarios -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Defines scenarios for v0.2 cloud stress testing.
;; Each scenario is designed to push context limits and trigger compaction.

(define-module (tests stress scenarios)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-scenario
            scenario?
            scenario-id
            scenario-name
            scenario-description
            scenario-setup
            scenario-prompts
            scenario-expected-tools
            scenario-min-tool-calls
            scenario-expect-compaction
            *scenarios*
            get-scenario))

;;; Scenario Record

(define-record-type <scenario>
  (make-scenario id name description setup prompts expected-tools min-tool-calls expect-compaction)
  scenario?
  (id scenario-id)
  (name scenario-name)
  (description scenario-description)
  (setup scenario-setup)
  (prompts scenario-prompts)
  (expected-tools scenario-expected-tools)
  (min-tool-calls scenario-min-tool-calls)
  (expect-compaction scenario-expect-compaction))

;;; ============================================================
;;; Category A: E-Commerce State Machine Analysis
;;; ============================================================

(define scenario-solidus-state-machine
  (make-scenario
   'solidus-state-machine
   "Solidus Order State Machine"
   "Extract TLA+ specification from Solidus order lifecycle"
   '((repo . "solidus/solidus")
     (focus . "core/app/models/spree/order"))
   '("I need to understand the Solidus e-commerce platform's order state machine.
      First, let me see what files are in the order models directory."

     "Now search for 'state_machine' in the codebase to find how order states are defined."

     "Read the main order model file to understand the state machine configuration."

     "What are all the possible order states? List each state and what it means."

     "What transitions are defined between states? Show me each event and its from/to states."

     "What guard conditions protect these transitions? Find the methods that check permissions."

     "Now write a TLA+ specification for this order state machine. Include:
      - All states as a CONSTANT
      - State variable
      - Init condition
      - Next state relation for each transition
      - Guard conditions as predicates
      - Invariants that should always hold"

     "What edge cases could cause invalid states? Check for race conditions or missing guards.")
   '("list_files" "search_files" "read_file" "glob_files")
   15
   #t))

(define scenario-saleor-checkout
  (make-scenario
   'saleor-checkout
   "Saleor Checkout Flow"
   "Map Python/Django checkout as formal state machine"
   '((repo . "saleor/saleor")
     (focus . "saleor/checkout"))
   '("Analyze the Saleor e-commerce checkout flow. Start by listing the checkout directory structure."

     "Search for checkout state management - look for 'CheckoutState', 'status', or 'state' patterns."

     "Read the main checkout models to understand the data structures."

     "What checkout states exist? Map them from the code."

     "How does payment integration affect the state machine? Find payment-related transitions."

     "Document this as a state diagram with all transitions and conditions."

     "Compare this to a typical e-commerce flow - what's unique about Saleor's approach?")
   '("list_files" "search_files" "read_file" "glob_files")
   12
   #t))

;;; ============================================================
;;; Category B: Protocol Analysis
;;; ============================================================

(define scenario-http2-frames
  (make-scenario
   'http2-frames
   "HTTP/2 Frame Processing"
   "Extract frame processing state machine from HTTP/2 implementation"
   '((repo . "python-hyper/h2")
     (focus . "src/h2"))
   '("I want to understand HTTP/2 frame processing. List the h2 library source files."

     "Search for 'frame' and 'state' to find the frame processing logic."

     "Read the connection state machine implementation."

     "What are the HTTP/2 stream states according to this implementation?"

     "How does the library handle frame type validation?"

     "What error conditions trigger connection or stream resets?"

     "Produce a state machine diagram for HTTP/2 stream lifecycle.")
   '("list_files" "search_files" "read_file")
   10
   #f))

;;; ============================================================
;;; Category C: Compaction Stress
;;; ============================================================

(define scenario-guile-sage-refactor
  (make-scenario
   'guile-sage-refactor
   "guile-sage Plugin Architecture"
   "Read entire codebase and propose plugin system"
   '((repo . "local")
     (focus . "src/sage"))
   '("List all the files in src/sage/ to understand the project structure."

     "Read src/sage/config.scm and explain all the configuration options."

     "Read src/sage/util.scm and explain each utility function."

     "Read src/sage/tools.scm and explain how tools are registered."

     "Read src/sage/session.scm and explain how sessions are managed."

     "Read src/sage/ollama.scm and explain the API client implementation."

     "Read src/sage/compaction.scm and explain the compaction strategies."

     "Read src/sage/repl.scm and explain how the REPL processes commands."

     "Search for 'define-public' across all files to find all exported functions."

     "Search for 'error' across all files to understand error handling patterns."

     "How are tools currently registered and discovered? Show me the code."

     "How does the session management work with token tracking?"

     "Propose an architecture for a plugin system that would allow:
      - Third-party tools
      - Custom providers
      - Session middleware
      - Output formatters"

     "Show the specific changes needed in config.scm to support plugins."

     "Show the specific changes needed in tools.scm to support plugins."

     "Show the specific changes needed in session.scm to support plugins."

     "What backwards compatibility concerns exist?"

     "Write a sample plugin that adds a 'weather' tool."

     "Write a sample plugin that adds a custom output formatter."

     "Summarize everything you've learned about the codebase architecture.")
   '("list_files" "read_file" "search_files" "glob_files")
   25
   #t))

(define scenario-documentation-gen
  (make-scenario
   'documentation-gen
   "Exhaustive Documentation"
   "Generate complete API docs for all exports"
   '((repo . "local")
     (focus . "src/sage"))
   '("List all .scm files in src/sage/ directory."

     "Read src/sage/config.scm completely."

     "Document every function in config.scm with usage examples."

     "Read src/sage/util.scm completely."

     "Document every function in util.scm with usage examples."

     "Read src/sage/tools.scm completely."

     "Document every function in tools.scm with usage examples."

     "Read src/sage/session.scm completely."

     "Document every function in session.scm with usage examples."

     "Read src/sage/ollama.scm completely."

     "Document every function in ollama.scm with usage examples."

     "Read src/sage/compaction.scm completely."

     "Document every function in compaction.scm with usage examples."

     "Read src/sage/repl.scm completely."

     "Document every function in repl.scm with usage examples."

     "Read src/sage/main.scm completely."

     "Document the main entry point and CLI options."

     "Read src/sage/version.scm completely."

     "Search for all error conditions in the codebase."

     "Search for all #:export declarations to verify we covered all functions."

     "Create a comprehensive API reference document."

     "Create a quick reference card with the most commonly used functions."

     "Create usage examples for tool registration."

     "Create usage examples for session management."

     "Compile all documentation into a final summary.")
   '("list_files" "read_file" "glob_files" "search_files")
   30
   #t))

;;; ============================================================
;;; Scenario Registry
;;; ============================================================

(define *scenarios*
  (list scenario-solidus-state-machine
        scenario-saleor-checkout
        scenario-http2-frames
        scenario-guile-sage-refactor
        scenario-documentation-gen))

(define (get-scenario id)
  (find (lambda (s) (eq? (scenario-id s) id)) *scenarios*))
