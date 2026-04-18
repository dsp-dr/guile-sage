;;; openai.scm --- OpenAI-compatible API provider -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Client for OpenAI-compatible LLM APIs (LiteLLM, vLLM, OpenAI).
;; Endpoint: ${SAGE_OPENAI_BASE}/chat/completions
;; Auth: Authorization: Bearer ${SAGE_OPENAI_API_KEY}

(define-module (sage openai)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (sage status)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:export (openai-host
            openai-model
            openai-api-key
            openai-aig-token
            openai-aig-mode
            openai-auth-headers
            openai-find-header
            openai-list-models
            openai-chat
            openai-chat-streaming
            openai-chat-with-tools
            openai-tools-to-api-format
            openai-parse-tool-call
            openai-extract-token-usage))

;;; ============================================================
;;; Configuration
;;; ============================================================

(define (openai-host)
  (or (config-get "OPENAI_BASE")
      (getenv "SAGE_OPENAI_BASE")
      "http://localhost:4000/v1"))

(define (openai-api-key)
  (or (config-get "OPENAI_API_KEY")
      (getenv "SAGE_OPENAI_API_KEY")
      "sk-litellm-local"))

(define (openai-model)
  (or (config-get "MODEL")
      (config-get "SAGE_MODEL")
      "gpt-4o-mini"))

;;; openai-aig-token: Cloudflare AI Gateway token (for stored-keys mode).
;;; When set, sage emits cf-aig-authorization alongside or instead of the
;;; downstream Authorization header (controlled by openai-aig-mode).
(define (openai-aig-token)
  (or (config-get "OPENAI_AIG_TOKEN")
      (getenv "SAGE_OPENAI_AIG_TOKEN")))

;;; openai-aig-mode: One of "stored", "both", "byok".
;;;   stored — emit ONLY cf-aig-authorization, suppress Authorization.
;;;           The gateway injects the downstream provider key itself.
;;;   both   — emit BOTH Authorization (BYOK downstream) and
;;;           cf-aig-authorization (gateway auth).
;;;           Will fail with 400 "Multiple authentication credentials"
;;;           if the gateway also has stored keys configured for the
;;;           same provider. Valid for BYOK-behind-a-gateway.
;;;   byok   — emit only Authorization (default when AIG_TOKEN unset).
;;;
;;; Default resolution: if AIG_TOKEN is set and mode is unset, default
;;; to "stored" (the most common CF AI Gateway deployment shape).
(define (openai-aig-mode)
  (let ((explicit (or (config-get "OPENAI_AIG_MODE")
                      (getenv "SAGE_OPENAI_AIG_MODE"))))
    (cond
     ((and (string? explicit) (not (string-null? explicit)))
      (string-downcase explicit))
     ((openai-aig-token) "stored")
     (else "byok"))))

(define (openai-auth-headers)
  "Assemble auth headers for openai-compat providers.

For Cloudflare AI Gateway configurations:
- stored mode → only `cf-aig-authorization: Bearer <gateway_token>`
- both mode   → both Authorization and cf-aig-authorization
- byok mode   → only Authorization (current / non-gateway default)"
  (let* ((aig-token (openai-aig-token))
         (mode (openai-aig-mode))
         (auth `("Authorization" . ,(string-append "Bearer "
                                                   (openai-api-key))))
         (aig (and aig-token
                   `("cf-aig-authorization" . ,(string-append "Bearer "
                                                              aig-token)))))
    (cond
     ;; Stored keys: CF gateway supplies the downstream key; sage must NOT
     ;; send Authorization or the gateway rejects with 400.
     ((and aig (string=? mode "stored"))
      (list aig))
     ;; Both: BYOK downstream, plus gateway auth.
     ((and aig (string=? mode "both"))
      (list auth aig))
     ;; Explicit byok OR AIG_TOKEN missing — original behaviour.
     (else
      (list auth)))))

;;; ============================================================
;;; Model Listing
;;; ============================================================

;;; openai-list-models: List available models via /models endpoint.
;;; Returns: list of model info alists (with "name" key for compat)
(define (openai-list-models)
  (let* ((url (string-append (openai-host) "/models"))
         (result (http-get url #:headers (openai-auth-headers)))
         (code (if (pair? result) (car result) 0))
         (body (if (pair? result) (cdr result) "")))
    (cond
     ((= code 200)
      (catch #t
        (lambda ()
          (let* ((parsed (json-read-string body))
                 (data (or (assoc-ref parsed "data") '())))
            ;; Normalise: OpenAI returns "id", Ollama expects "name"
            (map (lambda (m)
                   `(("name" . ,(or (assoc-ref m "id")
                                    (assoc-ref m "name")
                                    "unknown"))))
                 (if (list? data) data '()))))
        (lambda (key . args)
          (log-warn "openai" "Failed to parse models response"
                    `(("error" . ,(format #f "~a" key))))
          '())))
     (else
      (log-warn "openai" "Failed to list models"
                `(("code" . ,code) ("body" . ,body)))
      '()))))

;;; ============================================================
;;; Tool Format Conversion
;;; ============================================================

;;; openai-tools-to-api-format: Convert internal tool schema to
;;; OpenAI API format. Identical to Ollama format.
(define (openai-tools-to-api-format tools)
  (map (lambda (tool)
         `(("type" . "function")
           ("function" . (("name" . ,(assoc-ref tool "name"))
                          ("description" . ,(assoc-ref tool "description"))
                          ("parameters" . ,(assoc-ref tool "parameters"))))))
       tools))

;;; ============================================================
;;; Chat Completions
;;; ============================================================

;;; openai-find-header: Case-insensitive lookup in a response-headers alist.
(define (openai-find-header headers name)
  (let loop ((hs headers))
    (cond
     ((null? hs) #f)
     ((and (pair? (car hs))
           (string? (caar hs))
           (string-ci=? (caar hs) name))
      (cdar hs))
     (else (loop (cdr hs))))))

;;; openai-post-with-headers: POST with response-header capture.
;;;
;;; Routes through util.scm:http-post-with-headers-captured so that
;;; SAGE_DEBUG_HTTP=1 traces openai-provider traffic (LiteLLM, CF AI
;;; Gateway, vLLM). Previously this shelled out to curl directly,
;;; bypassing the wire logger — see docs/reports/20260417-cloudflare
;;; -ai-gateway-requirements.org § R7.
;;;
;;; Returns (code body guardrails) where guardrails is the value of the
;;; `x-litellm-applied-guardrails` response header or #f.
(define (openai-post-with-headers url body timeout headers)
  (let* ((result (http-post-with-headers-captured
                  url body
                  #:timeout timeout
                  #:headers headers))
         (code (if (and (list? result) (>= (length result) 1))
                   (car result) 0))
         (resp-body (if (and (list? result) (>= (length result) 2))
                        (cadr result) ""))
         (resp-headers (if (and (list? result) (>= (length result) 3))
                           (caddr result) '()))
         (guardrails (openai-find-header resp-headers
                                         "x-litellm-applied-guardrails")))
    (list code resp-body guardrails)))

;;; openai-chat: Non-streaming chat completion.
(define* (openai-chat model messages #:key (stream #f))
  (let* ((url (string-append (openai-host) "/chat/completions"))
         (request `(("model" . ,model)
                    ("messages" . ,(list->vector messages))
                    ("stream" . ,#f)))
         (body (json-write-string request))
         (start-time (current-time)))

    (log-api-request model "/chat/completions" #:tokens (length messages))
    (status-thinking #:model model #:host (openai-host))

    (let* ((result (openai-post-with-headers url body *request-timeout*
                                             (openai-auth-headers)))
           (elapsed (- (time-second (current-time)) (time-second start-time)))
           (code (if (list? result) (car result) 0))
           (resp-body (if (list? result) (cadr result) ""))
           (guardrails (if (and (list? result) (> (length result) 2))
                           (caddr result) #f)))

      (status-done elapsed)

      (cond
       ((= code 200)
        (catch #t
          (lambda ()
            (let* ((parsed (json-read-string resp-body))
                   (normalised (openai-normalise-response parsed)))
              (let ((usage (openai-extract-token-usage normalised)))
                (log-api-response code #:tokens (+ (assoc-ref usage 'prompt_tokens)
                                                    (assoc-ref usage 'completion_tokens))))
              (if guardrails (cons (cons "guardrails" guardrails) normalised) normalised)))
          (lambda (key . args)
            (log-error "openai" "Failed to parse API response"
                       `(("body_preview" . ,(substring resp-body 0
                                                        (min 200 (string-length resp-body))))))
            (error "Failed to parse API response" resp-body))))
       ((= code 0)
        (log-error "openai" "API connection failed" `(("error" . ,resp-body)))
        (error "API connection failed" resp-body))
       ((= code 400)
        ;; LiteLLM guardrail / content policy violation
        (let ((msg (openai-error-message resp-body)))
          (log-warn "openai" "Request blocked" `(("error" . ,msg)))
          ;; Return a synthetic response so the REPL doesn't crash
          `(("message" . (("role" . "assistant")
                          ("content" . ,(format #f "[Provider blocked request: ~a]" msg))))
            ("done" . ,#t)
            ("prompt_eval_count" . 0)
            ("eval_count" . 0))))
       (else
        (log-error "openai" "Chat request failed"
                   `(("code" . ,code) ("error" . ,resp-body)))
        (error "Chat request failed" code resp-body))))))

;;; openai-chat-streaming: Streaming chat via SSE.
(define* (openai-chat-streaming model messages on-token #:key (tools '()))
  (let* ((url (string-append (openai-host) "/chat/completions"))
         (api-tools (if (null? tools) '() (openai-tools-to-api-format tools)))
         (request `(("model" . ,model)
                    ("messages" . ,(list->vector messages))
                    ,@(if (null? api-tools)
                          '()
                          `(("tools" . ,(list->vector api-tools))))
                    ("stream" . ,#t)))
         (body (json-write-string request))
         (start-time (current-time))
         (accumulated-content "")
         (accumulated-tool-calls #f)
         (final-response #f))

    (log-api-request model "/chat/completions" #:tokens (length messages))

    ;; OpenAI SSE sends "data: {...}\n\n" lines and ends with "data: [DONE]".
    ;; http-post-streaming handles NDJSON; we strip the "data: " prefix.
    (let ((result (http-post-streaming
                   url body
                   (lambda (chunk)
                     ;; chunk is already parsed JSON from the NDJSON handler.
                     (let* ((choices (or (assoc-ref chunk "choices") '()))
                            (first-choice (and (pair? choices) (car choices)))
                            (delta (and first-choice (assoc-ref first-choice "delta")))
                            (content (and delta (assoc-ref delta "content")))
                            (tcs (and delta (assoc-ref delta "tool_calls"))))
                       (when (and content (string? content) (not (string-null? content)))
                         (set! accumulated-content
                               (string-append accumulated-content content))
                         (on-token content))
                       (when tcs
                         (set! accumulated-tool-calls tcs))
                       ;; Capture finish_reason
                       (when (and first-choice
                                  (equal? "stop" (assoc-ref first-choice "finish_reason")))
                         (set! final-response chunk))))
                   #:timeout *request-timeout*
                   #:headers (openai-auth-headers))))

      (let ((elapsed (- (time-second (current-time)) (time-second start-time))))
        ;; Build normalised response
        `(("message" . (("role" . "assistant")
                        ("content" . ,accumulated-content)
                        ,@(if accumulated-tool-calls
                              `(("tool_calls" . ,accumulated-tool-calls))
                              '())))
          ("done" . ,#t)
          ("prompt_eval_count" . 0)
          ("eval_count" . 0)
          ("elapsed" . ,elapsed))))))

;;; openai-chat-with-tools: Non-streaming chat with tool calling.
(define (openai-chat-with-tools model messages tools)
  (let* ((url (string-append (openai-host) "/chat/completions"))
         (api-tools (openai-tools-to-api-format tools))
         (request `(("model" . ,model)
                    ("messages" . ,(list->vector messages))
                    ("tools" . ,(list->vector api-tools))
                    ("stream" . ,#f)))
         (body (json-write-string request))
         (start-time (current-time)))

    (log-api-request model "/chat/completions" #:tokens (length messages))
    (status-thinking #:model model #:host (openai-host))

    (let* ((result (openai-post-with-headers url body *request-timeout*
                                             (openai-auth-headers)))
           (elapsed (- (time-second (current-time)) (time-second start-time)))
           (code (if (list? result) (car result) 0))
           (resp-body (if (list? result) (cadr result) ""))
           (guardrails (if (and (list? result) (> (length result) 2))
                           (caddr result) #f)))

      (status-done elapsed)

      (cond
       ((= code 200)
        (catch #t
          (lambda ()
            (let* ((parsed (json-read-string resp-body))
                   (normalised (openai-normalise-response parsed)))
              (let ((usage (openai-extract-token-usage normalised)))
                (log-api-response code #:tokens (+ (assoc-ref usage 'prompt_tokens)
                                                    (assoc-ref usage 'completion_tokens))))
              (if guardrails (cons (cons "guardrails" guardrails) normalised) normalised)))
          (lambda (key . args)
            (log-error "openai" "Failed to parse API response"
                       `(("body_preview" . ,(substring resp-body 0
                                                        (min 200 (string-length resp-body))))))
            (error "Failed to parse API response" resp-body))))
       ((= code 0)
        (log-error "openai" "API connection failed" `(("error" . ,resp-body)))
        (error "API connection failed" resp-body))
       ((= code 400)
        ;; LiteLLM guardrail / content policy violation
        (let ((msg (openai-error-message resp-body)))
          (log-warn "openai" "Request blocked" `(("error" . ,msg)))
          `(("message" . (("role" . "assistant")
                          ("content" . ,(format #f "[Provider blocked request: ~a]" msg))))
            ("done" . ,#t)
            ("prompt_eval_count" . 0)
            ("eval_count" . 0))))
       (else
        (log-error "openai" "Chat request failed"
                   `(("code" . ,code) ("error" . ,resp-body)))
        (error "Chat request failed" code resp-body))))))

;;; ============================================================
;;; Response Normalisation
;;; ============================================================

;;; openai-normalise-response: Convert OpenAI response to Ollama-shaped
;;; response so the rest of sage (repl, tools) can use a uniform format.
;;;
;;; OpenAI: {"choices":[{"message":{"role":"assistant","content":"..."
;;;           ,"tool_calls":[{"function":{"name":"..","arguments":"..."}}]}}],
;;;          "usage":{"prompt_tokens":N,"completion_tokens":N}}
;;;
;;; Ollama: {"message":{"role":"assistant","content":"...",
;;;           "tool_calls":[{"function":{"name":"..","arguments":{...}}}]},
;;;          "done":true,"prompt_eval_count":N,"eval_count":N}
(define (openai-normalise-response parsed)
  (let* ((choices (or (assoc-ref parsed "choices") '()))
         (first-choice (if (pair? choices) (car choices) '()))
         (message (or (assoc-ref first-choice "message") '()))
         (content (or (assoc-ref message "content") ""))
         (raw-tcs (assoc-ref message "tool_calls"))
         ;; OpenAI tool_calls have arguments as a JSON STRING.
         ;; Parse them to match Ollama's parsed-object convention.
         (tool-calls (openai-parse-tool-calls-list raw-tcs))
         (usage (or (assoc-ref parsed "usage") '()))
         (prompt-tokens (or (assoc-ref usage "prompt_tokens") 0))
         (completion-tokens (or (assoc-ref usage "completion_tokens") 0)))
    `(("message" . (("role" . "assistant")
                    ("content" . ,content)
                    ,@(if tool-calls
                          `(("tool_calls" . ,tool-calls))
                          '())))
      ("done" . ,#t)
      ("prompt_eval_count" . ,prompt-tokens)
      ("eval_count" . ,completion-tokens))))

;;; openai-parse-tool-calls-list: Parse OpenAI tool_calls array.
;;; Arguments are JSON strings in OpenAI — parse them to alists.
;;; Returns #f if no tool calls, or a list of normalised tool-call alists.
(define (openai-parse-tool-calls-list raw-tcs)
  (let ((tcs (as-list raw-tcs)))
    (if (null? tcs)
        #f
        (filter-map
         (lambda (tc)
           (let* ((fn (assoc-ref tc "function"))
                  (name (and fn (assoc-ref fn "name")))
                  (args-raw (and fn (assoc-ref fn "arguments"))))
             (if name
                 (let ((args (if (string? args-raw)
                                 (catch #t
                                   (lambda () (json-read-string args-raw))
                                   (lambda (key . rest) args-raw))
                                 (or args-raw '()))))
                   `(("function" . (("name" . ,name)
                                    ("arguments" . ,args)))))
                 #f)))
         tcs))))

;;; ============================================================
;;; Token Usage
;;; ============================================================

;;; openai-extract-token-usage: Extract token counts.
;;; Works on normalised (Ollama-shaped) response.
(define (openai-extract-token-usage response)
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

;;; openai-parse-tool-call: Extract first tool call from response message.
;;; Works on normalised message (after openai-normalise-response).
(define (openai-parse-tool-call message)
  (let* ((tool-calls-list (as-list (assoc-ref message "tool_calls")))
         (first-tc (and (pair? tool-calls-list) (car tool-calls-list))))
    (if first-tc
        (let ((fn (assoc-ref first-tc "function")))
          (if fn
              (let ((name (assoc-ref fn "name"))
                    (args (assoc-ref fn "arguments")))
                (log-info "openai" "Tool call"
                          `(("tool" . ,name)))
                `(("name" . ,name)
                  ("arguments" . ,args)))
              #f))
        #f)))

;;; ============================================================
;;; Error Handling
;;; ============================================================

;;; openai-error-message: Extract error message from OpenAI error body.
(define (openai-error-message body)
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
