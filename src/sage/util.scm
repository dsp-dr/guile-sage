;;; util.scm --- HTTP and JSON utilities -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Provides HTTP client and JSON utilities for guile-sage.
;; Uses Guile's native (web client) for HTTP - no shell/curl dependencies.

(define-module (sage util)
  #:use-module (web client)
  #:use-module (web uri)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 format)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 popen)
  #:use-module (srfi srfi-1)
  #:export (http-get
            http-post
            http-post-with-timeout
            http-post-with-headers-captured
            http-post-streaming
            json-read-string
            json-write-string
            json-empty-object
            as-list
            string-replace-substring
            make-temp-file
            parse-curl-header-dump
            ;; HTTP debug logging (SAGE_DEBUG_HTTP=1)
            http-debug-enabled?
            http-debug-log-file
            http-debug-log!
            http-debug-sensitive-header?))

;;; ============================================================
;;; JSON Parser (minimal implementation)
;;; ============================================================

(define (skip-ws str pos)
  (let loop ((i pos))
    (if (>= i (string-length str))
        i
        (if (char-whitespace? (string-ref str i))
            (loop (1+ i))
            i))))

(define (parse-str str pos)
  (let loop ((i pos) (acc '()))
    (if (>= i (string-length str))
        (error "Unterminated string")
        (let ((c (string-ref str i)))
          (cond
           ((char=? c #\")
            (cons (list->string (reverse acc)) (1+ i)))
           ((char=? c #\\)
            (let ((next (string-ref str (1+ i))))
              (loop (+ i 2)
                    (cons (case next
                            ((#\n) #\newline)
                            ((#\t) #\tab)
                            ((#\r) #\return)
                            (else next))
                          acc))))
           (else
            (loop (1+ i) (cons c acc))))))))

(define (parse-num str pos)
  (let loop ((i pos))
    (if (>= i (string-length str))
        (cons (string->number (substring str pos i)) i)
        (let ((c (string-ref str i)))
          (if (or (char-numeric? c)
                  (memv c '(#\- #\+ #\. #\e #\E)))
              (loop (1+ i))
              (cons (string->number (substring str pos i)) i))))))

(define (parse-arr str pos)
  (let ((pos (skip-ws str pos)))
    (if (char=? (string-ref str pos) #\])
        (cons '() (1+ pos))
        (let loop ((pos pos) (acc '()))
          (let* ((result (parse-val str pos))
                 (value (car result))
                 (pos (skip-ws str (cdr result))))
            (let ((c (string-ref str pos)))
              (cond
               ((char=? c #\])
                (cons (reverse (cons value acc)) (1+ pos)))
               ((char=? c #\,)
                (loop (1+ pos) (cons value acc)))
               (else
                (error "Expected , or ]")))))))))

(define (parse-obj str pos)
  (let ((pos (skip-ws str pos)))
    (if (char=? (string-ref str pos) #\})
        (cons '() (1+ pos))
        (let loop ((pos pos) (acc '()))
          (let ((pos (skip-ws str pos)))
            (let* ((key-result (parse-str str (1+ pos)))
                   (key (car key-result))
                   (pos (skip-ws str (cdr key-result))))
              (let* ((val-result (parse-val str (1+ pos)))
                     (val (car val-result))
                     (pos (skip-ws str (cdr val-result))))
                (let ((c (string-ref str pos)))
                  (cond
                   ((char=? c #\})
                    (cons (reverse (cons (cons key val) acc)) (1+ pos)))
                   ((char=? c #\,)
                    (loop (1+ pos) (cons (cons key val) acc)))
                   (else
                    (error "Expected , or }")))))))))))

(define (parse-val str pos)
  (let ((pos (skip-ws str pos)))
    (let ((c (string-ref str pos)))
      (cond
       ((char=? c #\") (parse-str str (1+ pos)))
       ((char=? c #\{) (parse-obj str (1+ pos)))
       ((char=? c #\[) (parse-arr str (1+ pos)))
       ((char=? c #\t) (cons #t (+ pos 4)))
       ((char=? c #\f) (cons #f (+ pos 5)))
       ((char=? c #\n) (cons 'null (+ pos 4)))
       ((or (char-numeric? c) (char=? c #\-)) (parse-num str pos))
       (else (error "Unexpected character" c))))))

(define (json-read-string str)
  (car (parse-val str 0)))

;;; ============================================================
;;; JSON Writer
;;; ============================================================

(define (escape-str s)
  (call-with-output-string
    (lambda (p)
      (string-for-each
       (lambda (c)
         (case c
           ((#\") (display "\\\"" p))
           ((#\\) (display "\\\\" p))
           ((#\newline) (display "\\n" p))
           ((#\return) (display "\\r" p))
           ((#\tab) (display "\\t" p))
           (else (display c p))))
       s))))

;;; json-empty-object: Sentinel for an empty JSON object {}.
;;;
;;; The JSON parser in this file collapses both [] and {} to '() because
;;; Scheme has no native distinction between empty list and empty alist.
;;; That's a one-way lossy decoding which is fine for inbound traffic
;;; (callers either don't care or specialise on context), but it means
;;; outbound writers can never produce {} from '() because (null? obj)
;;; eagerly emits "null".
;;;
;;; This sentinel exists so callers that NEED to emit {} explicitly can:
;;;
;;;   (json-write-string `(("capabilities" . (("sampling" . ,json-empty-object)))))
;;;   ;; => "{\"capabilities\":{\"sampling\":{}}}"
;;;
;;; Required by MCP's `initialize` request shape (see
;;; docs/MCP-CONTRACT.org). bd: guile-bw2.
(define json-empty-object 'json-empty-object)

(define (json-write obj port)
  (cond
   ((eq? obj #t) (display "true" port))
   ((eq? obj #f) (display "false" port))
   ((eq? obj 'null) (display "null" port))
   ((eq? obj json-empty-object) (display "{}" port))
   ((null? obj) (display "null" port))
   ((number? obj) (display obj port))
   ((string? obj)
    (display "\"" port)
    (display (escape-str obj) port)
    (display "\"" port))
   ((vector? obj)
    (display "[" port)
    (let ((len (vector-length obj)))
      (do ((i 0 (1+ i)))
          ((>= i len))
        (when (> i 0) (display "," port))
        (json-write (vector-ref obj i) port)))
    (display "]" port))
   ((and (pair? obj) (pair? (car obj)) (string? (caar obj)))
    (display "{" port)
    (let loop ((items obj) (first #t))
      (when (pair? items)
        (unless first (display "," port))
        (display "\"" port)
        (display (escape-str (caar items)) port)
        (display "\":" port)
        (json-write (cdar items) port)
        (loop (cdr items) #f)))
    (display "}" port))
   ((list? obj)
    (display "[" port)
    (let loop ((items obj) (first #t))
      (when (pair? items)
        (unless first (display "," port))
        (json-write (car items) port)
        (loop (cdr items) #f)))
    (display "]" port))
   (else (error "Cannot serialize" obj))))

(define (json-write-string obj)
  (call-with-output-string
    (lambda (port) (json-write obj port))))

;;; as-list: Coerce vector / list / #f / '() to a Scheme list.
;;;
;;; sage's JSON parser returns JSON arrays as Scheme LISTS, not vectors.
;;; But every place in the codebase that *constructs* a JSON array uses
;;; (list->vector ...) to make it serialize correctly. So a roundtrip
;;; (parse -> mutate -> serialize) sees BOTH shapes for what is
;;; semantically the same data: vector when sage built it, list when
;;; sage parsed it.
;;;
;;; The defensive pattern was first established in
;;; src/sage/ollama.scm:ollama-parse-tool-call (commit 0a7f24c) which
;;; accepted both shapes for the streaming-tool-call fix. The MCP
;;; envelope decoder will need the same shape coercion. Centralising
;;; here keeps the workaround in one place.
;;;
;;; Edge cases:
;;;   #f      -> '()  (treat \"missing\" as empty for callers using
;;;                    (assoc-ref obj \"key\") which returns #f)
;;;   '()     -> '()
;;;   list    -> identity
;;;   vector  -> (vector->list v)
;;;
;;; Anything else throws so the caller catches the type confusion early.
;;; bd: guile-p94.
(define (as-list obj)
  (cond
   ((not obj) '())
   ((null? obj) '())
   ((list? obj) obj)
   ((vector? obj) (vector->list obj))
   (else
    (error "as-list: cannot coerce" obj))))

;;; ============================================================
;;; HTTP Debug Logging
;;; ============================================================
;;;
;;; When SAGE_DEBUG_HTTP=1, every request/response that passes through
;;; http-post / http-post-with-timeout / http-post-streaming gets dumped
;;; as one JSONL line to .logs/http.jsonl. Lets us bidirectionally
;;; verify model/protocol compliance (compare what sage sends vs what
;;; curl would send) without rebuilding the request by hand.
;;;
;;; Bodies > 8192 chars are truncated unless SAGE_DEBUG_HTTP_FULL=1.
;;; Logging failures are silently swallowed so they never break the
;;; HTTP path itself.

(define (http-debug-enabled?)
  (and (getenv "SAGE_DEBUG_HTTP") #t))

(define (http-debug-full-bodies?)
  (and (getenv "SAGE_DEBUG_HTTP_FULL") #t))

(define (http-debug-log-file)
  (let ((dir (or (getenv "SAGE_LOG_DIR")
                 (string-append (getcwd) "/.logs"))))
    (string-append dir "/http.jsonl")))

(define (http-debug-now-iso)
  ;; ISO 8601 in UTC, microsecond precision
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

(define (http-debug-truncate s)
  (cond
   ((not (string? s)) "")
   ((http-debug-full-bodies?) s)
   ((> (string-length s) 8192)
    (string-append (substring s 0 8192)
                   (format #f "...[truncated, full size=~a]" (string-length s))))
   (else s)))

(define (http-debug-log! entry)
  "Append a JSONL entry to .logs/http.jsonl. Never throws."
  (when (http-debug-enabled?)
    (catch #t
      (lambda ()
        (let* ((path (http-debug-log-file))
               (dir (dirname path)))
          (unless (file-exists? dir)
            (system (format #f "mkdir -p '~a'" dir)))
          (let ((port (open-file path "a")))
            (display (json-write-string entry) port)
            (newline port)
            (close-port port))))
      (lambda args #f))))

(define (http-debug-sensitive-header? name)
  "Return #t if a header name should be redacted in debug logs.
Covers bearer-token-bearing headers for OpenAI-shape providers and
Cloudflare AI Gateway (cf-aig-authorization)."
  (and (string? name)
       (or (string-ci=? name "Authorization")
           (string-ci=? name "cf-aig-authorization")
           (string-ci=? name "x-api-key"))))

(define (http-debug-headers->display headers)
  ;; Render header alist as a list of "k: v" pairs for the log entry.
  ;; Redacts bearer-token-bearing headers to avoid credential leaks.
  (map (lambda (h)
         (let ((k (car h))
               (v (cdr h)))
           (if (http-debug-sensitive-header? k)
               (format #f "~a: <redacted>" k)
               (format #f "~a: ~a" k v))))
       headers))

;;; ============================================================
;;; HTTP Client
;;; - Native Guile (web client) for HTTP requests
;;; - curl fallback for HTTPS (gnutls cert issues)
;;; - Streaming via #:streaming? #t (body returned as port)
;;; ============================================================

(define (make-temp-file prefix)
  (format #f "/tmp/~a-~a-~a" prefix (getpid) (random 100000)))

;;; body->string: Convert response body to string
(define (body->string body)
  (cond
   ((string? body) body)
   ((bytevector? body) (utf8->string body))
   ((port? body) (get-string-all body))
   (else "")))

;;; headers->alist: Convert header alist to format expected by http-request
(define (headers->alist headers)
  (map (lambda (h)
         (cons (string->symbol (car h)) (cdr h)))
       headers))

;;; https?: Check if URL uses HTTPS
(define (https? url)
  (string-prefix? "https://" url))

;;; shell-escape: Escape string for safe shell use (single quotes)
(define (shell-escape str)
  ;; Replace ' with '\'' (end quote, escaped quote, start quote)
  (string-replace-substring str "'" "'\\''"))

;;; http-get-native: Native Guile HTTP GET (for non-HTTPS)
(define* (http-get-native url #:key (headers '()))
  (receive (response body)
      (http-request url
                    #:method 'GET
                    #:headers (headers->alist headers))
    (cons (response-code response)
          (body->string body))))

;;; http-get-curl: Curl fallback for HTTPS
(define* (http-get-curl url #:key (headers '()))
  (let* ((out-file (make-temp-file "sage-get"))
         (header-args (string-join
                       (map (lambda (h)
                              (format #f "-H '~a: ~a'"
                                      (shell-escape (car h))
                                      (shell-escape (cdr h))))
                            headers)
                       " "))
         (cmd (format #f "curl -s -w '\\n%{http_code}' ~a '~a' > '~a'"
                      header-args
                      (shell-escape url)
                      out-file)))
    (system cmd)
    (let ((output (call-with-input-file out-file get-string-all)))
      (delete-file out-file)
      (let* ((lines (string-split output #\newline))
             (code-line (last lines))
             (body-lines (drop-right lines 1)))
        (cons (string->number code-line)
              (string-join body-lines "\n"))))))

;;; http-post-native: Native Guile HTTP POST
(define* (http-post-native url body #:key (headers '()))
  (receive (response response-body)
      (http-request url
                    #:method 'POST
                    #:body body
                    #:headers (cons '(content-type application/json)
                                    (headers->alist headers)))
    (cons (response-code response)
          (body->string response-body))))

;;; http-post-streaming-native: Native Guile streaming POST
;;; Uses #:streaming? #t to get body as a port for line-by-line reading.
;;; No subprocess, no temp files.
(define* (http-post-streaming-native url body on-chunk
                                     #:key (timeout 30) (headers '()))
  (receive (response resp-body)
      (http-request url
                    #:method 'POST
                    #:body body
                    #:headers (cons '(content-type application/json)
                                    (headers->alist headers))
                    #:streaming? #t)
    (let ((final-chunk #f))
      (catch #t
        (lambda ()
          (let loop ()
            (let ((line (read-line resp-body)))
              (unless (eof-object? line)
                (let ((trimmed (string-trim-both line)))
                  (unless (string-null? trimmed)
                    (catch #t
                      (lambda ()
                        (let ((chunk (json-read-string trimmed)))
                          (on-chunk chunk)
                          (when (and (list? chunk)
                                     (eq? #t (assoc-ref chunk "done")))
                            (set! final-chunk chunk))))
                      (lambda (key . args)
                        ;; Skip malformed JSON lines
                        #f))))
                (loop)))))
        (lambda (key . args)
          ;; Ensure cleanup on error
          #f))
      (when (port? resp-body)
        (close-port resp-body))
      final-chunk)))

;;; http-post-curl: Curl fallback for HTTPS
;;; Now with timeout support (default 5 minutes)
(define* (http-post-curl url body #:key (headers '()) (timeout 300))
  (let* ((in-file (make-temp-file "sage-post-in"))
         (out-file (make-temp-file "sage-post-out"))
         (dummy (call-with-output-file in-file
                  (lambda (port) (display body port))))
         (header-args (string-join
                       (cons "-H 'Content-Type: application/json'"
                             (map (lambda (h)
                                    (format #f "-H '~a: ~a'"
                                            (shell-escape (car h))
                                            (shell-escape (cdr h))))
                                  headers))
                       " "))
         (cmd (format #f "curl -s --max-time ~a -w '\\n%{http_code}' -X POST ~a -d '@~a' '~a' > '~a'"
                      timeout header-args in-file
                      (shell-escape url)
                      out-file)))
    (system cmd)
    (let ((output (call-with-input-file out-file get-string-all)))
      (delete-file in-file)
      (delete-file out-file)
      (let* ((lines (string-split output #\newline))
             (code-line (last lines))
             (body-lines (drop-right lines 1)))
        (cons (string->number code-line)
              (string-join body-lines "\n"))))))

;;; http-get: Use curl for HTTPS (gnutls cert issues), native for HTTP
(define* (http-get url #:key (headers '()))
  (catch #t
    (lambda ()
      (if (https? url)
          (http-get-curl url #:headers headers)
          (http-get-native url #:headers headers)))
    (lambda (key . args)
      (cons 0 (format #f "HTTP error: ~a ~a" key args)))))

;;; http-post: Native for HTTP, curl fallback for HTTPS
(define* (http-post url body #:key (headers '()))
  (let ((start (gettimeofday)))
    (http-debug-log!
     `(("ts" . ,(http-debug-now-iso))
       ("type" . "request")
       ("method" . "POST")
       ("url" . ,url)
       ("headers" . ,(list->vector (http-debug-headers->display headers)))
       ("body_size" . ,(string-length (or body "")))
       ("body" . ,(http-debug-truncate (or body "")))))
    (let* ((result (catch #t
                     (lambda ()
                       (if (https? url)
                           (http-post-curl url body #:headers headers)
                           (http-post-native url body #:headers headers)))
                     (lambda (key . args)
                       (cons 0 (format #f "HTTP error: ~a ~a" key args)))))
           (now (gettimeofday))
           (elapsed-ms (+ (* 1000 (- (car now) (car start)))
                          (quotient (- (cdr now) (cdr start)) 1000)))
           (code (if (pair? result) (car result) 0))
           (resp (if (pair? result) (cdr result) "")))
      (http-debug-log!
       `(("ts" . ,(http-debug-now-iso))
         ("type" . "response")
         ("url" . ,url)
         ("code" . ,code)
         ("elapsed_ms" . ,elapsed-ms)
         ("body_size" . ,(string-length (or resp "")))
         ("body" . ,(http-debug-truncate (or resp "")))))
      result)))

;;; http-post-with-timeout: POST with explicit timeout in seconds
;;; Native for HTTP (timeout ignored -- local network), curl for HTTPS
(define* (http-post-with-timeout url body timeout #:key (headers '()))
  (let ((start (gettimeofday)))
    (http-debug-log!
     `(("ts" . ,(http-debug-now-iso))
       ("type" . "request")
       ("method" . "POST")
       ("url" . ,url)
       ("timeout_s" . ,timeout)
       ("headers" . ,(list->vector (http-debug-headers->display headers)))
       ("body_size" . ,(string-length (or body "")))
       ("body" . ,(http-debug-truncate (or body "")))))
    (let* ((result (catch #t
                     (lambda ()
                       (if (https? url)
                           (http-post-curl url body #:headers headers #:timeout timeout)
                           (http-post-native url body #:headers headers)))
                     (lambda (key . args)
                       (cons 0 (format #f "HTTP error: ~a ~a" key args)))))
           (now (gettimeofday))
           (elapsed-ms (+ (* 1000 (- (car now) (car start)))
                          (quotient (- (cdr now) (cdr start)) 1000)))
           (code (if (pair? result) (car result) 0))
           (resp (if (pair? result) (cdr result) "")))
      (http-debug-log!
       `(("ts" . ,(http-debug-now-iso))
         ("type" . "response")
         ("url" . ,url)
         ("code" . ,code)
         ("elapsed_ms" . ,elapsed-ms)
         ("body_size" . ,(string-length (or resp "")))
         ("body" . ,(http-debug-truncate (or resp "")))))
      result)))

;;; parse-curl-header-dump: Parse curl `-D` output into a response-headers alist.
;;; curl emits the status line followed by `Name: Value\r\n` pairs, a blank
;;; line, and potentially a second block if the server sent redirects or a
;;; 100-Continue. We want the LAST block (the response that carries the body)
;;; so we always return headers from the final non-empty block.
(define (parse-curl-header-dump text)
  (if (or (not (string? text)) (string-null? text))
      '()
      (let* ((normalised (string-replace-substring text "\r" ""))
             (raw-lines (string-split normalised #\newline))
             ;; Find the last status line (HTTP/...); headers we want are
             ;; everything after it, stopping at the next empty line.
             (reversed (reverse raw-lines))
             (after-last-status
              (let loop ((lines reversed) (acc '()))
                (cond
                 ((null? lines) acc)
                 ((string-prefix? "HTTP/" (string-trim-both (car lines)))
                  acc)
                 (else (loop (cdr lines) (cons (car lines) acc))))))
             ;; Stop at the first empty line (end of headers).
             (header-lines
              (let loop ((lines after-last-status) (acc '()))
                (cond
                 ((null? lines) (reverse acc))
                 ((string-null? (string-trim-both (car lines)))
                  (reverse acc))
                 (else (loop (cdr lines) (cons (car lines) acc)))))))
        (filter-map
         (lambda (line)
           (let ((colon (string-index line #\:)))
             (if (and colon (> colon 0))
                 (cons (string-trim-both (substring line 0 colon))
                       (string-trim-both (substring line (1+ colon))))
                 #f)))
         header-lines))))

;;; response-headers->alist: Convert Guile `(web response)` response-headers
;;; (which is a list of (symbol . value)) to a string-keyed alist matching
;;; the curl path's shape. Values can be strings or structured pairs; for
;;; unknown header types Guile returns the raw string, which is what we want.
(define (response-headers->alist raw)
  (map (lambda (h)
         (let ((k (car h))
               (v (cdr h)))
           (cons (cond ((symbol? k) (symbol->string k))
                       ((string? k) k)
                       (else (format #f "~a" k)))
                 (cond ((string? v) v)
                       (else (format #f "~a" v))))))
       raw))

;;; http-post-with-headers-captured-native: Native Guile POST that also
;;; returns the response headers. Used for non-HTTPS (local proxies, test).
(define* (http-post-with-headers-captured-native url body #:key (headers '()))
  (receive (response response-body)
      (http-request url
                    #:method 'POST
                    #:body body
                    #:headers (cons '(content-type application/json)
                                    (headers->alist headers)))
    (list (response-code response)
          (body->string response-body)
          (response-headers->alist (response-headers response)))))

;;; http-post-with-headers-captured-curl: Curl fallback for HTTPS, using -D
;;; to spool response headers to a temp file so we can extract them after
;;; the body lands.
(define* (http-post-with-headers-captured-curl url body
                                               #:key (headers '()) (timeout 300))
  (let* ((in-file (make-temp-file "sage-post-in"))
         (out-file (make-temp-file "sage-post-out"))
         (header-file (make-temp-file "sage-post-hdrs"))
         (dummy (call-with-output-file in-file
                  (lambda (port) (display body port))))
         (header-args (string-join
                       (cons "-H 'Content-Type: application/json'"
                             (map (lambda (h)
                                    (format #f "-H '~a: ~a'"
                                            (shell-escape (car h))
                                            (shell-escape (cdr h))))
                                  headers))
                       " "))
         (cmd (format #f "curl -s --max-time ~a -D '~a' -w '\\n%{http_code}' -X POST ~a -d '@~a' '~a' > '~a'"
                      timeout header-file header-args in-file
                      (shell-escape url)
                      out-file)))
    (system cmd)
    (let* ((output (if (file-exists? out-file)
                       (call-with-input-file out-file get-string-all)
                       ""))
           (lines (string-split output #\newline))
           (code-line (if (pair? lines) (last lines) "0"))
           (body-lines (if (pair? lines) (drop-right lines 1) '()))
           (resp-body (string-join body-lines "\n"))
           (code (or (string->number (string-trim-both code-line)) 0))
           (resp-headers
            (if (file-exists? header-file)
                (parse-curl-header-dump
                 (call-with-input-file header-file get-string-all))
                '())))
      (when (file-exists? in-file) (delete-file in-file))
      (when (file-exists? out-file) (delete-file out-file))
      (when (file-exists? header-file) (delete-file header-file))
      (list code resp-body resp-headers))))

;;; http-post-with-headers-captured: POST that returns code, body, AND
;;; response headers. Honours SAGE_DEBUG_HTTP like http-post-with-timeout.
;;;
;;; Returns: (code body response-headers-alist)
;;;   - code: integer HTTP status (0 on transport failure)
;;;   - body: response body as string
;;;   - response-headers-alist: ((name . value) ...) with string keys
;;;
;;; The openai-compat provider uses this to read guardrail headers like
;;; x-litellm-applied-guardrails without breaking wire debug logging.
(define* (http-post-with-headers-captured url body
                                          #:key (timeout 300) (headers '()))
  (let ((start (gettimeofday)))
    (http-debug-log!
     `(("ts" . ,(http-debug-now-iso))
       ("type" . "request")
       ("method" . "POST")
       ("url" . ,url)
       ("timeout_s" . ,timeout)
       ("headers" . ,(list->vector (http-debug-headers->display headers)))
       ("body_size" . ,(string-length (or body "")))
       ("body" . ,(http-debug-truncate (or body "")))))
    (let* ((result
            (catch #t
              (lambda ()
                (if (https? url)
                    (http-post-with-headers-captured-curl
                     url body #:headers headers #:timeout timeout)
                    (http-post-with-headers-captured-native
                     url body #:headers headers)))
              (lambda (key . args)
                (list 0
                      (format #f "HTTP error: ~a ~a" key args)
                      '()))))
           (now (gettimeofday))
           (elapsed-ms (+ (* 1000 (- (car now) (car start)))
                          (quotient (- (cdr now) (cdr start)) 1000)))
           (code (if (and (list? result) (>= (length result) 1))
                     (car result) 0))
           (resp (if (and (list? result) (>= (length result) 2))
                     (cadr result) ""))
           (resp-headers (if (and (list? result) (>= (length result) 3))
                             (caddr result) '())))
      (http-debug-log!
       `(("ts" . ,(http-debug-now-iso))
         ("type" . "response")
         ("url" . ,url)
         ("code" . ,code)
         ("elapsed_ms" . ,elapsed-ms)
         ("body_size" . ,(string-length (or resp "")))
         ("response_headers"
          . ,(list->vector (http-debug-headers->display resp-headers)))
         ("body" . ,(http-debug-truncate (or resp "")))))
      result)))

;;; http-post-streaming-curl: Curl fallback for HTTPS streaming
;;; Also captures response headers via -D for guardrail visibility.
(define* (http-post-streaming-curl url body on-chunk
                                   #:key (timeout 30) (headers '()))
  (let* ((tmp-file (make-temp-file "sage-stream"))
         (header-file (format #f "/tmp/sage-stream-hdrs-~a" (getpid)))
         (dummy (call-with-output-file tmp-file
                  (lambda (port) (display body port))))
         (header-args (string-join
                       (cons "-H 'Content-Type: application/json'"
                             (map (lambda (h)
                                    (format #f "-H '~a: ~a'"
                                            (shell-escape (car h))
                                            (shell-escape (cdr h))))
                                  headers))
                       " "))
         (cmd (format #f "curl -sN --connect-timeout ~a -D '~a' -X POST ~a -d '@~a' '~a'"
                      timeout header-file header-args tmp-file
                      (shell-escape url)))
         (pipe (open-input-pipe cmd))
         (final-chunk #f))
    (catch #t
      (lambda ()
        (let loop ()
          (let ((line (read-line pipe)))
            (unless (eof-object? line)
              (let ((trimmed (string-trim-both line)))
                (unless (string-null? trimmed)
                  (catch #t
                    (lambda ()
                      (let ((chunk (json-read-string trimmed)))
                        (on-chunk chunk)
                        (when (and (list? chunk)
                                   (eq? #t (assoc-ref chunk "done")))
                          (set! final-chunk chunk))))
                    (lambda (key . args)
                      #f))))
              (loop)))))
      (lambda (key . args)
        #f))
    (close-pipe pipe)
    ;; Extract guardrail header from response headers if present
    (let ((guardrails
           (catch #t
             (lambda ()
               (if (file-exists? header-file)
                   (let ((hdrs (call-with-input-file header-file get-string-all)))
                     (let ((match (string-contains hdrs "x-litellm-applied-guardrails:")))
                       (if match
                           (let* ((start (+ match (string-length "x-litellm-applied-guardrails:")))
                                  (end (or (string-index hdrs #\newline start)
                                           (string-length hdrs))))
                             (string-trim-both (substring hdrs start end)))
                           #f)))
                   #f))
             (lambda args #f))))
      (catch #t (lambda () (delete-file tmp-file)) (lambda args #f))
      (catch #t (lambda () (when (file-exists? header-file) (delete-file header-file))) (lambda args #f))
      ;; Attach guardrails to final chunk if present
      (if (and final-chunk guardrails)
          (cons `("guardrails" . ,guardrails) final-chunk)
          final-chunk))))

;;; http-post-streaming: POST with streaming NDJSON response
;;; Native Guile for HTTP, curl fallback for HTTPS.
;;; Arguments:
;;;   url - Target URL
;;;   body - Request body string (JSON)
;;;   on-chunk - Callback (chunk-alist) called for each parsed JSON line
;;;   timeout - Connection timeout in seconds (default 30)
;;;   headers - Additional headers as alist (default '())
;;; Returns: The final chunk (where "done" is #t), or #f
(define* (http-post-streaming url body on-chunk
                              #:key (timeout 30) (headers '()))
  (let ((start (gettimeofday))
        ;; Capture chunks for the debug log without disturbing the
        ;; caller's on-chunk handler. Each chunk is the parsed JSON
        ;; alist, so we just count and serialize the count + first/last.
        (chunk-count 0)
        (first-chunk #f)
        (last-chunk #f))
    (http-debug-log!
     `(("ts" . ,(http-debug-now-iso))
       ("type" . "request")
       ("method" . "POST-stream")
       ("url" . ,url)
       ("timeout_s" . ,timeout)
       ("headers" . ,(list->vector (http-debug-headers->display headers)))
       ("body_size" . ,(string-length (or body "")))
       ("body" . ,(http-debug-truncate (or body "")))))
    (let* ((wrapped-on-chunk
            (if (http-debug-enabled?)
                (lambda (chunk)
                  (set! chunk-count (1+ chunk-count))
                  (unless first-chunk (set! first-chunk chunk))
                  (set! last-chunk chunk)
                  (on-chunk chunk))
                on-chunk))
           (result (catch #t
                     (lambda ()
                       (if (https? url)
                           (http-post-streaming-curl url body wrapped-on-chunk
                                                     #:timeout timeout #:headers headers)
                           (http-post-streaming-native url body wrapped-on-chunk
                                                       #:timeout timeout #:headers headers)))
                     (lambda (key . args) #f)))
           (now (gettimeofday))
           (elapsed-ms (+ (* 1000 (- (car now) (car start)))
                          (quotient (- (cdr now) (cdr start)) 1000))))
      (http-debug-log!
       `(("ts" . ,(http-debug-now-iso))
         ("type" . "response-stream")
         ("url" . ,url)
         ("elapsed_ms" . ,elapsed-ms)
         ("chunk_count" . ,chunk-count)
         ("first_chunk" . ,(http-debug-truncate
                            (if first-chunk (json-write-string first-chunk) "")))
         ("last_chunk" . ,(http-debug-truncate
                           (if last-chunk (json-write-string last-chunk) "")))))
      result)))

;;; ============================================================
;;; String Utilities
;;; ============================================================

;;; string-replace-substring: Replace all occurrences of search with replace
(define (string-replace-substring str search replace)
  (let ((search-len (string-length search)))
    (if (= search-len 0)
        str
        (let loop ((pos 0) (acc '()))
          (let ((found (string-contains str search pos)))
            (if found
                (loop (+ found search-len)
                      (cons replace
                            (cons (substring str pos found)
                                  acc)))
                (string-concatenate
                 (reverse (cons (substring str pos) acc)))))))))
