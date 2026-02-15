;;; status.scm --- Terminal status indicators -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Simple visual feedback during operations.
;; No threads - just status messages before/after blocking calls.

(define-module (sage status)
  #:use-module (ice-9 format)
  #:export (*request-timeout*
            status-show
            status-clear
            status-thinking
            status-done
            format-duration))

;;; ============================================================
;;; Configuration
;;; ============================================================

;; Request timeout in seconds (passed to curl)
;; 30s accommodates tool-rich requests (~25 tools, ~1800 prompt tokens)
;; Image gen uses its own timeout (600s)
(define *request-timeout* 30)

;;; ============================================================
;;; ANSI Helpers
;;; ============================================================

(define (ansi-dim text)
  (format #f "\x1b[2m~a\x1b[0m" text))

(define (ansi-clear-line)
  "\r\x1b[K")

;;; ============================================================
;;; Status Display
;;; ============================================================

(define (status-show msg)
  "Show a status message (dim, on current line)."
  (display (ansi-dim (format #f "~a ~a" "⏳" msg)))
  (force-output))

(define (status-clear)
  "Clear the current line."
  (display (ansi-clear-line))
  (force-output))

(define* (status-thinking #:key (model #f) (host #f))
  "Show thinking indicator with model/host context."
  (let ((msg (cond
              ((and model host)
               (format #f "Waiting for ~a (~a, timeout: ~as)..."
                       model host *request-timeout*))
              (model
               (format #f "Waiting for ~a (timeout: ~as)..."
                       model *request-timeout*))
              (else
               (format #f "Waiting for response (timeout: ~as)..."
                       *request-timeout*)))))
    (status-show msg)))

(define (status-done duration)
  "Show completion with duration."
  (status-clear)
  (display (ansi-dim (format #f "✓ Response received (~a)\n" (format-duration duration))))
  (force-output))

;;; ============================================================
;;; Duration Formatting
;;; ============================================================

(define (format-duration seconds)
  "Format seconds as human-readable duration."
  (let ((s (inexact->exact (floor seconds))))
    (cond
     ((< s 1) "<1s")
     ((< s 60) (format #f "~as" s))
     ((< s 3600) (format #f "~am ~as" (quotient s 60) (modulo s 60)))
     (else (format #f "~ah ~am" (quotient s 3600) (modulo (quotient s 60) 60))))))
