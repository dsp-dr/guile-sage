# guile-sage Plugin & Tool Development Guide

## Overview

guile-sage uses a tool-based architecture where AI models can invoke registered functions. Tools are the primary extension mechanism.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      LLM (Ollama)                       │
│  "Use search_files to find all define-module forms"    │
└────────────────────────┬────────────────────────────────┘
                         │ Tool Call
                         ▼
┌─────────────────────────────────────────────────────────┐
│                   Tool Registry                         │
│  *tools* alist: name → {description, params, execute}   │
└────────────────────────┬────────────────────────────────┘
                         │ Permission Check
                         ▼
┌─────────────────────────────────────────────────────────┐
│              Tool Execution (execute-tool)              │
│  - Check *safe-tools* or YOLO_MODE                      │
│  - Log call & result                                    │
│  - Return result string to LLM                          │
└─────────────────────────────────────────────────────────┘
```

## Tool Structure

Every tool has four components:

```scheme
(register-tool
  NAME          ;; String: unique tool identifier
  DESCRIPTION   ;; String: what the tool does (shown to LLM)
  PARAMETERS    ;; Alist: JSON Schema for arguments
  EXECUTE-FN)   ;; Lambda: (args) → result-string
```

## Quick Start: Your First Tool

### 1. Simple Tool (No Parameters)

```scheme
(register-tool
  "hello_world"
  "Say hello from sage"
  '(("type" . "object")
    ("properties" . ())
    ("required" . #()))
  (lambda (args)
    "Hello from guile-sage!"))
```

### 2. Tool With Parameters

```scheme
(register-tool
  "greet_user"
  "Greet a user by name"
  '(("type" . "object")
    ("properties" .
      (("name" . (("type" . "string")
                  ("description" . "Name to greet")))))
    ("required" . #("name")))
  (lambda (args)
    (let ((name (assoc-ref args "name")))
      (format #f "Hello, ~a! Welcome to sage." name))))
```

### 3. Safe Tool (Always Allowed)

```scheme
(register-safe-tool
  "current_time"
  "Get current time"
  '(("type" . "object")
    ("properties" . ())
    ("required" . #()))
  (lambda (args)
    (strftime "%Y-%m-%d %H:%M:%S" (localtime (current-time)))))
```

## Parameter Schema (JSON Schema)

Tools use JSON Schema to define parameters:

```scheme
'(("type" . "object")
  ("properties" .
    (("path" . (("type" . "string")
                ("description" . "File path")))
     ("count" . (("type" . "integer")
                 ("description" . "Number of items")
                 ("default" . 10)))
     ("recursive" . (("type" . "boolean")
                     ("description" . "Search recursively")))))
  ("required" . #("path")))  ;; Vector of required params
```

### Supported Types
- `"string"` - Text values
- `"integer"` - Whole numbers
- `"number"` - Decimals
- `"boolean"` - #t / #f
- `"array"` - Lists
- `"object"` - Nested structures

## Safety & Permissions

### Safe vs Unsafe Tools

```scheme
;; Safe tools - always allowed
*safe-tools* = '("read_file" "list_files" "git_status" ...)

;; Check permission before execution
(define (check-permission tool-name args)
  (or (member tool-name *safe-tools*)
      (config-get "YOLO_MODE")
      #f))
```

### Path Safety

```scheme
;; Check path is within workspace
(define (safe-path? path)
  (let ((ws (workspace)))
    (and (not (string-contains path ".."))
         (string-prefix? ws (canonicalize-path path))
         (not (regexp-exec
                (make-regexp "(\\.env|\\.git/|\\.ssh)")
                path)))))
```

## Complete Example: Call Graph Analyzer

Here's the etags-like tool the user requested:

```scheme
;;; scheme-call-graph.scm - Analyze Scheme call graphs
;;; Place in src/sage/plugins/ or load directly

(use-modules (sage tools)
             (ice-9 ftw)
             (ice-9 regex)
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; Parse a Scheme file for definitions
(define (extract-definitions content)
  "Extract (define ...) and (define-module ...) forms"
  (let ((defines '())
        (pattern (make-regexp "\\(define[*]?\\s+\\(?([a-zA-Z0-9_-]+)")))
    (regexp-substitute/global #f pattern content
      'pre
      (lambda (m)
        (set! defines (cons (match:substring m 1) defines))
        "")
      'post)
    (reverse defines)))

;;; Extract function calls from a definition
(define (extract-calls content func-name)
  "Find what functions are called within a definition"
  (let ((calls '())
        ;; Simple heuristic: look for (func-name ...)
        (pattern (make-regexp "\\(([a-zA-Z0-9_-]+)\\s")))
    (regexp-substitute/global #f pattern content
      'pre
      (lambda (m)
        (let ((called (match:substring m 1)))
          (unless (member called '("define" "lambda" "let" "if" "cond"
                                   "begin" "and" "or" "when" "unless"))
            (set! calls (cons called calls))))
        "")
      'post)
    (delete-duplicates calls)))

;;; Build call graph for a file
(define (analyze-file path)
  "Analyze a Scheme file and return call graph edges"
  (let* ((content (call-with-input-file path get-string-all))
         (defines (extract-definitions content)))
    (map (lambda (def)
           `((name . ,def)
             (file . ,path)
             (calls . ,(extract-calls content def))))
         defines)))

;;; Register the tool
(register-safe-tool
  "scheme_call_graph"
  "Analyze Scheme source files to build a call graph DAG.
   Finds all function definitions and their dependencies."
  '(("type" . "object")
    ("properties" .
      (("path" . (("type" . "string")
                  ("description" . "File or directory to analyze")))
       ("pattern" . (("type" . "string")
                     ("description" . "Glob pattern (default: *.scm)")))
       ("output" . (("type" . "string")
                    ("description" . "Output format: text, dot, json")))))
    ("required" . #("path")))

  (lambda (args)
    (let* ((path (assoc-ref args "path"))
           (pattern (or (assoc-ref args "pattern") "*.scm"))
           (output (or (assoc-ref args "output") "text"))
           (full-path (string-append (workspace) "/" path)))

      (if (not (safe-path? path))
          (format #f "Unsafe path: ~a" path)

          (let ((files (if (file-is-directory? full-path)
                          ;; Directory: find all matching files
                          (find-files full-path
                            (lambda (f s) (string-suffix? ".scm" f)))
                          ;; Single file
                          (list full-path))))

            (let ((graph (append-map analyze-file files)))
              (case (string->symbol output)
                ((dot)
                 ;; GraphViz DOT format
                 (string-append
                   "digraph CallGraph {\n"
                   (string-join
                     (append-map
                       (lambda (node)
                         (map (lambda (callee)
                                (format #f "  \"~a\" -> \"~a\";"
                                        (assoc-ref node 'name)
                                        callee))
                              (assoc-ref node 'calls)))
                       graph)
                     "\n")
                   "\n}\n"))

                ((json)
                 ;; JSON format
                 (json-write-string graph))

                (else
                 ;; Text format
                 (string-join
                   (map (lambda (node)
                          (format #f "~a (~a):\n  calls: ~a"
                                  (assoc-ref node 'name)
                                  (assoc-ref node 'file)
                                  (string-join
                                    (assoc-ref node 'calls) ", ")))
                        graph)
                   "\n\n")))))))))
```

## Plugin Loading

### Method 1: Add to init-default-tools

Edit `src/sage/tools.scm`:

```scheme
(define (init-default-tools)
  ;; ... existing tools ...

  ;; Load custom plugins
  (load "plugins/my-tool.scm"))
```

### Method 2: Runtime Registration

From REPL or agent:

```scheme
sage> Use the create_tool tool to register a new tool...
```

### Method 3: Plugin Directory (Future)

```
src/sage/plugins/
├── scheme-analysis.scm
├── documentation.scm
└── testing.scm
```

## Best Practices

### 1. Always Return Strings
```scheme
;; Good
(lambda (args) (format #f "Result: ~a" value))

;; Bad - will error
(lambda (args) value)
```

### 2. Handle Missing Parameters
```scheme
(let ((count (or (assoc-ref args "count") 10)))
  ...)
```

### 3. Validate Paths
```scheme
(if (safe-path? path)
    (do-work path)
    (format #f "Unsafe path: ~a" path))
```

### 4. Log Important Operations
```scheme
(log-info "my-tool" "Processing file"
          `(("path" . ,path)))
```

### 5. Use Descriptive Names
```scheme
;; Good: verb_noun pattern
"analyze_call_graph"
"generate_documentation"

;; Bad: vague names
"process"
"do_thing"
```

## Testing Tools

### Manual Testing
```scheme
;; In REPL
sage> /tools
sage> Use scheme_call_graph on src/sage/

;; Or directly
(execute-tool "scheme_call_graph"
              '(("path" . "src/sage") ("output" . "dot")))
```

### Unit Tests
```scheme
;; tests/test-my-tool.scm
(define (test-my-tool)
  (let ((result (execute-tool "my_tool" '(("arg" . "value")))))
    (assert-contains result "expected")))
```

## Tool Schema for LLM

Tools are converted to Ollama tool format:

```scheme
(define (tools-to-schema)
  (map (lambda (t)
         `(("type" . "function")
           ("function" .
             (("name" . ,(assoc-ref t "name"))
              ("description" . ,(assoc-ref t "description"))
              ("parameters" . ,(assoc-ref t "parameters"))))))
       *tools*))
```

## Debugging

### Enable Debug Mode
```scheme
sage> /debug
Debug mode: ON
```

### Check Tool Registration
```scheme
sage> /tools
Available tools:
  - read_file [safe]
  - scheme_call_graph [safe]
  ...
```

### View Logs
```scheme
sage> /logs 20 DEBUG
```

## Example Plugin Ideas

| Plugin | Description |
|--------|-------------|
| `scheme_call_graph` | Build DAG of function calls |
| `generate_tags` | Create TAGS file for navigation |
| `lint_scheme` | Check for common issues |
| `run_tests` | Execute test suite |
| `profile_code` | Performance analysis |
| `doc_generator` | Extract docstrings |
| `dependency_graph` | Module dependencies |
| `dead_code_finder` | Unused definitions |

## See Also

- `src/sage/tools.scm` - Tool system implementation
- `src/sage/agent.scm` - Agent task tools
- `docs/THEME.md` - UI styling guide
