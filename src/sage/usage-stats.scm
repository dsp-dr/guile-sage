;;; usage-stats.scm --- Local JSONL usage-stats store -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Append-only JSONL ledger of tool-call events, used by /stats (and a
;; future /onboarding command) to show which tools are used and how
;; long they take.
;;
;; Storage: $XDG_STATE_HOME/sage/usage.jsonl (default
;; ~/.local/state/sage/usage.jsonl). One JSON object per line:
;;
;;   {"ts":"2026-04-19T21:00:00Z","tool":"read_file",
;;    "args_digest":"path=LICENSE","duration_ms":4,"result_bytes":1085}
;;
;; Opt-out: set SAGE_STATS_DISABLE=1 to make usage-put! a no-op.
;;
;; Failure mode: usage-put! swallows every error and logs at WARN so a
;; stats-write failure never disturbs the caller (mirrors telemetry.scm
;; and provenance.scm). Aggregation in usage-summary linearly scans the
;; file — fine for now; can be swapped for incremental state if it gets
;; slow.
;;
;; bd: guile-sage-b5c.

(define-module (sage usage-stats)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 format)
  #:export (usage-put!
            usage-summary
            usage-clear!
            usage-log-file
            usage-disabled?))

;;; ============================================================
;;; Paths + opt-out
;;; ============================================================

(define (usage-log-file)
  "Absolute path to the usage JSONL ledger."
  (string-append (sage-state-dir) "/usage.jsonl"))

(define (usage-disabled?)
  "Return #t when SAGE_STATS_DISABLE is set (non-empty, non-0)."
  (let ((v (getenv "SAGE_STATS_DISABLE")))
    (and v (not (string-null? v)) (not (string=? v "0")))))

;;; ============================================================
;;; Time formatting
;;; ============================================================

(define (now-iso)
  "ISO 8601 UTC timestamp, second precision."
  (let* ((t (gettimeofday))
         (gm (gmtime (car t))))
    (format #f "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            (+ 1900 (tm:year gm))
            (+ 1 (tm:mon gm))
            (tm:mday gm)
            (tm:hour gm)
            (tm:min gm)
            (tm:sec gm))))

;;; ============================================================
;;; Directory helper (inline, mirrors sage/config ensure-dir)
;;; ============================================================

(define (ensure-dir! path)
  (unless (file-exists? path)
    (let ((pid (primitive-fork)))
      (cond
       ((= pid 0)
        (catch #t
          (lambda () (execlp "mkdir" "mkdir" "-p" path))
          (lambda args (primitive-exit 127))))
       (else (waitpid pid))))))

;;; ============================================================
;;; Digest: truncate to 80 chars so we don't bloat the ledger
;;; with full arg alists (privacy + size).
;;; ============================================================

(define (truncate-digest s)
  (let ((str (if (string? s) s (format #f "~a" s))))
    (if (> (string-length str) 80)
        (substring str 0 80)
        str)))

;;; ============================================================
;;; Writer
;;; ============================================================

;;; usage-put!: Append one event to the ledger.
;;;
;;;   tool-name       string
;;;   args-summary    string or any — coerced via format ~a, then truncated
;;;   duration-ms     number
;;;   result-bytes    integer
;;;
;;; Returns #t on success, #f on any failure (which is also logged at WARN).
(define (usage-put! tool-name args-summary duration-ms result-bytes)
  (if (usage-disabled?)
      #f
      (catch #t
        (lambda ()
          (let* ((path (usage-log-file))
                 (entry `(("ts"           . ,(now-iso))
                          ("tool"         . ,(format #f "~a" tool-name))
                          ("args_digest"  . ,(truncate-digest args-summary))
                          ("duration_ms"  . ,(or duration-ms 0))
                          ("result_bytes" . ,(or result-bytes 0)))))
            (ensure-dir! (dirname path))
            (let ((port (open-file path "a")))
              (display (json-write-string entry) port)
              (newline port)
              (close-port port))
            #t))
        (lambda (key . args)
          (log-warn "usage-stats"
                    (format #f "Failed to append usage entry: ~a ~a" key args)
                    `(("tool" . ,(format #f "~a" tool-name))))
          #f))))

;;; ============================================================
;;; Reader + aggregator
;;; ============================================================

(define (read-jsonl-lines path)
  "Return a list of parsed JSON objects from a JSONL file.
Malformed lines are skipped. Missing file -> '()."
  (if (not (file-exists? path))
      '()
      (call-with-input-file path
        (lambda (port)
          (let loop ((line (read-line port)) (acc '()))
            (cond
             ((eof-object? line) (reverse acc))
             ((string-null? (string-trim-both line))
              (loop (read-line port) acc))
             (else
              (let ((parsed (catch #t
                              (lambda () (json-read-string line))
                              (lambda args #f))))
                (loop (read-line port)
                      (if parsed (cons parsed acc) acc))))))))))

(define (alist-add alist key amount)
  "Return alist with key's value increased by amount (or set to amount
if absent). Pure — does not mutate its argument."
  (let ((cur (assoc-ref alist key)))
    (if cur
        (assoc-set! alist key (+ cur amount))
        (cons (cons key amount) alist))))

(define (sort-desc-by-cdr alist)
  (sort alist (lambda (a b) (> (cdr a) (cdr b)))))

;;; usage-summary: Aggregate the ledger.
;;;
;;; Returns an alist:
;;;   (("total_calls"  . N)
;;;    ("by_tool"      . ((tool . count) ...))       sorted desc by count
;;;    ("by_duration"  . ((tool . total_ms) ...))    sorted desc by total_ms
;;;    ("first_seen"   . iso-or-#f)
;;;    ("last_seen"    . iso-or-#f))
(define (usage-summary)
  (let loop ((entries (read-jsonl-lines (usage-log-file)))
             (total 0)
             (by-tool '())
             (by-duration '())
             (first-seen #f)
             (last-seen #f))
    (cond
     ((null? entries)
      `(("total_calls" . ,total)
        ("by_tool"     . ,(sort-desc-by-cdr by-tool))
        ("by_duration" . ,(sort-desc-by-cdr by-duration))
        ("first_seen"  . ,first-seen)
        ("last_seen"   . ,last-seen)))
     (else
      (let* ((e (car entries))
             (tool (or (assoc-ref e "tool") "unknown"))
             (dur  (or (assoc-ref e "duration_ms") 0))
             (ts   (assoc-ref e "ts")))
        (loop (cdr entries)
              (+ total 1)
              (alist-add by-tool tool 1)
              (alist-add by-duration tool dur)
              (or first-seen ts)   ; entries are in file (append) order
              (or ts last-seen)))))))

;;; ============================================================
;;; Clear (for testing)
;;; ============================================================

(define (usage-clear!)
  "Remove the ledger file. Always returns #t (missing file is fine)."
  (catch #t
    (lambda () (delete-file (usage-log-file)) #t)
    (lambda args #t)))
