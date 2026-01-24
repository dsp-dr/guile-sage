;;; ollama.scm --- Ollama API client -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Client for the Ollama LLM API.
;; Provides model listing, chat completions, and tool calling.

(define-module (sage ollama)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:export (ollama-host
            ollama-api-key
            ollama-model
            ollama-auth-headers
            ollama-list-models
            ollama-chat
            ollama-chat-with-tools
            ollama-format-tool-prompt
            ollama-parse-tool-call))

;;; ollama-host: Get configured Ollama host
;;; Returns: Host URL string
(define (ollama-host)
  (or (config-get "OLLAMA_HOST")
      (config-get "ollama-host")
      *default-ollama-host*))

;;; ollama-api-key: Get API key for cloud Ollama
;;; Returns: API key string or #f if not set
(define (ollama-api-key)
  (or (config-get "OLLAMA_API_KEY")
      (config-get "ollama-api-key")))

;;; ollama-model: Get configured model
;;; Returns: Model name string
(define (ollama-model)
  (or (config-get "MODEL")
      (config-get "SAGE_MODEL")
      "qwen3-coder:latest"))

;;; ollama-auth-headers: Get authentication headers for cloud API
;;; Returns: List of header pairs
(define (ollama-auth-headers)
  (let ((api-key (ollama-api-key)))
    (if api-key
        `(("Authorization" . ,(string-append "Bearer " api-key)))
        '())))

;;; ollama-list-models: List available models
;;; Returns: List of model info alists
(define (ollama-list-models)
  (let* ((url (string-append (ollama-host) "/api/tags"))
         (result (http-get url #:headers (ollama-auth-headers)))
         (code (car result))
         (body (cdr result)))
    (if (= code 200)
        (let ((parsed (json-read-string body)))
          (assoc-ref parsed "models"))
        (error "Failed to list models" code body))))

;;; ollama-chat: Send chat completion request
;;; Arguments:
;;;   model - Model name string
;;;   messages - List of message alists with 'role and 'content
;;;   stream - Whether to stream (default #f)
;;; Returns: Response alist
(define* (ollama-chat model messages #:key (stream #f))
  (let* ((url (string-append (ollama-host) "/api/chat"))
         (request `(("model" . ,model)
                    ("messages" . ,(list->vector messages))
                    ("stream" . ,stream)))
         (body (json-write-string request))
         (result (http-post url body #:headers (ollama-auth-headers)))
         (code (car result))
         (resp-body (cdr result)))
    (if (= code 200)
        (json-read-string resp-body)
        (error "Chat request failed" code resp-body))))

;;; ollama-format-tool-prompt: Generate system prompt for tool calling
;;; Arguments:
;;;   tools - List of tool definitions
;;; Returns: System prompt string
(define (ollama-format-tool-prompt tools)
  (string-append
   "You have access to the following tools:\n\n"
   (string-join
    (map (lambda (tool)
           (format #f "- ~a: ~a\n  Parameters: ~a"
                   (assoc-ref tool "name")
                   (assoc-ref tool "description")
                   (json-write-string (assoc-ref tool "parameters"))))
         tools)
    "\n\n")
   "\n\nTo call a tool, respond with:\n"
   "```tool\n{\"name\": \"tool_name\", \"arguments\": {...}}\n```"))

;;; ollama-chat-with-tools: Chat with tool calling support
;;; Arguments:
;;;   model - Model name string
;;;   messages - List of message alists
;;;   tools - List of tool definitions
;;; Returns: Response alist
(define (ollama-chat-with-tools model messages tools)
  (let* ((system-msg `(("role" . "system")
                       ("content" . ,(ollama-format-tool-prompt tools))))
         (all-messages (cons system-msg messages)))
    (ollama-chat model all-messages)))

;;; ollama-parse-tool-call: Parse tool call from response
;;; Arguments:
;;;   content - Response content string
;;; Returns: Tool call alist or #f if no tool call found
(define (ollama-parse-tool-call content)
  (let ((match-start (string-contains content "```tool\n")))
    (if match-start
        (let* ((json-start (+ match-start 8))  ; length of "```tool\n"
               (json-end (string-contains content "```" json-start)))
          (if json-end
              (let ((json-str (substring content json-start json-end)))
                (json-read-string (string-trim-both json-str)))
              #f))
        #f)))
