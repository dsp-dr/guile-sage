;;; scratch.scm --- Content-addressed scratch store -*- coding: utf-8 -*-

;;; Commentary:
;;
;; In-memory store for large tool outputs (fetch_url bodies, file reads,
;; log dumps, MCP tool results) that would otherwise blow the model's
;; context window. Keyed by SHA-256; the model gets back a short
;; reference (sha, size, content-type, first-N chars) and retrieves
;; pages of the full body via scratch_get(sha, offset, len).
;;
;; Session-scoped. Cleared on REPL exit or via scratch-clear!.
;;
;; Public API:
;;   (scratch-put! sha content [metadata])   -> sha
;;   (scratch-get sha [#:offset N] [#:len N]) -> string or #f
;;   (scratch-has? sha)                        -> boolean
;;   (scratch-list)                            -> list of (sha . metadata)
;;   (scratch-clear!)                          -> #t

(define-module (sage scratch)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (scratch-put!
            scratch-get
            scratch-has?
            scratch-list
            scratch-clear!
            scratch-size))

(define *scratch* (make-hash-table))

(define (scratch-put! sha content . opts)
  "Store CONTENT under SHA. Extra args are metadata key/value pairs.
Returns SHA. Idempotent: storing the same SHA again updates metadata
and replaces content."
  (let* ((metadata (if (odd? (length opts))
                       '()
                       (let loop ((xs opts) (acc '()))
                         (if (null? xs)
                             (reverse acc)
                             (loop (cddr xs)
                                   (cons (cons (car xs) (cadr xs)) acc)))))))
    (hash-set! *scratch*
               sha
               `(("content" . ,content)
                 ("bytes" . ,(string-length content))
                 ("stored-at" . ,(current-time))
                 ("metadata" . ,metadata)))
    sha))

(define* (scratch-get sha #:key (offset 0) (len #f))
  "Return a window of the content stored at SHA: (substring content
OFFSET (min (+ OFFSET LEN) (string-length content))). Missing LEN
returns the rest of the content from OFFSET. Returns #f if SHA not
present."
  (let ((entry (hash-ref *scratch* sha #f)))
    (and entry
         (let* ((body (assoc-ref entry "content"))
                (total (string-length body))
                (start (max 0 (min offset total)))
                (end (if len
                         (max start (min (+ start len) total))
                         total)))
           (substring body start end)))))

(define (scratch-has? sha)
  (and (hash-ref *scratch* sha #f) #t))

(define (scratch-list)
  "Return list of (sha . (bytes . stored-at)) pairs for inspection."
  (hash-map->list
   (lambda (sha entry)
     (cons sha
           (cons (assoc-ref entry "bytes")
                 (assoc-ref entry "stored-at"))))
   *scratch*))

(define (scratch-size)
  "Total bytes currently stored across all scratch entries."
  (fold (lambda (entry acc)
          (+ acc (assoc-ref entry "bytes")))
        0
        (hash-map->list (lambda (k v) v) *scratch*)))

(define (scratch-clear!)
  (hash-clear! *scratch*)
  #t)
