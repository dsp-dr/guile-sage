;;; ollama.scm --- Ollama API client -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Client for the Ollama LLM API.
;; Provides model listing, chat completions, and tool calling.

(define-module (sage ollama)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (sage status)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:export (ollama-host
            ollama-api-key
            ollama-model
            ollama-auth-headers
            ollama-list-models
            ollama-chat
            ollama-chat-streaming
            ollama-chat-with-tools
            ollama-tools-to-api-format
            ollama-parse-tool-call
            ollama-extract-token-usage
            ollama-image-host
            ollama-image-model
            ollama-generate-image
            ;; Model availability + fallback (graceful removal handling)
            chat-capable-model?
            model-available?
            select-fallback-model
            ollama-error-message))

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
         (code (if (pair? result) (car result) 0))
         (body (if (pair? result) (cdr result) "")))
    (cond
     ((not (number? code))
      (error "Invalid API response" result))
     ((= code 200)
      (catch #t
        (lambda ()
          (let ((parsed (json-read-string body)))
            (or (assoc-ref parsed "models") '())))
        (lambda (key . args)
          (error "Failed to parse models response" body))))
     (else
      (error "Failed to list models" code body)))))

;;; ============================================================
;;; Model availability + graceful fallback
;;; ============================================================
;;;
;;; When a configured model has been removed locally (e.g. `ollama rm
;;; mistral:latest` to free disk), sage should not crash on the first
;;; chat turn. These helpers detect that case and pick a sensible
;;; substitute from whatever is still installed.

;;; chat-capable-model?: Is this model usable for /api/chat?
;;; Filters out embedding models and image generation models so we
;;; never auto-fall-back to nomic-embed-text or x/flux2-klein.
;;; Arguments:
;;;   model-info - one entry from ollama-list-models (alist)
;;; Returns: #t if the model can serve chat completions
(define (chat-capable-model? model-info)
  (let* ((details (or (assoc-ref model-info "details") '()))
         (family  (or (assoc-ref details "family") ""))
         (format  (or (assoc-ref details "format") "")))
    (and
     ;; Image generation models come as safetensors, not gguf
     (not (equal? format "safetensors"))
     ;; Embedding model families
     (not (string-contains family "bert"))
     (not (string-contains family "embed"))
     ;; Non-empty family — empty means unknown/specialized
     (not (string-null? family)))))

;;; model-available?: Is the named model in the available list?
;;; Arguments:
;;;   name             - model name string (e.g. "llama3.2:latest")
;;;   available-models - list of model info alists from ollama-list-models
(define (model-available? name available-models)
  (and (find (lambda (m) (equal? (assoc-ref m "name") name))
             available-models)
       #t))

;;; model-size: Extract the model size in bytes (or +inf.0 if missing).
;;; Used to sort fallback candidates so we prefer the smallest/fastest.
(define (model-size model-info)
  (let ((s (assoc-ref model-info "size")))
    (if (number? s) s +inf.0)))

;;; select-fallback-model: Pick the best available chat model.
;;; Arguments:
;;;   preferred        - desired model name (string)
;;;   available-models - list from ollama-list-models
;;; Returns: a model name string, or #f if nothing usable exists.
;;;
;;; Selection order:
;;;   1. The preferred model, if installed
;;;   2. The smallest chat-capable model (sorted by size in bytes)
;;;   3. The first model in the available list (last-resort)
;;;   4. #f
;;;
;;; Why "smallest first": after `ollama rm` the user wants to keep
;;; iterating, and a smaller model is faster to load and produces
;;; tighter feedback loops. Ollama returns models in modification-
;;; time order, which is rarely what we want here.
(define (select-fallback-model preferred available-models)
  (cond
   ((null? available-models) #f)
   ((model-available? preferred available-models) preferred)
   (else
    (let ((chat-models (filter chat-capable-model? available-models)))
      (cond
       ((not (null? chat-models))
        (let ((sorted (sort chat-models
                            (lambda (a b) (< (model-size a) (model-size b))))))
          (assoc-ref (car sorted) "name")))
       (else
        (assoc-ref (car available-models) "name")))))))

;;; ollama-error-message: Extract a human-friendly message from an
;;; Ollama error response body. The body is JSON like {"error":"..."}
;;; or sometimes a plain string. Returns a fallback if parsing fails.
;;; Arguments:
;;;   body - response body string
;;; Returns: short error message string
(define (ollama-error-message body)
  (catch #t
    (lambda ()
      (if (or (not body) (string-null? body))
          "(empty response)"
          (let ((parsed (json-read-string body)))
            (or (and (pair? parsed) (assoc-ref parsed "error"))
                body))))
    (lambda args (or body "(unparseable response)"))))

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
         (start-time (current-time)))

    ;; Log the API request
    (log-api-request model "/api/chat" #:tokens (length messages))

    ;; Show status with context
    (status-thinking #:model model #:host (ollama-host))

    (let* ((result (http-post-with-timeout url body *request-timeout*
                                           #:headers (ollama-auth-headers)))
           (elapsed (- (time-second (current-time)) (time-second start-time)))
           (code (if (pair? result) (car result) 0))
           (resp-body (if (pair? result) (cdr result) "")))

      ;; Clear status
      (status-done elapsed)

      (cond
       ((not (number? code))
        (log-error "ollama" "Invalid API response" `(("result" . ,(format #f "~a" result))))
        (status-clear)
        (error "Invalid API response" result))
       ((= code 200)
        (catch #t
          (lambda ()
            (let ((parsed (json-read-string resp-body)))
              (let ((usage (ollama-extract-token-usage parsed)))
                (log-api-response code #:tokens (+ (assoc-ref usage 'prompt_tokens)
                                                   (assoc-ref usage 'completion_tokens))))
              parsed))
          (lambda (key . args)
            (log-error "ollama" "Failed to parse API response"
                       `(("body_preview" . ,(substring resp-body 0 (min 200 (string-length resp-body))))))
            (error "Failed to parse API response" resp-body))))
       ((= code 0)
        (log-error "ollama" "API connection failed" `(("error" . ,resp-body)))
        (error "API connection failed" resp-body))
       ((= code 404)
        ;; Model not found locally — common after `ollama rm`. Surface
        ;; a clean message instead of a generic chat-request failure
        ;; so the REPL can prompt the user to pick another model.
        (let ((msg (ollama-error-message resp-body)))
          (log-error "ollama" "Model not found"
                     `(("model" . ,model) ("error" . ,msg)))
          (status-clear)
          (error 'model-not-found model msg)))
       (else
        (log-error "ollama" "Chat request failed" `(("code" . ,code) ("error" . ,resp-body)))
        (error "Chat request failed" code resp-body))))))

;;; ollama-chat-streaming: Send streaming chat request
;;; Calls on-token with each content fragment as it arrives.
;;; Arguments:
;;;   model - Model name string
;;;   messages - List of message alists
;;;   on-token - Callback (string) for each token
;;;   tools - Tool definitions (optional, for request context)
;;; Returns: Response alist compatible with non-streaming version
(define* (ollama-chat-streaming model messages on-token #:key (tools '()))
  (let* ((url (string-append (ollama-host) "/api/chat"))
         (api-tools (if (null? tools) '() (ollama-tools-to-api-format tools)))
         (request `(("model" . ,model)
                    ("messages" . ,(list->vector messages))
                    ,@(if (null? api-tools)
                          '()
                          `(("tools" . ,(list->vector api-tools))))
                    ("stream" . ,#t)))
         (body (json-write-string request))
         (start-time (current-time))
         (accumulated-content "")
         ;; tool_calls can arrive in any chunk (Ollama puts them in the
         ;; first chunk for llama3.2 and clears the message in done:true).
         ;; We must capture them whenever they appear, NOT only on done.
         (accumulated-tool-calls #f)
         (final-response #f))

    (log-api-request model "/api/chat" #:tokens (length messages))

    (let ((result (http-post-streaming
                   url body
                   (lambda (chunk)
                     (let* ((message (assoc-ref chunk "message"))
                            (content (and message (assoc-ref message "content")))
                            (tcs (and message (assoc-ref message "tool_calls"))))
                       ;; Stream content tokens
                       (when (and content (string? content) (not (string-null? content)))
                         (set! accumulated-content
                               (string-append accumulated-content content))
                         (on-token content))
                       ;; Capture tool_calls from ANY chunk (first chunk
                       ;; for llama3.2; rare for them to span chunks)
                       (when tcs
                         (set! accumulated-tool-calls tcs)))
                     ;; Capture final chunk for metadata (timings, eval_count)
                     (when (and (list? chunk) (eq? #t (assoc-ref chunk "done")))
                       (set! final-response chunk)))
                   #:timeout *request-timeout*
                   #:headers (ollama-auth-headers))))

      (let* ((elapsed (- (time-second (current-time)) (time-second start-time)))
             ;; Build a response alist compatible with non-streaming format
             (response (or final-response '()))
             (usage (ollama-extract-token-usage response)))
        (log-api-response 200 #:tokens (+ (assoc-ref usage 'prompt_tokens)
                                           (assoc-ref usage 'completion_tokens)))
        ;; Return response with accumulated content + accumulated tool_calls
        `(("message" . (("role" . "assistant")
                        ("content" . ,accumulated-content)
                        ,@(if accumulated-tool-calls
                              `(("tool_calls" . ,accumulated-tool-calls))
                              '())))
          ("done" . ,#t)
          ("prompt_eval_count" . ,(assoc-ref usage 'prompt_tokens))
          ("eval_count" . ,(assoc-ref usage 'completion_tokens))
          ("elapsed" . ,elapsed))))))

;;; ollama-tools-to-api-format: Convert internal tool schema to Ollama API format
;;; Arguments:
;;;   tools - List of tool definitions (name, description, parameters)
;;; Returns: List of Ollama-formatted tool objects
(define (ollama-tools-to-api-format tools)
  (map (lambda (tool)
         `(("type" . "function")
           ("function" . (("name" . ,(assoc-ref tool "name"))
                          ("description" . ,(assoc-ref tool "description"))
                          ("parameters" . ,(assoc-ref tool "parameters"))))))
       tools))

;;; ollama-chat-with-tools: Chat with native Ollama tool calling
;;; Arguments:
;;;   model - Model name string
;;;   messages - List of message alists
;;;   tools - List of tool definitions
;;; Returns: Response alist
(define (ollama-chat-with-tools model messages tools)
  (let* ((url (string-append (ollama-host) "/api/chat"))
         (api-tools (ollama-tools-to-api-format tools))
         (request `(("model" . ,model)
                    ("messages" . ,(list->vector messages))
                    ("tools" . ,(list->vector api-tools))
                    ("stream" . ,#f)))
         (body (json-write-string request))
         (start-time (current-time)))

    (log-api-request model "/api/chat" #:tokens (length messages))
    (status-thinking #:model model #:host (ollama-host))

    (let* ((result (http-post-with-timeout url body *request-timeout*
                                           #:headers (ollama-auth-headers)))
           (elapsed (- (time-second (current-time)) (time-second start-time)))
           (code (if (pair? result) (car result) 0))
           (resp-body (if (pair? result) (cdr result) "")))

      (status-done elapsed)

      (cond
       ((= code 200)
        (catch #t
          (lambda ()
            (let ((parsed (json-read-string resp-body)))
              (let ((usage (ollama-extract-token-usage parsed)))
                (log-api-response code #:tokens (+ (assoc-ref usage 'prompt_tokens)
                                                   (assoc-ref usage 'completion_tokens))))
              parsed))
          (lambda (key . args)
            (log-error "ollama" "Failed to parse API response"
                       `(("body_preview" . ,(substring resp-body 0 (min 200 (string-length resp-body))))))
            (error "Failed to parse API response" resp-body))))
       ((= code 0)
        (log-error "ollama" "API connection failed" `(("error" . ,resp-body)))
        (error "API connection failed" resp-body))
       ((= code 404)
        ;; Model not found locally — common after `ollama rm`. Surface
        ;; a clean message instead of a generic chat-request failure
        ;; so the REPL can prompt the user to pick another model.
        (let ((msg (ollama-error-message resp-body)))
          (log-error "ollama" "Model not found"
                     `(("model" . ,model) ("error" . ,msg)))
          (status-clear)
          (error 'model-not-found model msg)))
       (else
        (log-error "ollama" "Chat request failed" `(("code" . ,code) ("error" . ,resp-body)))
        (error "Chat request failed" code resp-body))))))

;;; ollama-parse-tool-call: Extract tool call from Ollama response message
;;; Checks native tool_calls first, falls back to ```tool content parsing
;;; Arguments:
;;;   message - Response message alist (has "content", may have "tool_calls")
;;; Returns: Tool call alist with "name" and "arguments", or #f
(define (ollama-parse-tool-call message)
  (let* ((tool-calls (assoc-ref message "tool_calls"))
         ;; util.scm's JSON parser returns arrays as LISTS, but other
         ;; callers may pass vectors. Accept both shapes uniformly.
         (first-tc (cond
                    ((and tool-calls (vector? tool-calls)
                          (> (vector-length tool-calls) 0))
                     (vector-ref tool-calls 0))
                    ((and tool-calls (pair? tool-calls))
                     (car tool-calls))
                    (else #f))))
    (if first-tc
        ;; Native Ollama tool calling
        (let ((fn (assoc-ref first-tc "function")))
          (if fn
              (let ((name (assoc-ref fn "name"))
                    (args (assoc-ref fn "arguments")))
                (log-info "ollama" "Native tool call"
                          `(("tool" . ,name)))
                `(("name" . ,name)
                  ("arguments" . ,args)))
              #f))
        ;; Fallback: parse ```tool blocks from content
        (let ((content (or (assoc-ref message "content") "")))
          (let ((match-start (string-contains content "```tool\n")))
            (if match-start
                (let* ((json-start (+ match-start 8))
                       (json-end (string-contains content "```" json-start)))
                  (if json-end
                      (catch #t
                        (lambda ()
                          (let ((parsed (json-read-string
                                         (string-trim-both
                                           (substring content json-start json-end)))))
                            (log-info "ollama" "Parsed tool call from content"
                                      `(("tool" . ,(assoc-ref parsed "name"))))
                            parsed))
                        (lambda (key . args)
                          (log-warn "ollama" "Malformed tool call JSON"
                                    `(("error" . ,(format #f "~a ~a" key args))))
                          #f))
                      #f))
                #f))))))

;;; ollama-extract-token-usage: Extract token usage from Ollama response
;;; Arguments:
;;;   response - Response alist from ollama-chat
;;; Returns: Alist with 'prompt_tokens and 'completion_tokens
(define (ollama-extract-token-usage response)
  (if (and response (list? response))
      (list
       (cons 'prompt_tokens
             (let ((v (assoc-ref response "prompt_eval_count")))
               (if (number? v) v 0)))
       (cons 'completion_tokens
             (let ((v (assoc-ref response "eval_count")))
               (if (number? v) v 0))))
      ;; Fallback for invalid response
      (list (cons 'prompt_tokens 0)
            (cons 'completion_tokens 0))))

;;; ============================================================
;;; Image Generation
;;; ============================================================

;;; ollama-image-host: Get configured Ollama image generation host
;;; Returns: Host URL string (defaults to localhost)
(define (ollama-image-host)
  (or (config-get "OLLAMA_IMAGE_HOST")
      *default-ollama-host*))

;;; ollama-image-model: Get configured image generation model
;;; Returns: Model name string
(define (ollama-image-model)
  (or (config-get "OLLAMA_IMAGE_MODEL")
      "x/flux2-klein:4b"))

;;; ollama-generate-image: Generate an image from a text prompt
;;; Arguments:
;;;   prompt - Text description of the image to generate
;;;   output-path - File path to save the PNG image
;;;   width - Image width in pixels (optional, default: model default)
;;;   height - Image height in pixels (optional, default: model default)
;;;   steps - Number of diffusion steps (optional, default: model default)
;;; Returns: output-path on success, or raises an error
(define* (ollama-generate-image prompt output-path
                                #:key (width #f) (height #f) (steps #f))
  (let* ((url (string-append (ollama-image-host) "/api/generate"))
         (base-request `(("model" . ,(ollama-image-model))
                         ("prompt" . ,prompt)
                         ("stream" . ,#f)))
         ;; Append optional image generation parameters
         (request (append base-request
                          (if width `(("width" . ,width)) '())
                          (if height `(("height" . ,height)) '())
                          (if steps `(("steps" . ,steps)) '())))
         (body (json-write-string request))
         (start-time (current-time)))

    (log-info "ollama" "Generating image"
              `(("model" . ,(ollama-image-model))
                ("prompt" . ,prompt)
                ("output" . ,output-path)))

    (status-thinking #:model (ollama-image-model) #:host (ollama-image-host))

    ;; Image generation can take a while; use 10 minute timeout via curl
    (let* ((result (http-post-with-timeout url body 600))
           (elapsed (- (time-second (current-time)) (time-second start-time)))
           (code (if (pair? result) (car result) 0))
           (resp-body (if (pair? result) (cdr result) "")))

      (status-done elapsed)

      (cond
       ((= code 200)
        (catch #t
          (lambda ()
            (let* ((parsed (json-read-string resp-body))
                   ;; Ollama returns image data in "image" (singular) field
                   (image-data (assoc-ref parsed "image"))
                   ;; Also check "images" (list) as fallback
                   (images (assoc-ref parsed "images")))
              (cond
               ;; Primary: "image" field (string, base64)
               ((and image-data (string? image-data)
                     (> (string-length image-data) 0))
                (save-base64-png image-data output-path)
                (log-info "ollama" "Image saved"
                          `(("path" . ,output-path)
                            ("elapsed" . ,elapsed)))
                output-path)
               ;; Fallback: "images" field (list of base64 strings)
               ((and images (pair? images))
                (save-base64-png (car images) output-path)
                (log-info "ollama" "Image saved (from images list)"
                          `(("path" . ,output-path)
                            ("elapsed" . ,elapsed)))
                output-path)
               (else
                (log-error "ollama" "No image data in response"
                           `(("keys" . ,(format #f "~a"
                                                (map car parsed)))))
                (error "No image data in API response")))))
          (lambda (key . args)
            (log-error "ollama" "Failed to parse image response"
                       `(("error" . ,(format #f "~a ~a" key args))))
            (error "Failed to parse image response" key args))))
       ((= code 0)
        (log-error "ollama" "Image API connection failed"
                   `(("host" . ,(ollama-image-host))
                     ("error" . ,resp-body)))
        (error "Image API connection failed" resp-body))
       (else
        (log-error "ollama" "Image generation failed"
                   `(("code" . ,code) ("error" . ,resp-body)))
        (error "Image generation failed" code resp-body))))))

;;; save-base64-png: Decode base64 data and write to PNG file
;;; Arguments:
;;;   b64-data - Base64-encoded image data string
;;;   path - Output file path
(define (save-base64-png b64-data path)
  ;; Ensure parent directory exists
  (let ((dir (dirname path)))
    (unless (file-exists? dir)
      (mkdir dir)))
  ;; Use base64 command to decode since Guile lacks native base64
  (let ((tmp-b64 (make-temp-file "sage-b64")))
    (call-with-output-file tmp-b64
      (lambda (port) (display b64-data port)))
    (system (format #f "base64 -d < '~a' > '~a'" tmp-b64 path))
    (delete-file tmp-b64)))
