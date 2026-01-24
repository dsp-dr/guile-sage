;;; util.scm --- HTTP and JSON utilities -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Provides HTTP client and JSON utilities for guile-sage.
;; Uses Guile's (web client) and (json) modules.

(define-module (sage util)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:export (http-get
            http-post
            json-read-string
            json-write-string))

;;; json-read-string: Parse JSON from string
;;; Arguments:
;;;   str - JSON string
;;; Returns: Scheme data structure
(define (json-read-string str)
  (call-with-input-string str json->scm))

;;; json-write-string: Serialize to JSON string
;;; Arguments:
;;;   obj - Scheme data structure
;;; Returns: JSON string
(define (json-write-string obj)
  (call-with-output-string
    (lambda (port)
      (scm->json obj port))))

;;; http-get: Make HTTP GET request
;;; Arguments:
;;;   url - URL string
;;;   headers - Alist of headers (optional)
;;; Returns: (response-code . body-string)
(define* (http-get url #:key (headers '()))
  (let-values (((response body)
                (http-request url
                              #:method 'GET
                              #:headers headers)))
    (cons (response-code response)
          (if (bytevector? body)
              (utf8->string body)
              body))))

;;; http-post: Make HTTP POST request
;;; Arguments:
;;;   url - URL string
;;;   body - Request body string
;;;   headers - Alist of headers (optional)
;;; Returns: (response-code . body-string)
(define* (http-post url body #:key (headers '()))
  (let-values (((response resp-body)
                (http-request url
                              #:method 'POST
                              #:body body
                              #:headers (cons '(content-type . (application/json))
                                             headers))))
    (cons (response-code response)
          (if (bytevector? resp-body)
              (utf8->string resp-body)
              resp-body))))
