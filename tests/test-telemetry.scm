#!/usr/bin/env guile3
!#
;;; test-telemetry.scm --- Tests for OTLP/HTTP telemetry module

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage telemetry)
             (sage util)
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

;;; Restore disabled state for test isolation
(setenv "SAGE_TELEMETRY_DISABLE" "1")
(telemetry-shutdown!)

(test-summary)
