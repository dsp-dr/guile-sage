;;; provider.scm --- Multi-provider LLM dispatch -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Dispatch layer for multi-provider LLM support.
;; Reads SAGE_PROVIDER env var and routes to the correct backend:
;;   ollama  — local Ollama (default)
;;   gemini  — Google AI Gemini
;;   openai  — OpenAI-compatible (LiteLLM, vLLM, etc.)
;;   litellm — alias for openai

(define-module (sage provider)
  #:use-module (sage config)
  #:use-module (sage logging)
  #:use-module (ice-9 format)
  #:export (current-provider
            provider-chat
            provider-chat-streaming
            provider-chat-with-tools
            provider-extract-token-usage
            provider-parse-tool-call
            provider-list-models
            provider-model
            provider-host))

;;; ============================================================
;;; Provider Resolution
;;; ============================================================

;;; current-provider: Read SAGE_PROVIDER and normalise.
;;; Returns a symbol: ollama, gemini, or openai.
(define (current-provider)
  (let ((raw (or (config-get "PROVIDER")
                 (getenv "SAGE_PROVIDER")
                 "ollama")))
    (cond
     ((string=? raw "ollama")  'ollama)
     ((string=? raw "gemini")  'gemini)
     ((string=? raw "openai")  'openai)
     ((string=? raw "litellm") 'openai)   ; alias
     (else
      (log-warn "provider" (format #f "Unknown provider '~a', falling back to ollama" raw))
      'ollama))))

;;; ============================================================
;;; Lazy Module Resolution
;;; ============================================================
;;;
;;; We resolve provider modules lazily (at dispatch time) so that
;;; loading (sage provider) itself never forces a load of gemini.scm
;;; or openai.scm when they are not needed.

(define (ollama-ref sym)
  (module-ref (resolve-module '(sage ollama)) sym))

(define (gemini-ref sym)
  (module-ref (resolve-module '(sage gemini)) sym))

(define (openai-ref sym)
  (module-ref (resolve-module '(sage openai)) sym))

;;; ============================================================
;;; Public API — mirrors ollama.scm exports
;;; ============================================================

;;; provider-host: Get the configured host/base URL.
(define (provider-host)
  (case (current-provider)
    ((ollama) ((ollama-ref 'ollama-host)))
    ((gemini) ((gemini-ref 'gemini-host)))
    ((openai) ((openai-ref 'openai-host)))))

;;; provider-model: Get the configured model name.
(define (provider-model)
  (case (current-provider)
    ((ollama) ((ollama-ref 'ollama-model)))
    ((gemini) ((gemini-ref 'gemini-model)))
    ((openai) ((openai-ref 'openai-model)))))

;;; provider-list-models: List available models.
(define (provider-list-models)
  (case (current-provider)
    ((ollama) ((ollama-ref 'ollama-list-models)))
    ((gemini) ((gemini-ref 'gemini-list-models)))
    ((openai) ((openai-ref 'openai-list-models)))))

;;; provider-chat: Non-streaming chat completion.
;;; Arguments:
;;;   model    - model name string
;;;   messages - list of message alists
;;; Returns: response alist (provider-normalised)
(define* (provider-chat model messages #:key (stream #f))
  (case (current-provider)
    ((ollama) ((ollama-ref 'ollama-chat) model messages #:stream stream))
    ((gemini) ((gemini-ref 'gemini-chat) model messages #:stream stream))
    ((openai) ((openai-ref 'openai-chat) model messages #:stream stream))))

;;; provider-chat-streaming: Streaming chat completion.
;;; Arguments:
;;;   model    - model name string
;;;   messages - list of message alists
;;;   on-token - callback (string) per token
;;;   tools    - tool definitions (optional)
;;; Returns: response alist (provider-normalised)
(define* (provider-chat-streaming model messages on-token #:key (tools '()))
  (case (current-provider)
    ((ollama)
     ((ollama-ref 'ollama-chat-streaming) model messages on-token #:tools tools))
    ((gemini)
     ((gemini-ref 'gemini-chat-streaming) model messages on-token #:tools tools))
    ((openai)
     ((openai-ref 'openai-chat-streaming) model messages on-token #:tools tools))))

;;; provider-chat-with-tools: Non-streaming chat with tool calling.
;;; Arguments:
;;;   model    - model name string
;;;   messages - list of message alists
;;;   tools    - tool definitions
;;; Returns: response alist (provider-normalised)
(define (provider-chat-with-tools model messages tools)
  (case (current-provider)
    ((ollama) ((ollama-ref 'ollama-chat-with-tools) model messages tools))
    ((gemini) ((gemini-ref 'gemini-chat-with-tools) model messages tools))
    ((openai) ((openai-ref 'openai-chat-with-tools) model messages tools))))

;;; provider-extract-token-usage: Extract token counts from response.
;;; Returns: alist with 'prompt_tokens and 'completion_tokens
(define (provider-extract-token-usage response)
  (case (current-provider)
    ((ollama) ((ollama-ref 'ollama-extract-token-usage) response))
    ((gemini) ((gemini-ref 'gemini-extract-token-usage) response))
    ((openai) ((openai-ref 'openai-extract-token-usage) response))))

;;; provider-parse-tool-call: Extract tool call from response message.
;;; Returns: alist with "name" and "arguments", or #f
(define (provider-parse-tool-call message)
  (case (current-provider)
    ((ollama) ((ollama-ref 'ollama-parse-tool-call) message))
    ((gemini) ((gemini-ref 'gemini-parse-tool-call) message))
    ((openai) ((openai-ref 'openai-parse-tool-call) message))))
