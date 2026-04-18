#!/usr/bin/env guile3
!#
;;; test-openai-aig.scm --- Cloudflare AI Gateway auth-header tests
;;;
;;; Covers SAGE_OPENAI_AIG_TOKEN and SAGE_OPENAI_AIG_MODE interaction
;;; with openai-auth-headers. Pure unit tests — no network.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage openai)
             (sage util)
             (ice-9 format)
             (srfi srfi-1))

(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== Cloudflare AI Gateway Auth Headers ===~%")

;;; ------------------------------------------------------------
;;; Helpers
;;; ------------------------------------------------------------

(define (header-names alist)
  (map (lambda (h) (string-downcase (car h))) alist))

(define (has-header? alist name)
  (any (lambda (h) (string-ci=? (car h) name)) alist))

(define (header-value alist name)
  (let loop ((hs alist))
    (cond
     ((null? hs) #f)
     ((string-ci=? (caar hs) name) (cdar hs))
     (else (loop (cdr hs))))))

(define (with-clean-env thunk)
  "Clear all AIG-related env vars, run thunk, then restore."
  (let ((saved-token (getenv "SAGE_OPENAI_AIG_TOKEN"))
        (saved-mode  (getenv "SAGE_OPENAI_AIG_MODE"))
        (saved-key   (getenv "SAGE_OPENAI_API_KEY")))
    (unsetenv "SAGE_OPENAI_AIG_TOKEN")
    (unsetenv "SAGE_OPENAI_AIG_MODE")
    (setenv "SAGE_OPENAI_API_KEY" "sk-test-downstream")
    (dynamic-wind
      (lambda () #f)
      thunk
      (lambda ()
        (if saved-token (setenv "SAGE_OPENAI_AIG_TOKEN" saved-token)
            (unsetenv "SAGE_OPENAI_AIG_TOKEN"))
        (if saved-mode (setenv "SAGE_OPENAI_AIG_MODE" saved-mode)
            (unsetenv "SAGE_OPENAI_AIG_MODE"))
        (if saved-key (setenv "SAGE_OPENAI_API_KEY" saved-key)
            (unsetenv "SAGE_OPENAI_API_KEY"))))))

;;; ------------------------------------------------------------
;;; Default (BYOK / no gateway)
;;; ------------------------------------------------------------

(format #t "~%--- Default (AIG_TOKEN unset) ---~%")

(run-test "default: only Authorization header emitted"
  (lambda ()
    (with-clean-env
     (lambda ()
       (let ((h (openai-auth-headers)))
         (assert-equal (length h) 1 "exactly one header")
         (assert-true (has-header? h "Authorization")
                      "Authorization present")
         (assert-false (has-header? h "cf-aig-authorization")
                       "cf-aig-authorization absent"))))))

(run-test "default: mode resolves to byok when token unset"
  (lambda ()
    (with-clean-env
     (lambda ()
       (assert-equal (openai-aig-mode) "byok"
                     "default mode should be byok")))))

(run-test "default: aig-token returns #f when env unset"
  (lambda ()
    (with-clean-env
     (lambda ()
       (assert-false (openai-aig-token) "no AIG token when unset")))))

;;; ------------------------------------------------------------
;;; Stored mode (AIG_TOKEN set, mode defaults to stored)
;;; ------------------------------------------------------------

(format #t "~%--- Stored mode (default when AIG_TOKEN set) ---~%")

(run-test "stored: only cf-aig-authorization emitted, Authorization suppressed"
  (lambda ()
    (with-clean-env
     (lambda ()
       (setenv "SAGE_OPENAI_AIG_TOKEN" "cfut_test_gateway_token")
       (let ((h (openai-auth-headers)))
         (assert-equal (length h) 1 "exactly one header")
         (assert-false (has-header? h "Authorization")
                       "Authorization suppressed in stored mode")
         (assert-true (has-header? h "cf-aig-authorization")
                      "cf-aig-authorization present")
         (assert-equal (header-value h "cf-aig-authorization")
                       "Bearer cfut_test_gateway_token"
                       "bearer value matches AIG_TOKEN"))))))

(run-test "stored: mode defaults to 'stored' when AIG_TOKEN set"
  (lambda ()
    (with-clean-env
     (lambda ()
       (setenv "SAGE_OPENAI_AIG_TOKEN" "cfut_xyz")
       (assert-equal (openai-aig-mode) "stored"
                     "mode defaults to stored")))))

(run-test "stored: explicit SAGE_OPENAI_AIG_MODE=stored"
  (lambda ()
    (with-clean-env
     (lambda ()
       (setenv "SAGE_OPENAI_AIG_TOKEN" "cfut_xyz")
       (setenv "SAGE_OPENAI_AIG_MODE" "stored")
       (let ((h (openai-auth-headers)))
         (assert-equal (length h) 1 "one header in stored mode")
         (assert-true (has-header? h "cf-aig-authorization")
                      "cf-aig present"))))))

;;; ------------------------------------------------------------
;;; Both mode
;;; ------------------------------------------------------------

(format #t "~%--- Both mode ---~%")

(run-test "both: emits Authorization AND cf-aig-authorization"
  (lambda ()
    (with-clean-env
     (lambda ()
       (setenv "SAGE_OPENAI_AIG_TOKEN" "cfut_xyz")
       (setenv "SAGE_OPENAI_AIG_MODE" "both")
       (let ((h (openai-auth-headers)))
         (assert-equal (length h) 2 "two headers")
         (assert-true (has-header? h "Authorization")
                      "Authorization present in both mode")
         (assert-true (has-header? h "cf-aig-authorization")
                      "cf-aig-authorization present in both mode")
         ;; Authorization uses downstream key
         (assert-equal (header-value h "Authorization")
                       "Bearer sk-test-downstream"
                       "Authorization uses downstream key")
         (assert-equal (header-value h "cf-aig-authorization")
                       "Bearer cfut_xyz"
                       "cf-aig uses gateway token"))))))

;;; ------------------------------------------------------------
;;; BYOK mode explicit
;;; ------------------------------------------------------------

(format #t "~%--- BYOK mode explicit ---~%")

(run-test "byok: explicit mode suppresses cf-aig even if token set"
  (lambda ()
    (with-clean-env
     (lambda ()
       (setenv "SAGE_OPENAI_AIG_TOKEN" "cfut_xyz")
       (setenv "SAGE_OPENAI_AIG_MODE" "byok")
       (let ((h (openai-auth-headers)))
         (assert-equal (length h) 1 "exactly one header")
         (assert-true (has-header? h "Authorization") "Authorization")
         (assert-false (has-header? h "cf-aig-authorization")
                       "cf-aig suppressed in explicit byok mode"))))))

;;; ------------------------------------------------------------
;;; Mode case normalisation
;;; ------------------------------------------------------------

(format #t "~%--- Mode case normalisation ---~%")

(run-test "mode value is case-normalised (STORED == stored)"
  (lambda ()
    (with-clean-env
     (lambda ()
       (setenv "SAGE_OPENAI_AIG_TOKEN" "cfut_xyz")
       (setenv "SAGE_OPENAI_AIG_MODE" "STORED")
       (assert-equal (openai-aig-mode) "stored"
                     "uppercase normalises to lowercase")
       (let ((h (openai-auth-headers)))
         (assert-false (has-header? h "Authorization")
                       "Authorization still suppressed"))))))

;;; ------------------------------------------------------------
;;; Debug-log redaction sanity
;;; ------------------------------------------------------------

(format #t "~%--- cf-aig redaction ---~%")

(run-test "cf-aig-authorization recognised as sensitive header"
  (lambda ()
    (assert-true (http-debug-sensitive-header? "cf-aig-authorization")
                 "cf-aig-authorization sensitive")
    (assert-true (http-debug-sensitive-header? "Cf-Aig-Authorization")
                 "case-insensitive")))

(test-summary)
