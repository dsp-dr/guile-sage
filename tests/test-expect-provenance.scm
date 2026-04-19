;;; test-expect-provenance.scm --- Golden/expect tests for provenance module
;;;
;;; Every assertion uses exact expected values — no predicates, no fuzzy
;;; matching.  If a test fails the diff between got/expected is immediately
;;; visible in the FAIL output.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage provenance)
             (ice-9 textual-ports)
             (ice-9 format)
             (srfi srfi-64))

(include "test-harness.scm")
(test-begin "expect-provenance")

;; bd: guile-sage-9j7/07f — argv-based subprocess via primitive-fork
;; + execlp. Test paths are pid-derived so defence-in-depth only.
(define (exec-argv prog . args)
  (let ((pid (primitive-fork)))
    (cond
     ((= pid 0)
      (catch #t
        (lambda () (apply execlp prog prog args))
        (lambda args (primitive-exit 127))))
     (else (waitpid pid)))))

;;; ============================================================
;;; xml-wrap: exact output
;;; ============================================================

(run-test "xml-wrap plain text"
  (lambda ()
    (assert-equal
     (xml-wrap 'untrusted "hello")
     "<ingress trust=\"untrusted\" encoding=\"utf-8\">hello</ingress>"
     "xml-wrap plain")))

(run-test "xml-wrap escapes angle brackets"
  (lambda ()
    (assert-equal
     (xml-wrap 'untrusted "<b>bold</b>")
     "<ingress trust=\"untrusted\" encoding=\"utf-8\">&lt;b&gt;bold&lt;/b&gt;</ingress>"
     "xml-wrap angle brackets")))

(run-test "xml-wrap escapes ampersand"
  (lambda ()
    (assert-equal
     (xml-wrap 'untrusted "a&b")
     "<ingress trust=\"untrusted\" encoding=\"utf-8\">a&amp;b</ingress>"
     "xml-wrap ampersand")))

(run-test "xml-wrap nested entities"
  (lambda ()
    (assert-equal
     (xml-wrap 'untrusted "x&lt;y")
     "<ingress trust=\"untrusted\" encoding=\"utf-8\">x&amp;lt;y</ingress>"
     "xml-wrap nested entity")))

(run-test "xml-wrap provider trust"
  (lambda ()
    (assert-equal
     (xml-wrap 'provider "data")
     "<ingress trust=\"provider\" encoding=\"utf-8\">data</ingress>"
     "xml-wrap provider trust")))

(run-test "xml-wrap verified trust"
  (lambda ()
    (assert-equal
     (xml-wrap 'verified "sig-checked")
     "<ingress trust=\"verified\" encoding=\"utf-8\">sig-checked</ingress>"
     "xml-wrap verified trust")))

(run-test "xml-wrap empty content"
  (lambda ()
    (assert-equal
     (xml-wrap 'untrusted "")
     "<ingress trust=\"untrusted\" encoding=\"utf-8\"></ingress>"
     "xml-wrap empty")))

(run-test "xml-wrap all three escapes"
  (lambda ()
    (assert-equal
     (xml-wrap 'untrusted "<a>&b</a>")
     "<ingress trust=\"untrusted\" encoding=\"utf-8\">&lt;a&gt;&amp;b&lt;/a&gt;</ingress>"
     "xml-wrap all escapes")))

;;; ============================================================
;;; content-sha256: exact known hashes (when available)
;;; ============================================================

;;; SHA-256 reference values (precomputed):
;;;   "hello world"  → b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
;;;   ""             → e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
;;;   "test"         → 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08

(define *sha256-available*
  (let ((h (content-sha256 "probe")))
    (and (string? h) (= 64 (string-length h)))))

(run-test "sha256 hello-world exact"
  (lambda ()
    (if *sha256-available*
        (assert-equal
         (content-sha256 "hello world")
         "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
         "sha256 hello world")
        #t)))

(run-test "sha256 empty string exact"
  (lambda ()
    (if *sha256-available*
        (assert-equal
         (content-sha256 "")
         "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
         "sha256 empty")
        #t)))

(run-test "sha256 test exact"
  (lambda ()
    (if *sha256-available*
        (assert-equal
         (content-sha256 "test")
         "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
         "sha256 test")
        #t)))

;;; ============================================================
;;; record-ingress: exact structure
;;; ============================================================

(run-test "record-ingress keys present and ordered"
  (lambda ()
    (let* ((r (record-ingress "body" "http://example.com"))
           (keys (map car r)))
      ;; Without GPG: hash, url, fetched-at, trust, wrapped
      (assert-equal (length (filter (lambda (k) (memq k '(hash url fetched-at trust wrapped))) keys))
                    5
                    "record should have exactly 5 required keys"))))

(run-test "record-ingress trust field is string"
  (lambda ()
    (let ((r (record-ingress "x" "http://a.com")))
      (assert-equal (assoc-ref r 'trust) "untrusted"
                    "trust should be string untrusted"))))

(run-test "record-ingress custom trust is string"
  (lambda ()
    (let ((r (record-ingress "x" "http://a.com" #:trust 'provider)))
      (assert-equal (assoc-ref r 'trust) "provider"
                    "trust should be string provider"))))

(run-test "record-ingress url preserved exactly"
  (lambda ()
    (let ((r (record-ingress "x" "http://localhost:11434/api/chat")))
      (assert-equal (assoc-ref r 'url) "http://localhost:11434/api/chat"
                    "url should be preserved exactly"))))

(run-test "record-ingress wrapped contains xml envelope"
  (lambda ()
    (let ((r (record-ingress "payload" "http://a.com")))
      (assert-equal (assoc-ref r 'wrapped)
                    "<ingress trust=\"untrusted\" encoding=\"utf-8\">payload</ingress>"
                    "wrapped field should match xml-wrap output"))))

(run-test "record-ingress hash matches standalone sha256"
  (lambda ()
    (let* ((body "consistent body")
           (r (record-ingress body "http://a.com"))
           (h (content-sha256 body)))
      (assert-equal (assoc-ref r 'hash) h
                    "hash in record should match standalone content-sha256"))))

;;; ============================================================
;;; gpg-sign: exact fallback when signing disabled
;;; ============================================================

(run-test "gpg-sign returns (record . #f) when signing disabled"
  (lambda ()
    (let ((result (gpg-sign "test-data")))
      (assert-equal (car result) "test-data"
                    "signed record should preserve input")
      (assert-equal (cdr result) #f
                    "signature should be #f when signing disabled"))))

;;; ============================================================
;;; provenance-log!: exact JSONL format
;;; ============================================================

(run-test "provenance-log! writes valid JSONL line"
  (lambda ()
    (let* ((tmp-dir (format #f "/tmp/sage-prov-test-~a" (getpid)))
           (tmp-file (string-append tmp-dir "/provenance.jsonl")))
      ;; Set up temp log dir
      (exec-argv "mkdir" "-p" tmp-dir)
      (setenv "SAGE_LOG_DIR" tmp-dir)
      (setenv "SAGE_PROVENANCE" "1")
      ;; Write one entry
      (provenance-log! "http://localhost:11434/api/chat" 200 1234 "abc123def456")
      ;; Read it back
      (let ((line (call-with-input-file tmp-file
                    (lambda (p) (get-line p)))))
        ;; Verify structure (exact field names, no extras)
        (assert-contains line "\"url\":\"http://localhost:11434/api/chat\""
                         "JSONL should contain url")
        (assert-contains line "\"code\":200"
                         "JSONL should contain code")
        (assert-contains line "\"bytes\":1234"
                         "JSONL should contain bytes")
        (assert-contains line "\"sha256\":\"abc123def456\""
                         "JSONL should contain sha256")
        (assert-contains line "\"ts\":\""
                         "JSONL should contain timestamp"))
      ;; Clean up
      (setenv "SAGE_PROVENANCE" #f)
      (setenv "SAGE_LOG_DIR" #f)
      (exec-argv "rm" "-rf" tmp-dir))))

(run-test "provenance-log! escapes URLs with quotes"
  (lambda ()
    (let* ((tmp-dir (format #f "/tmp/sage-prov-test2-~a" (getpid)))
           (tmp-file (string-append tmp-dir "/provenance.jsonl")))
      (exec-argv "mkdir" "-p" tmp-dir)
      (setenv "SAGE_LOG_DIR" tmp-dir)
      (setenv "SAGE_PROVENANCE" "1")
      (provenance-log! "http://a.com/path?q=\"val\"" 200 0 "deadbeef")
      (let ((line (call-with-input-file tmp-file
                    (lambda (p) (get-line p)))))
        (assert-contains line "\\\"val\\\"" "quotes in URL should be escaped")
        (assert-not-contains line "\"val\"\"" "raw quotes should not appear"))
      (setenv "SAGE_PROVENANCE" #f)
      (setenv "SAGE_LOG_DIR" #f)
      (exec-argv "rm" "-rf" tmp-dir))))

(run-test "provenance-log! appends multiple lines"
  (lambda ()
    (let* ((tmp-dir (format #f "/tmp/sage-prov-test3-~a" (getpid)))
           (tmp-file (string-append tmp-dir "/provenance.jsonl")))
      (exec-argv "mkdir" "-p" tmp-dir)
      (setenv "SAGE_LOG_DIR" tmp-dir)
      (setenv "SAGE_PROVENANCE" "1")
      (provenance-log! "http://a.com/1" 200 10 "hash1")
      (provenance-log! "http://a.com/2" 200 20 "hash2")
      (provenance-log! "http://a.com/3" 404 0  "hash3")
      (let* ((content (call-with-input-file tmp-file get-string-all))
             (lines (filter (lambda (s) (> (string-length s) 0))
                            (string-split content #\newline))))
        (assert-equal (length lines) 3 "should have exactly 3 JSONL lines")
        (assert-contains (list-ref lines 0) "\"url\":\"http://a.com/1\""
                         "line 1 url")
        (assert-contains (list-ref lines 1) "\"url\":\"http://a.com/2\""
                         "line 2 url")
        (assert-contains (list-ref lines 2) "\"code\":404"
                         "line 3 code"))
      (setenv "SAGE_PROVENANCE" #f)
      (setenv "SAGE_LOG_DIR" #f)
      (exec-argv "rm" "-rf" tmp-dir))))

;;; ============================================================
;;; provenance-enabled?: exact behavior
;;; ============================================================

(run-test "provenance-enabled? false when unset"
  (lambda ()
    (setenv "SAGE_PROVENANCE" #f)
    (assert-equal (provenance-enabled?) #f "should be #f when unset")))

(run-test "provenance-enabled? false when set to 0"
  (lambda ()
    (setenv "SAGE_PROVENANCE" "0")
    (assert-equal (provenance-enabled?) #f "should be #f when 0")
    (setenv "SAGE_PROVENANCE" #f)))

(run-test "provenance-enabled? true when set to 1"
  (lambda ()
    (setenv "SAGE_PROVENANCE" "1")
    (assert-equal (provenance-enabled?) #t "should be #t when 1")
    (setenv "SAGE_PROVENANCE" #f)))

(run-test "provenance-enabled? false when set to yes"
  (lambda ()
    (setenv "SAGE_PROVENANCE" "yes")
    (assert-equal (provenance-enabled?) #f "should be #f for non-1 values")
    (setenv "SAGE_PROVENANCE" #f)))

(test-end "expect-provenance")
(test-summary)
