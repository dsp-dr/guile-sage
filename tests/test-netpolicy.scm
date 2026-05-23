#!/usr/bin/env guile3
!#
;;; test-netpolicy.scm --- Tests for bot-compliance pre-flight (netpolicy)
;;;
;;; Pure-function coverage (no network): UA token extraction, compliance
;;; gating, URL splitting, robots.txt parsing + RFC 9309 longest-match
;;; decisions, crawl-delay, and compliance-preflight via a stub getter.
;;; Anchored on the real wal.sh robots.txt shape (a specific
;;; Walsh-Research group plus wildcard "*" query rules).

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage netpolicy)
             (srfi srfi-13)
             (ice-9 format))

(define *tests-run* 0)
(define *tests-passed* 0)

(define (run-test name thunk)
  (set! *tests-run* (1+ *tests-run*))
  (catch #t
    (lambda ()
      (thunk)
      (set! *tests-passed* (1+ *tests-passed*))
      (format #t "PASS: ~a~%" name))
    (lambda (key . args)
      (format #t "FAIL: ~a - ~a: ~a~%" name key args))))

(define (check-equal label expected actual)
  (unless (equal? expected actual)
    (error (format #f "~a: expected ~s got ~s" label expected actual))))

;;; Sample robots.txt mirroring wal.sh's structure.
(define sample-robots
  (string-append
   "# robots.txt for wal.sh\n"
   "User-agent: *\n"
   "Allow: /\n"
   "Sitemap: https://wal.sh/sitemap.xml\n"
   "\n"
   "User-agent: SemrushBot\n"
   "Crawl-delay: 10\n"
   "\n"
   "User-agent: Walsh-Research\n"
   "Disallow: /research/bots/dogfood-disallow\n"
   "Crawl-delay: 5\n"
   "\n"
   "User-agent: *\n"
   "Disallow: /*?*w=\n"
   "Disallow: /*?*t=\n"))

(define walsh-ua "Mozilla/5.0 (compatible; Walsh-Research/1.0; +https://wal.sh/bot/)")
(define guile-ua "guile-sage/1.0.1 (+https://github.com/dsp-dr/guile-sage; Guile Scheme AI agent)")

;;; ============================================================

(format #t "~%=== netpolicy: identity ===~%")

(run-test "ua-robots-token extracts Walsh-Research from compatible UA"
  (lambda () (check-equal "token" "Walsh-Research" (ua-robots-token walsh-ua))))

(run-test "ua-robots-token extracts guile-sage from product UA"
  (lambda () (check-equal "token" "guile-sage" (ua-robots-token guile-ua))))

(run-test "ua-robots-token falls back to * for non-string"
  (lambda () (check-equal "token" "*" (ua-robots-token #f))))

(run-test "compliance-mode? on for Walsh-Research UA"
  (lambda ()
    (unsetenv "SAGE_FETCH_COMPLIANCE")
    (unless (compliance-mode? walsh-ua) (error "should be on"))))

(run-test "compliance-mode? off for plain guile-sage UA"
  (lambda ()
    (unsetenv "SAGE_FETCH_COMPLIANCE")
    (when (compliance-mode? guile-ua) (error "should be off"))))

(run-test "SAGE_FETCH_COMPLIANCE=1 forces compliance on for guile UA"
  (lambda ()
    (setenv "SAGE_FETCH_COMPLIANCE" "1")
    (unless (compliance-mode? guile-ua) (error "flag should force on"))
    (unsetenv "SAGE_FETCH_COMPLIANCE")))

(run-test "SAGE_FETCH_COMPLIANCE=0 forces compliance off for Walsh UA"
  (lambda ()
    (setenv "SAGE_FETCH_COMPLIANCE" "0")
    (when (compliance-mode? walsh-ua) (error "flag should force off"))
    (unsetenv "SAGE_FETCH_COMPLIANCE")))

(format #t "~%=== netpolicy: url splitting ===~%")

(run-test "split-url keeps query, strips fragment"
  (lambda ()
    (check-equal "split"
                 '("https://wal.sh" . "/research/bots/compliance-spec?x=1")
                 (split-url "https://wal.sh/research/bots/compliance-spec?x=1#frag"))))

(run-test "split-url defaults path to /"
  (lambda () (check-equal "split" '("https://wal.sh" . "/") (split-url "https://wal.sh"))))

(format #t "~%=== netpolicy: robots.txt decisions ===~%")

(run-test "Walsh-Research may fetch compliance-spec (own group, no match)"
  (lambda ()
    (unless (robots-allows? sample-robots "Walsh-Research" "/research/bots/compliance-spec")
      (error "should be allowed"))))

(run-test "Walsh-Research is disallowed from dogfood path"
  (lambda ()
    (when (robots-allows? sample-robots "Walsh-Research" "/research/bots/dogfood-disallow")
      (error "should be disallowed"))))

(run-test "Walsh-Research disallow matches by prefix"
  (lambda ()
    (when (robots-allows? sample-robots "Walsh-Research" "/research/bots/dogfood-disallow/x")
      (error "prefix should be disallowed"))))

(run-test "specific group means * rules do NOT apply to Walsh-Research"
  (lambda ()
    ;; The "*" group disallows /*?*w= ; Walsh-Research has its own group,
    ;; so the wildcard query rule must not block it.
    (unless (robots-allows? sample-robots "Walsh-Research" "/page?w=1")
      (error "* rule must not apply to a named group"))))

(run-test "* token: wildcard query pattern disallows ?w="
  (lambda ()
    (when (robots-allows? sample-robots "guile-sage" "/page?w=1")
      (error "should be disallowed by /*?*w="))))

(run-test "* token: ordinary path is allowed"
  (lambda ()
    (unless (robots-allows? sample-robots "guile-sage" "/research/foo")
      (error "should be allowed"))))

(run-test "no robots rules => allowed"
  (lambda ()
    (unless (robots-allows? "" "anybot" "/anything") (error "empty robots = allow"))))

(run-test "crawl-delay read for named group"
  (lambda () (check-equal "delay" 5 (robots-crawl-delay sample-robots "Walsh-Research"))))

(format #t "~%=== netpolicy: preflight (stub getter) ===~%")

;; Stub getter: serve sample robots + a fake llms.txt for wal.sh.
(define (stub-get u)
  (cond
   ((string-suffix? "/robots.txt" u) sample-robots)
   ((string-suffix? "/llms.txt" u) "# wal.sh\n> guidance for LLMs\n")
   (else #f)))

(run-test "preflight allows compliance-spec and reports llms present"
  (lambda ()
    (netpolicy-reset-cache!)
    (let ((p (compliance-preflight
              "https://wal.sh/research/bots/compliance-spec" walsh-ua stub-get)))
      (unless (assoc-ref p "allowed") (error "should be allowed"))
      (unless (assoc-ref p "llms-url") (error "llms.txt should be discovered"))
      (check-equal "token" "Walsh-Research" (assoc-ref p "token")))))

(run-test "preflight blocks dogfood path with a reason"
  (lambda ()
    (netpolicy-reset-cache!)
    (let ((p (compliance-preflight
              "https://wal.sh/research/bots/dogfood-disallow" walsh-ua stub-get)))
      (when (assoc-ref p "allowed") (error "should be blocked"))
      (unless (string-contains (assoc-ref p "reason") "disallows")
        (error "reason should explain the block")))))

(run-test "preflight consults robots.txt and llms.txt URLs"
  (lambda ()
    (netpolicy-reset-cache!)
    (let* ((p (compliance-preflight "https://wal.sh/x" walsh-ua stub-get))
           (consulted (assoc-ref p "consulted")))
      (unless (member "https://wal.sh/robots.txt" consulted)
        (error "must consult robots.txt"))
      (unless (member "https://wal.sh/llms.txt" consulted)
        (error "must consult llms.txt")))))

(run-test "preflight allows when host has no robots.txt"
  (lambda ()
    (netpolicy-reset-cache!)
    (let ((p (compliance-preflight "https://example.com/anything" walsh-ua
                                   (lambda (u) #f))))
      (unless (assoc-ref p "allowed") (error "no robots = allowed"))
      (when (assoc-ref p "robots?") (error "robots? should be #f")))))

;;; Summary

(format #t "~%=== Summary ===~%")
(format #t "Tests: ~a/~a passed~%" *tests-passed* *tests-run*)
(if (= *tests-passed* *tests-run*)
    (begin (format #t "All tests passed!~%") (exit 0))
    (begin (format #t "Some tests failed!~%") (exit 1)))
