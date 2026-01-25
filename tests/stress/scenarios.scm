;;; scenarios.scm --- Cloud stress test scenarios -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Defines scenarios for v0.2 cloud stress testing.
;; Each scenario is designed to push context limits and trigger compaction.

(define-module (stress scenarios)
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
   '("Read all the source files in src/sage/ to understand the current architecture."

     "List all exported functions from each module."

     "How are tools currently registered and discovered?"

     "How does the session management work?"

     "Propose an architecture for a plugin system that would allow:
      - Third-party tools
      - Custom providers
      - Session middleware
      - Output formatters"

     "Show the specific changes needed in each file to support this."

     "What backwards compatibility concerns exist?"

     "Write a sample plugin that adds a 'weather' tool.")
   '("list_files" "read_file" "search_files" "glob_files")
   20
   #t))

(define scenario-documentation-gen
  (make-scenario
   'documentation-gen
   "Exhaustive Documentation"
   "Generate complete API docs for all exports"
   '((repo . "local")
     (focus . "src/sage"))
   '("List all .scm files in src/sage/."

     "For each module, extract the #:export list."

     "Read config.scm and document every exported function with examples."

     "Read util.scm and document every exported function with examples."

     "Read tools.scm and document every exported function with examples."

     "Read session.scm and document every exported function with examples."

     "Read ollama.scm and document every exported function with examples."

     "Read compaction.scm and document every exported function with examples."

     "Read repl.scm and document every exported function with examples."

     "Compile all documentation into a single API reference.")
   '("list_files" "read_file" "glob_files")
   25
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
