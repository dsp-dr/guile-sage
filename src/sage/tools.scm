;;; tools.scm --- Tool registration and execution -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Tool system for guile-sage.
;; Provides tool registration, permission checking, and execution.

(define-module (sage tools)
  #:use-module (sage config)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (sage agent)
  #:use-module (sage irc)
  #:use-module (sage ollama)
  #:use-module (sage telemetry)
  #:use-module (sage usage-stats)
  #:use-module (sage provenance)
  #:use-module (sage scratch)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 eval-string)
  #:export (*tools*
            *safe-tools*
            *workspace*
            workspace
            register-tool
            register-safe-tool
            get-tool
            list-tools
            execute-tool
            check-permission
            safe-path?
            resolve-path
            init-default-tools
            tools-to-schema))

;;; Tool Registry

(define *tools* '())
;; Tools always permitted, no YOLO required.
;; Filesystem/git mutating tools (write_file, edit_file, git_commit,
;; git_add_note, git_push) are intentionally absent: they require
;; SAGE_YOLO_MODE. Task and image tools remain here because they only
;; touch sage-managed state, not source files or git history.
(define *safe-tools* '("read_file" "list_files" "git_status" "git_diff"
                       "git_log" "git_fetch" "glob_files" "search_files"
                       "read_logs" "search_logs"
                       "sage_task_create" "sage_task_push"
                       "sage_task_complete" "sage_task_list" "sage_task_status"
                       "scratch_get" "scratch_list"
                       "generate_image"))
(define *workspace* #f)

;;; workspace: Get current workspace directory
(define (workspace)
  (or *workspace*
      (config-get "WORKSPACE")
      (config-get "SAGE_WORKSPACE")
      (getcwd)))

;;; set-workspace!: Set workspace directory
(define (set-workspace! path)
  (set! *workspace* path))

;;; resolve-path: Map a tool-supplied path to its actual filesystem location.
;;;
;;; - Absolute paths (starting with "/") are kept as-is, so /tmp/foo
;;;   ends up at /tmp/foo on disk, NOT at <workspace>//tmp/foo. Before
;;;   this helper, write_file/edit_file/read_file/list_files all did
;;;   (string-append (workspace) "/" path) which silently produced a
;;;   workspace-relative file for absolute inputs and then echoed the
;;;   ORIGINAL path back to the user, lying about where the file went.
;;;   See bd guile-ecn and docs/UX-FINDINGS-0.6.0.md gap #1.
;;;
;;; - Relative paths are anchored to the current workspace.
;;;
;;; This is a pure function — no I/O, no canonicalisation. safe-path?
;;; uses it for the /tmp / workspace check; tool implementations use
;;; it both to find the file AND to report the resolved path back to
;;; the caller.
(define (resolve-path path)
  (cond
   ((not path) #f)
   ((string-null? path) (workspace))
   ((string-prefix? "/" path) path)
   (else (string-append (workspace) "/" path))))

;;; safe-path?: Check if path is within workspace
(define (safe-path? path)
  ;; Traversal check applies globally — no path with ".." is ever safe
  (if (string-contains path "..")
      #f
      (let ((ws (workspace))
            (expanded (resolve-path path)))
        ;; Allow /tmp for temporary files, otherwise check workspace containment
        (or (string-prefix? "/tmp/" expanded)
            (and (string-prefix? ws (canonicalize-path-safe expanded))
                 (not (regexp-exec (make-regexp "(\\.env|\\.git/|\\.ssh|\\.gnupg)") path)))))))

;;; coerce->int: Force a JSON-supplied value to a Scheme exact integer.
;;;
;;; LLM-emitted tool arguments are inconsistent: the model sometimes
;;; produces `"lines": 20` (int), sometimes `"lines": "20"` (string),
;;; sometimes `"lines": 20.0` (inexact float). util.scm's JSON parser
;;; passes all of these through unchanged, so any tool that does
;;; (min N other) or (take lst N) crashes on the wrong-type input.
;;;
;;; This helper normalises at the tool boundary. NOTE: Guile's
;;; (integer? 20.0) is #t — 20.0 is mathematically an integer, just
;;; inexact — so we cannot fast-path on integer? alone. Always run
;;; through (inexact->exact (round ...)) to guarantee exactness.
;;;
;;; bd: guile-bcy.
(define (coerce->int v default)
  (let ((raw (cond
              ((not v) default)
              ((number? v) v)
              ((string? v) (or (string->number v) default))
              (else default))))
    (if (number? raw)
        (inexact->exact (round raw))
        default)))

;;; canonicalize-path-safe: Safe path canonicalization
(define (canonicalize-path-safe path)
  (catch #t
    (lambda () (canonicalize-path path))
    (lambda args path)))

;;; ============================================================
;;; Safe subprocess execution
;;; ============================================================
;;;
;;; SECURITY (bd: guile-sage-9j7 / guile-sage-07f): Tool
;;; implementations historically built shell commands via
;;; (system (string-append "cd ~a && git add ~a && git commit ..."
;;;                        workspace files msg))
;;; which is a textbook shell-injection vector — any attacker-controlled
;;; metachar in workspace paths, file lists, or commit messages becomes
;;; arbitrary shell execution.
;;;
;;; We use `primitive-fork + execlp` (not system*/spawn) for two reasons:
;;; 1. argv-based exec: shell metachars in ARGS are treated as literal
;;;    bytes, not parsed as shell syntax.
;;; 2. dodges the known macOS Guile 3.0.11 spawn+bad-FD bug that makes
;;;    `system*` and `open-pipe*` fail with "Bad file descriptor".
;;;
;;; `argv-clean?` is a defence-in-depth string check; primary defence
;;; is the argv-based exec path which doesn't interpret shell metachars
;;; at all.

(define %shell-meta-re
  ;; Characters that, in a shell context, change the meaning of a
  ;; command: ;, |, &, `, $, newline, carriage-return, <, >.
  (make-regexp "[;|&`$\n\r<>]"))

(define (argv-clean? s)
  "Return #t if S is a string with no shell metacharacters. Used as a
defence-in-depth check on top of argv-based subprocess invocation."
  (and (string? s)
       (not (regexp-exec %shell-meta-re s))))

(define (capture-argv-in-dir dir prog . args)
  "Run PROG with ARGS as argv in directory DIR, capturing stdout+stderr.
Uses primitive-fork + execlp so no /bin/sh is involved. Returns the
combined output as a string. On any error returns \"\"."
  (catch #t
    (lambda ()
      (let* ((p (pipe))
             (read-port (car p))
             (write-port (cdr p))
             (pid (primitive-fork)))
        (cond
         ((= pid 0)
          (close-port read-port)
          (chdir dir)
          (dup2 (fileno write-port) 1)
          (dup2 (fileno write-port) 2)
          (close-port write-port)
          (catch #t
            (lambda () (apply execlp prog prog args))
            (lambda args (primitive-exit 127))))
         (else
          (close-port write-port)
          (let ((out (get-string-all read-port)))
            (close-port read-port)
            (waitpid pid)
            out)))))
    (lambda args "")))

(define (run-argv-in-dir dir prog . args)
  "Like capture-argv-in-dir but returns (status . output) so callers
that care about the exit code (git_push, git_commit) can surface it."
  (catch #t
    (lambda ()
      (let* ((p (pipe))
             (read-port (car p))
             (write-port (cdr p))
             (pid (primitive-fork)))
        (cond
         ((= pid 0)
          (close-port read-port)
          (chdir dir)
          (dup2 (fileno write-port) 1)
          (dup2 (fileno write-port) 2)
          (close-port write-port)
          (catch #t
            (lambda () (apply execlp prog prog args))
            (lambda args (primitive-exit 127))))
         (else
          (close-port write-port)
          (let ((out (get-string-all read-port)))
            (close-port read-port)
            (let* ((status-pair (waitpid pid))
                   (status (cdr status-pair))
                   (code (status:exit-val status)))
              (cons (or code 1) out)))))))
    (lambda args (cons 127 ""))))

;;; register-tool: Register a new tool
;;; Arguments:
;;;   name - Tool name string
;;;   description - Description string
;;;   parameters - JSON schema for parameters
;;;   execute-fn - Function (args) -> result-string
;;;   safe - Whether tool is safe (default #f)
(define* (register-tool name description parameters execute-fn #:key (safe #f))
  (set! *tools*
        (cons `(("name" . ,name)
                ("description" . ,description)
                ("parameters" . ,parameters)
                ("execute" . ,execute-fn))
              (filter (lambda (t) (not (equal? (assoc-ref t "name") name)))
                      *tools*)))
  (when safe
    (set! *safe-tools* (cons name *safe-tools*)))
  (log-debug "tools" (format #f "Registered tool: ~a" name)
             `(("safe" . ,(if safe "yes" "no")))))

;;; register-safe-tool: Register a safe tool
(define (register-safe-tool name description parameters execute-fn)
  (register-tool name description parameters execute-fn #:safe #t))

;;; get-tool: Get tool by name
(define (get-tool name)
  (find (lambda (t) (equal? (assoc-ref t "name") name)) *tools*))

;;; list-tools: List all registered tools
(define (list-tools)
  (map (lambda (t)
         `((name . ,(assoc-ref t "name"))
           (description . ,(assoc-ref t "description"))
           (safe . ,(member (assoc-ref t "name") *safe-tools*))))
       *tools*))

;;; check-permission: Check if tool execution is allowed
;;; Arguments:
;;;   tool-name - Name of tool
;;;   args - Arguments to tool
;;; Returns: #t if allowed
(define (check-permission tool-name args)
  (or (member tool-name *safe-tools*)
      (config-get "YOLO_MODE")
      ;; In non-interactive mode, deny unsafe tools by default
      #f))

;;; ============================================================
;;; eval_scheme Sandbox (NC12: fires even in YOLO mode)
;;; ============================================================
;;;
;;; Denylist of symbols that would give eval_scheme access to the
;;; shell, filesystem mutation, subprocesses, network pipes, code
;;; loading, or a recursive eval escape. This list is intentionally
;;; broad — if a symbol is even *named* in the code string, the call
;;; is rejected, regardless of whether it would actually be resolved
;;; to the dangerous binding. False positives are cheaper than an RCE.
(define eval-scheme-denied-symbols
  '(;; Shell-out / subprocess
    system system* primitive-fork execl execle execlp
    ;; Pipes (ice-9 popen)
    open-pipe open-pipe* open-input-pipe open-output-pipe
    open-input-output-pipe
    ;; Network sockets
    socket connect bind accept listen
    ;; Filesystem mutation
    delete-file rename-file copy-file chmod chown
    mkdir rmdir symlink truncate-file umask
    ;; File I/O that could read secrets or write arbitrary bytes
    open-file open-input-file open-output-file open-io-file
    call-with-input-file call-with-output-file
    with-input-from-file with-output-to-file
    ;; Module loading / recursive eval / code injection
    load primitive-load primitive-load-path
    load-from-path load-compiled eval-string
    eval compile compile-file
    resolve-module use-modules module-use! module-use-interfaces!
    ;; Continuation escape to parent
    dynamic-wind make-continuation call-with-current-continuation
    call/cc
    ;; Raw memory / FFI
    dynamic-link dynamic-func dynamic-call dynamic-pointer
    pointer->bytevector bytevector->pointer
    ;; Environment mutation
    setenv unsetenv putenv
    ;; ftw helpers that walk the filesystem
    ftw nftw scandir opendir readdir closedir
    ;; Exit / abort the host process
    exit quit primitive-exit abort abort-to-prompt))

;;; walk-sexp-for-denied: recursively inspect an s-expression and
;;; return the first denied symbol found, or #f. Lists, vectors, and
;;; pairs are all descended. Strings, numbers, and other atoms are
;;; safe — we only denylist identifiers.
(define (walk-sexp-for-denied sexp)
  (cond
   ((symbol? sexp)
    (if (memq sexp eval-scheme-denied-symbols) sexp #f))
   ((pair? sexp)
    (or (walk-sexp-for-denied (car sexp))
        (walk-sexp-for-denied (cdr sexp))))
   ((vector? sexp)
    (let loop ((i 0))
      (cond
       ((>= i (vector-length sexp)) #f)
       ((walk-sexp-for-denied (vector-ref sexp i)))
       (else (loop (+ i 1))))))
   (else #f)))

;;; eval-scheme-sandbox-check: parse the code string and check it
;;; against the denylist. Returns 'allow on success, or
;;; (veto . reason-string) on denial.
;;;
;;; This enforces NC12 (docs/HOOK-NEGATIVE-CONTRACTS.org): safety
;;; invariants that fire even in YOLO mode. YOLO lets eval_scheme be
;;; *called*; this sandbox constrains what it can *do*.
(define (eval-scheme-sandbox-check code)
  (catch #t
    (lambda ()
      (let* ((port (open-input-string code))
             ;; Read all top-level forms so multi-form strings
             ;; like "(define x 1) (system ...)" are scanned too.
             (forms (let loop ((acc '()))
                      (let ((f (read port)))
                        (if (eof-object? f)
                            (reverse acc)
                            (loop (cons f acc)))))))
        (let ((hit (walk-sexp-for-denied forms)))
          (if hit
              (cons 'veto
                    (format #f "denied symbol '~a' (sandbox blocks shell-out, filesystem mutation, pipes, and code loading even in YOLO mode — NC12)"
                            hit))
              'allow))))
    (lambda (key . rest)
      ;; If the code doesn't even parse, reject — we can't safely
      ;; walk it and eval-string would just throw anyway, but we'd
      ;; rather the sandbox message be clear.
      (cons 'veto (format #f "parse error: ~a ~a" key rest)))))

;;; args-digest-for: Short human-readable summary of a tool-call args
;;; alist. Used by usage-stats for privacy + size (we deliberately do
;;; NOT log the full args alist). We take the first kv pair, render
;;; as "key=value", and let usage-put! truncate to 80 chars.
(define (args-digest-for args)
  (cond
   ((null? args) "")
   ((and (pair? args) (pair? (car args)))
    (let ((k (caar args))
          (v (cdar args)))
      (format #f "~a=~a" k v)))
   (else (format #f "~a" args))))

;;; execute-tool: Execute a tool by name
;;; Arguments:
;;;   name - Tool name
;;;   args - Alist of arguments
;;; Returns: Result string or error
(define (execute-tool name args)
  (let ((tool (get-tool name))
        (hook-mod (false-if-exception (resolve-module '(sage hooks) #:ensure #f))))
    (if tool
        (if (check-permission name args)
            (let* ((pre (if hook-mod
                            ((module-ref hook-mod 'hook-fire-pre-tool) name args)
                            #t))
                   (vetoed? (or (not pre) (and (pair? pre) (not (car pre))))))
              (if vetoed?
                  (let ((reason (if (pair? pre) (cdr pre) "hook veto")))
                    (log-warn "tools" (format #f "PreToolUse vetoed ~a: ~a" name reason)
                              `(("tool" . ,name) ("reason" . ,reason)))
                    (inc-counter! "guile_sage.code_edit.tool_decision"
                                  `(("tool_name" . ,name) ("decision" . "veto")) 1)
                    (format #f "Hook vetoed: ~a" reason))
                  (begin
                    (log-tool-call name args)
                    (inc-counter! "guile_sage.code_edit.tool_decision"
                                  `(("tool_name" . ,name) ("decision" . "accept")) 1)
                    (let ((start-time (get-internal-real-time)))
                      (catch #t
                        (lambda ()
                          (let* ((result ((assoc-ref tool "execute") args))
                                 (end-time (get-internal-real-time))
                                 (duration-ms (/ (- end-time start-time)
                                                 (/ internal-time-units-per-second 1000))))
                            (log-tool-call name args #:result result #:duration duration-ms)
                            (when hook-mod
                              ((module-ref hook-mod 'hook-fire-post-tool) name args result))
                            ;; Append to local usage ledger (opt-out via
                            ;; SAGE_STATS_DISABLE). Errors are swallowed
                            ;; inside usage-put! — never blocks the caller.
                            (usage-put! name
                                        (args-digest-for args)
                                        (inexact->exact (round duration-ms))
                                        (if (string? result)
                                            (string-length result)
                                            0))
                            result))
                        (lambda (key . rest)
                          (log-error "tools" (format #f "Tool execution failed: ~a" name)
                                     `(("error" . ,(format #f "~a ~a" key rest))))
                          (format #f "Tool error: ~a ~a" key rest)))))))
            (begin
              (log-warn "tools" (format #f "Permission denied: ~a" name)
                        `(("tool" . ,name)))
              (inc-counter! "guile_sage.code_edit.tool_decision"
                            `(("tool_name" . ,name) ("decision" . "reject")) 1)
              (format #f "Permission denied for tool: ~a" name)))
        (begin
          (log-warn "tools" (format #f "Unknown tool: ~a" name))
          (format #f "Unknown tool: ~a" name)))))

;;; tools-to-schema: Convert tools to JSON schema for LLM
(define (tools-to-schema)
  (map (lambda (t)
         `(("name" . ,(assoc-ref t "name"))
           ("description" . ,(assoc-ref t "description"))
           ("parameters" . ,(assoc-ref t "parameters"))))
       *tools*))

;;; ============================================================
;;; Built-in Tools
;;; ============================================================

;;; fetch_url tool (classified safe).
;;;
;;; Contract: https://wal.sh/research/guile-sage-inject.html
;;;   - GET only, UA contains "guile-sage/0.1"
;;;   - Only http:// and https:// schemes
;;;   - Cap: 1 MB body, 10 s timeout
;;;
;;; Wrapper contract: framing + provenance only, NO sanitisation.
;;; Output is a single <fetch-result> XML element with the body verbatim
;;; inside CDATA. Attributes carry source URL, byte count, SHA-256,
;;; fetched-at ISO timestamp, trust label, and the exact UA we sent.
;;; Consumers decide what to do with the body; the wrapper does not.
;;;
;;; Design notes:
;;; - Script stripping was removed on 2026-04-19 after the wal.sh T3
;;;   test confirmed the <tool-result> role-boundary layer prevents the
;;;   model acting on injected instructions. Stripping in the wrapper
;;;   conflates framing with rendering-safety; keep them separate.
;;; - CDATA is split on any occurrence of "]]>" in the body so we never
;;;   emit invalid XML even if the source contains the terminator.

(define *fetch-ua*
  "guile-sage/0.1 (+https://github.com/dsp-dr/guile-sage; Guile Scheme AI agent)")
(define *fetch-max-bytes* 1048576)
(define *fetch-timeout-secs* 10)
;; Bodies larger than *fetch-inline-threshold* are stored in the
;; scratch module and fetch_url returns a reference (head preview +
;; sha). Tunable via env var for stress testing.
(define *fetch-inline-threshold*
  (or (and=> (getenv "SAGE_FETCH_INLINE_THRESHOLD") string->number)
      1024))
(define *fetch-preview-bytes* 500)

(define (fetch-url-scheme-ok? url)
  (or (string-prefix? "http://" url)
      (string-prefix? "https://" url)))

(define (fetch-cdata-safe body)
  "Split any ]]> in BODY across two CDATA sections so the envelope stays
well-formed XML. Lossless: concatenating the text content of every
CDATA section inside a <fetch-result> reproduces BODY byte-for-byte."
  (let loop ((s body) (acc '()))
    (let ((i (string-contains s "]]>")))
      (if (not i)
          (apply string-append (reverse (cons s acc)))
          (loop (substring s (+ i 3))
                (cons "]]]]><![CDATA[>"
                      (cons (substring s 0 i) acc)))))))

(define (fetch-attr-escape s)
  "Escape S for use inside a double-quoted XML attribute."
  (let* ((s1 (string-replace-substring s "&" "&amp;"))
         (s2 (string-replace-substring s1 "<" "&lt;"))
         (s3 (string-replace-substring s2 ">" "&gt;"))
         (s4 (string-replace-substring s3 "\"" "&quot;")))
    s4))

(define (fetch-now-iso)
  "ISO-8601 timestamp in UTC."
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (fetch-sha256 content)
  "Compute SHA-256 of CONTENT via shasum/sha256sum using the argv-based
exec path (capture-argv-in-dir). The provenance module's content-sha256
uses open-input-pipe which triggers the macOS Guile 3.0.11 Bad-FD bug;
this is a local replacement that mirrors the curl call pattern."
  (catch #t
    (lambda ()
      (let* ((tmp (format #f "/tmp/sage-fetch-sha-~a-~a"
                          (getpid) (random 1000000)))
             (_ (call-with-output-file tmp
                  (lambda (p) (display content p))))
             ;; shasum on macOS, sha256sum on Linux/FreeBSD
             (out (or (let ((s (capture-argv-in-dir "/tmp" "shasum" "-a" "256" tmp)))
                        (and s (not (string-null? s)) s))
                      (let ((s (capture-argv-in-dir "/tmp" "sha256sum" tmp)))
                        (and s (not (string-null? s)) s))
                      ""))
             (hex (if (>= (string-length out) 64)
                      (substring out 0 64)
                      "hash-error")))
        (when (file-exists? tmp) (delete-file tmp))
        hex))
    (lambda (key . args) "hash-unavailable")))

(define (fetch-url-execute args)
  (let ((url (assoc-ref args "url")))
    (cond
     ((or (not url) (not (string? url)) (string-null? url))
      "Error: url argument is required")
     ((not (fetch-url-scheme-ok? url))
      (format #f "Error: only http:// and https:// URLs are permitted (got: ~a)" url))
     (else
      ;; Two-file curl: body goes to -o, headers to -D, and -w writes
      ;; "<content-type>\n<http-code>\n" to stdout so capture-argv-in-dir
      ;; returns just the metadata. Accept header prefers markdown,
      ;; falls through to plain text, then HTML, then anything.
      (let* ((body-tmp (format #f "/tmp/sage-fetch-body-~a-~a"
                               (getpid) (random 1000000)))
             (hdr-tmp (format #f "/tmp/sage-fetch-hdr-~a-~a"
                              (getpid) (random 1000000)))
             (meta (capture-argv-in-dir
                    "/tmp"
                    "curl" "-sSL"
                    "-A" *fetch-ua*
                    "-H" "Accept: text/markdown, text/plain;q=0.9, text/html;q=0.8, */*;q=0.5"
                    "--max-time" (number->string *fetch-timeout-secs*)
                    "--max-filesize" (number->string *fetch-max-bytes*)
                    "-o" body-tmp
                    "-D" hdr-tmp
                    "-w" "%{content_type}\n%{http_code}\n"
                    url))
             (meta-parts (string-split (string-trim-both meta) #\newline))
             (content-type (if (pair? meta-parts)
                               (car meta-parts)
                               "unknown"))
             (http-code (if (>= (length meta-parts) 2)
                            (cadr meta-parts)
                            "000"))
             (body (if (file-exists? body-tmp)
                       (call-with-input-file body-tmp get-string-all)
                       ""))
             (bytes (string-length body))
             (sha (fetch-sha256 body))
             (ts (fetch-now-iso))
             (inline? (<= bytes *fetch-inline-threshold*)))
        (when (file-exists? body-tmp) (delete-file body-tmp))
        (when (file-exists? hdr-tmp) (delete-file hdr-tmp))
        ;; Large bodies go to scratch; small ones go inline. Either
        ;; way the envelope carries the sha so the consumer can
        ;; scratch_get by sha if the body was stored.
        (unless inline?
          (scratch-put! sha body
                        "source" url
                        "content-type" content-type
                        "fetched-at" ts))
        (string-append
         "<fetch-result"
         " source=\"" (fetch-attr-escape url) "\""
         " content-type=\"" (fetch-attr-escape content-type) "\""
         " http-code=\"" http-code "\""
         " bytes=\"" (number->string bytes) "\""
         " sha256=\"" sha "\""
         " fetched-at=\"" ts "\""
         " trust=\"untrusted\""
         " storage=\"" (if inline? "inline" "scratch") "\""
         " user-agent=\"" (fetch-attr-escape *fetch-ua*) "\">"
         (if inline?
             (string-append "<![CDATA[" (fetch-cdata-safe body) "]]>")
             (string-append
              "<![CDATA["
              (fetch-cdata-safe (substring body 0 (min *fetch-preview-bytes* bytes)))
              "]]><preview-truncated>"
              "Body stored in scratch. Retrieve more with: "
              "scratch_get sha=" sha " offset=0 len=2000"
              "</preview-truncated>"))
         "</fetch-result>"))))))

;;; format-edit-diff: Produce a small unified-diff-style summary for
;;; edit_file's return value. Shows ~2 lines of context before the
;;; changed region and the old/new block.
;;;
;;; path       : resolved absolute path (for the header)
;;; content    : original file content (pre-edit)
;;; match-pos  : byte offset where SEARCH begins in CONTENT
;;; search     : old text (possibly multi-line)
;;; replace    : new text (possibly multi-line)
(define (format-edit-diff path content match-pos search replace)
  (let* ((line-of-match
          ;; Count newlines in content[0..match-pos]
          (let loop ((i 0) (n 1))
            (if (>= i match-pos)
                n
                (loop (+ i 1)
                      (if (char=? (string-ref content i) #\newline)
                          (+ n 1)
                          n)))))
         (context-lines 2)
         (start-line (max 1 (- line-of-match context-lines)))
         (lines (string-split content #\newline))
         (prefix (if (< start-line line-of-match)
                     (string-join
                      (map (lambda (n)
                             (format #f "  ~a" (list-ref lines (- n 1))))
                           (iota (- line-of-match start-line) start-line))
                      "\n")
                     ""))
         (format-block
          (lambda (sign text)
            (string-join
             (map (lambda (l) (format #f "~a ~a" sign l))
                  (string-split text #\newline))
             "\n"))))
    (string-append
     (format #f "Edited ~a (@ line ~a)~%" path line-of-match)
     (format #f "@@ -~a,~a +~a,~a @@~%"
             line-of-match (length (string-split search #\newline))
             line-of-match (length (string-split replace #\newline)))
     (if (string-null? prefix) "" (string-append prefix "\n"))
     (format-block "-" search) "\n"
     (format-block "+" replace))))

(define (init-default-tools)
  ;; fetch_url (safe: read-only GET, URL scheme + size/time caps)
  (register-tool
   "fetch_url"
   "Fetch an http(s) URL via GET. Sends Accept: text/markdown, text/plain;q=0.9, text/html;q=0.8 so servers that support content negotiation return the agent-friendly shape. Returns a <fetch-result> XML envelope with source, content-type, http-code, bytes, SHA-256, fetched-at, trust, and user-agent attributes; body is inside CDATA verbatim (no sanitisation — the role-boundary layer handles safety). Bodies over SAGE_FETCH_INLINE_THRESHOLD (default 1 KB) are stored in scratch and the envelope carries a 500-char preview + sha for retrieval via scratch_get. Capped at 1 MB / 10 s."
   '(("type" . "object")
     ("properties" . (("url" . (("type" . "string")
                                ("description" . "http:// or https:// URL to fetch")))))
     ("required" . #("url")))
   fetch-url-execute
   #:safe #t)

  ;; read_file
  (register-tool
   "read_file"
   "Read contents of a file within workspace"
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "File path relative to workspace")))))
     ("required" . #("path")))
   (lambda (args)
     (let ((path (assoc-ref args "path")))
       (if (safe-path? path)
           (let ((full-path (resolve-path path)))
             (if (file-exists? full-path)
                 (call-with-input-file full-path get-string-all)
                 (format #f "File not found: ~a" full-path)))
           (format #f "Unsafe path: ~a" path)))))

  ;; list_files
  (register-tool
   "list_files"
   "List files in a directory within workspace"
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "Directory path relative to workspace")))
                      ("pattern" . (("type" . "string")
                                   ("description" . "Optional glob pattern")))))
     ("required" . #("path")))
   (lambda (args)
     (let ((path (or (assoc-ref args "path") "."))
           (pattern (or (assoc-ref args "pattern") "*")))
       (if (safe-path? path)
           (let ((full-path (resolve-path path)))
             (if (file-exists? full-path)
                 (string-join
                  (scandir full-path
                           (lambda (f) (not (string-prefix? "." f))))
                  "\n")
                 (format #f "Directory not found: ~a" path)))
           (format #f "Unsafe path: ~a" path)))))

  ;; write_file
  (register-tool
   "write_file"
   "Write content to a file within workspace"
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "File path relative to workspace")))
                      ("content" . (("type" . "string")
                                   ("description" . "Content to write")))))
     ("required" . #("path" "content")))
   (lambda (args)
     (let ((path (assoc-ref args "path"))
           (content (assoc-ref args "content")))
       (if (safe-path? path)
           (let ((full-path (resolve-path path)))
             (call-with-output-file full-path
               (lambda (port) (display content port)))
             ;; Echo the RESOLVED path so /tmp/foo (absolute) lands at
             ;; /tmp/foo and the user is told that. Workspace-relative
             ;; paths still appear as workspace-anchored absolute.
             ;; bd: guile-ecn.
             (format #f "Wrote ~a bytes to ~a" (string-length content) full-path))
           (format #f "Unsafe path: ~a" path)))))

  ;; git_status
  ;; bd: guile-sage-9j7/07f — used to shell-interpolate workspace path.
  ;; Now argv-based via capture-argv-in-dir (no /bin/sh).
  (register-tool
   "git_status"
   "Get git status of workspace"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (capture-argv-in-dir (workspace) "git" "status" "--porcelain")))

  ;; git_diff — argv-based, no shell (bd: guile-sage-9j7/07f).
  (register-tool
   "git_diff"
   "Get git diff of workspace"
   '(("type" . "object")
     ("properties" . (("staged" . (("type" . "boolean")
                                   ("description" . "Show staged changes only")))))
     ("required" . #()))
   (lambda (args)
     (let ((staged (assoc-ref args "staged")))
       (if staged
           (capture-argv-in-dir (workspace) "git" "diff" "--staged")
           (capture-argv-in-dir (workspace) "git" "diff")))))

  ;; git_log — argv-based; count coerced to integer string so a crafted
  ;; value cannot inject flags (bd: guile-sage-9j7/07f).
  (register-tool
   "git_log"
   "Get git log of workspace"
   '(("type" . "object")
     ("properties" . (("count" . (("type" . "integer")
                                  ("description" . "Number of commits to show")))))
     ("required" . #()))
   (lambda (args)
     (let* ((count (coerce->int (assoc-ref args "count") 10))
            (count-str (number->string count)))
       (capture-argv-in-dir (workspace) "git" "log" "--oneline"
                            "-n" count-str))))

  ;; search_files
  ;; bd: guile-sage-9j7/07f — previously shell-interpolated pattern,
  ;; file-pattern, and scope-path. A pattern like "foo'; rm -rf / #"
  ;; escaped the quotes and ran rm. Now grep is fork+exec'd with argv
  ;; directly; head -200 truncation is replicated in-process.
  (register-tool
   "search_files"
   "Search for pattern in files (optionally scoped to a subdirectory)"
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Search pattern (literal string)")))
                      ("path" . (("type" . "string")
                                 ("description" . "Subdirectory to search relative to workspace; defaults to workspace root")))
                      ("file_pattern" . (("type" . "string")
                                         ("description" . "Filename glob (basename only, no slashes), e.g. *.scm")))
                      ("regex" . (("type" . "boolean")
                                  ("description" . "Treat pattern as regex (default: false)")))))
     ("required" . #("pattern")))
   (lambda (args)
     (let* ((pattern (assoc-ref args "pattern"))
            (raw-path (or (assoc-ref args "path") "."))
            (file-pattern (or (assoc-ref args "file_pattern") "*"))
            (use-regex (assoc-ref args "regex"))
            (grep-flag (if use-regex "-r" "-rF")))
       (cond
        ((not (safe-path? raw-path))
         (format #f "Unsafe path: ~a" raw-path))
        (else
         (let* ((scope-path (if (equal? raw-path ".") "." raw-path))
                (raw-out (capture-argv-in-dir
                          (workspace)
                          "grep"
                          grep-flag
                          (string-append "--include=" file-pattern)
                          "--"
                          pattern
                          scope-path))
                (lines (string-split raw-out #\newline))
                (kept (if (> (length lines) 200)
                          (take lines 200)
                          lines)))
           (string-join kept "\n")))))))

  ;; glob_files — argv-based find; name pattern never touches /bin/sh
  ;; (bd: guile-sage-9j7/07f).
  (register-tool
   "glob_files"
   "Find files matching glob pattern"
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Glob pattern (e.g. **/*.scm)")))))
     ("required" . #("pattern")))
   (lambda (args)
     (let* ((pattern (assoc-ref args "pattern"))
            (dir-part (dirname pattern))
            (name-part (basename pattern))
            (search-path (if (equal? dir-part ".") "." dir-part))
            (raw-out (capture-argv-in-dir (workspace)
                                          "find" search-path
                                          "-name" name-part))
            (lines (string-split raw-out #\newline))
            (kept (if (> (length lines) 100)
                      (take lines 100)
                      lines)))
       (string-join kept "\n"))))

  ;; ============================================================
  ;; Self-Modification Tools
  ;; ============================================================

  ;; edit_file - Edit existing files with search/replace; returns a diff.
  (register-tool
   "edit_file"
   "Edit a file by replacing text (search and replace). Returns a short unified diff with ~2 lines of context so the caller sees exactly what changed."
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "File path relative to workspace")))
                      ("search" . (("type" . "string")
                                   ("description" . "Text to search for")))
                      ("replace" . (("type" . "string")
                                    ("description" . "Text to replace with")))))
     ("required" . #("path" "search" "replace")))
   (lambda (args)
     (let ((path (assoc-ref args "path"))
           (search (assoc-ref args "search"))
           (replace (assoc-ref args "replace")))
       (if (safe-path? path)
           (let ((full-path (resolve-path path)))
             (if (file-exists? full-path)
                 (let* ((content (call-with-input-file full-path get-string-all))
                        (match-pos (string-contains content search)))
                   (cond
                    ((not match-pos)
                     (format #f "No match found for search text in ~a" full-path))
                    (else
                     (let ((new-content (string-replace-substring content search replace)))
                       (call-with-output-file full-path
                         (lambda (port) (display new-content port)))
                       (format-edit-diff full-path content match-pos search replace)))))
                 (format #f "File not found: ~a" full-path)))
           (format #f "Unsafe path: ~a" path)))))

  ;; run_tests - Execute test suite
  ;; bd: guile-sage-9j7/07f — previously built a shell for-loop that
  ;; interpolated PATTERN into the command and used $(command -v ...)
  ;; for guile path. An attacker-controlled pattern could inject. Now
  ;; we expand the glob in-process (scandir + regex) and exec guile
  ;; with argv.
  (register-tool
   "run_tests"
   "Run the test suite"
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Test file pattern (default: test-*.scm)")))))
     ("required" . #()))
   (lambda (args)
     (let* ((pattern (or (assoc-ref args "pattern") "test-*.scm"))
            (tests-dir (string-append (workspace) "/tests"))
            (guile-bin (or (find file-exists?
                                 '("/usr/local/bin/guile3"
                                   "/usr/bin/guile3"
                                   "/opt/homebrew/bin/guile3"
                                   "/usr/local/bin/guile"
                                   "/usr/bin/guile"
                                   "/opt/homebrew/bin/guile"))
                           "guile"))
            (safe-pat? (and (string? pattern)
                            (not (string-contains pattern "/"))
                            (argv-clean? pattern)))
            (glob->re (lambda (p)
                        (let loop ((chars (string->list p))
                                   (acc '(#\^)))
                          (cond
                           ((null? chars) (list->string (reverse (cons #\$ acc))))
                           ((char=? (car chars) #\*)
                            (loop (cdr chars) (append (list #\* #\.) acc)))
                           ((char=? (car chars) #\?)
                            (loop (cdr chars) (cons #\. acc)))
                           ((memv (car chars)
                                  '(#\. #\+ #\( #\) #\[ #\] #\{ #\} #\\))
                            (loop (cdr chars)
                                  (cons (car chars) (cons #\\ acc))))
                           (else
                            (loop (cdr chars) (cons (car chars) acc))))))))
       (cond
        ((not safe-pat?)
         (format #f "Unsafe pattern: ~a" pattern))
        ((not (file-exists? tests-dir))
         "No tests/ directory")
        (else
         (let* ((re (make-regexp (glob->re pattern)))
                (entries (catch #t
                           (lambda () (scandir tests-dir))
                           (lambda args '())))
                (matches (filter (lambda (f) (regexp-exec re f)) (or entries '())))
                (raw (string-concatenate
                      (map (lambda (test-file)
                             (capture-argv-in-dir
                              (workspace)
                              guile-bin "-L" "src"
                              (string-append "tests/" test-file)))
                           (sort matches string<?))))
                (stripped (regexp-substitute/global
                           #f "\x1b\\[[0-9;]*[a-zA-Z]" raw 'pre 'post))
                (max-len 4096)
                (truncated (if (> (string-length stripped) max-len)
                               (string-append (substring stripped 0 max-len)
                                              "\n... [truncated, "
                                              (number->string (string-length stripped))
                                              " chars total]")
                               stripped)))
           truncated))))))

  ;; git_commit - Make atomic commits
  ;; bd: guile-sage-9j7/07f — CRITICAL FIX. Commit messages and file
  ;; paths were shell-interpolated into a single `/bin/sh -c` command.
  ;; A message like "fix'; rm -rf $HOME; echo '" escaped the quoted
  ;; context and ran arbitrary commands. Now git add/commit are fork
  ;; +exec'd separately with argv; message and filenames are literal
  ;; argv elements. Also: reject file paths with shell metachars or
  ;; `..` — no legitimate path needs those.
  (register-tool
   "git_commit"
   "Stage files and create a git commit"
   '(("type" . "object")
     ("properties" . (("files" . (("type" . "array")
                                  ("items" . (("type" . "string")))
                                  ("description" . "Files to stage")))
                      ("message" . (("type" . "string")
                                    ("description" . "Commit message")))))
     ("required" . #("files" "message")))
   (lambda (args)
     (let* ((files (assoc-ref args "files"))
            (message (assoc-ref args "message"))
            (file-list (cond
                        ((list? files) files)
                        ((string? files) (list files))
                        (else '())))
            (coauthor (or (getenv "SAGE_COAUTHOR")
                          "Sage <sage@users.noreply.github.com>"))
            (full-msg (string-append message
                                     "\n\nCo-Authored-By: " coauthor)))
       (cond
        ((not (string? message))
         "Error: message must be a string")
        ((null? file-list)
         "Error: files is empty")
        ((not (every (lambda (f)
                       (and (string? f)
                            (argv-clean? f)
                            (not (string-contains f ".."))))
                     file-list))
         "Error: file list contains unsafe path(s)")
        (else
         (let* ((add-result (apply run-argv-in-dir
                                   (workspace) "git" "add" "--" file-list))
                (add-status (car add-result))
                (add-out (cdr add-result)))
           (if (not (zero? add-status))
               (format #f "git add failed (status ~a):\n~a" add-status add-out)
               (let* ((commit-result (run-argv-in-dir
                                      (workspace)
                                      "git" "commit" "-m" full-msg))
                      (commit-out (cdr commit-result)))
                 (string-append add-out commit-out)))))))))

  ;; git_add_note - Add git notes for documentation
  ;; bd: guile-sage-9j7/07f — message passed as argv, not interpolated
  ;; into a shell-quoted string.
  (register-tool
   "git_add_note"
   "Add a git note to the current HEAD commit"
   '(("type" . "object")
     ("properties" . (("message" . (("type" . "string")
                                    ("description" . "Note message")))))
     ("required" . #("message")))
   (lambda (args)
     (let ((message (assoc-ref args "message")))
       (if (not (string? message))
           "Error: message must be a string"
           (let* ((res (run-argv-in-dir
                        (workspace)
                        "git" "notes" "add" "-f" "-m" message))
                  (out (cdr res)))
             (if (string-null? (string-trim-both out))
                 "Note added successfully"
                 out))))))

  ;; git_push - Push commits to remote
  ;; bd: guile-sage-9j7/07f — remote/branch are argv elements. Reject
  ;; values containing shell metachars since git ref names never do.
  (register-tool
   "git_push"
   "Push commits to the remote repository"
   '(("type" . "object")
     ("properties" . (("remote" . (("type" . "string")
                                   ("description" . "Remote name (default: origin)")))
                      ("branch" . (("type" . "string")
                                   ("description" . "Branch to push (default: current branch)")))))
     ("required" . #()))
   (lambda (args)
     (let* ((remote (or (assoc-ref args "remote") "origin"))
            (branch (assoc-ref args "branch")))
       (cond
        ((not (argv-clean? remote))
         "Error: remote name contains unsafe characters")
        ((and branch (not (argv-clean? branch)))
         "Error: branch name contains unsafe characters")
        (else
         (let* ((res (if branch
                         (run-argv-in-dir (workspace) "git" "push" remote branch)
                         (run-argv-in-dir (workspace) "git" "push" remote)))
                (out (cdr res)))
           (if (string-null? (string-trim-both out))
               "Push completed (no output)"
               out)))))))

  (register-tool
   "git_pull"
   "Pull commits from the remote repository (may merge or rebase; mutates working tree)"
   '(("type" . "object")
     ("properties" . (("remote" . (("type" . "string")
                                   ("description" . "Remote name (default: origin)")))
                      ("branch" . (("type" . "string")
                                   ("description" . "Branch to pull (default: current)")))
                      ("rebase" . (("type" . "boolean")
                                   ("description" . "Use --rebase instead of merge (default: true)")))))
     ("required" . #()))
   (lambda (args)
     (let* ((remote (or (assoc-ref args "remote") "origin"))
            (branch (assoc-ref args "branch"))
            (rebase (let ((r (assoc-ref args "rebase")))
                      (if (eq? r #f) #f (if (eq? r #t) #t #t))))
            (flag (if rebase "--rebase" "--ff-only")))
       (cond
        ((not (argv-clean? remote))
         "Error: remote name contains unsafe characters")
        ((and branch (not (argv-clean? branch)))
         "Error: branch name contains unsafe characters")
        (else
         (let* ((res (if branch
                         (run-argv-in-dir (workspace) "git" "pull" flag remote branch)
                         (run-argv-in-dir (workspace) "git" "pull" flag remote)))
                (out (cdr res)))
           (if (string-null? (string-trim-both out))
               "Pull completed (no output)"
               out)))))))

  (register-tool
   "git_fetch"
   "Fetch remote refs without merging (non-mutating)"
   '(("type" . "object")
     ("properties" . (("remote" . (("type" . "string")
                                   ("description" . "Remote name (default: origin)")))))
     ("required" . #()))
   (lambda (args)
     (let ((remote (or (assoc-ref args "remote") "origin")))
       (cond
        ((not (argv-clean? remote))
         "Error: remote name contains unsafe characters")
        (else
         (let* ((res (run-argv-in-dir (workspace) "git" "fetch" remote))
                (out (cdr res)))
           (if (string-null? (string-trim-both out))
               "Fetch completed (no new refs)"
               out)))))))

  ;; eval_scheme - Evaluate scheme code dynamically (sandboxed)
  ;;
  ;; The eval_scheme sandbox is a safety invariant per
  ;; docs/HOOK-NEGATIVE-CONTRACTS.org NC12: "guards fire even in YOLO
  ;; mode". YOLO gates whether the tool is callable at all (ADR-0003),
  ;; but this sandbox gates WHAT the tool can do regardless of YOLO.
  ;;
  ;; Approach: symbol denylist. We parse the code string once, walk
  ;; the s-expression tree, and reject the call if any identifier
  ;; appears in eval-scheme-denied-symbols. This stops the common
  ;; attack vectors (system, pipes, filesystem mutation, recursive
  ;; eval, module loading) without needing a full interpreter rewrite.
  ;;
  ;; Red team findings #2 (guile-sage-6tp / guile-sage-h9y).
  (register-tool
   "eval_scheme"
   "Evaluate Scheme code and return result (sandboxed — no I/O, no shell, no filesystem mutation)"
   '(("type" . "object")
     ("properties" . (("code" . (("type" . "string")
                                 ("description" . "Scheme code to evaluate")))))
     ("required" . #("code")))
   (lambda (args)
     (let ((code (assoc-ref args "code")))
       (catch #t
         (lambda ()
           (let ((sandbox-check (eval-scheme-sandbox-check code)))
             (if (eq? sandbox-check 'allow)
                 (let ((result (eval-string code)))
                   (format #f "~s" result))
                 ;; sandbox-check is (veto . reason)
                 (format #f "eval_scheme sandbox denied: ~a"
                         (cdr sandbox-check)))))
         (lambda (key . rest)
           (format #f "Evaluation error: ~a ~a" key rest))))))

  ;; reload_module - Reload a guile module
  (register-tool
   "reload_module"
   "Reload a Guile module to pick up changes"
   '(("type" . "object")
     ("properties" . (("module" . (("type" . "string")
                                   ("description" . "Module name (e.g. sage tools)")))))
     ("required" . #("module")))
   (lambda (args)
     (let ((module-str (assoc-ref args "module")))
       (catch #t
         (lambda ()
           (let* ((module-name (map string->symbol (string-split module-str #\space)))
                  (mod (resolve-module module-name)))
             (reload-module mod)
             (format #f "Reloaded module: ~a" module-name)))
         (lambda (key . rest)
           (format #f "Reload error: ~a ~a" key rest))))))

  ;; create_tool - Dynamically register a new tool
  (register-tool
   "create_tool"
   "Create and register a new tool dynamically"
   '(("type" . "object")
     ("properties" . (("name" . (("type" . "string")
                                 ("description" . "Tool name")))
                      ("description" . (("type" . "string")
                                        ("description" . "Tool description")))
                      ("code" . (("type" . "string")
                                 ("description" . "Scheme code for tool execution function (lambda (args) ...)")))))
     ("required" . #("name" "description" "code")))
   (lambda (args)
     (let ((name (assoc-ref args "name"))
           (desc (assoc-ref args "description"))
           (code (assoc-ref args "code")))
       (catch #t
         (lambda ()
           (let ((fn (eval-string code)))
             (register-tool name desc
                           '(("type" . "object")
                             ("properties" . ())
                             ("required" . #()))
                           fn)
             (format #f "Created tool: ~a" name)))
         (lambda (key . rest)
           (format #f "Error creating tool: ~a ~a" key rest))))))

  ;; ============================================================
  ;; Self-Inspection Tools (Logging)
  ;; ============================================================

  ;; read_logs - Read recent log entries
  (register-tool
   "read_logs"
   "Read recent log entries for self-inspection and debugging"
   '(("type" . "object")
     ("properties" . (("lines" . (("type" . "integer")
                                  ("description" . "Number of lines to read (default 50)")))
                      ("level" . (("type" . "string")
                                  ("description" . "Filter by level: debug|info|warn|error")))))
     ("required" . #()))
   (lambda (args)
     (let ((lines (coerce->int (assoc-ref args "lines") 50))
           (level (assoc-ref args "level")))
       (read-recent-logs #:lines lines
                         #:level (and level (string->symbol level))))))

  ;; search_logs - Search logs for pattern
  (register-tool
   "search_logs"
   "Search logs for a pattern to diagnose issues"
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Search pattern (case-insensitive)")))
                      ("level" . (("type" . "string")
                                  ("description" . "Filter by level: debug|info|warn|error")))
                      ("limit" . (("type" . "integer")
                                  ("description" . "Max results (default 100)")))))
     ("required" . #("pattern")))
   (lambda (args)
     (let ((pattern (assoc-ref args "pattern"))
           (level (assoc-ref args "level"))
           (limit (coerce->int (assoc-ref args "limit") 100)))
       (search-logs pattern
                    #:level (and level (string->symbol level))
                    #:limit limit))))

  ;; log_stats - Log statistics for self-debugging
  (register-safe-tool
   "log_stats"
   "Parse log file and return statistics: message counts by level, error rate, most common tool calls"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (log-stats)))

  ;; log_errors - Recent errors with context
  (register-safe-tool
   "log_errors"
   "Extract and summarize recent errors from the log file with context details"
   '(("type" . "object")
     ("properties" . (("count" . (("type" . "integer")
                                  ("description" . "Number of recent errors to show (default 10)")))))
     ("required" . #()))
   (lambda (args)
     (let ((count (or (assoc-ref args "count") 10)))
       (log-errors #:count count))))

  ;; log_timeline - Event timeline
  (register-safe-tool
   "log_timeline"
   "Show a timeline of events from the log with level markers and tool call annotations"
   '(("type" . "object")
     ("properties" . (("count" . (("type" . "integer")
                                  ("description" . "Number of recent entries to show (default 50)")))
                      ("module" . (("type" . "string")
                                   ("description" . "Filter by module name (e.g. tools, ollama, session)")))))
     ("required" . #()))
   (lambda (args)
     (let ((count (or (assoc-ref args "count") 50))
           (mod (assoc-ref args "module")))
       (log-timeline #:count count
                     #:module-filter mod))))

  ;; log_search_advanced - Multi-criteria log search
  (register-safe-tool
   "log_search_advanced"
   "Search logs with multiple criteria: level, module, message pattern, tool name, and time range"
   '(("type" . "object")
     ("properties" . (("level" . (("type" . "string")
                                  ("description" . "Filter by level: debug|info|warn|error")))
                      ("module" . (("type" . "string")
                                   ("description" . "Filter by module name")))
                      ("message_pattern" . (("type" . "string")
                                            ("description" . "Regex pattern to match in message text")))
                      ("tool" . (("type" . "string")
                                 ("description" . "Filter by tool name in context")))
                      ("from_time" . (("type" . "string")
                                      ("description" . "Start timestamp (ISO 8601 prefix, e.g. 2026-01-25)")))
                      ("to_time" . (("type" . "string")
                                    ("description" . "End timestamp (ISO 8601 prefix, e.g. 2026-01-26)")))
                      ("limit" . (("type" . "integer")
                                  ("description" . "Max results (default 100)")))))
     ("required" . #()))
   (lambda (args)
     (let ((level (assoc-ref args "level"))
           (mod (assoc-ref args "module"))
           (msg-pat (assoc-ref args "message_pattern"))
           (tool (assoc-ref args "tool"))
           (from-t (assoc-ref args "from_time"))
           (to-t (assoc-ref args "to_time"))
           (limit (coerce->int (assoc-ref args "limit") 100)))
       (log-search-advanced #:level level
                            #:module mod
                            #:message-pattern msg-pat
                            #:tool tool
                            #:from-time from-t
                            #:to-time to-t
                            #:limit limit))))

  ;; ============================================================
  ;; Agent Task Tools
  ;; ============================================================

  ;; sage_task_create - Append task to the BACK of the queue (FIFO)
  (register-tool
   "sage_task_create"
   "Append a task to the BACK of the queue (FIFO). Use for independent follow-on work. For sub-tasks that must run BEFORE queued siblings, use sage_task_push."
   '(("type" . "object")
     ("properties" . (("title" . (("type" . "string")
                                  ("description" . "Brief task title")))
                      ("description" . (("type" . "string")
                                        ("description" . "Detailed task description")))))
     ("required" . #("title" "description")))
   (lambda (args)
     (let ((title (assoc-ref args "title"))
           (desc (assoc-ref args "description")))
       (let ((id (task-create title desc)))
         (if id
             (format #f "Task created: ~a - ~a" id title)
             "Failed to create task (is beads available?)")))))

  ;; sage_task_push - Push sub-task onto the FRONT of the queue (LIFO)
  (register-tool
   "sage_task_push"
   "Push a sub-task onto the FRONT of the queue (LIFO). Use when decomposing the current work: the new sub-task runs BEFORE anything else already queued. Ideal for 'first extract X, then summarise' patterns."
   '(("type" . "object")
     ("properties" . (("title" . (("type" . "string")
                                  ("description" . "Brief sub-task title")))
                      ("description" . (("type" . "string")
                                        ("description" . "What to do; may reference scratch sha from a prior fetch_url result")))))
     ("required" . #("title" "description")))
   (lambda (args)
     (let ((title (assoc-ref args "title"))
           (desc (assoc-ref args "description")))
       (let ((id (task-push! title desc)))
         (if id
             (format #f "Sub-task pushed: ~a - ~a" id title)
             "Failed to push sub-task")))))

  ;; scratch_get - Retrieve a window of scratch-stored content by sha
  (register-tool
   "scratch_get"
   "Retrieve a window of content stored in the scratch (e.g. by fetch_url when bytes exceed the inline threshold). Returns up to LEN bytes starting at OFFSET. Use paged retrieval to work through a large body in chunks without blowing the context."
   '(("type" . "object")
     ("properties" . (("sha" . (("type" . "string")
                                ("description" . "sha256 key as reported by fetch_url")))
                      ("offset" . (("type" . "integer")
                                   ("description" . "Byte offset (default 0)")))
                      ("len" . (("type" . "integer")
                                ("description" . "Byte count to return (default 2000)")))))
     ("required" . #("sha")))
   (lambda (args)
     (let* ((sha (assoc-ref args "sha"))
            (offset (or (assoc-ref args "offset") 0))
            (len (or (assoc-ref args "len") 2000))
            (chunk (scratch-get sha #:offset offset #:len len)))
       (if chunk
           chunk
           (format #f "No scratch entry for sha=~a" sha)))))

  ;; scratch_list - Enumerate stored entries (sha + size)
  (register-tool
   "scratch_list"
   "List scratch entries as 'sha: bytes' lines. Useful for agents to rediscover available stored content across tool calls."
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (let ((entries (scratch-list)))
       (if (null? entries)
           "Scratch is empty."
           (string-join
            (map (lambda (e)
                   (format #f "~a: ~a bytes" (car e) (cadr e)))
                 entries)
            "\n")))))

  ;; sage_task_complete - Mark current task complete
  (register-tool
   "sage_task_complete"
   "Mark the current task as complete with a result note"
   '(("type" . "object")
     ("properties" . (("result" . (("type" . "string")
                                   ("description" . "Result or completion note")))))
     ("required" . #("result")))
   (lambda (args)
     (let ((result (assoc-ref args "result")))
       (let ((id (task-complete result)))
         (if id
             (format #f "Task completed: ~a" id)
             "No current task to complete")))))

  ;; sage_task_list - List pending tasks
  (register-tool
   "sage_task_list"
   "List all pending sage agent tasks"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (let ((tasks (task-list)))
       (if (null? tasks)
           "No pending tasks"
           (string-join
            (map (lambda (t)
                   (format #f "~a: ~a" (car t) (cdr t)))
                 tasks)
            "\n")))))

  ;; sage_task_status - Get agent status
  (register-tool
   "sage_task_status"
   "Get current agent status including mode, tasks, and iteration count"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (format-task-status)))

  ;; ============================================================
  ;; Identity Tools
  ;; ============================================================

  ;; whoami - Agent identity introspection
  (register-safe-tool
   "whoami"
   "Return agent identity and capabilities for self-awareness"
   '(("type" . "object")
     ("properties" . ())
     ("required" . #()))
   (lambda (args)
     (string-append
      "Name: Sage\n"
      "System: guile-sage (Guile Scheme AI agent framework)\n"
      "Role: Autonomous software engineering agent\n"
      "IRC: SageNet (#sage-agents, #sage-tasks, #sage-debug) -- optional\n"
      "Workspace: " (workspace) "\n"
      "Tools: " (number->string (length *tools*)) " registered\n"
      "Mode: " (symbol->string (agent-mode)))))

  ;; irc_send - Only register when IRC is enabled (avoids the model
  ;; wasting a tool call on a guaranteed failure every time)
  (when (irc-connected?)
    (register-safe-tool
     "irc_send"
     "Send a message to an IRC channel on SageNet"
     '(("type" . "object")
       ("properties" . (("channel" . (("type" . "string")
                                      ("description" . "Channel name (e.g. #sage-agents)")))
                        ("message" . (("type" . "string")
                                      ("description" . "Message to send")))))
       ("required" . #("channel" "message")))
     (lambda (args)
       (let ((channel (assoc-ref args "channel"))
             (message (assoc-ref args "message")))
         (irc-send channel message)
         (format #f "Sent to ~a: ~a" channel message)))))

  ;; ============================================================
  ;; Image Generation Tools
  ;; ============================================================

  ;; generate_image - Generate image via Ollama
  (register-safe-tool
   "generate_image"
   "Generate an image from a text prompt using Ollama image model. Supports optional width, height, and steps parameters."
   '(("type" . "object")
     ("properties" . (("prompt" . (("type" . "string")
                                   ("description" . "Text description of the image to generate")))
                      ("filename" . (("type" . "string")
                                     ("description" . "Output filename without extension (defaults to timestamp)")))
                      ("width" . (("type" . "integer")
                                  ("description" . "Image width in pixels (default: model default, typically 1024)")))
                      ("height" . (("type" . "integer")
                                   ("description" . "Image height in pixels (default: model default, typically 1024)")))
                      ("steps" . (("type" . "integer")
                                  ("description" . "Number of diffusion steps (higher = better quality, slower)")))))
     ("required" . #("prompt")))
   (lambda (args)
     (let* ((prompt (assoc-ref args "prompt"))
            (filename (or (assoc-ref args "filename")
                          (format #f "image-~a" (car (gettimeofday)))))
            (width (assoc-ref args "width"))
            (height (assoc-ref args "height"))
            (steps (assoc-ref args "steps"))
            (output-dir (string-append (workspace) "/output"))
            (output-path (string-append output-dir "/" filename ".png")))
       ;; Ensure output directory exists
       (unless (file-exists? output-dir)
         (mkdir output-dir))
       (catch #t
         (lambda ()
           (ollama-generate-image prompt output-path
                                  #:width width #:height height #:steps steps)
           (format #f "Saved to output/~a.png" filename))
         (lambda (key . rest)
           (format #f "Image generation error: ~a ~a" key rest)))))))
