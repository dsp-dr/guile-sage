;;; attest.scm --- CAVA: canonical action verification + attestation -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Reference implementation of the CAVA layer (RFC-004; targets spec §17).
;; CAVA is "formalize-and-thread": it reuses the existing append-only ledger
;; substrate (provenance.scm), the mutation choke point (tools.scm execute-tool
;; via repl.scm execute-tool-chain), and the prev_sha hash-chain convention.
;;
;; This module defines the three first-class values as pure/total constructors
;; plus an effectful append-only audit log:
;;
;;   §17.1 canonical-action   — deterministic normalized action record + action-sha
;;   §17.2 policy-verdict     — pure (action,env) -> {decision, reason, inputs}, fail-closed
;;   §17.3 attestation        — {ts, actor, action-sha, verdict, result-sha?, prev_sha, gpg-sig?}
;;   §17.6 attest-log-append! — best-effort by default; SAGE_ATTEST_STRICT aborts on
;;                              write failure; SAGE_ATTEST_DISABLE opts out of LOGGING only.
;;
;; CRITICAL (§8 spawn boundary): per-mutation hashing uses a PURE-SCHEME sha256
;; (sha256-hex below) — it never forks shasum via /tmp (unlike
;; provenance.scm content-sha256), so it does not collide with the
;; spawn-SIGSEGV boundary. Hash MUTATIONS only, never read-only calls.
;;
;; This module intentionally does NOT import (sage tools): the caller passes in
;; the pure safe-path? / resolve-path predicates and the safe? classification, so
;; attest stays dependency-light and cycle-free.

(define-module (sage attest)
  #:use-module (sage util)          ; env-affirmative?
  #:use-module (sage provenance)    ; now-iso, gpg-sign
  #:use-module (srfi srfi-1)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 format)
  #:export (sha256-hex
            canonical-action
            action-sha
            action-ref
            policy-verdict
            verdict-decision
            verdict-reason
            verdict-inputs
            attestation
            attestation-encode
            attestation-chain
            attestation-verify-chain
            attest-genesis-sha
            attest-disabled?
            attest-strict?
            attest-log-file
            attest-log-append!
            attest-chain-head
            attest-reset-chain!
            attest!))

;;; ============================================================
;;; §CRITICAL — Pure-Scheme SHA-256 (no fork, no /tmp)
;;; ============================================================
;;;
;;; FIPS 180-4. Operates on a bytevector; sha256-hex hashes the UTF-8
;;; encoding of a string. Property-tested against the standard vectors
;;; ("" / "abc" / "hello") in tests/test-pbt.scm.

(define *sha256-k*
  #(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1
    #x923f82a4 #xab1c5ed5 #xd807aa98 #x12835b01 #x243185be #x550c7dc3
    #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174 #xe49b69c1 #xefbe4786
    #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
    #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147
    #x06ca6351 #x14292967 #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13
    #x650a7354 #x766a0abb #x81c2c92e #x92722c85 #xa2bfe8a1 #xa81a664b
    #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
    #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a
    #x5b9cca4f #x682e6ff3 #x748f82ee #x78a5636f #x84c87814 #x8cc70208
    #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

(define (u32 x) (logand x #xffffffff))

(define (rotr32 x n)
  (u32 (logior (ash x (- n)) (ash x (- 32 n)))))

(define (shr32 x n) (ash x (- n)))

(define (sha256-digest bv)
  "Return the SHA-256 digest of bytevector BV as a 32-byte bytevector."
  (let* ((len (bytevector-length bv))
         (bitlen (* len 8))
         ;; padded length: message + 0x80 + zeros + 8-byte length, multiple of 64
         (padlen (let loop ((n (+ len 1)))
                   (if (= 0 (modulo (+ n 8) 64)) (+ n 8) (loop (+ n 1)))))
         (msg (make-bytevector padlen 0)))
    (bytevector-copy! bv 0 msg 0 len)
    (bytevector-u8-set! msg len #x80)
    ;; 64-bit big-endian bit length in the final 8 bytes
    (let loop ((i 0) (v bitlen))
      (when (< i 8)
        (bytevector-u8-set! msg (- padlen 1 i) (logand v #xff))
        (loop (+ i 1) (ash v -8))))
    (let ((h0 #x6a09e667) (h1 #xbb67ae85) (h2 #x3c6ef372) (h3 #xa54ff53a)
          (h4 #x510e527f) (h5 #x9b05688c) (h6 #x1f83d9ab) (h7 #x5be0cd19)
          (w (make-vector 64 0)))
      (let block-loop ((off 0))
        (when (< off padlen)
          ;; load 16 big-endian words
          (do ((t 0 (+ t 1))) ((= t 16))
            (let ((b (+ off (* t 4))))
              (vector-set! w t
                (u32 (logior (ash (bytevector-u8-ref msg b) 24)
                             (ash (bytevector-u8-ref msg (+ b 1)) 16)
                             (ash (bytevector-u8-ref msg (+ b 2)) 8)
                             (bytevector-u8-ref msg (+ b 3)))))))
          ;; extend
          (do ((t 16 (+ t 1))) ((= t 64))
            (let* ((w15 (vector-ref w (- t 15)))
                   (w2  (vector-ref w (- t 2)))
                   (s0 (logxor (rotr32 w15 7) (rotr32 w15 18) (shr32 w15 3)))
                   (s1 (logxor (rotr32 w2 17) (rotr32 w2 19) (shr32 w2 10))))
              (vector-set! w t
                (u32 (+ (vector-ref w (- t 16)) s0
                        (vector-ref w (- t 7)) s1)))))
          (let loop ((t 0) (a h0) (b h1) (c h2) (d h3)
                     (e h4) (f h5) (g h6) (h h7))
            (if (= t 64)
                (begin
                  (set! h0 (u32 (+ h0 a))) (set! h1 (u32 (+ h1 b)))
                  (set! h2 (u32 (+ h2 c))) (set! h3 (u32 (+ h3 d)))
                  (set! h4 (u32 (+ h4 e))) (set! h5 (u32 (+ h5 f)))
                  (set! h6 (u32 (+ h6 g))) (set! h7 (u32 (+ h7 h))))
                (let* ((S1 (logxor (rotr32 e 6) (rotr32 e 11) (rotr32 e 25)))
                       (ch (logxor (logand e f) (logand (lognot e) g)))
                       (temp1 (u32 (+ h S1 ch (vector-ref *sha256-k* t) (vector-ref w t))))
                       (S0 (logxor (rotr32 a 2) (rotr32 a 13) (rotr32 a 22)))
                       (maj (logxor (logand a b) (logand a c) (logand b c)))
                       (temp2 (u32 (+ S0 maj))))
                  (loop (+ t 1)
                        (u32 (+ temp1 temp2)) a b c
                        (u32 (+ d temp1)) e f g))))
          (block-loop (+ off 64))))
      (let ((out (make-bytevector 32 0)))
        (for-each (lambda (i hv)
                    (bytevector-u8-set! out i (logand (ash hv -24) #xff))
                    (bytevector-u8-set! out (+ i 1) (logand (ash hv -16) #xff))
                    (bytevector-u8-set! out (+ i 2) (logand (ash hv -8) #xff))
                    (bytevector-u8-set! out (+ i 3) (logand hv #xff)))
                  '(0 4 8 12 16 20 24 28)
                  (list h0 h1 h2 h3 h4 h5 h6 h7))
        out))))

(define *hex-chars* "0123456789abcdef")

(define (sha256-bv->hex bv)
  (let ((out (make-string (* 2 (bytevector-length bv)))))
    (do ((i 0 (+ i 1))) ((= i (bytevector-length bv)) out)
      (let ((b (bytevector-u8-ref bv i)))
        (string-set! out (* 2 i) (string-ref *hex-chars* (ash b -4)))
        (string-set! out (+ 1 (* 2 i)) (string-ref *hex-chars* (logand b #xf)))))))

(define (sha256-hex str)
  "SHA-256 hex digest of the UTF-8 encoding of STR. Pure; no subprocess."
  (sha256-bv->hex (sha256-digest (string->utf8 (if (string? str) str "")))))

;;; ============================================================
;;; Canonical JSON (deterministic, key-sorted) — §16.3
;;; ============================================================
;;;
;;; Byte-canonical re-encode: object keys sorted (string<?), stable value
;;; encoding. Independent of the util JSON writer so the attestation encoding
;;; never drifts with unrelated JSON changes. This is what makes action-sha
;;; deterministic (property #4) and arg-permutation invariant (property #5).

(define (canon-escape s)
  (let loop ((chars (string->list s)) (acc '()))
    (if (null? chars)
        (list->string (reverse acc))
        (let ((c (car chars)))
          (loop (cdr chars)
                (cond
                 ((char=? c #\") (append '(#\" #\\) acc))
                 ((char=? c #\\) (append '(#\\ #\\) acc))
                 ((char=? c #\newline) (append '(#\n #\\) acc))
                 ((char=? c #\return) (append '(#\r #\\) acc))
                 ((char=? c #\tab) (append '(#\t #\\) acc))
                 (else (cons c acc))))))))

(define (alist-of-strings? obj)
  ;; a JSON object: non-empty list whose every element is (string . value)
  (and (pair? obj)
       (every (lambda (kv) (and (pair? kv) (string? (car kv)))) obj)))

(define (canon-json obj)
  "Deterministic JSON encoding of OBJ. Object keys are sorted; arrays keep
order. Handles strings, numbers, booleans, symbols, #f/null, vectors, lists,
and string-keyed alists."
  (cond
   ((eq? obj #t) "true")
   ((eq? obj #f) "false")
   ((eq? obj 'null) "null")
   ((string? obj) (string-append "\"" (canon-escape obj) "\""))
   ((symbol? obj) (string-append "\"" (canon-escape (symbol->string obj)) "\""))
   ((number? obj) (if (and (exact? obj) (integer? obj))
                      (number->string obj)
                      (number->string obj)))
   ((null? obj) "[]")
   ((alist-of-strings? obj)
    (let* ((sorted (sort obj (lambda (a b) (string<? (car a) (car b)))))
           (parts (map (lambda (kv)
                         (string-append "\"" (canon-escape (car kv)) "\":"
                                        (canon-json (cdr kv))))
                       sorted)))
      (string-append "{" (string-join parts ",") "}")))
   ((vector? obj)
    (string-append "[" (string-join (map canon-json (vector->list obj)) ",") "]"))
   ((list? obj)
    (string-append "[" (string-join (map canon-json obj) ",") "]"))
   (else (string-append "\"" (canon-escape (format #f "~a" obj)) "\""))))

;;; ============================================================
;;; §17.1 — Canonical action
;;; ============================================================
;;;
;;; Build a deterministic normalized record {tool, args*, paths*,
;;; mutation-class, actor, ts}. Pure/total; never mutates state; MUST NOT
;;; loosen safe-path or coercion — it CONSULTS the caller's pure safe-path?
;;; verdict, it does not re-implement it.
;;;
;;; action-sha = sha256(canonical-encoding) over {tool,args,paths,mutation-class,
;;; actor} — deliberately EXCLUDING ts so the sha is time-independent (property
;;; #4) and permutation-invariant (property #5).

(define (arg-path-values args)
  "Extract path-shaped argument values from ARGS: the \"path\" string plus each
element of a \"files\" array (list or vector). Total; ignores non-strings."
  (let* ((p (and (pair? args) (assoc-ref args "path")))
         (files (and (pair? args) (assoc-ref args "files")))
         (file-list (cond ((vector? files) (vector->list files))
                          ((list? files) files)
                          ((string? files) (list files))
                          (else '()))))
    (filter string?
            (cons (and (string? p) p) file-list))))

(define* (canonical-action tool args
                           #:key
                           (actor 'own-llm)
                           (ts #f)
                           (mutation-class 'mutating)
                           (safe-path? (lambda (p) #t))
                           (resolve-path (lambda (p) p)))
  "Build the canonical action record for a (TOOL, ARGS) call. MUTATION-CLASS is
one of 'read-only, 'mutating, 'unclassified. SAFE-PATH? / RESOLVE-PATH are the
caller's PURE predicates (from (sage tools)); path verdicts are recorded, not
recomputed loosely."
  (let* ((now (or ts (now-iso)))
         (norm-args (if (pair? args) args '()))
         (paths (map (lambda (raw)
                       `(("raw" . ,raw)
                         ("resolved" . ,(let ((r (catch #t (lambda () (resolve-path raw))
                                                     (lambda _ raw))))
                                          (if (string? r) r raw)))
                         ("safe" . ,(and (catch #t (lambda () (safe-path? raw))
                                            (lambda _ #f)) #t))))
                     (arg-path-values norm-args)))
         (mc (symbol->string mutation-class))
         (actor-str (if (symbol? actor) (symbol->string actor) (format #f "~a" actor)))
         ;; action-sha covers tool/args/paths/mutation-class/actor, NOT ts.
         (sha-body `(("actor" . ,actor-str)
                     ("args" . ,norm-args)
                     ("mutation-class" . ,mc)
                     ("paths" . ,paths)
                     ("tool" . ,(if (string? tool) tool (format #f "~a" tool)))))
         (sha (sha256-hex (canon-json sha-body))))
    `(("tool" . ,(if (string? tool) tool (format #f "~a" tool)))
      ("args" . ,norm-args)
      ("paths" . ,paths)
      ("mutation-class" . ,mc)
      ("actor" . ,actor-str)
      ("ts" . ,now)
      ("action-sha" . ,sha))))

(define (action-ref action key) (assoc-ref action key))
(define (action-sha action) (assoc-ref action "action-sha"))

;;; ============================================================
;;; §17.2 — Policy verdict
;;; ============================================================
;;;
;;; Pure (action, env) -> {decision ∈ {allow,confirm,deny}, reason, inputs}.
;;; inputs records EVERY gate consulted: safe-set membership (mutation-class),
;;; value-gated YOLO_MODE (§15.3), the pure safe-path? verdicts, any PreToolUse
;;; veto (§9). Deterministic; FAIL-CLOSED (any gate error/absence ⇒ deny);
;;; default-deny for unclassified mutations.
;;;
;;; ENV is a plain alist, e.g. (("YOLO_MODE" . "1")) — passing env as data keeps
;;; this pure and testable. PRE-VETO is #f (no veto) or a reason string.
;;;
;;; The DECISION mirrors check-permission exactly (read-only⇒allow;
;;; mutating+YOLO⇒allow; else deny) so threading CAVA in changes no behavior;
;;; path verdicts are RECORDED but the tool retains its own safe-path
;;; enforcement (defense in depth, unchanged).

(define (make-verdict decision reason inputs)
  `(("decision" . ,(symbol->string decision))
    ("reason" . ,reason)
    ("inputs" . ,inputs)))

(define (verdict-decision v)
  (let ((d (assoc-ref v "decision")))
    (cond ((symbol? d) d)
          ((string? d) (string->symbol d))
          (else 'deny))))
(define (verdict-reason v) (or (assoc-ref v "reason") ""))
(define (verdict-inputs v) (or (assoc-ref v "inputs") '()))

(define* (policy-verdict action env #:key (pre-veto #f))
  "Produce the policy verdict for ACTION under ENV. FAIL-CLOSED on any error."
  (catch #t
    (lambda ()
      (let* ((mc (assoc-ref action "mutation-class"))
             (paths (or (assoc-ref action "paths") '()))
             (yolo-val (and (pair? env) (assoc-ref env "YOLO_MODE")))
             (yolo (env-affirmative? yolo-val))
             (path-verdicts (map (lambda (p) (and (assoc-ref p "safe") #t)) paths))
             (all-paths-safe (every (lambda (x) x) path-verdicts))
             (inputs `(("mutation-class" . ,mc)
                       ("safe-set" . ,(if (equal? mc "read-only") #t #f))
                       ("yolo-mode" . ,yolo)
                       ("path-verdicts" . ,(list->vector path-verdicts))
                       ("all-paths-safe" . ,all-paths-safe)
                       ("pre-veto" . ,(if pre-veto #t #f)))))
        (cond
         ;; A PreToolUse veto (§9) is fail-closed regardless of class.
         (pre-veto
          (make-verdict 'deny (format #f "PreToolUse veto: ~a" pre-veto) inputs))
         ;; read-only (safe-set) tools are always allowed.
         ((equal? mc "read-only")
          (make-verdict 'allow "safe tool (read-only)" inputs))
         ;; known mutation: gate on value-gated YOLO_MODE (§15.3).
         ((equal? mc "mutating")
          (if yolo
              (make-verdict 'allow "mutation permitted by YOLO_MODE" inputs)
              (make-verdict 'deny "mutation requires YOLO_MODE (value-gated)" inputs)))
         ;; anything else is an unclassified mutation ⇒ default-deny.
         (else
          (make-verdict 'deny "unclassified mutation (default-deny)" inputs)))))
    (lambda (key . args)
      ;; Any gate error ⇒ deny (fail-closed, property #12).
      (make-verdict 'deny
                    (format #f "verdict gate error (fail-closed): ~a" key)
                    `(("error" . ,(format #f "~a ~a" key args)))))))

;;; ============================================================
;;; §17.3 — Attestation record + tamper-evident chain
;;; ============================================================
;;;
;;; {ts, actor, action-sha, verdict, result-sha?, prev_sha, gpg-sig?}.
;;; Byte-canonical (stable re-encode). result-sha absent on deny. prev_sha
;;; chains the previous record: record[N].prev_sha == sha256(encode(record[N-1])).

(define (attest-genesis-sha)
  "Chain root: 64 zero hex chars (no predecessor)."
  (make-string 64 #\0))

(define* (attestation action verdict
                      #:key (result-sha #f) (prev-sha #f) (actor #f)
                      (ts #f) (gpg-sig #f))
  "Construct an attestation record (alist) for ACTION + VERDICT. RESULT-SHA is
present only for an executed mutation (absent/#f on deny)."
  (let ((decision (verdict-decision verdict)))
    `(("ts" . ,(or ts (assoc-ref action "ts") (now-iso)))
      ("actor" . ,(or actor (assoc-ref action "actor") "own-llm"))
      ("action-sha" . ,(or (assoc-ref action "action-sha") ""))
      ("decision" . ,(symbol->string decision))
      ("reason" . ,(verdict-reason verdict))
      ("result-sha" . ,(if (eq? decision 'allow) (or result-sha 'null) 'null))
      ("prev-sha" . ,(or prev-sha (attest-genesis-sha)))
      ("gpg-sig" . ,(or gpg-sig 'null)))))

(define (attestation-encode record)
  "Byte-canonical single-line encoding of an attestation RECORD (fixed key
order). This exact string is what prev_sha hashes over."
  (let ((get (lambda (k) (assoc-ref record k))))
    (canon-json
     `(("ts" . ,(or (get "ts") 'null))
       ("actor" . ,(or (get "actor") 'null))
       ("action-sha" . ,(or (get "action-sha") 'null))
       ("decision" . ,(or (get "decision") 'null))
       ("reason" . ,(or (get "reason") 'null))
       ("result-sha" . ,(let ((r (get "result-sha"))) (if r r 'null)))
       ("prev-sha" . ,(or (get "prev-sha") 'null))
       ("gpg-sig" . ,(let ((g (get "gpg-sig"))) (if g g 'null)))))))

(define (attestation-chain records)
  "Thread prev_sha through a list of RECORDS (pure). Each record's prev-sha is
set to sha256(encode(previous)); the first uses the genesis sha. Returns the
linked records."
  (let loop ((rs records) (prev (attest-genesis-sha)) (acc '()))
    (if (null? rs)
        (reverse acc)
        (let* ((r (car rs))
               (linked (map (lambda (kv)
                              (if (equal? (car kv) "prev-sha")
                                  (cons "prev-sha" prev)
                                  kv))
                            r))
               (h (sha256-hex (attestation-encode linked))))
          (loop (cdr rs) h (cons linked acc))))))

(define (attestation-verify-chain records)
  "Return #t iff RECORDS form an intact prev_sha chain: each record's prev-sha
equals sha256(encode(previous)), first == genesis. A middle edit breaks it."
  (let loop ((rs records) (prev (attest-genesis-sha)))
    (cond
     ((null? rs) #t)
     ((not (equal? (assoc-ref (car rs) "prev-sha") prev)) #f)
     (else (loop (cdr rs) (sha256-hex (attestation-encode (car rs))))))))

;;; ============================================================
;;; §17.6 — Failure modes: append-only audit log
;;; ============================================================
;;;
;;; Best-effort WRITE by default (never breaks the tool path, like the
;;; provenance/usage ledgers). SAGE_ATTEST_STRICT aborts the mutation if the
;;; record cannot persist. SAGE_ATTEST_DISABLE opts out of LOGGING only — it
;;; NEVER relaxes §17.2 verification. Both flags are VALUE-gated (§15.3) via
;;; env-affirmative?, not presence.

(define (attest-disabled?)
  (env-affirmative? (getenv "SAGE_ATTEST_DISABLE")))

(define (attest-strict?)
  (env-affirmative? (getenv "SAGE_ATTEST_STRICT")))

(define (attest-log-file)
  (let ((dir (or (getenv "SAGE_LOG_DIR")
                 (string-append (getcwd) "/.logs"))))
    (string-append dir "/attest.jsonl")))

;; In-process chain head: sha of the last appended record (or genesis).
(define *attest-chain-head* (attest-genesis-sha))
(define (attest-chain-head) *attest-chain-head*)
(define (attest-reset-chain!) (set! *attest-chain-head* (attest-genesis-sha)))

(define* (attest-log-append! record
                             #:key
                             (strict? (attest-strict?))
                             (disabled? (attest-disabled?))
                             (log-file (attest-log-file)))
  "Append RECORD's byte-canonical encoding as one JSONL line. Returns 'skipped
when logging is disabled, 'ok on success, 'failed on a swallowed (best-effort)
write error. When STRICT? and the write fails, THROWS 'attest-write-failed so
the caller can abort the mutation (§17.6)."
  (if disabled?
      'skipped
      (let ((line (attestation-encode record)))
        (catch #t
          (lambda ()
            (let ((dir (dirname log-file)))
              (unless (file-exists? dir)
                (mkdir dir))
              (let ((port (open-file log-file "a")))
                (display line port)
                (newline port)
                (close-port port))
              'ok))
          (lambda (key . args)
            (if strict?
                (throw 'attest-write-failed key args)
                'failed))))))

(define* (attest! action verdict
                  #:key (result-sha #f) (actor #f)
                  (strict? (attest-strict?)) (disabled? (attest-disabled?))
                  (log-file (attest-log-file)))
  "High-level Path A/B entry: build the attestation record for ACTION+VERDICT,
chain it onto the in-process head, append it (best-effort/strict/disabled), and
advance the head. Returns the (linked) record. VERIFICATION already happened in
policy-verdict; this only handles LOGGING (§17.6)."
  (let* ((rec (attestation action verdict
                           #:result-sha result-sha
                           #:actor actor
                           #:prev-sha *attest-chain-head*))
         (status (attest-log-append! rec
                                     #:strict? strict?
                                     #:disabled? disabled?
                                     #:log-file log-file)))
    ;; Advance the chain head on a real (or would-be) record so the chain stays
    ;; monotone even when logging is disabled/best-effort-failed.
    (set! *attest-chain-head* (sha256-hex (attestation-encode rec)))
    rec))
