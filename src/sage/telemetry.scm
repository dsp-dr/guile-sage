;;; telemetry.scm --- OTLP/HTTP JSON metric emission -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Emits cumulative counter metrics to an OpenTelemetry Collector via the
;; OTLP/HTTP JSON protocol (proto3 JSON mapping). Designed for the NexusHive
;; observability stack on the LAN_SUBNET LAN: counters land in Prometheus
;; with `exported_job=guile-sage` and appear on the AI Tools dashboard alongside
;; Claude Code, Gemini CLI, Codex, and Aider.
;;
;; Public API:
;;   (telemetry-init)            -- read env vars, build resource attrs
;;   (telemetry-enabled?)        -- #t when emission is configured
;;   (inc-counter! name labels n) -- bump cumulative counter
;;   (telemetry-flush!)          -- POST current totals to the collector
;;   (telemetry-shutdown!)       -- final flush before exit
;;
;; Transport: OTLP/HTTP JSON to ${endpoint}/v1/metrics. Prefers
;; OTEL_EXPORTER_OTLP_METRICS_ENDPOINT, then derives :4318/v1/metrics from
;; OTEL_EXPORTER_OTLP_ENDPOINT (substituting the gRPC port :4317 if present).
;;
;; Failure mode: any error (timeout, refused, non-2xx) is logged via log-warn
;; and silently swallowed. Telemetry must never break the REPL.
;;
;; Opt-out: set SAGE_TELEMETRY_DISABLE=1 to make every operation a no-op.

(define-module (sage telemetry)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (sage version)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:export (telemetry-init
            telemetry-enabled?
            telemetry-endpoint
            inc-counter!
            telemetry-flush!
            telemetry-shutdown!
            ;; Exposed for tests
            *counters*
            *flush-backoff-seconds*
            *last-flush-failure*
            in-flush-backoff?
            counter-key
            normalize-labels
            build-resource-attributes
            build-metrics-payload
            current-time-unix-nano
            parse-otel-resource-attrs))

;;; ============================================================
;;; State
;;; ============================================================

(define *enabled* #f)
(define *endpoint* #f)
(define *resource-attrs* '())
(define *start-time-unix-nano* "0")
(define *counters* (make-hash-table))
(define *initialized* #f)

;;; Backoff state: suppress flush retries for *flush-backoff-seconds* after
;;; a failed POST, so a down collector doesn't burn wall time on every turn.
;;; Counters accumulate in memory continuously; only the PUSH is rate-limited.
(define *last-flush-failure* #f)    ; #f or epoch seconds of last failure
(define *flush-backoff-seconds* 60) ; how long to suppress retries

;;; Scope identifies the meter name + version (matches "otel_scope_name" in
;;; Prometheus). Mirrors the spec's example "com.nexushive.my_agent".
(define *scope-name* "com.dsp-dr.guile_sage")

;;; Per-metric unit lookup. The OTel collector's Prometheus exporter
;;; uses these to suffix the Prometheus metric name (e.g. unit "tokens"
;;; produces `_tokens_total`). Must match the spec's metric naming table.
(define *metric-units*
  '(("guile_sage.token.usage"        . "tokens")
    ("guile_sage.cost.usage"         . "USD")
    ("guile_sage.active.time"        . "s")
    ("guile_sage.session.count"      . "1")
    ("guile_sage.code_edit.tool_decision" . "1")))

(define (metric-unit name)
  (or (assoc-ref *metric-units* name) "1"))

;;; ============================================================
;;; Time helpers
;;; ============================================================

;;; current-time-unix-nano: Nanoseconds since epoch as integer.
(define (current-time-unix-nano)
  (let ((t (current-time time-utc)))
    (+ (* (time-second t) 1000000000)
       (time-nanosecond t))))

;;; ============================================================
;;; Endpoint resolution
;;; ============================================================

;;; resolve-endpoint: Pick the OTLP/HTTP metrics URL from env vars.
;;; Prefers OTEL_EXPORTER_OTLP_METRICS_ENDPOINT (already a full URL),
;;; otherwise derives one from OTEL_EXPORTER_OTLP_ENDPOINT by substituting
;;; :4317 -> :4318 and appending /v1/metrics.
(define (resolve-endpoint)
  (let ((metrics-url (or (getenv "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
                         (config-get "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")))
        (base (or (getenv "OTEL_EXPORTER_OTLP_ENDPOINT")
                  (config-get "OTEL_EXPORTER_OTLP_ENDPOINT"))))
    (cond
     (metrics-url metrics-url)
     (base
      (let* ((http-base (regexp-substitute/global #f ":4317" base
                                                  'pre ":4318" 'post)))
        (string-append http-base "/v1/metrics")))
     (else #f))))

;;; ============================================================
;;; Resource attributes
;;; ============================================================

;;; parse-otel-resource-attrs: Parse "k1=v1,k2=v2,..." into an alist.
;;; Returns: list of (string . string) pairs. Whitespace trimmed.
(define (parse-otel-resource-attrs str)
  (if (or (not str) (string-null? str))
      '()
      (filter-map
       (lambda (kv)
         (let ((eq-pos (string-index kv #\=)))
           (and eq-pos
                (cons (string-trim-both (substring kv 0 eq-pos))
                      (string-trim-both (substring kv (1+ eq-pos)))))))
       (string-split str #\,))))

;;; gethostname-safe: Return hostname or "unknown" on failure.
(define (gethostname-safe)
  (catch #t
    (lambda () (gethostname))
    (lambda args "unknown")))

;;; build-resource-attributes: Build the OTLP resource.attributes vector.
;;; Always includes service.name=guile-sage and service.version=<ver>.
;;; Merges OTEL_RESOURCE_ATTRIBUTES from env so existing host.name, team,
;;; sefaca.* tags propagate. Caller-provided keys override env values.
(define (build-resource-attributes)
  (let* ((env-attrs (parse-otel-resource-attrs
                     (or (getenv "OTEL_RESOURCE_ATTRIBUTES") "")))
         (host (or (assoc-ref env-attrs "host.name")
                   (gethostname-safe)))
         (defaults `(("service.name" . "guile-sage")
                     ("service.version" . ,(version-string))
                     ("host.name" . ,host)))
         ;; env attrs first, then defaults override (so service.name wins)
         (merged (let loop ((acc env-attrs) (over defaults))
                   (if (null? over)
                       acc
                       (let* ((k (caar over))
                              (v (cdar over))
                              (rest (filter (lambda (p) (not (equal? (car p) k)))
                                            acc)))
                         (loop (cons (cons k v) rest) (cdr over)))))))
    (list->vector
     (map (lambda (pair)
            `(("key" . ,(car pair))
              ("value" . (("stringValue" . ,(cdr pair))))))
          merged))))

;;; ============================================================
;;; Counter registry
;;; ============================================================

;;; normalize-labels: Sort labels by key for stable hash keys.
;;; Arguments:
;;;   labels - alist of (string . string) label pairs
;;; Returns: sorted alist
(define (normalize-labels labels)
  (sort labels (lambda (a b) (string<? (car a) (car b)))))

;;; counter-key: Build a stable lookup key for the counter table.
(define (counter-key name labels)
  (cons name (normalize-labels labels)))

;;; inc-counter!: Bump a cumulative counter by n.
;;; No-op when telemetry is disabled.
;;; Arguments:
;;;   name   - OTLP metric name (e.g. "guile_sage.session.count")
;;;   labels - alist of (string . string) data-point attributes
;;;   n      - integer increment (default 1)
(define* (inc-counter! name labels #:optional (n 1))
  (when *enabled*
    (let* ((key (counter-key name labels))
           (cur (hash-ref *counters* key 0)))
      (hash-set! *counters* key (+ cur n)))))

;;; ============================================================
;;; OTLP payload construction
;;; ============================================================

;;; labels->attribute-vec: Convert label alist to OTLP attributes vector.
(define (labels->attribute-vec labels)
  (list->vector
   (map (lambda (pair)
          `(("key" . ,(car pair))
            ("value" . (("stringValue" . ,(cdr pair))))))
        labels)))

;;; counter-entry->datapoint: Build one OTLP NumberDataPoint object.
(define (counter-entry->datapoint entry now-nanos)
  (let* ((key (car entry))
         (count (cdr entry))
         (labels (cdr key)))
    `(("attributes" . ,(labels->attribute-vec labels))
      ("startTimeUnixNano" . ,*start-time-unix-nano*)
      ("timeUnixNano" . ,(number->string now-nanos))
      ("asInt" . ,(number->string count)))))

;;; group-by-metric-name: Group counter entries by metric name.
;;; Returns: alist of (metric-name . (entries...))
(define (group-by-metric-name entries)
  (let ((groups '()))
    (for-each
     (lambda (entry)
       (let* ((name (caar entry))
              (existing (assoc name groups)))
         (if existing
             (set-cdr! existing (cons entry (cdr existing)))
             (set! groups (cons (list name entry) groups)))))
     entries)
    groups))

;;; group->metric: Build one OTLP Metric from a (name . entries) group.
(define (group->metric group now-nanos)
  (let ((name (car group))
        (entries (cdr group)))
    `(("name" . ,name)
      ("unit" . ,(metric-unit name))
      ("sum" . (("aggregationTemporality" . 2)
                ("isMonotonic" . #t)
                ("dataPoints" .
                 ,(list->vector
                   (map (lambda (e) (counter-entry->datapoint e now-nanos))
                        entries))))))))

;;; collect-counters: Snapshot the counter hash as a list of entries.
(define (collect-counters)
  (let ((entries '()))
    (hash-for-each
     (lambda (k v)
       (set! entries (cons (cons k v) entries)))
     *counters*)
    entries))

;;; build-metrics-payload: Build a complete OTLP ExportMetricsServiceRequest
;;; alist ready for json-write-string. Same-named counters with different
;;; label sets are grouped into a single Metric with multiple data points.
(define (build-metrics-payload)
  (let* ((now (current-time-unix-nano))
         (entries (collect-counters))
         (groups (group-by-metric-name entries))
         (metrics (list->vector
                   (map (lambda (g) (group->metric g now)) groups))))
    `(("resourceMetrics" .
       ,(vector
         `(("resource" . (("attributes" . ,*resource-attrs*)))
           ("scopeMetrics" .
            ,(vector
              `(("scope" . (("name" . ,*scope-name*)
                            ("version" . ,(version-string))))
                ("metrics" . ,metrics))))))))))

;;; ============================================================
;;; Flush backoff
;;; ============================================================

;;; in-flush-backoff?: Return #t if we're within the backoff window
;;; following a failed flush. The caller should skip the POST.
(define (in-flush-backoff?)
  (and *last-flush-failure*
       (let ((now (time-second (current-time time-utc))))
         (< (- now *last-flush-failure*) *flush-backoff-seconds*))))

;;; ============================================================
;;; Init / flush / shutdown
;;; ============================================================

;;; telemetry-init: Read env vars and build static state.
;;; Idempotent: subsequent calls are no-ops.
;;; Disabled when SAGE_TELEMETRY_DISABLE is set or no endpoint resolves.
(define (telemetry-init)
  (unless *initialized*
    (set! *initialized* #t)
    (cond
     ((getenv "SAGE_TELEMETRY_DISABLE")
      (set! *enabled* #f)
      (log-info "telemetry" "Telemetry disabled via SAGE_TELEMETRY_DISABLE"))
     (else
      (let ((url (resolve-endpoint)))
        (cond
         ((not url)
          (set! *enabled* #f)
          (log-info "telemetry"
                    "Telemetry disabled: no OTEL_EXPORTER_OTLP_ENDPOINT set"))
         (else
          (set! *endpoint* url)
          (set! *resource-attrs* (build-resource-attributes))
          (set! *start-time-unix-nano*
                (number->string (current-time-unix-nano)))
          (set! *enabled* #t)
          (log-info "telemetry" "Telemetry enabled"
                    `(("endpoint" . ,url)
                      ("service" . "guile-sage")
                      ("version" . ,(version-string)))))))))))

;;; telemetry-enabled?: Check whether emission is currently active.
(define (telemetry-enabled?) *enabled*)

;;; telemetry-endpoint: Return the resolved metrics URL or #f.
(define (telemetry-endpoint) *endpoint*)

;;; telemetry-flush!: POST current cumulative totals to the collector.
;;; Fail-soft: any error is logged at WARN and discarded.
;;; When a previous flush has failed, subsequent calls are suppressed for
;;; *flush-backoff-seconds* to avoid burning wall time on a dead collector.
;;; Counters stay in memory and the next successful flush carries everything.
(define (telemetry-flush!)
  (when (and *enabled* (> (hash-count (const #t) *counters*) 0))
    (if (in-flush-backoff?)
        (log-debug "telemetry" "Flush skipped (backoff window)"
                   `(("backoff_seconds" . ,*flush-backoff-seconds*)))
        (catch #t
          (lambda ()
            (let* ((payload (build-metrics-payload))
                   (body (json-write-string payload))
                   (result (http-post-with-timeout *endpoint* body 2)))
              (let ((code (if (pair? result) (car result) 0)))
                (cond
                 ((and (number? code) (>= code 200) (< code 300))
                  ;; Success -- clear any prior backoff
                  (set! *last-flush-failure* #f)
                  (log-debug "telemetry" "Flush succeeded"
                             `(("code" . ,code)
                               ("counters" . ,(hash-count (const #t) *counters*)))))
                 (else
                  ;; Non-2xx -- enter backoff
                  (set! *last-flush-failure*
                        (time-second (current-time time-utc)))
                  (log-warn "telemetry" "Flush failed (non-2xx)"
                            `(("code" . ,code)
                              ("endpoint" . ,*endpoint*))))))))
          (lambda (key . args)
            ;; Exception -- enter backoff
            (set! *last-flush-failure*
                  (time-second (current-time time-utc)))
            (log-warn "telemetry" "Flush threw"
                      `(("error" . ,(format #f "~a ~a" key args)))))))))

;;; telemetry-shutdown!: Final flush before process exit.
;;; Always attempts one last flush regardless of backoff state -- this is the
;;; user's last chance to push accumulated counters before the process dies.
;;; Resets state so a subsequent telemetry-init can re-initialize.
(define (telemetry-shutdown!)
  (when *enabled*
    ;; Clear backoff so the final flush attempt actually fires.
    (set! *last-flush-failure* #f)
    (telemetry-flush!))
  (set! *initialized* #f))
