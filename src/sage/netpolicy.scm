;;; netpolicy.scm --- Bot-compliance pre-flight for outbound fetches -*- coding: utf-8 -*-

;;; Commentary:
;;
;; When guile-sage fetches third-party URLs under a *declared bot
;; identity* (e.g. the wal.sh "Walsh-Research" UA), it is bound by that
;; identity's published contract -- https://wal.sh/research/bots/compliance-spec.
;; This module implements the pre-request gates a polite, conformant bot
;; must pass before retrieving content:
;;
;;   R2  robots.txt (RFC 9309) -- fetch, match our product token, and
;;       refuse Disallowed paths.
;;   +   llms.txt (llmstxt.org) -- discover the site's LLM guidance file
;;       and surface it (informational; does not block).
;;
;; Crawl-delay is parsed and surfaced but not yet enforced; the operator
;; blocklist (R3), rate limiting (R4) and Retry-After backoff (R5) remain
;; tracked in guile-sage-0bi.
;;
;; The parsing/decision functions are pure and unit-tested; only
;; compliance-preflight touches the network, via a caller-supplied getter
;; so it stays testable.

(define-module (sage netpolicy)
  #:use-module (sage config)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (ua-robots-token
            compliance-mode?
            split-url
            url-origin
            url-pathquery
            parse-robots
            robots-allows?
            robots-crawl-delay
            compliance-preflight
            netpolicy-reset-cache!))

;;; ============================================================
;;; Identity
;;; ============================================================

;;; ua-robots-token: the product token a server matches in robots.txt.
;;; For a "Mozilla/5.0 (compatible; Walsh-Research/1.0; +...)" UA the
;;; token is "Walsh-Research"; otherwise the leading product token before
;;; the first slash (e.g. "guile-sage").
(define (ua-robots-token ua)
  (cond
   ((not (string? ua)) "*")
   ((string-match "compatible;[ \t]*([A-Za-z0-9._-]+)" ua)
    => (lambda (m) (match:substring m 1)))
   ((string-match "^([A-Za-z0-9._-]+)" ua)
    => (lambda (m) (match:substring m 1)))
   (else "*")))

;;; compliance-mode?: should pre-flight gates run for this UA?
;;; SAGE_FETCH_COMPLIANCE forces on/off; otherwise it activates when the
;;; UA carries a contract-bound identity (currently Walsh-Research).
(define (compliance-mode? ua)
  (let ((flag (config-get "FETCH_COMPLIANCE")))
    (cond
     ((and (string? flag)
           (member (string-downcase (string-trim-both flag))
                   '("0" "false" "no" "off")))
      #f)
     ((and (string? flag)
           (member (string-downcase (string-trim-both flag))
                   '("1" "true" "yes" "on")))
      #t)
     ((not (string? ua)) #f)
     (else (and (string-contains ua "Walsh-Research") #t)))))

;;; ============================================================
;;; URL splitting
;;; ============================================================

;;; split-url: (origin . pathquery). ORIGIN is scheme://host[:port];
;;; PATHQUERY is path plus query (fragment stripped), defaulting to "/".
(define (split-url url)
  (let* ((sidx (string-contains url "://"))
         (scheme (if sidx (substring url 0 sidx) "https"))
         (rest (if sidx (substring url (+ sidx 3)) url))
         (slash (string-index rest #\/))
         (host (if slash (substring rest 0 slash) rest))
         (pq0 (if slash (substring rest slash) "/"))
         (hashi (string-index pq0 #\#))
         (pq (if hashi (substring pq0 0 hashi) pq0)))
    (cons (string-append scheme "://" host)
          (if (string-null? pq) "/" pq))))

(define (url-origin url) (car (split-url url)))
(define (url-pathquery url) (cdr (split-url url)))

;;; ============================================================
;;; robots.txt (RFC 9309 subset)
;;; ============================================================

;;; parse-robots: TEXT -> list of (agents . rules). AGENTS is a list of
;;; lowercased user-agent tokens; RULES is a list of (type . pattern),
;;; type in {allow disallow crawl-delay}. Consecutive User-agent lines
;;; share the rules that follow them.
(define (parse-robots text)
  (let loop ((lines (string-split text #\newline))
             (cur-agents '())
             (cur-rules '())
             (expecting-agent #t)
             (groups '()))
    (define (flush)
      (if (null? cur-agents)
          groups
          (cons (cons (reverse cur-agents) (reverse cur-rules)) groups)))
    (if (null? lines)
        (reverse (flush))
        (let* ((raw (car lines))
               (hashi (string-index raw #\#))
               (line (string-trim-both (if hashi (substring raw 0 hashi) raw)))
               (rest (cdr lines))
               (ua-m (string-match
                      "^[Uu][Ss][Ee][Rr]-[Aa][Gg][Ee][Nn][Tt][ \t]*:[ \t]*(.*)$"
                      line))
               (kv-m (string-match
                      "^([A-Za-z][A-Za-z-]*)[ \t]*:[ \t]*(.*)$"
                      line)))
          (cond
           ((string-null? line)
            (loop rest cur-agents cur-rules expecting-agent groups))
           (ua-m
            (let ((val (string-downcase
                        (string-trim-both (match:substring ua-m 1)))))
              (if expecting-agent
                  (loop rest (cons val cur-agents) cur-rules #t groups)
                  ;; rules already seen -> a new group begins
                  (loop rest (list val) '() #t (flush)))))
           (kv-m
            (let ((field (string-downcase (match:substring kv-m 1)))
                  (val (string-trim-both (match:substring kv-m 2))))
              (cond
               ((member field '("disallow" "allow"))
                (loop rest cur-agents
                      (cons (cons (string->symbol field) val) cur-rules)
                      #f groups))
               ((string=? field "crawl-delay")
                (loop rest cur-agents
                      (cons (cons 'crawl-delay val) cur-rules)
                      #f groups))
               (else
                ;; sitemap/host/content-signal/etc -- not part of a group
                (loop rest cur-agents cur-rules #f groups)))))
           (else
            (loop rest cur-agents cur-rules expecting-agent groups)))))))

;;; robots-applicable-rules: merge rules of every group naming TOKEN
;;; (case-insensitive exact); fall back to all "*" groups; else '().
(define (robots-applicable-rules groups token)
  (let* ((tok (string-downcase token))
         (named (append-map cdr
                            (filter (lambda (g) (member tok (car g))) groups))))
    (if (pair? named)
        named
        (append-map cdr (filter (lambda (g) (member "*" (car g))) groups)))))

;;; robots-pattern->regex: robots path pattern -> anchored regex string.
;;; "*" -> ".*", a trailing "$" anchors the end, other regex specials are
;;; escaped. An empty pattern yields #f (it matches nothing -- i.e.
;;; "Disallow:" imposes no restriction).
(define (robots-pattern->regex pat)
  (and (not (string-null? pat))
       (let* ((anchor-end (string-suffix? "$" pat))
              (core (if anchor-end (substring pat 0 (1- (string-length pat))) pat))
              (out (string-concatenate
                    (map (lambda (ch)
                           (cond
                            ((char=? ch #\*) ".*")
                            ((memv ch '(#\. #\+ #\? #\( #\) #\[ #\] #\{ #\} #\^ #\$ #\\ #\|))
                             (string #\\ ch))
                            (else (string ch))))
                         (string->list core)))))
         (string-append "^" out (if anchor-end "$" "")))))

(define (robots-rule-matches? pat path)
  (let ((rx (robots-pattern->regex pat)))
    (and rx (string-match rx path) #t)))

;;; robots-allows?: RFC 9309 longest-match decision for PATH under TOKEN.
;;; No matching rule => allowed. The longest matching pattern wins; an
;;; Allow wins ties with an equally long Disallow.
(define (robots-allows? text token path)
  (let ((rules (robots-applicable-rules (parse-robots text) token))
        (best-allow -1)
        (best-disallow -1))
    (for-each
     (lambda (r)
       (let ((type (car r)) (pat (cdr r)))
         (when (and (memq type '(allow disallow))
                    (robots-rule-matches? pat path))
           (let ((len (string-length pat)))
             (cond
              ((eq? type 'allow) (when (> len best-allow) (set! best-allow len)))
              ((eq? type 'disallow) (when (> len best-disallow) (set! best-disallow len))))))))
     rules)
    (cond
     ((and (= best-allow -1) (= best-disallow -1)) #t)
     ((>= best-allow best-disallow) #t)
     (else #f))))

;;; robots-crawl-delay: Crawl-delay (seconds) for TOKEN, or #f.
(define (robots-crawl-delay text token)
  (let* ((rules (robots-applicable-rules (parse-robots text) token))
         (cd (assq 'crawl-delay rules)))
    (and cd (string->number (cdr cd)))))

;;; ============================================================
;;; Pre-flight orchestration
;;; ============================================================

;;; Per-process cache: origin -> (robots-text|#f . llms-text|#f). robots
;;; and llms rarely change within a session and we never want to amplify
;;; load on the very hosts we are trying to be polite to.
(define *netpolicy-cache* (make-hash-table))

(define (netpolicy-reset-cache!)
  (set! *netpolicy-cache* (make-hash-table)))

;;; compliance-preflight: decide whether fetching URL is permitted under
;;; our contract identity. GET is (lambda (u) -> body-string|#f), a 200
;;; body or #f. Returns an alist (string keys): "allowed" (bool),
;;; "token", "path", "robots-url", "robots?" (bool), "llms-url"
;;; (string|#f), "consulted" (list), "crawl-delay" (num|#f), "reason".
(define (compliance-preflight url ua get)
  (let* ((origin (url-origin url))
         (path (url-pathquery url))
         (token (ua-robots-token ua))
         (robots-url (string-append origin "/robots.txt"))
         (llms-url (string-append origin "/llms.txt"))
         (cached (hash-ref *netpolicy-cache* origin))
         (pair (or cached
                   (let ((p (cons (get robots-url) (get llms-url))))
                     (hash-set! *netpolicy-cache* origin p)
                     p)))
         (robots (car pair))
         (llms (cdr pair))
         (robots? (and (string? robots) (not (string-null? robots))))
         (llms? (and (string? llms) (not (string-null? llms))))
         (allowed (if robots? (robots-allows? robots token path) #t))
         (delay (and robots? (robots-crawl-delay robots token))))
    (list (cons "allowed" allowed)
          (cons "token" token)
          (cons "path" path)
          (cons "robots-url" robots-url)
          (cons "robots?" robots?)
          (cons "llms-url" (and llms? llms-url))
          (cons "consulted" (list robots-url llms-url))
          (cons "crawl-delay" delay)
          (cons "reason"
                (if allowed
                    ""
                    (string-append "robots.txt disallows " path
                                   " for product token " token))))))
