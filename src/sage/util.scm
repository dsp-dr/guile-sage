;;; util.scm --- HTTP and JSON utilities -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Provides HTTP client and JSON utilities for guile-sage.
;; Uses curl for HTTP and implements simple JSON serialization.

(define-module (sage util)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (http-get
            http-post
            json-read-string
            json-write-string
            string-replace-substring
            make-temp-file))

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

(define (json-write obj port)
  (cond
   ((eq? obj #t) (display "true" port))
   ((eq? obj #f) (display "false" port))
   ((eq? obj 'null) (display "null" port))
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

;;; ============================================================
;;; HTTP Client (using curl with temp files to avoid popen segfault)
;;; ============================================================

(define (make-temp-file prefix)
  (format #f "/tmp/~a-~a-~a" prefix (getpid) (random 100000)))

(define* (http-get url #:key (headers '()))
  (let* ((out-file (make-temp-file "sage-get"))
         (header-args (string-join
                       (map (lambda (h)
                              (format #f "-H '~a: ~a'" (car h) (cdr h)))
                            headers)
                       " "))
         (cmd (format #f "curl -s -w '\\n%{http_code}' ~a '~a' > ~a"
                      header-args url out-file)))
    (system cmd)
    (let ((output (call-with-input-file out-file get-string-all)))
      (delete-file out-file)
      (let* ((lines (string-split output #\newline))
             (code-line (last lines))
             (body-lines (drop-right lines 1)))
        (cons (string->number code-line)
              (string-join body-lines "\n"))))))

(define* (http-post url body #:key (headers '()))
  (let* ((in-file (make-temp-file "sage-post-in"))
         (out-file (make-temp-file "sage-post-out"))
         (dummy (call-with-output-file in-file
                  (lambda (port) (display body port))))
         (header-args (string-join
                       (cons "-H 'Content-Type: application/json'"
                             (map (lambda (h)
                                    (format #f "-H '~a: ~a'" (car h) (cdr h)))
                                  headers))
                       " "))
         (cmd (format #f "curl -s -w '\\n%{http_code}' -X POST ~a -d @~a '~a' > ~a"
                      header-args in-file url out-file)))
    (system cmd)
    (let ((output (call-with-input-file out-file get-string-all)))
      (delete-file in-file)
      (delete-file out-file)
      (let* ((lines (string-split output #\newline))
             (code-line (last lines))
             (body-lines (drop-right lines 1)))
        (cons (string->number code-line)
              (string-join body-lines "\n"))))))

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
