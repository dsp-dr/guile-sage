;;; version.scm --- Version information for guile-sage -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Central version management for guile-sage.
;; Version follows semantic versioning (MAJOR.MINOR.PATCH).

(define-module (sage version)
  #:export (*version*
            *version-major*
            *version-minor*
            *version-patch*
            version-string
            version-info))

;;; Version components
(define *version-major* 1)
(define *version-minor* 0)
(define *version-patch* 1)

;;; Combined version string
(define *version* "1.0.1")

;;; version-string: Get version as string
(define (version-string)
  *version*)

;;; version-info: Get detailed version information
;;; Returns: alist with version details
(define (version-info)
  `(("version" . ,*version*)
    ("major" . ,*version-major*)
    ("minor" . ,*version-minor*)
    ("patch" . ,*version-patch*)
    ("guile" . ,(version))
    ("name" . "guile-sage")
    ("description" . "AI REPL with Tool Calling and Guardrails")))
