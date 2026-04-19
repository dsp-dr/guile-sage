#!/usr/bin/env guile3
!#
;;; test-model-fallback.scm --- Graceful handling of removed models

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage ollama)
             (sage model-tier)
             (ice-9 format))

(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Model Fallback (graceful removal handling) ===~%")

;;; Synthetic /api/tags entries that exercise each branch of the
;;; chat-capable filter without touching the live Ollama daemon.

;; Sizes are in bytes (matches what /api/tags returns). Picked to make
;; the size-ASC ordering deterministic and obvious.

(define gguf-llama
  '(("name" . "llama3.2:latest")
    ("size" . 2000000000)  ; 2 GB
    ("details" . (("family" . "llama") ("format" . "gguf")))))

(define gguf-qwen
  '(("name" . "qwen2.5-coder:7b")
    ("size" . 4700000000)  ; 4.7 GB
    ("details" . (("family" . "qwen2") ("format" . "gguf")))))

(define gguf-qwen-big
  '(("name" . "qwen2.5-coder:14b-instruct-q4_K_M")
    ("size" . 9000000000)  ; 9 GB
    ("details" . (("family" . "qwen2") ("format" . "gguf")))))

(define gguf-embed
  '(("name" . "nomic-embed-text:v1.5")
    ("size" . 274000000)  ; 274 MB but rejected as embedding
    ("details" . (("family" . "nomic-bert") ("format" . "gguf")))))

(define safetensors-image
  '(("name" . "x/flux2-klein:4b")
    ("size" . 5700000000)  ; 5.7 GB but rejected as image
    ("details" . (("family" . "") ("format" . "safetensors")))))

(define empty-family
  '(("name" . "wellecks/ntpctx-llama3-8b:latest")
    ("size" . 8500000000)
    ("details" . (("family" . "") ("format" . "gguf")))))

;; Order is intentionally NOT sorted by size, to verify select-fallback's sort.
(define all-fakes
  (list gguf-qwen-big gguf-qwen gguf-embed safetensors-image empty-family gguf-llama))

;;; ----- chat-capable-model? -----

(format #t "~%--- chat-capable-model? ---~%")

(run-test "gguf llama is chat-capable"
  (lambda ()
    (unless (chat-capable-model? gguf-llama)
      (error "llama gguf should be chat-capable"))))

(run-test "gguf qwen is chat-capable"
  (lambda ()
    (unless (chat-capable-model? gguf-qwen)
      (error "qwen gguf should be chat-capable"))))

(run-test "nomic-bert embedding model is rejected"
  (lambda ()
    (when (chat-capable-model? gguf-embed)
      (error "embedding model must not be chat-capable"))))

(run-test "safetensors image model is rejected"
  (lambda ()
    (when (chat-capable-model? safetensors-image)
      (error "image gen model must not be chat-capable"))))

(run-test "model with empty family is rejected"
  (lambda ()
    (when (chat-capable-model? empty-family)
      (error "empty family must not be chat-capable"))))

;;; ----- model-available? -----

(format #t "~%--- model-available? ---~%")

(run-test "model-available? returns #t for installed model"
  (lambda ()
    (unless (model-available? "llama3.2:latest" all-fakes)
      (error "llama3.2:latest should be available"))))

(run-test "model-available? returns #f for missing model"
  (lambda ()
    (when (model-available? "mistral:latest" all-fakes)
      (error "mistral:latest should not be available"))))

(run-test "model-available? returns #f on empty list"
  (lambda ()
    (when (model-available? "anything" '())
      (error "empty list should not contain anything"))))

;;; ----- select-fallback-model -----

(format #t "~%--- select-fallback-model ---~%")

(run-test "select-fallback returns preferred when present"
  (lambda ()
    (let ((picked (select-fallback-model "qwen2.5-coder:7b" all-fakes)))
      (unless (equal? picked "qwen2.5-coder:7b")
        (error "should return preferred when available" picked)))))

(run-test "select-fallback skips embedding models"
  (lambda ()
    (let ((picked (select-fallback-model "missing:model"
                                         (list gguf-embed gguf-llama))))
      (unless (equal? picked "llama3.2:latest")
        (error "should skip embed and pick llama" picked)))))

(run-test "select-fallback skips image models"
  (lambda ()
    (let ((picked (select-fallback-model "missing:model"
                                         (list safetensors-image gguf-qwen))))
      (unless (equal? picked "qwen2.5-coder:7b")
        (error "should skip image and pick qwen" picked)))))

(run-test "select-fallback prefers smallest chat model when preferred missing"
  (lambda ()
    ;; all-fakes order is intentionally NOT size-ASC. The fallback must
    ;; sort and pick the smallest chat-capable (llama3.2 at 2 GB).
    (let ((picked (select-fallback-model "mistral:latest" all-fakes)))
      (unless (equal? picked "llama3.2:latest")
        (error "should pick smallest chat model" picked)))))

(run-test "select-fallback picks 7B over 14B when both are present"
  (lambda ()
    ;; Mimic the live dev-host: only qwen2.5-coder variants left, no llama.
    ;; Smallest = 7b at 4.7 GB.
    (let ((picked (select-fallback-model "mistral:latest"
                                         (list gguf-qwen-big gguf-qwen))))
      (unless (equal? picked "qwen2.5-coder:7b")
        (error "should pick 7b over 14b" picked)))))

(run-test "select-fallback last-resort: pick first model when none chat-capable"
  (lambda ()
    (let ((picked (select-fallback-model "missing:model"
                                         (list gguf-embed safetensors-image))))
      ;; Both filtered out by chat-capable, so the last-resort branch
      ;; returns whatever is first in the raw list.
      (unless (equal? picked "nomic-embed-text:v1.5")
        (error "last-resort should return first model" picked)))))

(run-test "select-fallback returns #f on empty list"
  (lambda ()
    (let ((picked (select-fallback-model "anything" '())))
      (when picked
        (error "empty list should yield #f" picked)))))

;;; ----- ollama-error-message -----

(format #t "~%--- ollama-error-message ---~%")

(run-test "extracts error from ollama 404 JSON"
  (lambda ()
    (let ((msg (ollama-error-message
                "{\"error\":\"model 'mistral:latest' not found\"}")))
      (unless (equal? msg "model 'mistral:latest' not found")
        (error "wrong message" msg)))))

(run-test "passes plain text through unchanged"
  (lambda ()
    (let ((msg (ollama-error-message "internal server error")))
      (unless (string-contains msg "internal server error")
        (error "should pass plain text through" msg)))))

(run-test "handles empty body"
  (lambda ()
    (let ((msg (ollama-error-message "")))
      (unless (string-contains msg "empty")
        (error "should describe empty body" msg)))))

(run-test "handles malformed JSON without crashing"
  (lambda ()
    (let ((msg (ollama-error-message "{not valid json")))
      ;; Just shouldn't throw
      (unless (string? msg)
        (error "should always return a string" msg)))))

;;; ----- model-tier defaults match the new picks -----

(format #t "~%--- model-tier defaults ---~%")

(run-test "default standard tier no longer references mistral"
  (lambda ()
    (let ((standard (cadr *model-tiers*)))
      (when (string-contains (tier-model standard) "mistral")
        (error "standard tier should not default to mistral after removal"
               (tier-model standard))))))

(run-test "default fast tier supports tools"
  (lambda ()
    (let ((fast (car *model-tiers*)))
      (unless (tier-supports-tools? fast)
        (error "fast tier (llama3.2) supports tool calling")))))

(test-summary)
