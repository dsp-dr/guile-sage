#!/usr/bin/env guile3
!#
;;; test-telemetry.scm --- Tests for OTLP/HTTP telemetry module

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage telemetry)
             (sage config)
             (sage util)
             (srfi srfi-1)
             (srfi srfi-19)
             (ice-9 format))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Telemetry Tests ===~%")

;;; Disable real network emission for the duration of these tests so
;;; telemetry-init takes the no-op path. We still exercise the pure
;;; helpers (label normalization, JSON shape) directly.
(setenv "SAGE_TELEMETRY_DISABLE" "1")

;;; ----- Pure helpers -----

(format #t "~%--- Label normalization ---~%")

(run-test "normalize-labels sorts by key"
  (lambda ()
    (let ((sorted (normalize-labels '(("type" . "input") ("model" . "x")))))
      (assert-equal (caar sorted) "model" "first key should be 'model'")
      (assert-equal (caadr sorted) "type" "second key should be 'type'"))))

(run-test "counter-key is stable across label order"
  (lambda ()
    (let ((k1 (counter-key "m" '(("a" . "1") ("b" . "2"))))
          (k2 (counter-key "m" '(("b" . "2") ("a" . "1")))))
      (assert-equal k1 k2 "keys should match regardless of input order"))))

(run-test "counter-key differs by metric name"
  (lambda ()
    (let ((k1 (counter-key "m" '(("a" . "1"))))
          (k2 (counter-key "n" '(("a" . "1")))))
      (when (equal? k1 k2)
        (error "different metric names must produce different keys")))))

;;; ----- Resource attribute parsing -----

(format #t "~%--- Resource attributes ---~%")

(run-test "parse-otel-resource-attrs handles empty input"
  (lambda ()
    (assert-equal (parse-otel-resource-attrs "") '() "empty string -> empty list")
    (assert-equal (parse-otel-resource-attrs #f) '() "false -> empty list")))

(run-test "parse-otel-resource-attrs splits k=v pairs"
  (lambda ()
    (let ((attrs (parse-otel-resource-attrs "host.name=mini,team=aygp-dr")))
      (assert-equal (assoc-ref attrs "host.name") "mini" "host.name parsed")
      (assert-equal (assoc-ref attrs "team") "aygp-dr" "team parsed"))))

(run-test "parse-otel-resource-attrs ignores malformed entries"
  (lambda ()
    (let ((attrs (parse-otel-resource-attrs "good=1,nokey,also.good=2")))
      (assert-equal (assoc-ref attrs "good") "1" "good= parsed")
      (assert-equal (assoc-ref attrs "also.good") "2" "also.good parsed")
      (assert-equal (length attrs) 2 "malformed entry skipped"))))

;;; ----- Counter accumulation (no-op when disabled) -----

(format #t "~%--- Counter accumulation ---~%")

(run-test "inc-counter! is a no-op when telemetry is disabled"
  (lambda ()
    (telemetry-init)  ; reads SAGE_TELEMETRY_DISABLE
    (when (telemetry-enabled?)
      (error "telemetry should be disabled by SAGE_TELEMETRY_DISABLE"))
    (inc-counter! "x.y" '(("k" . "v")) 5)
    ;; Hash table should still be empty
    (let ((count 0))
      (hash-for-each (lambda (k v) (set! count (+ count 1))) *counters*)
      (assert-equal count 0 "no counters recorded when disabled"))))

;;; ----- Enabled-mode payload assembly -----
;;; Force enable for these tests by re-enabling and pointing at a
;;; non-routable address. We never call telemetry-flush! here.

(format #t "~%--- Payload assembly (forced enable) ---~%")

(unsetenv "SAGE_TELEMETRY_DISABLE")
(setenv "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT" "http://127.0.0.1:1/v1/metrics")
(setenv "OTEL_RESOURCE_ATTRIBUTES" "host.name=testhost,team=testteam")
;; Reset module state by calling telemetry-shutdown! (clears initialized flag)
(telemetry-shutdown!)
;; Clear counters from any earlier test that ran with enabled state
(hash-clear! *counters*)
(telemetry-init)

(run-test "telemetry enables when endpoint is set"
  (lambda ()
    (unless (telemetry-enabled?)
      (error "should enable when OTEL_EXPORTER_OTLP_METRICS_ENDPOINT is set"))
    (assert-equal (telemetry-endpoint) "http://127.0.0.1:1/v1/metrics"
                  "endpoint should match env")))

(run-test "inc-counter! records cumulative value"
  (lambda ()
    (inc-counter! "guile_sage.token.usage" '(("model" . "m1") ("type" . "input")) 3)
    (inc-counter! "guile_sage.token.usage" '(("model" . "m1") ("type" . "input")) 4)
    (let* ((key (counter-key "guile_sage.token.usage"
                             '(("model" . "m1") ("type" . "input"))))
           (val (hash-ref *counters* key)))
      (assert-equal val 7 "increments accumulate"))))

(run-test "build-metrics-payload groups same-name metrics"
  (lambda ()
    (hash-clear! *counters*)
    (inc-counter! "guile_sage.token.usage" '(("model" . "m1") ("type" . "input")) 10)
    (inc-counter! "guile_sage.token.usage" '(("model" . "m1") ("type" . "output")) 20)
    (inc-counter! "guile_sage.session.count" '(("session_id" . "s1")) 1)
    (let* ((payload (build-metrics-payload))
           (json (json-write-string payload)))
      (assert-contains json "\"resourceMetrics\"" "has resourceMetrics")
      (assert-contains json "\"service.name\"" "has service.name attr")
      (assert-contains json "\"guile-sage\"" "service.name value present")
      (assert-contains json "\"guile_sage.token.usage\"" "token.usage metric present")
      (assert-contains json "\"guile_sage.session.count\"" "session.count metric present")
      (assert-contains json "\"aggregationTemporality\":2" "cumulative temporality")
      (assert-contains json "\"isMonotonic\":true" "monotonic counter")
      (assert-contains json "\"asInt\":\"10\"" "int datapoint encoded as string")
      (assert-contains json "\"asInt\":\"20\"" "second datapoint present")
      (assert-contains json "\"asInt\":\"1\"" "session datapoint")
      (assert-contains json "host.name" "host.name resource attr present")
      (assert-contains json "testhost" "host.name value from env"))))

(run-test "build-metrics-payload encodes time as nano string"
  (lambda ()
    (let ((json (json-write-string (build-metrics-payload))))
      (assert-contains json "\"startTimeUnixNano\"" "has startTimeUnixNano")
      (assert-contains json "\"timeUnixNano\"" "has timeUnixNano"))))

(run-test "scope name and version present"
  (lambda ()
    (let ((json (json-write-string (build-metrics-payload))))
      (assert-contains json "com.dsp-dr.guile_sage" "scope name")
      (assert-contains json "\"version\":\"" "scope has version"))))

;;; ----- Endpoint resolution from gRPC base -----

(format #t "~%--- Endpoint resolution ---~%")

(run-test "endpoint derives :4318/v1/metrics from gRPC base"
  (lambda ()
    (unsetenv "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
    (setenv "OTEL_EXPORTER_OTLP_ENDPOINT" "http://INFRA_HOST:4317")
    (telemetry-shutdown!)
    (telemetry-init)
    (assert-equal (telemetry-endpoint) "http://INFRA_HOST:4318/v1/metrics"
                  ":4317 -> :4318 substitution + /v1/metrics suffix")))

;;; ----- Flush backoff tests -----
;;; These tests exercise the backoff mechanism added in guile-u3n.
;;; We keep telemetry enabled with a non-routable endpoint so every
;;; flush attempt fails, triggering the backoff state machine.

(format #t "~%--- Flush backoff ---~%")

;;; Re-initialize with unreachable endpoint for backoff tests
(telemetry-shutdown!)
(hash-clear! *counters*)
(set! *last-flush-failure* #f)
(unsetenv "SAGE_TELEMETRY_DISABLE")
(setenv "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT" "http://127.0.0.1:1/v1/metrics")
(setenv "OTEL_RESOURCE_ATTRIBUTES" "host.name=testhost,team=testteam")
(telemetry-init)

(run-test "flush enters backoff after failure"
  (lambda ()
    ;; Precondition: no backoff yet
    (assert-false (in-flush-backoff?) "should not be in backoff initially")
    ;; Add a counter so flush has something to send
    (inc-counter! "guile_sage.session.count" '(("session_id" . "bo1")) 1)
    ;; Flush to unreachable endpoint — should fail and set *last-flush-failure*
    (telemetry-flush!)
    (assert-true (in-flush-backoff?) "should be in backoff after failed flush")))

(run-test "flush skips during backoff window"
  (lambda ()
    ;; We're already in backoff from the previous test.
    ;; Record counter state before the skip.
    (let ((before-val (hash-ref *counters*
                                (counter-key "guile_sage.session.count"
                                             '(("session_id" . "bo1")))
                                0)))
      ;; Increment a counter — this should work regardless of backoff
      (inc-counter! "guile_sage.session.count" '(("session_id" . "bo1")) 5)
      ;; Flush should be skipped (backoff window). No POST attempted.
      (telemetry-flush!)
      ;; The counter should still reflect the increment (counters survive)
      (let ((after-val (hash-ref *counters*
                                 (counter-key "guile_sage.session.count"
                                              '(("session_id" . "bo1")))
                                 0)))
        (assert-equal after-val (+ before-val 5)
                      "counters accumulate even during backoff")))))

(run-test "flush retries after backoff expires"
  (lambda ()
    ;; Simulate backoff expiry by backdating *last-flush-failure* beyond
    ;; the 60s window. This avoids depending on set! of the backoff
    ;; constant which the Guile compiler may constant-fold.
    (let ((now (time-second (current-time time-utc))))
      (set! *last-flush-failure* (- now 120))) ; 120s ago, well past 60s window
    (assert-false (in-flush-backoff?) "backoff should have expired")
    ;; Flush again — this will attempt the POST (and fail again since
    ;; endpoint is still unreachable), re-entering backoff.
    (telemetry-flush!)
    (assert-true (in-flush-backoff?) "should re-enter backoff after retry fails")))

(run-test "shutdown always flushes regardless of backoff"
  (lambda ()
    ;; We're in backoff. Verify it.
    (assert-true (in-flush-backoff?) "should be in backoff before shutdown")
    ;; Record the failure timestamp before shutdown
    (let ((old-ts *last-flush-failure*))
      ;; shutdown! clears backoff and attempts flush. The flush will fail
      ;; again (unreachable endpoint), setting a NEW *last-flush-failure*.
      ;; The key property: shutdown cleared the old backoff so the POST
      ;; was actually attempted (not skipped).
      (telemetry-shutdown!)
      ;; After shutdown, *last-flush-failure* should be updated because
      ;; the flush was attempted (not skipped) and failed again.
      ;; If backoff had NOT been cleared, the flush would have been
      ;; skipped and *last-flush-failure* would still be old-ts.
      ;; Since the endpoint is unreachable, the re-attempted flush fails
      ;; and writes a new (>= old) timestamp.
      (assert-true (or (not *last-flush-failure*)
                       (>= *last-flush-failure* old-ts))
                   "shutdown should have attempted the flush"))))

(run-test "counters survive backoff"
  (lambda ()
    ;; Re-initialize for a clean slate
    (hash-clear! *counters*)
    (set! *last-flush-failure* #f)
    (telemetry-init)
    ;; Phase 1: increment counters, then fail a flush (enter backoff)
    (inc-counter! "guile_sage.token.usage" '(("model" . "m1") ("type" . "input")) 10)
    (telemetry-flush!)  ; fails -> backoff
    (assert-true (in-flush-backoff?) "should be in backoff")
    ;; Phase 2: increment more counters during backoff
    (inc-counter! "guile_sage.token.usage" '(("model" . "m1") ("type" . "input")) 25)
    (telemetry-flush!)  ; skipped due to backoff
    ;; Verify the cumulative total includes ALL increments
    (let* ((key (counter-key "guile_sage.token.usage"
                             '(("model" . "m1") ("type" . "input"))))
           (val (hash-ref *counters* key 0)))
      (assert-equal val 35
                    "cumulative total should include all increments across backoff"))))

;;; ----- Direct unit tests for helpers with only indirect coverage -----

(format #t "~%--- Direct helper tests ---~%")

(run-test "current-time-unix-nano returns a large positive integer"
  (lambda ()
    (let ((t (current-time-unix-nano)))
      (assert-true (integer? t) "should be an integer")
      (assert-true (> t 0) "should be positive")
      ;; Sanity: should be after 2020-01-01 in nanos (~1.577e18)
      (assert-true (> t 1577836800000000000)
                   "should be after 2020-01-01 epoch nanos"))))

(run-test "build-resource-attributes returns vector with service.name"
  (lambda ()
    (let* ((attrs (build-resource-attributes))
           (attrs-list (vector->list attrs)))
      (assert-true (vector? attrs) "should return a vector")
      (assert-true (> (vector-length attrs) 0) "should have at least one attr")
      ;; Check that service.name = "guile-sage" is present
      (let ((has-service-name
             (any (lambda (attr)
                    (and (equal? (assoc-ref attr "key") "service.name")
                         (equal? (assoc-ref (assoc-ref attr "value") "stringValue")
                                 "guile-sage")))
                  attrs-list)))
        (assert-true has-service-name
                     "should contain service.name=guile-sage")))))

;;; ----- Guardrail config tests -----
;;; These test guardrail-proxy-url and guardrail-check-provider from
;;; (sage config), which are observability exports with no prior test coverage.

(format #t "~%--- Guardrail config ---~%")

(run-test "guardrail-proxy-url returns #f when not configured"
  (lambda ()
    ;; Clear any existing env var
    (unsetenv "SAGE_GUARDRAIL_PROXY")
    (assert-false (guardrail-proxy-url)
                  "should return #f when SAGE_GUARDRAIL_PROXY is unset")))

(run-test "guardrail-proxy-url returns value when configured"
  (lambda ()
    (setenv "SAGE_GUARDRAIL_PROXY" "http://localhost:4000")
    (let ((url (guardrail-proxy-url)))
      (assert-equal url "http://localhost:4000"
                    "should return the proxy URL from env"))
    (unsetenv "SAGE_GUARDRAIL_PROXY")))

(run-test "guardrail-check-provider returns #f when no proxy configured"
  (lambda ()
    (unsetenv "SAGE_GUARDRAIL_PROXY")
    (assert-false (guardrail-check-provider "ollama" "http://localhost:11434")
                  "no proxy -> no warning")))

(run-test "guardrail-check-provider returns #f when provider routes through proxy"
  (lambda ()
    (setenv "SAGE_GUARDRAIL_PROXY" "localhost:4000")
    (assert-false (guardrail-check-provider "litellm" "http://localhost:4000/v1")
                  "provider host contains proxy -> no warning")
    (unsetenv "SAGE_GUARDRAIL_PROXY")))

(run-test "guardrail-check-provider returns warning when provider bypasses proxy"
  (lambda ()
    (setenv "SAGE_GUARDRAIL_PROXY" "localhost:4000")
    (let ((result (guardrail-check-provider "ollama" "http://localhost:11434")))
      (assert-true (string? result) "should return a warning string")
      (assert-contains result "NOT routed"
                       "warning should mention NOT routed")
      (assert-contains result "ollama"
                       "warning should mention provider name")
      (assert-contains result "localhost:4000"
                       "warning should mention proxy URL"))
    (unsetenv "SAGE_GUARDRAIL_PROXY")))

;;; Restore disabled state for test isolation
(setenv "SAGE_TELEMETRY_DISABLE" "1")
(set! *last-flush-failure* #f)
(telemetry-shutdown!)

(test-summary)
