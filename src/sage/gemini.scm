;;; gemini.scm --- Google AI Gemini provider -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Client for Google AI Gemini API.
;; Endpoint: https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
;; Auth: x-goog-api-key header (or ?key= query param)

(define-module (sage gemini)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (sage status)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 format)
  #:export (gemini-host
            gemini-model
            gemini-api-key
            gemini-auth-headers
            gemini-list-models
            gemini-chat
            gemini-chat-streaming
            gemini-chat-with-tools
            gemini-tools-to-api-format
            gemini-parse-tool-call
            gemini-extract-token-usage))

;;; ============================================================
;;; Configuration
;;; ============================================================

(define (gemini-host)
  (or (config-get "GEMINI_HOST")
      (getenv "SAGE_GEMINI_HOST")
      "https://generativelanguage.googleapis.com"))

(define (gemini-api-key)
  (or (config-get "GEMINI_API_KEY")
      (getenv "GEMINI_API_KEY")
      ""))

(define (gemini-model)
  (or (config-get "GEMINI_MODEL")
      (config-get "MODEL")
      (config-get "SAGE_MODEL")
      "gemini-2.0-flash-exp"))

(define (gemini-auth-headers)
  (let ((key (gemini-api-key)))
    (if (and key (not (string-null? key)))
        `(("x-goog-api-key" . ,key))
        '())))

;;; ============================================================
;;; URL Construction
;;; ============================================================

;;; gemini-url: Build Gemini API URL for a model + method.
;;; Method is :generateContent or :streamGenerateContent.
(define (gemini-url model method)
  (string-append (gemini-host)
                 "/v1beta/models/" model method))

;;; ============================================================
;;; Message Format Conversion
;;; ============================================================

;;; gemini-convert-messages: Convert Ollama/OpenAI-style messages to
;;; Gemini contents format.
;;;
;;; Input:  [{"role":"user","content":"hi"}, {"role":"assistant","content":"hello"}]
;;; Output: [{"role":"user","parts":[{"text":"hi"}]}, {"role":"model","parts":[{"text":"hello"}]}]
;;;
;;; Gemini uses "model" instead of "assistant" and "parts" instead of "content".
;;; System messages become the first user message with a system prompt prefix.
(define (gemini-convert-messages messages)
  (let ((system-parts '())
        (converted '()))
    (for-each
     (lambda (msg)
       (let ((role (assoc-ref msg "role"))
             (content (or (assoc-ref msg "content") "")))
         (cond
          ;; System messages: collect and prepend to first user message
          ((equal? role "system")
           (set! system-parts
                 (append system-parts (list content))))
          ;; Assistant -> model
          ((equal? role "assistant")
           (set! converted
                 (append converted
                         (list `(("role" . "model")
                                 ("parts" . ,(list `(("text" . ,content)))))))))
          ;; User messages
          ((equal? role "user")
           (let ((text (if (and (not (null? system-parts))
                                (null? converted))
                           ;; Prepend system instructions to first user message
                           (string-append
                            (string-join system-parts "\n\n")
                            "\n\n" content)
                           content)))
             (set! converted
                   (append converted
                           (list `(("role" . "user")
                                   ("parts" . ,(list `(("text" . ,text))))))))))
          ;; Tool results -> user role with functionResponse
          ((equal? role "tool")
           (set! converted
                 (append converted
                         (list `(("role" . "user")
                                 ("parts" . ,(list `(("text" . ,content)))))))))
          (else
           ;; Unknown role: treat as user
           (set! converted
                 (append converted
                         (list `(("role" . "user")
                                 ("parts" . ,(list `(("text" . ,content))))))))))))
     messages)
    ;; If only system messages and no user messages, create a user turn
    (if (null? converted)
        (if (not (null? system-parts))
            (list `(("role" . "user")
                    ("parts" . ,(list `(("text" . ,(string-join system-parts "\n\n")))))))
            '())
        converted)))

;;; ============================================================
;;; Tool Format Conversion
;;; ============================================================

;;; gemini-tools-to-api-format: Convert internal tool schema to
;;; Gemini functionDeclarations format.
;;;
;;; Input: [{"name":"read_file","description":"...","parameters":{...}}]
;;; Output: [{"functionDeclarations":[{"name":"read_file","description":"...","parameters":{...}}]}]
(define (gemini-tools-to-api-format tools)
  (if (null? tools)
      '()
      (list
       `(("functionDeclarations" .
          ,(list->vector
            (map (lambda (tool)
                   `(("name" . ,(assoc-ref tool "name"))
                     ("description" . ,(or (assoc-ref tool "description") ""))
                     ("parameters" . ,(or (assoc-ref tool "parameters")
                                          '(("type" . "object")
                                            ("properties" . ()))))))
                 tools)))))))

;;; ============================================================
;;; Model Listing
;;; ============================================================

;;; gemini-list-models: List available Gemini models.
;;; Returns: list of model info alists (with "name" key for compat)
(define (gemini-list-models)
  (let* ((url (string-append (gemini-host) "/v1beta/models"))
         (result (http-get url #:headers (gemini-auth-headers)))
         (code (if (pair? result) (car result) 0))
         (body (if (pair? result) (cdr result) "")))
    (cond
     ((= code 200)
      (catch #t
        (lambda ()
          (let* ((parsed (json-read-string body))
                 (models (or (assoc-ref parsed "models") '())))
            (map (lambda (m)
                   `(("name" . ,(or (assoc-ref m "name")
                                    (assoc-ref m "displayName")
                                    "unknown"))))
                 (if (list? models) models '()))))
        (lambda (key . args)
          (log-warn "gemini" "Failed to parse models response"
                    `(("error" . ,(format #f "~a" key))))
          '())))
     (else
      (log-warn "gemini" "Failed to list models"
                `(("code" . ,code)))
      '()))))

;;; ============================================================
;;; Chat Completions
;;; ============================================================

;;; gemini-chat: Non-streaming chat completion.
(define* (gemini-chat model messages #:key (stream #f))
  (let* ((url (gemini-url model ":generateContent"))
         (contents (gemini-convert-messages messages))
         (request `(("contents" . ,(list->vector contents))))
         (body (json-write-string request))
         (start-time (current-time)))

    (log-api-request model ":generateContent" #:tokens (length messages))
    (status-thinking #:model model #:host (gemini-host))

    (let* ((result (http-post-with-timeout url body *request-timeout*
                                           #:headers (gemini-auth-headers)))
           (elapsed (- (time-second (current-time)) (time-second start-time)))
           (code (if (pair? result) (car result) 0))
           (resp-body (if (pair? result) (cdr result) "")))

      (status-done elapsed)

      (cond
       ((= code 200)
        (catch #t
          (lambda ()
            (let* ((parsed (json-read-string resp-body))
                   (normalised (gemini-normalise-response parsed)))
              (let ((usage (gemini-extract-token-usage normalised)))
                (log-api-response code #:tokens (+ (assoc-ref usage 'prompt_tokens)
                                                    (assoc-ref usage 'completion_tokens))))
              normalised))
          (lambda (key . args)
            (log-error "gemini" "Failed to parse API response"
                       `(("body_preview" . ,(substring resp-body 0
                                                        (min 200 (string-length resp-body))))))
            (gemini-error-response 200 resp-body))))
       (else
        ;; Any non-200: log full detail, surface a clean one-line message to
        ;; the user, and keep the REPL alive. Never throw the raw body.
        (log-error "gemini" "Chat request failed"
                   `(("code" . ,code) ("error" . ,resp-body)))
        (gemini-error-response code resp-body))))))

;;; gemini-chat-streaming: Streaming chat via SSE.
;;; Gemini streaming uses :streamGenerateContent?alt=sse
(define* (gemini-chat-streaming model messages on-token #:key (tools '()))
  (let* ((url (string-append (gemini-url model ":streamGenerateContent") "?alt=sse"))
         (contents (gemini-convert-messages messages))
         (api-tools (if (null? tools) '() (gemini-tools-to-api-format tools)))
         (request `(("contents" . ,(list->vector contents))
                    ,@(if (null? api-tools)
                          '()
                          `(("tools" . ,(list->vector api-tools))))))
         (body (json-write-string request))
         (start-time (current-time))
         (accumulated-content "")
         (accumulated-tool-calls #f)
         (stream-error #f))

    (log-api-request model ":streamGenerateContent" #:tokens (length messages))

    (let ((result (http-post-streaming
                   url body
                   (lambda (chunk)
                     ;; A non-2xx (e.g. bad key) returns {"error":{...}} on the
                     ;; stream instead of candidates. Capture it so we can
                     ;; surface a clean message instead of silently emitting
                     ;; nothing.
                     (let ((err (and (list? chunk) (assoc-ref chunk "error"))))
                       (when err
                         (set! stream-error
                               (or (and (pair? err) (assoc-ref err "message"))
                                   "request failed"))))
                     ;; Gemini streaming: each chunk is a candidate response
                     (let* ((candidates (or (assoc-ref chunk "candidates") '()))
                            (first-cand (and (pair? candidates) (car candidates)))
                            (cand-content (and first-cand (assoc-ref first-cand "content")))
                            (parts (and cand-content
                                        (as-list (assoc-ref cand-content "parts")))))
                       (when parts
                         (for-each
                          (lambda (part)
                            (let ((text (assoc-ref part "text"))
                                  (fc (assoc-ref part "functionCall")))
                              (when (and text (string? text) (not (string-null? text)))
                                (set! accumulated-content
                                      (string-append accumulated-content text))
                                (on-token text))
                              (when fc
                                (set! accumulated-tool-calls
                                      (append (or (as-list accumulated-tool-calls) '())
                                              (list fc))))))
                          parts))))
                   #:timeout *request-timeout*
                   #:headers (gemini-auth-headers))))

      (when (and stream-error (string-null? accumulated-content))
        (log-error "gemini" "Streaming request failed"
                   `(("error" . ,stream-error)))
        (let ((emsg (format #f "[Gemini error: ~a]" stream-error)))
          (set! accumulated-content emsg)
          (on-token emsg)))
      ;; If the stream produced nothing at all (no content, no tool calls, no
      ;; parseable error chunk), the failure was likely a non-2xx whose body
      ;; the line parser couldn't assemble (e.g. a bad key returns multi-line
      ;; JSON). Fall back to one non-streaming request, which has full error
      ;; handling, so the user sees a clean message instead of silence.
      (when (and (string-null? accumulated-content)
                 (not accumulated-tool-calls)
                 (not stream-error))
        (let* ((resp (gemini-chat model messages))
               (msg (assoc-ref resp "message"))
               (content (and msg (assoc-ref msg "content"))))
          (when (and content (string? content) (not (string-null? content)))
            (set! accumulated-content content)
            (on-token content))))
      (let ((elapsed (- (time-second (current-time)) (time-second start-time))))
        ;; Build normalised tool_calls from Gemini functionCall format
        (let ((norm-tcs (gemini-normalise-tool-calls accumulated-tool-calls)))
          `(("message" . (("role" . "assistant")
                          ("content" . ,accumulated-content)
                          ,@(if norm-tcs
                                `(("tool_calls" . ,norm-tcs))
                                '())))
            ("done" . ,#t)
            ("prompt_eval_count" . 0)
            ("eval_count" . 0)
            ("elapsed" . ,elapsed)))))))

;;; gemini-chat-with-tools: Non-streaming chat with tool calling.
(define (gemini-chat-with-tools model messages tools)
  (let* ((url (gemini-url model ":generateContent"))
         (contents (gemini-convert-messages messages))
         (api-tools (gemini-tools-to-api-format tools))
         (request `(("contents" . ,(list->vector contents))
                    ,@(if (null? api-tools)
                          '()
                          `(("tools" . ,(list->vector api-tools))))))
         (body (json-write-string request))
         (start-time (current-time)))

    (log-api-request model ":generateContent" #:tokens (length messages))
    (status-thinking #:model model #:host (gemini-host))

    (let* ((result (http-post-with-timeout url body *request-timeout*
                                           #:headers (gemini-auth-headers)))
           (elapsed (- (time-second (current-time)) (time-second start-time)))
           (code (if (pair? result) (car result) 0))
           (resp-body (if (pair? result) (cdr result) "")))

      (status-done elapsed)

      (cond
       ((= code 200)
        (catch #t
          (lambda ()
            (let* ((parsed (json-read-string resp-body))
                   (normalised (gemini-normalise-response parsed)))
              (let ((usage (gemini-extract-token-usage normalised)))
                (log-api-response code #:tokens (+ (assoc-ref usage 'prompt_tokens)
                                                    (assoc-ref usage 'completion_tokens))))
              normalised))
          (lambda (key . args)
            (log-error "gemini" "Failed to parse API response"
                       `(("body_preview" . ,(substring resp-body 0
                                                        (min 200 (string-length resp-body))))))
            (gemini-error-response 200 resp-body))))
       (else
        ;; Any non-200: clean message, no raw body, REPL stays alive.
        (log-error "gemini" "Chat request failed"
                   `(("code" . ,code) ("error" . ,resp-body)))
        (gemini-error-response code resp-body))))))

;;; ============================================================
;;; Response Normalisation
;;; ============================================================

;;; gemini-normalise-response: Convert Gemini response to Ollama-shaped
;;; response so the rest of sage uses a uniform format.
;;;
;;; Gemini: {"candidates":[{"content":{"parts":[{"text":"..."},
;;;           {"functionCall":{"name":"..","args":{...}}}]}}],
;;;          "usageMetadata":{"promptTokenCount":N,"candidatesTokenCount":N}}
(define (gemini-normalise-response parsed)
  (let* ((candidates (or (assoc-ref parsed "candidates") '()))
         (first-cand (if (pair? candidates) (car candidates) '()))
         (cand-content (or (assoc-ref first-cand "content") '()))
         (parts (as-list (or (assoc-ref cand-content "parts") '())))
         ;; Extract text from all text parts
         (text-parts (filter-map (lambda (p) (assoc-ref p "text")) parts))
         (content (if (null? text-parts) "" (string-join text-parts "")))
         ;; Extract functionCall parts
         (fc-parts (filter-map (lambda (p) (assoc-ref p "functionCall")) parts))
         (tool-calls (gemini-normalise-tool-calls fc-parts))
         ;; Token usage from usageMetadata
         (usage (or (assoc-ref parsed "usageMetadata") '()))
         (prompt-tokens (or (assoc-ref usage "promptTokenCount") 0))
         (completion-tokens (or (assoc-ref usage "candidatesTokenCount") 0)))
    `(("message" . (("role" . "assistant")
                    ("content" . ,content)
                    ,@(if tool-calls
                          `(("tool_calls" . ,tool-calls))
                          '())))
      ("done" . ,#t)
      ("prompt_eval_count" . ,prompt-tokens)
      ("eval_count" . ,completion-tokens))))

;;; gemini-normalise-tool-calls: Convert Gemini functionCall list to
;;; Ollama-style tool_calls.
;;;
;;; Input:  [{"name":"read_file","args":{"path":"/tmp/x"}}]
;;; Output: [{"function":{"name":"read_file","arguments":{"path":"/tmp/x"}}}]
(define (gemini-normalise-tool-calls fc-parts)
  (let ((fcs (as-list fc-parts)))
    (if (null? fcs)
        #f
        (map (lambda (fc)
               `(("function" . (("name" . ,(or (assoc-ref fc "name") "unknown"))
                                ("arguments" . ,(or (assoc-ref fc "args") '()))))))
             fcs))))

;;; ============================================================
;;; Token Usage
;;; ============================================================

;;; gemini-extract-token-usage: Extract token counts.
;;; Works on normalised (Ollama-shaped) response.
(define (gemini-extract-token-usage response)
  (if (and response (list? response))
      (list
       (cons 'prompt_tokens
             (let ((v (assoc-ref response "prompt_eval_count")))
               (if (number? v) v 0)))
       (cons 'completion_tokens
             (let ((v (assoc-ref response "eval_count")))
               (if (number? v) v 0))))
      (list (cons 'prompt_tokens 0)
            (cons 'completion_tokens 0))))

;;; ============================================================
;;; Tool Call Parsing
;;; ============================================================

;;; gemini-parse-tool-call: Extract first tool call from response message.
;;; Works on normalised message (after gemini-normalise-response).
(define (gemini-parse-tool-call message)
  (let* ((tool-calls-list (as-list (assoc-ref message "tool_calls")))
         (first-tc (and (pair? tool-calls-list) (car tool-calls-list))))
    (if first-tc
        (let ((fn (assoc-ref first-tc "function")))
          (if fn
              (let ((name (assoc-ref fn "name"))
                    (args (assoc-ref fn "arguments")))
                (log-info "gemini" "Tool call"
                          `(("tool" . ,name)))
                `(("name" . ,name)
                  ("arguments" . ,args)))
              #f))
        #f)))

;;; ============================================================
;;; Error Handling
;;; ============================================================

;;; gemini-error-message: Extract error message from Gemini error body.
(define (gemini-error-message body)
  (catch #t
    (lambda ()
      (if (or (not body) (string-null? body))
          "(empty response)"
          (let* ((parsed (json-read-string body))
                 (err (assoc-ref parsed "error")))
            (if (pair? err)
                (or (assoc-ref err "message") body)
                (or err body)))))
    (lambda args (or body "(unparseable response)"))))

;;; gemini-error-response: Build a clean, normalised assistant message for a
;;; non-200 response. Never throws — keeps the REPL alive and never leaks the
;;; raw provider body or a stray Scheme value to the screen. Full detail is
;;; logged separately by the caller.
(define (gemini-error-response code body)
  (let ((msg (gemini-error-message body))
        (label (cond ((= code 0)    "connection failed")
                     ((= code 401)  "authentication failed (invalid/expired API key)")
                     ((= code 403)  "authentication failed (forbidden)")
                     ((= code 404)  "model not found")
                     ((= code 429)  "rate limited")
                     ((>= code 500) "server error")
                     (else (format #f "request failed (HTTP ~a)" code)))))
    `(("message" . (("role" . "assistant")
                    ("content" . ,(format #f "[Gemini ~a: ~a]" label msg))))
      ("done" . ,#t)
      ("prompt_eval_count" . 0)
      ("eval_count" . 0))))
