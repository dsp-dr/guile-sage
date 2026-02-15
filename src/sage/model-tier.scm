;;; model-tier.scm --- Dynamic model tier selection -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Selects the appropriate model based on current token count.
;; Lighter models for small contexts, heavier models for large.
;; Pure logic -- no side effects or I/O.

(define-module (sage model-tier)
  #:use-module (sage config)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (*model-tiers*
            resolve-model-for-tokens
            load-model-tiers
            tier-available?
            filter-available-tiers
            tier-model
            tier-name
            tier-ceiling
            tier-context-limit
            tier-supports-tools?))

;;; ============================================================
;;; Tier Data Structure
;;; ============================================================

;;; Each tier is an alist:
;;;   name          - human label ("fast", "standard")
;;;   model         - Ollama model name
;;;   ceiling       - max token count for this tier
;;;   context-limit - model's hard context window
;;;   tools?        - whether model supports native tool calling

(define *default-model-tiers*
  `((("name" . "fast")
     ("model" . "llama3.2:latest")
     ("ceiling" . 2000)
     ("context-limit" . 8000)
     ("tools?" . #f))
    (("name" . "standard")
     ("model" . "mistral:latest")
     ("ceiling" . 6000)
     ("context-limit" . 8000)
     ("tools?" . #t))))

(define *model-tiers* *default-model-tiers*)

;;; ============================================================
;;; Tier Accessors
;;; ============================================================

(define (tier-name tier) (assoc-ref tier "name"))
(define (tier-model tier) (assoc-ref tier "model"))
(define (tier-ceiling tier) (assoc-ref tier "ceiling"))
(define (tier-context-limit tier) (assoc-ref tier "context-limit"))
(define (tier-supports-tools? tier) (assoc-ref tier "tools?"))

;;; ============================================================
;;; Tier Resolution
;;; ============================================================

;;; resolve-model-for-tokens: Select tier for current token count
;;; Returns: tier alist. First tier whose ceiling > tokens wins.
;;;          If none, returns last tier (heaviest available).
(define* (resolve-model-for-tokens tokens #:optional (tiers *model-tiers*))
  (or (find (lambda (t) (< tokens (tier-ceiling t))) tiers)
      (last tiers)))

;;; ============================================================
;;; Tier Configuration
;;; ============================================================

;;; load-model-tiers: Load tier config from env, filter by available models
;;; Arguments:
;;;   available-model-names - list of model name strings from ollama-list-models
;;; Returns: filtered list of tier alists
(define* (load-model-tiers #:optional (available-model-names '()))
  (let* ((fast-model (or (config-get "MODEL_TIER_FAST") "llama3.2:latest"))
         (standard-model (or (config-get "MODEL_TIER_STANDARD") "mistral:latest"))
         (fast-ceiling (or (and=> (config-get "MODEL_TIER_CEILING_FAST") string->number)
                           2000))
         (standard-ceiling (or (and=> (config-get "MODEL_TIER_CEILING_STANDARD") string->number)
                               6000))
         (tiers `((("name" . "fast")
                   ("model" . ,fast-model)
                   ("ceiling" . ,fast-ceiling)
                   ("context-limit" . ,(get-token-limit fast-model))
                   ("tools?" . #f))
                  (("name" . "standard")
                   ("model" . ,standard-model)
                   ("ceiling" . ,standard-ceiling)
                   ("context-limit" . ,(get-token-limit standard-model))
                   ("tools?" . #t)))))
    (if (null? available-model-names)
        tiers
        (filter-available-tiers tiers available-model-names))))

;;; tier-available?: Check if a tier's model is in available list
(define (tier-available? tier available-model-names)
  (any (lambda (name)
         (string-contains name (tier-model tier)))
       available-model-names))

;;; filter-available-tiers: Keep only tiers whose models are pulled
(define (filter-available-tiers tiers available-model-names)
  (let ((filtered (filter (lambda (t)
                            (tier-available? t available-model-names))
                          tiers)))
    (if (null? filtered)
        ;; Nothing available -- keep defaults and hope for the best
        tiers
        filtered)))
