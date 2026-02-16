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
            ollama-generate-image))

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
         (final-response #f))

    (log-api-request model "/api/chat" #:tokens (length messages))

    (let ((result (http-post-streaming
                   url body
                   (lambda (chunk)
                     ;; Extract token content from chunk
                     (let* ((message (assoc-ref chunk "message"))
                            (content (and message (assoc-ref message "content"))))
                       (when (and content (string? content) (not (string-null? content)))
                         (set! accumulated-content
                               (string-append accumulated-content content))
                         (on-token content)))
                     ;; Capture final chunk for metadata
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
        ;; Return response with accumulated content in message
        `(("message" . (("role" . "assistant")
                        ("content" . ,accumulated-content)
                        ,@(let ((tc (and final-response
                                         (assoc-ref (assoc-ref final-response "message")
                                                    "tool_calls"))))
                            (if tc `(("tool_calls" . ,tc)) '()))))
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
       (else
        (log-error "ollama" "Chat request failed" `(("code" . ,code) ("error" . ,resp-body)))
        (error "Chat request failed" code resp-body))))))

;;; ollama-parse-tool-call: Extract tool call from Ollama response message
;;; Checks native tool_calls first, falls back to ```tool content parsing
;;; Arguments:
;;;   message - Response message alist (has "content", may have "tool_calls")
;;; Returns: Tool call alist with "name" and "arguments", or #f
(define (ollama-parse-tool-call message)
  (let ((tool-calls (assoc-ref message "tool_calls")))
    (if (and tool-calls (vector? tool-calls) (> (vector-length tool-calls) 0))
        ;; Native Ollama tool calling
        (let* ((tc (vector-ref tool-calls 0))
               (fn (assoc-ref tc "function")))
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
