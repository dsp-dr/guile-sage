;;; provenance.scm --- Ingress provenance tracking -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Records chain-of-custody metadata for all data fetched from external
;; sources.  Every HTTP response gets a provenance record: SHA-256 hash,
;; source URL, fetch timestamp, and an XML trust wrapper.  Records are
;; optionally GPG-signed and appended to .logs/provenance.jsonl.
;;
;; Enable via SAGE_PROVENANCE=1 (off by default for local-only Ollama).

(define-module (sage provenance)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:export (provenance-enabled?
            content-sha256
            xml-wrap
            gpg-sign
            record-ingress
            provenance-log!))

;;; ============================================================
;;; Configuration
;;; ============================================================

(define (provenance-enabled?)
  "Provenance tracking is on when SAGE_PROVENANCE=1."
  (equal? "1" (getenv "SAGE_PROVENANCE")))

(define (provenance-log-file)
  (let ((dir (or (getenv "SAGE_LOG_DIR")
                 (string-append (getcwd) "/.logs"))))
    (string-append dir "/provenance.jsonl")))

(define (provenance-gpg-sign?)
  "GPG signing when SAGE_PROVENANCE_SIGN=1 and gpg is available."
  (and (equal? "1" (getenv "SAGE_PROVENANCE_SIGN"))
       (catch #t
         (lambda ()
           (let* ((port (open-input-pipe "gpg --version 2>/dev/null"))
                  (line (read-line port))
                  (ok (and (string? line) (string-contains line "gpg"))))
             (close-pipe port)
             ok))
         (lambda (key . args) #f))))

;;; ============================================================
;;; SHA-256 hashing
;;; ============================================================

(define (content-sha256 content)
  "Compute SHA-256 hex digest of CONTENT string.
Tries shasum (macOS) then sha256sum (Linux/FreeBSD)."
  (catch #t
    (lambda ()
      (let ((tmp (format #f "/tmp/sage-sha-~a-~a" (getpid) (random 1000000))))
        (call-with-output-file tmp
          (lambda (p) (display content p)))
        (let ((hash (try-hash-cmd "shasum -a 256" tmp)))
          (unless hash
            (set! hash (try-hash-cmd "sha256sum" tmp)))
          (when (file-exists? tmp) (delete-file tmp))
          (or hash "hash-error"))))
    (lambda (key . args)
      "hash-unavailable")))

(define (try-hash-cmd cmd tmp)
  "Run CMD on TMP file, extract 64-char hex hash or return #f."
  (catch #t
    (lambda ()
      (let* ((port (open-input-pipe (format #f "~a '~a'" cmd tmp)))
             (line (read-line port)))
        (close-pipe port)
        (and (string? line)
             (>= (string-length line) 64)
             (substring line 0 64))))
    (lambda (key . args) #f)))

;;; ============================================================
;;; XML trust wrapping
;;; ============================================================

(define (xml-wrap trust-level content)
  "Wrap CONTENT in an XML envelope tagged with TRUST-LEVEL.
TRUST-LEVEL is a symbol: untrusted, provider, local, verified."
  (format #f "<ingress trust=\"~a\" encoding=\"utf-8\">~a</ingress>"
          trust-level
          (xml-escape content)))

(define (xml-escape s)
  "Escape &, <, > for XML embedding."
  (let* ((s1 (string-replace-all s "&" "&amp;"))
         (s2 (string-replace-all s1 "<" "&lt;"))
         (s3 (string-replace-all s2 ">" "&gt;")))
    s3))

(define (string-replace-all str old new)
  "Replace all occurrences of OLD in STR with NEW."
  (let loop ((s str) (acc ""))
    (let ((idx (string-contains s old)))
      (if idx
          (loop (substring s (+ idx (string-length old)))
                (string-append acc (substring s 0 idx) new))
          (string-append acc s)))))

;;; ============================================================
;;; GPG signing
;;; ============================================================

(define (gpg-sign record-str)
  "GPG-sign RECORD-STR, returning (record . signature) or (record . #f).
Uses the default GPG key.  Fails gracefully — never breaks the HTTP path."
  (if (not (provenance-gpg-sign?))
      (cons record-str #f)
      (catch #t
        (lambda ()
          (let* ((tmp (format #f "/tmp/sage-prov-~a-~a" (getpid) (random 100000)))
                 (_ (call-with-output-file tmp
                      (lambda (p) (display record-str p))))
                 (sig-file (string-append tmp ".asc"))
                 ;; bd: guile-sage-9j7/07f — argv-based gpg. tmp and
                 ;; sig-file are pid-derived so not attacker-controlled,
                 ;; but we avoid /bin/sh on principle.
                 (rc (prov-exec "gpg" "--batch" "--yes" "--detach-sign"
                                "--armor" "-o" sig-file tmp)))
            (if (zero? rc)
                (let ((sig (call-with-input-file sig-file get-string-all)))
                  (delete-file tmp)
                  (delete-file sig-file)
                  (cons record-str sig))
                (begin
                  (when (file-exists? tmp) (delete-file tmp))
                  (when (file-exists? sig-file) (delete-file sig-file))
                  (cons record-str #f)))))
        (lambda (key . args)
          (cons record-str #f)))))

;;; ============================================================
;;; Shell escape (local copy to avoid circular dep on util)
;;; ============================================================

(define (shell-escape str)
  (string-replace-all str "'" "'\\''"))

;;; bd: guile-sage-9j7/07f — local argv-based system* helper.
;;; Can't use a shared helper because util imports provenance.
;;; primitive-fork + execlp dodges shell injection and the macOS
;;; Guile 3.0.11 spawn+bad-FD bug.
(define (prov-exec prog . args)
  (catch #t
    (lambda ()
      (let ((pid (primitive-fork)))
        (cond
         ((= pid 0)
          (catch #t
            (lambda () (apply execlp prog prog args))
            (lambda args (primitive-exit 127))))
         (else
          (let* ((pair (waitpid pid))
                 (status (cdr pair)))
            (or (status:exit-val status) 1))))))
    (lambda args 127)))

;;; ============================================================
;;; ISO 8601 timestamp
;;; ============================================================

(define (now-iso)
  (let* ((t (gettimeofday))
         (sec (car t))
         (usec (cdr t))
         (gm (gmtime sec)))
    (format #f "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d.~6,'0dZ"
            (+ 1900 (tm:year gm))
            (+ 1 (tm:mon gm))
            (tm:mday gm)
            (tm:hour gm)
            (tm:min gm)
            (tm:sec gm)
            usec)))

;;; ============================================================
;;; Core: record-ingress
;;; ============================================================

(define* (record-ingress content url #:key (trust 'untrusted))
  "Build a provenance record for CONTENT fetched from URL.
Returns an alist: hash, url, fetched-at, wrapped, and optionally gpg-sig."
  (let* ((hash    (content-sha256 content))
         (ts      (now-iso))
         (wrapped (xml-wrap trust content))
         (record  `((hash       . ,hash)
                    (url        . ,url)
                    (fetched-at . ,ts)
                    (trust      . ,(symbol->string trust))
                    (wrapped    . ,wrapped)))
         (signed  (gpg-sign (format #f "~a|~a|~a" hash url ts))))
    (if (cdr signed)
        (cons `(gpg-sig . ,(cdr signed)) record)
        record)))

;;; ============================================================
;;; Provenance ledger (append-only JSONL)
;;; ============================================================

(define (provenance-log! url code content-length hash)
  "Append a provenance entry to .logs/provenance.jsonl.  Never throws."
  (catch #t
    (lambda ()
      (let* ((path (provenance-log-file))
             (dir  (dirname path)))
        ;; bd: guile-sage-9j7/07f — argv-based mkdir via prov-exec.
        (unless (file-exists? dir)
          (prov-exec "mkdir" "-p" dir))
        (let ((port (open-file path "a")))
          ;; Minimal JSONL — no dependency on json-write-string to avoid
          ;; circular imports from util.
          (format port "{\"ts\":\"~a\",\"url\":\"~a\",\"code\":~a,\"bytes\":~a,\"sha256\":\"~a\"}~%"
                  (now-iso)
                  (json-escape-str url)
                  code
                  content-length
                  hash)
          (close-port port))))
    (lambda (key . args)
      ;; Silent — never break the HTTP path for bookkeeping.
      #f)))

(define (json-escape-str s)
  "Minimal JSON string escaping (quotes and backslashes)."
  (let* ((s1 (string-replace-all s "\\" "\\\\"))
         (s2 (string-replace-all s1 "\"" "\\\"")))
    s2))
