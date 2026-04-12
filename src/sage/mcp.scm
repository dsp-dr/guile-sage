;;; mcp.scm --- MCP (Model Context Protocol) SSE client -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Fail-soft MCP client for guile-sage. Connects to SSE-based MCP servers
;; (discovered from ~/.claude.json), performs the initialize handshake,
;; discovers tools via tools/list, and registers them into sage's tool
;; registry so the LLM can invoke them.
;;
;; Public API:
;;   (mcp-init)                          ; connect to configured servers
;;   (mcp-enabled?)                      ; #t if any server connected
;;   (mcp-call-tool server tool args)    ; invoke a tool via JSON-RPC
;;   (mcp-shutdown!)                     ; clean up connections
;;
;; Transport: HTTP GET with streaming for SSE, HTTP POST for JSON-RPC.
;; The SSE and POST paths are separate TCP connections; correlation is
;; by JSON-RPC id. See docs/MCP-CONTRACT.org for invariants I01-I23.
;;
;; Failure mode: any error (network, timeout, parse) is logged at WARN
;; and swallowed. MCP must never crash the REPL.

(define-module (sage mcp)
  #:use-module (web client)
  #:use-module (web uri)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 format)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 popen)
  #:use-module (srfi srfi-1)
  #:use-module (sage util)
  #:use-module (sage logging)
  #:use-module (sage config)
  #:use-module (sage version)
  #:use-module (sage telemetry)
  #:use-module (sage tools)
  #:export (mcp-init
            mcp-enabled?
            mcp-call-tool
            mcp-shutdown!
            ;; Exposed for tests
            mcp-server-reachable?
            *mcp-servers*
            *mcp-next-id*
            mcp-next-id!
            mcp-make-request
            mcp-make-notification
            sse-parse-lines
            mcp-read-claude-json
            mcp-extract-sse-servers
            mcp-register-tools-from-list))

;;; ============================================================
;;; State
;;; ============================================================

;; Alist of server-name -> server-state. Each server-state is an alist:
;;   ("name" . "skills-hub")
;;   ("url" . "http://...")
;;   ("headers" . (("Authorization" . "Bearer ...")))
;;   ("endpoint" . "http://...?session_id=...")  ; POST URL, set after SSE connect
;;   ("sse-port" . <port>)                       ; streaming GET body port
;;   ("connected" . #t/#f)
;;   ("server-info" . <alist>)                   ; from initialize response
;;   ("capabilities" . <alist>)                  ; from initialize response
(define *mcp-servers* '())

;; Monotonically-increasing JSON-RPC id counter
(define *mcp-next-id* 0)

;;; ============================================================
;;; JSON-RPC envelope construction (pure, no I/O)
;;; ============================================================

(define (mcp-next-id!)
  "Allocate and return the next JSON-RPC request id."
  (set! *mcp-next-id* (1+ *mcp-next-id*))
  *mcp-next-id*)

(define (mcp-make-request method params)
  "Build a JSON-RPC 2.0 request envelope with auto-allocated id.
Returns (values id json-string)."
  (let ((id (mcp-next-id!)))
    (values id
            (json-write-string
             `(("jsonrpc" . "2.0")
               ("id" . ,id)
               ("method" . ,method)
               ("params" . ,params))))))

(define (mcp-make-notification method params)
  "Build a JSON-RPC 2.0 notification (no id, no response expected)."
  (json-write-string
   `(("jsonrpc" . "2.0")
     ("method" . ,method)
     ("params" . ,params))))

;;; ============================================================
;;; SSE line parser (pure, no I/O)
;;; ============================================================

(define (sse-parse-lines lines)
  "Parse a list of SSE lines into an alist with keys 'event and 'data.
SSE protocol: 'event:' sets event type, 'data:' sets payload,
':' prefix is a comment (dropped), empty line terminates the event.
Returns: alist ((\"event\" . <type>) (\"data\" . <payload>)) or #f if no event."
  (let loop ((lines lines)
             (event #f)
             (data #f))
    (if (null? lines)
        ;; End of lines — return accumulated event if any
        (if (or event data)
            `(("event" . ,(or event "message"))
              ("data" . ,(or data "")))
            #f)
        (let ((line (car lines)))
          (cond
           ;; Comment line (I04)
           ((and (> (string-length line) 0)
                 (char=? (string-ref line 0) #\:))
            (loop (cdr lines) event data))
           ;; Empty line — event delimiter
           ((string-null? (string-trim-both line))
            (if (or event data)
                `(("event" . ,(or event "message"))
                  ("data" . ,(or data "")))
                (loop (cdr lines) #f #f)))
           ;; event: line
           ((string-prefix? "event:" line)
            (let ((val (string-trim-both (substring line 6))))
              (loop (cdr lines) val data)))
           ((string-prefix? "event: " line)
            (let ((val (string-trim-both (substring line 7))))
              (loop (cdr lines) val data)))
           ;; data: line
           ((string-prefix? "data:" line)
            (let ((val (if (and (> (string-length line) 5)
                                (char=? (string-ref line 5) #\space))
                           (substring line 6)
                           (substring line 5))))
              ;; If we already have data, append with newline (multi-line data)
              (loop (cdr lines) event
                    (if data (string-append data "\n" val) val))))
           ;; Unknown field — skip
           (else
            (loop (cdr lines) event data)))))))

;;; ============================================================
;;; Config discovery
;;; ============================================================

(define (mcp-read-claude-json)
  "Read ~/.claude.json and return the parsed alist, or #f on failure."
  (let ((path (string-append (getenv "HOME") "/.claude.json")))
    (catch #t
      (lambda ()
        (if (file-exists? path)
            (json-read-string (call-with-input-file path get-string-all))
            #f))
      (lambda (key . args)
        (log-warn "mcp" (format #f "Failed to read ~/.claude.json: ~a ~a" key args))
        #f))))

(define (mcp-extract-sse-servers config)
  "Extract SSE MCP servers from a parsed ~/.claude.json config.
Returns a list of alists, each with keys: name, url, headers."
  (if (not config)
      '()
      (let ((servers (assoc-ref config "mcpServers")))
        (if (not servers)
            '()
            (filter-map
             (lambda (entry)
               (let* ((name (car entry))
                      (spec (cdr entry))
                      (url (and (list? spec) (assoc-ref spec "url")))
                      (stype (and (list? spec) (assoc-ref spec "type")))
                      (hdrs (and (list? spec) (assoc-ref spec "headers"))))
                 ;; Only SSE servers (type=sse or has url without command)
                 (if (and url
                          (string? url)
                          (or (equal? stype "sse")
                              (not (and (list? spec) (assoc-ref spec "command")))))
                     `(("name" . ,name)
                       ("url" . ,url)
                       ("headers" . ,(if (and hdrs (list? hdrs))
                                         hdrs
                                         '())))
                     #f)))
             (if (list? servers) servers '()))))))

;;; ============================================================
;;; SSE connection (blocking I/O)
;;; ============================================================

(define* (sse-open-connection url headers #:key (timeout 5))
  "Open a streaming GET to an SSE endpoint via curl + FIFO.
Guile's native (web client) rejects Accept: text/event-stream (bad
MIME type in header validator). Guile's open-input-pipe is broken on
macOS (Bad file descriptor in execvp). So we create a FIFO (named
pipe), run curl in the background writing to it, and return an
open-input-file port on the FIFO for line-by-line SSE reading.
Returns an input port for the SSE stream, or #f on failure.
The caller reads SSE events from this port via sse-read-event."
  (catch #t
    (lambda ()
      (let* ((fifo-path (format #f "/tmp/sage-sse-~a" (getpid)))
             ;; Clean up any stale FIFO from a previous crash
             (_ (when (file-exists? fifo-path)
                  (delete-file fifo-path)))
             (_ (system (format #f "mkfifo '~a'" fifo-path)))
             (header-args
              (string-join
               (cons "-H 'Accept: text/event-stream'"
                     (map (lambda (h)
                            (format #f "-H '~a: ~a'" (car h) (cdr h)))
                          headers))
               " "))
             ;; Run curl in background writing to the FIFO.
             ;; -s: silent, -N: no-buffer (stream immediately).
             ;; The & backgrounds it so we can open the FIFO for reading.
             (cmd (format #f "curl -sN --connect-timeout ~a ~a '~a' > '~a' &"
                          timeout header-args url fifo-path)))
        (system cmd)
        ;; open-input-file blocks until curl starts writing to the FIFO.
        ;; This is the correct behaviour — it synchronizes the reader
        ;; with the writer without polling.
        (let ((port (open-input-file fifo-path)))
          (log-info "mcp" (format #f "SSE FIFO opened for ~a at ~a" url fifo-path))
          port)))
    (lambda (key . args)
      (log-warn "mcp" (format #f "SSE connection failed for ~a: ~a ~a"
                              url key args))
      #f)))

(define (sse-read-event port)
  "Read the next SSE event from a streaming port.
Returns an alist with 'event and 'data keys, or #f on EOF/error."
  (catch #t
    (lambda ()
      (let loop ((lines '()))
        (let ((line (read-line port)))
          (if (eof-object? line)
              ;; EOF — try to parse whatever we accumulated
              (if (null? lines)
                  #f
                  (sse-parse-lines (reverse lines)))
              (let ((trimmed (string-trim-right line #\return)))
                (if (string-null? trimmed)
                    ;; Empty line = event delimiter
                    (if (null? lines)
                        (loop '())  ; skip leading blank lines
                        (sse-parse-lines (reverse lines)))
                    (loop (cons trimmed lines))))))))
    (lambda (key . args)
      (log-warn "mcp" (format #f "SSE read error: ~a ~a" key args))
      #f)))

(define (sse-read-endpoint-event port base-url)
  "Read SSE events until we get the 'endpoint' event.
Returns the full POST URL or #f on failure.
Skips comment-only and ping events per I04."
  (let loop ((attempts 0))
    (if (> attempts 50)  ; safety valve
        (begin
          (log-warn "mcp" "No endpoint event received after 50 reads")
          #f)
        (let ((event (sse-read-event port)))
          (if (not event)
              #f
              (let ((etype (assoc-ref event "event"))
                    (edata (assoc-ref event "data")))
                (if (equal? etype "endpoint")
                    ;; Construct POST URL: base origin + data path (I03)
                    (let* ((uri (string->uri base-url))
                           (scheme (uri-scheme uri))
                           (host (uri-host uri))
                           (port-num (uri-port uri))
                           (origin (if port-num
                                       (format #f "~a://~a:~a" scheme host port-num)
                                       (format #f "~a://~a" scheme host))))
                      (string-append origin edata))
                    ;; Not endpoint — keep reading
                    (loop (1+ attempts)))))))))

;;; ============================================================
;;; JSON-RPC POST (blocking I/O, uses util.scm)
;;; ============================================================

(define* (mcp-post endpoint body headers #:key (timeout 10))
  "POST a JSON-RPC body to the endpoint URL with auth headers.
Returns (code . body-string) pair. I06: always sends Content-Type + Auth."
  (http-post-with-timeout endpoint body timeout
                          #:headers headers))

;;; ============================================================
;;; SSE response reader — waits for a specific JSON-RPC id
;;; ============================================================

(define* (sse-wait-for-response port target-id #:key (timeout-seconds 60))
  "Read SSE events until we find a JSON-RPC response matching target-id.
Returns the parsed JSON-RPC result alist, or #f on timeout/error.
Implements I09 (match by id) and I12 (timeout)."
  (let ((deadline (+ (car (gettimeofday)) timeout-seconds)))
    (let loop ()
      (if (> (car (gettimeofday)) deadline)
          (begin
            (log-warn "mcp"
                      (format #f "Timeout waiting for response id=~a" target-id))
            #f)
          (let ((event (sse-read-event port)))
            (if (not event)
                #f  ; EOF or error
                (let ((etype (assoc-ref event "event"))
                      (edata (assoc-ref event "data")))
                  (if (equal? etype "message")
                      ;; Try to parse as JSON-RPC
                      (catch #t
                        (lambda ()
                          (let* ((envelope (json-read-string edata))
                                 (eid (assoc-ref envelope "id")))
                            (if (eqv? eid target-id)
                                envelope
                                ;; Wrong id — log and continue (late response)
                                (begin
                                  (log-warn "mcp"
                                            (format #f "Unexpected id ~a (want ~a)"
                                                    eid target-id))
                                  (loop)))))
                        (lambda (key . args)
                          ;; Malformed JSON in SSE data — skip
                          (log-warn "mcp"
                                    (format #f "Bad JSON in SSE data: ~a" key))
                          (loop)))
                      ;; Not a message event — skip (ping, etc.)
                      (loop)))))))))

;;; ============================================================
;;; MCP lifecycle — connect, initialize, discover tools
;;; ============================================================

(define (mcp-connect-server! server-spec)
  "Connect to a single MCP server. Returns updated server-state or #f."
  (let* ((name (assoc-ref server-spec "name"))
         (url (assoc-ref server-spec "url"))
         (headers (or (assoc-ref server-spec "headers") '())))
    (log-info "mcp" (format #f "Connecting to MCP server: ~a at ~a" name url))

    ;; Step 1: Open SSE connection
    (let ((sse-port (sse-open-connection url headers)))
      (if (not sse-port)
          (begin
            (log-warn "mcp" (format #f "Failed to connect SSE to ~a" name))
            #f)

          ;; Step 2: Read endpoint event (I02)
          (let ((endpoint (sse-read-endpoint-event sse-port url)))
            (if (not endpoint)
                (begin
                  (log-warn "mcp" (format #f "No endpoint event from ~a" name))
                  (when (port? sse-port) (close-port sse-port))
                  #f)

                ;; Step 3: Initialize handshake (I13, I14)
                (let ((init-result (mcp-do-initialize! endpoint sse-port headers)))
                  (if (not init-result)
                      (begin
                        (log-warn "mcp"
                                  (format #f "Initialize failed for ~a" name))
                        (when (port? sse-port) (close-port sse-port))
                        #f)

                      ;; Step 4: Send notifications/initialized (I16)
                      (begin
                        (mcp-do-initialized-notification! endpoint headers)

                        ;; Build server state
                        (let* ((server-info
                                (assoc-ref (assoc-ref init-result "result")
                                           "serverInfo"))
                               (capabilities
                                (assoc-ref (assoc-ref init-result "result")
                                           "capabilities"))
                               (state
                                `(("name" . ,name)
                                  ("url" . ,url)
                                  ("headers" . ,headers)
                                  ("endpoint" . ,endpoint)
                                  ("sse-port" . ,sse-port)
                                  ("connected" . #t)
                                  ("server-info" . ,(or server-info '()))
                                  ("capabilities" . ,(or capabilities '())))))
                          (log-info "mcp"
                                    (format #f "Connected to ~a (server: ~a)"
                                            name
                                            (and server-info
                                                 (assoc-ref server-info "name"))))
                          state))))))))))

(define (mcp-do-initialize! endpoint sse-port headers)
  "Send initialize request and wait for response. Returns envelope or #f."
  (receive (id body)
      (mcp-make-request "initialize"
                        `(("protocolVersion" . "2024-11-05")
                          ("capabilities" . (("sampling" . ,json-empty-object)))
                          ("clientInfo" . (("name" . "guile-sage")
                                           ("version" . ,(version-string))))))
    (let ((result (mcp-post endpoint body headers #:timeout 10)))
      (if (and (pair? result) (= 202 (car result)))
          ;; Wait for SSE response
          (sse-wait-for-response sse-port id #:timeout-seconds 10)
          (begin
            (log-warn "mcp"
                      (format #f "Initialize POST failed: ~a"
                              (if (pair? result) (car result) result)))
            #f)))))

(define (mcp-do-initialized-notification! endpoint headers)
  "Send notifications/initialized (fire-and-forget). I16."
  (let ((body (mcp-make-notification "notifications/initialized"
                                     json-empty-object)))
    (catch #t
      (lambda ()
        (mcp-post endpoint body headers #:timeout 5))
      (lambda (key . args)
        (log-warn "mcp"
                  (format #f "initialized notification failed: ~a" key))))))

;;; ============================================================
;;; Tool discovery
;;; ============================================================

(define (mcp-discover-tools! server-state)
  "Send tools/list and return the list of tool descriptors, or '()."
  (let ((endpoint (assoc-ref server-state "endpoint"))
        (sse-port (assoc-ref server-state "sse-port"))
        (headers (assoc-ref server-state "headers"))
        (capabilities (assoc-ref server-state "capabilities")))

    ;; I17: only call tools/list if server advertises tools capability
    (if (and capabilities
             (not (assoc-ref capabilities "tools")))
        (begin
          (log-info "mcp" "Server does not advertise tools capability")
          '())

        ;; Send tools/list
        (receive (id body)
            (mcp-make-request "tools/list" json-empty-object)
          (let ((result (mcp-post endpoint body headers #:timeout 10)))
            (if (and (pair? result) (= 202 (car result)))
                ;; Wait for SSE response
                (let ((envelope (sse-wait-for-response sse-port id
                                                       #:timeout-seconds 15)))
                  (if envelope
                      (let ((result-obj (assoc-ref envelope "result")))
                        (if result-obj
                            (as-list (assoc-ref result-obj "tools"))
                            '()))
                      '()))
                (begin
                  (log-warn "mcp"
                            (format #f "tools/list POST failed: ~a"
                                    (if (pair? result) (car result) result)))
                  '())))))))

;;; ============================================================
;;; Tool registration — bridge MCP tools into sage's tool registry
;;; ============================================================

(define (mcp-register-tools-from-list server-name tools)
  "Register a list of MCP tool descriptors into sage's tool registry.
Each tool gets a namespaced name: <server-name>.<tool-name>.
Also registers under the bare tool name if no collision with local tools."
  (let ((count 0))
    (for-each
     (lambda (tool-desc)
       (let* ((tool-name (assoc-ref tool-desc "name"))
              (description (or (assoc-ref tool-desc "description")
                               (format #f "MCP tool: ~a" tool-name)))
              (input-schema (or (assoc-ref tool-desc "inputSchema")
                                '(("type" . "object")
                                  ("properties" . (("query" . (("type" . "string"))))))))
              ;; Namespaced name (I22)
              (ns-name (format #f "~a.~a" server-name tool-name))
              ;; Execute lambda — calls mcp-call-tool
              (exec-fn (lambda (args)
                         (mcp-call-tool server-name tool-name args))))

         ;; Register namespaced version
         (register-tool ns-name
                        (format #f "[~a] ~a" server-name description)
                        input-schema
                        exec-fn)

         ;; Also register bare name if no collision (I22)
         (unless (get-tool tool-name)
           (register-tool tool-name description input-schema exec-fn))

         (set! count (1+ count))))
     (as-list tools))
    (log-info "mcp"
              (format #f "Registered ~a tools from server ~a" count server-name))
    count))

;;; ============================================================
;;; Tool execution via JSON-RPC
;;; ============================================================

(define (mcp-call-tool server-name tool-name args)
  "Invoke a tool on an MCP server via JSON-RPC tools/call.
Returns the tool result text, or an error string."
  (let ((server (assoc-ref *mcp-servers* server-name)))
    (if (not server)
        (format #f "MCP server not connected: ~a" server-name)
        (let ((endpoint (assoc-ref server "endpoint"))
              (sse-port (assoc-ref server "sse-port"))
              (headers (assoc-ref server "headers")))
          (catch #t
            (lambda ()
              ;; Telemetry
              (inc-counter! "guile_sage.mcp.tool_call"
                            `(("server" . ,server-name)
                              ("tool_name" . ,tool-name))
                            1)

              ;; Build and send tools/call request
              (receive (id body)
                  (mcp-make-request "tools/call"
                                    `(("name" . ,tool-name)
                                      ("arguments" . ,(or args
                                                          json-empty-object))))
                (let ((result (mcp-post endpoint body headers #:timeout 10)))
                  (if (and (pair? result) (= 202 (car result)))
                      ;; Wait for response (I12: timeout)
                      (let ((envelope (sse-wait-for-response sse-port id
                                                             #:timeout-seconds 60)))
                        (if envelope
                            (mcp-extract-tool-result envelope)
                            "MCP tool call timed out"))
                      (format #f "MCP POST failed with status ~a"
                              (if (pair? result) (car result) "unknown"))))))
            (lambda (key . rest)
              (log-warn "mcp"
                        (format #f "MCP tool call error: ~a ~a" key rest))
              (format #f "MCP tool error: ~a ~a" key rest)))))))

(define (mcp-extract-tool-result envelope)
  "Extract tool result text from a JSON-RPC response envelope.
Handles both result.content (I20 path 2) and error (I20 path 1)."
  ;; Check for JSON-RPC error field first
  (let ((error-obj (assoc-ref envelope "error")))
    (if error-obj
        (format #f "MCP RPC error ~a: ~a"
                (or (assoc-ref error-obj "code") "?")
                (or (assoc-ref error-obj "message") "unknown"))
        ;; Check result
        (let ((result-obj (assoc-ref envelope "result")))
          (if (not result-obj)
              "MCP: no result in response"
              (let* ((is-error (assoc-ref result-obj "isError"))
                     (content (as-list (assoc-ref result-obj "content")))
                     ;; Flatten content[].text (I21)
                     (texts (filter-map
                             (lambda (block)
                               (and (list? block)
                                    (equal? (assoc-ref block "type") "text")
                                    (assoc-ref block "text")))
                             content))
                     (result-text (if (null? texts)
                                      ""
                                      (string-join texts "\n"))))
                (if (eq? is-error #t)
                    (format #f "MCP tool error: ~a" result-text)
                    result-text)))))))

;;; ============================================================
;;; Public API
;;; ============================================================

(define (mcp-enabled?)
  "Return #t if at least one MCP server is connected."
  (any (lambda (entry)
         (and (pair? entry)
              (let ((state (cdr entry)))
                (and (list? state)
                     (eq? #t (assoc-ref state "connected"))))))
       *mcp-servers*))

(define (mcp-server-reachable?)
  "Quick check if the default MCP server is network-reachable.
Used to guard live integration tests. Uses curl with a short timeout
to avoid hanging on the SSE long-lived connection."
  (catch #t
    (lambda ()
      (let* ((cmd "curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer andhbHNoQG1pbmk6bm9uZTpub25l' -H 'Accept: text/event-stream' http://192.168.86.100:8400/sse")
             (pipe (open-input-pipe cmd))
             (output (get-string-all pipe)))
        (close-pipe pipe)
        (equal? (string-trim-both output) "200")))
    (lambda (key . args) #f)))

(define (mcp-init)
  "Discover MCP servers from ~/.claude.json and connect to SSE servers.
Fail-soft: logs warnings and continues if anything goes wrong."
  (catch #t
    (lambda ()
      (let* ((config (mcp-read-claude-json))
             (server-specs (mcp-extract-sse-servers config)))
        (if (null? server-specs)
            (log-info "mcp" "No SSE MCP servers configured in ~/.claude.json")
            (begin
              (log-info "mcp"
                        (format #f "Found ~a SSE MCP server(s) in config"
                                (length server-specs)))
              (for-each
               (lambda (spec)
                 (catch #t
                   (lambda ()
                     (let ((state (mcp-connect-server! spec)))
                       (when state
                         (let ((name (assoc-ref state "name")))
                           ;; Store in *mcp-servers*
                           (set! *mcp-servers*
                                 (cons (cons name state)
                                       (filter (lambda (e)
                                                 (not (equal? (car e) name)))
                                               *mcp-servers*)))
                           ;; Discover and register tools
                           (let ((tools (mcp-discover-tools! state)))
                             (when (and tools (not (null? tools)))
                               (mcp-register-tools-from-list name tools)))))))
                   (lambda (key . args)
                     (log-warn "mcp"
                               (format #f "Failed to connect to ~a: ~a ~a"
                                       (assoc-ref spec "name") key args)))))
               server-specs)))))
    (lambda (key . args)
      (log-warn "mcp" (format #f "MCP init failed: ~a ~a" key args)))))

(define (mcp-shutdown!)
  "Clean up all MCP server connections."
  (for-each
   (lambda (entry)
     (catch #t
       (lambda ()
         (let* ((state (cdr entry))
                (sse-port (and (list? state) (assoc-ref state "sse-port"))))
           (when (and sse-port (port? sse-port) (not (port-closed? sse-port)))
             (close-port sse-port))))
       (lambda (key . args) #f)))
   *mcp-servers*)
  (set! *mcp-servers* '())
  (log-info "mcp" "MCP connections shut down"))
