;;; sandbox.scm --- Execution-context / confinement awareness -*- coding: utf-8 -*-

;;; Commentary:
;;
;; First-class sandbox awareness. Answers "what can I NOT do here?" rather than
;; "what am I?" — `uname` tells you the OS, not the sandbox (a Bastille jail looks
;; like its FreeBSD host; a container looks like plain Linux).
;;
;; Detection (best-effort, declaration beats detection where available):
;;   (sandbox-os)         -> 'darwin | 'linux | 'freebsd | 'other
;;   (sandbox-jailed?)    -> #t in a FreeBSD jail   (security.jail.jailed=1)
;;   (sandbox-container?) -> #t in docker/sbx       (/.dockerenv)
;;   (sandbox-context)    -> alist (os jailed? container? label)
;;
;; Confinement probes ("what can I NOT do"):
;;   (sandbox-can-read? PATH) / (sandbox-can-write? DIR)
;;   (sandbox-confinement-report) -> alist capability -> 'allowed | 'blocked
;;
;; Actionable signal:
;;   (sandbox-confined?) -> #t when the OS already confines us (jailed, in a
;;   container, or $HOME is read-only). When #t, sage can afford to relax its
;;   in-process paranoia (e.g. the eval_scheme NC12 guard in tools.scm) because
;;   the surrounding sandbox already contains the blast radius. When #f (bare
;;   host), keep the in-process guards strict.
;;
;; Caveat: a credential read can be 'blocked because the file is *absent*, not
;; because we're confined — so `sandbox-confined?` keys off unambiguous signals
;; ($HOME write, jail, container), not credential-read results.

(define-module (sage sandbox)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:export (sandbox-os
            sandbox-jailed?
            sandbox-container?
            sandbox-label
            sandbox-context
            sandbox-can-read?
            sandbox-can-write?
            sandbox-confinement-report
            sandbox-confined?
            sandbox-summary))

(define (sandbox-os)
  "OS as a symbol: 'darwin | 'linux | 'freebsd | 'other."
  (let ((s (utsname:sysname (uname))))
    (cond ((string=? s "Darwin") 'darwin)
          ((string=? s "Linux") 'linux)
          ((string=? s "FreeBSD") 'freebsd)
          (else 'other))))

(define (read-cmd cmd)
  "Run CMD via the shell; return its first line trimmed, or #f on failure."
  (false-if-exception
   (let* ((port (open-input-pipe cmd))
          (line (read-line port)))
     (close-pipe port)
     (and (string? line) (string-trim-both line)))))

(define (sandbox-jailed?)
  "#t inside a FreeBSD jail."
  (and (eq? (sandbox-os) 'freebsd)
       (equal? (read-cmd "sysctl -n security.jail.jailed 2>/dev/null") "1")))

(define (sandbox-container?)
  "#t inside a docker/sbx container."
  (file-exists? "/.dockerenv"))

(define (sandbox-label)
  "Human label for the execution context."
  (cond ((sandbox-container?) "container")
        ((sandbox-jailed?) "bastille-jail")
        (else (symbol->string (sandbox-os)))))

(define (sandbox-context)
  "Alist describing the execution context."
  `((os . ,(sandbox-os))
    (jailed? . ,(sandbox-jailed?))
    (container? . ,(sandbox-container?))
    (label . ,(sandbox-label))))

(define (sandbox-can-read? path)
  "#t if PATH can be opened and one byte read (probe)."
  (and (false-if-exception
        (call-with-input-file path (lambda (p) (read-char p) #t)))
       #t))

(define (sandbox-can-write? dir)
  "#t if a probe file can be created and removed under DIR."
  (let ((probe (string-append dir "/.sage-sandbox-probe")))
    (and (false-if-exception
          (begin
            (call-with-output-file probe (lambda (p) (display "x" p)))
            (delete-file probe)
            #t))
         #t)))

(define %home (or (getenv "HOME") ""))

(define %credential-paths
  (map (lambda (rel) (string-append %home rel))
       '("/.aws/credentials"
         "/.config/gcloud/application_default_credentials.json"
         "/.ssh/id_ed25519"
         "/.ollama/id_ed25519")))

(define (cap state) (if state 'allowed 'blocked))

(define (sandbox-confinement-report)
  "Alist of capability -> 'allowed | 'blocked. 'blocked on a credential read is
good (confined) — but note an absent file also reads as 'blocked."
  `((context . ,(sandbox-context))
    (read-credentials . ,(cap (any sandbox-can-read? %credential-paths)))
    (write-home . ,(cap (and (not (string-null? %home))
                             (sandbox-can-write? %home))))
    (write-tmp . ,(cap (sandbox-can-write? "/tmp")))))

(define (sandbox-confined?)
  "#t when the OS already confines us — keyed on unambiguous signals (jail,
container, or read-only $HOME), NOT on credential reads (which an absent file
would falsely satisfy). When #t, sage may relax in-process guards."
  (or (sandbox-container?)
      (sandbox-jailed?)
      (and (not (string-null? %home))
           (not (sandbox-can-write? %home)))))

(define (sandbox-summary)
  "One-line human summary for startup logs."
  (let ((c (sandbox-context)))
    (format #f "sandbox: ~a (os=~a jailed=~a container=~a) confined=~a"
            (assq-ref c 'label) (assq-ref c 'os)
            (assq-ref c 'jailed?) (assq-ref c 'container?)
            (sandbox-confined?))))

;;; sandbox.scm ends here
