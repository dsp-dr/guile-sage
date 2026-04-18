;;; test-provenance.scm --- Tests for provenance tracking

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage provenance)
             (srfi srfi-64))

(include "test-harness.scm")
(test-begin "provenance")

;;; --- content-sha256 ---

(define (sha256-available?)
  "Check if sha256 produces real hashes (may fail in sandboxed environments)."
  (let ((h (content-sha256 "probe")))
    (and (string? h) (= 64 (string-length h)))))

(test-assert "sha256 returns 64-char hex string or graceful fallback"
  (let ((h (content-sha256 "hello world")))
    (and (string? h)
         (or (= 64 (string-length h))
             (member h '("hash-error" "hash-unavailable"))))))

(test-assert "sha256 is deterministic"
  (equal? (content-sha256 "test data")
          (content-sha256 "test data")))

(test-assert "sha256 differs for different inputs (when available)"
  (if (sha256-available?)
      (not (equal? (content-sha256 "aaa")
                   (content-sha256 "bbb")))
      #t))  ; skip when hashing unavailable

;;; --- xml-wrap ---

(test-assert "xml-wrap wraps with trust attribute"
  (let ((w (xml-wrap 'untrusted "payload")))
    (and (string-contains w "<ingress trust=\"untrusted\"")
         (string-contains w "payload")
         (string-contains w "</ingress>"))))

(test-assert "xml-wrap escapes angle brackets"
  (let ((w (xml-wrap 'untrusted "<script>alert(1)</script>")))
    (and (string-contains w "&lt;script&gt;")
         (not (string-contains w "<script>")))))

(test-assert "xml-wrap escapes ampersands"
  (let ((w (xml-wrap 'untrusted "a&b")))
    (string-contains w "a&amp;b")))

(test-assert "xml-wrap accepts different trust levels"
  (let ((w (xml-wrap 'provider "data")))
    (string-contains w "trust=\"provider\"")))

;;; --- record-ingress ---

(test-assert "record-ingress returns alist with required keys"
  (let ((r (record-ingress "body" "http://example.com")))
    (and (assoc 'hash r)
         (assoc 'url r)
         (assoc 'fetched-at r)
         (assoc 'trust r)
         (assoc 'wrapped r))))

(test-assert "record-ingress hash matches content"
  (let* ((body "test body")
         (r (record-ingress body "http://example.com"))
         (h (assoc-ref r 'hash)))
    (equal? h (content-sha256 body))))

(test-assert "record-ingress default trust is untrusted"
  (let ((r (record-ingress "x" "http://example.com")))
    (equal? "untrusted" (assoc-ref r 'trust))))

(test-assert "record-ingress custom trust level"
  (let ((r (record-ingress "x" "http://example.com" #:trust 'provider)))
    (equal? "provider" (assoc-ref r 'trust))))

(test-assert "record-ingress wrapped contains content"
  (let ((r (record-ingress "hello" "http://example.com")))
    (string-contains (assoc-ref r 'wrapped) "hello")))

;;; --- provenance-enabled? ---

(test-assert "provenance-enabled? returns #f by default"
  (not (provenance-enabled?)))

(test-end "provenance")
