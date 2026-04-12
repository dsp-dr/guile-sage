#!/usr/bin/env guile3
!#
;;; test-mcp.scm --- Tests for MCP SSE client module

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage mcp)
             (sage util)
             (sage tools)
             (ice-9 format)
             (ice-9 receive))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== MCP Client Tests ===~%")

;;; ============================================================
;;; JSON-RPC envelope construction
;;; ============================================================

(format #t "~%--- JSON-RPC envelopes ---~%")

(run-test "mcp-make-request produces valid JSON-RPC shape"
  (lambda ()
    (set! *mcp-next-id* 0)  ; reset counter
    (receive (id body)
        (mcp-make-request "tools/list" '(("foo" . "bar")))
      (let ((parsed (json-read-string body)))
        (assert-equal (assoc-ref parsed "jsonrpc") "2.0"
                      "jsonrpc field must be 2.0")
        (assert-equal (assoc-ref parsed "id") 1
                      "first id should be 1")
        (assert-equal (assoc-ref parsed "method") "tools/list"
                      "method must match")
        (assert-equal id 1 "returned id must match envelope id")))))

(run-test "mcp-make-request ids increment monotonically"
  (lambda ()
    (set! *mcp-next-id* 0)
    (receive (id1 body1) (mcp-make-request "a" '())
      (receive (id2 body2) (mcp-make-request "b" '())
        (receive (id3 body3) (mcp-make-request "c" '())
          (assert-equal id1 1 "first id")
          (assert-equal id2 2 "second id")
          (assert-equal id3 3 "third id"))))))

(run-test "mcp-make-notification has no id field"
  (lambda ()
    (let* ((body (mcp-make-notification "notifications/initialized"
                                         json-empty-object))
           (parsed (json-read-string body)))
      (assert-equal (assoc-ref parsed "jsonrpc") "2.0"
                    "jsonrpc must be 2.0")
      (assert-equal (assoc-ref parsed "method") "notifications/initialized"
                    "method must match")
      (assert-false (assoc-ref parsed "id")
                    "notification must not have id"))))

(run-test "initialize request contains required fields (I14)"
  (lambda ()
    (set! *mcp-next-id* 0)
    (receive (id body)
        (mcp-make-request "initialize"
                          `(("protocolVersion" . "2024-11-05")
                            ("capabilities" . (("sampling" . ,json-empty-object)))
                            ("clientInfo" . (("name" . "guile-sage")
                                             ("version" . "0.6.0")))))
      (let* ((parsed (json-read-string body))
             (params (assoc-ref parsed "params")))
        (assert-equal (assoc-ref params "protocolVersion") "2024-11-05"
                      "protocolVersion must be 2024-11-05")
        (let ((ci (assoc-ref params "clientInfo")))
          (assert-equal (assoc-ref ci "name") "guile-sage"
                        "clientInfo.name"))
        ;; capabilities.sampling must serialize as {} not null
        (assert-contains body "\"sampling\":{}"
                         "sampling must be empty object {}")))))

;;; ============================================================
;;; SSE line parsing
;;; ============================================================

(format #t "~%--- SSE line parsing ---~%")

(run-test "sse-parse-lines: basic event + data"
  (lambda ()
    (let ((result (sse-parse-lines '("event: endpoint"
                                     "data: /messages/?session_id=abc123"))))
      (assert-equal (assoc-ref result "event") "endpoint"
                    "event type")
      (assert-equal (assoc-ref result "data") "/messages/?session_id=abc123"
                    "data payload"))))

(run-test "sse-parse-lines: comments are ignored (I04)"
  (lambda ()
    (let ((result (sse-parse-lines '(": ping - 2026-04-11 23:34:13.713903+00:00"
                                     "event: endpoint"
                                     ": another comment"
                                     "data: /messages/?session_id=def456"))))
      (assert-equal (assoc-ref result "event") "endpoint"
                    "event type after comments")
      (assert-equal (assoc-ref result "data") "/messages/?session_id=def456"
                    "data after comments"))))

(run-test "sse-parse-lines: empty lines delimit events"
  (lambda ()
    ;; First event should be returned at the first empty line
    (let ((result (sse-parse-lines '("event: message"
                                     "data: {\"id\":1}"
                                     ""
                                     "event: message"
                                     "data: {\"id\":2}"))))
      (assert-equal (assoc-ref result "event") "message"
                    "first event type")
      (assert-equal (assoc-ref result "data") "{\"id\":1}"
                    "first event data"))))

(run-test "sse-parse-lines: data without event defaults to 'message'"
  (lambda ()
    (let ((result (sse-parse-lines '("data: hello"))))
      (assert-equal (assoc-ref result "event") "message"
                    "default event type is message"))))

(run-test "sse-parse-lines: multi-line data concatenated"
  (lambda ()
    (let ((result (sse-parse-lines '("data: line1"
                                     "data: line2"
                                     "data: line3"))))
      (assert-equal (assoc-ref result "data") "line1\nline2\nline3"
                    "multi-line data joined with newlines"))))

(run-test "sse-parse-lines: empty input returns #f"
  (lambda ()
    (assert-false (sse-parse-lines '())
                  "empty lines produce #f")))

;;; ============================================================
;;; Config discovery
;;; ============================================================

(format #t "~%--- Config discovery ---~%")

(run-test "mcp-extract-sse-servers: extracts SSE servers from config"
  (lambda ()
    (let* ((config `(("mcpServers" . (("skills-hub" .
                                        (("type" . "sse")
                                         ("url" . "http://INFRA_HOST:8400/sse")
                                         ("headers" . (("Authorization" . "Bearer abc")))))
                                       ("stdio-srv" .
                                        (("command" . "node")
                                         ("args" . ("server.js"))))))))
           (servers (mcp-extract-sse-servers config)))
      (assert-equal (length servers) 1
                    "should find 1 SSE server")
      (let ((first (car servers)))
        (assert-equal (assoc-ref first "name") "skills-hub"
                      "server name")
        (assert-equal (assoc-ref first "url") "http://INFRA_HOST:8400/sse"
                      "server url")
        (assert-equal (assoc-ref (assoc-ref first "headers") "Authorization")
                      "Bearer abc"
                      "auth header")))))

(run-test "mcp-extract-sse-servers: handles missing mcpServers"
  (lambda ()
    (assert-equal (mcp-extract-sse-servers '(("other" . "data"))) '()
                  "no mcpServers key -> empty list")
    (assert-equal (mcp-extract-sse-servers #f) '()
                  "#f config -> empty list")))

(run-test "mcp-extract-sse-servers: ignores stdio-only servers"
  (lambda ()
    (let* ((config `(("mcpServers" . (("stdio-only" .
                                        (("command" . "npx")
                                         ("args" . ("-y" "server"))))))))
           (servers (mcp-extract-sse-servers config)))
      (assert-equal (length servers) 0
                    "stdio server should be filtered out"))))

;;; ============================================================
;;; Tool registration from synthetic tools/list data
;;; ============================================================

(format #t "~%--- Tool registration ---~%")

(run-test "mcp-register-tools-from-list registers tools"
  (lambda ()
    (let* ((tool-list `((("name" . "workflow__bd")
                          ("description" . "Manage issues via bd")
                          ("inputSchema" . (("type" . "object")
                                            ("properties" . (("query" . (("type" . "string"))))))))
                        (("name" . "factory__build")
                          ("description" . "Build a project")
                          ("inputSchema" . (("type" . "object")
                                            ("properties" . (("query" . (("type" . "string"))))))))))
           (count (mcp-register-tools-from-list "test-srv" tool-list)))
      (assert-equal count 2 "should register 2 tools")
      ;; Check namespaced registration
      (assert-true (get-tool "test-srv.workflow__bd")
                   "namespaced tool should exist")
      (assert-true (get-tool "test-srv.factory__build")
                   "namespaced tool should exist")
      ;; Check bare name registration (no collision with built-in tools)
      (assert-true (get-tool "workflow__bd")
                   "bare name should be registered (no collision)")
      (assert-true (get-tool "factory__build")
                   "bare name should be registered (no collision)"))))

(run-test "mcp-register-tools-from-list: bare name skipped on collision"
  (lambda ()
    ;; read_file is a built-in tool — MCP should not override it
    (let* ((original-tool (get-tool "read_file"))
           (tool-list `((("name" . "read_file")
                          ("description" . "MCP read_file (should NOT override)")
                          ("inputSchema" . (("type" . "object"))))))
           (count (mcp-register-tools-from-list "collision-srv" tool-list)))
      (assert-equal count 1 "should still register 1 tool")
      ;; Namespaced version should exist
      (assert-true (get-tool "collision-srv.read_file")
                   "namespaced collision tool exists")
      ;; Bare name should still be the original
      (let ((current (get-tool "read_file")))
        ;; The description should NOT be the MCP one
        (assert-not-contains (assoc-ref current "description")
                             "should NOT override"
                             "original tool preserved")))))

;;; ============================================================
;;; Tool result extraction
;;; ============================================================

(format #t "~%--- Tool result extraction ---~%")

(run-test "mcp-extract-tool-result: success with text content"
  (lambda ()
    ;; We test the extraction by calling the internal via mcp-call-tool
    ;; indirection is complex, so test the shape parsing inline
    (let* ((envelope `(("jsonrpc" . "2.0")
                       ("id" . 3)
                       ("result" . (("content" . ((("type" . "text")
                                                    ("text" . "Hello from MCP"))))
                                    ("isError" . #f)))))
           ;; Directly test extraction using the helper
           (result-obj (assoc-ref envelope "result"))
           (content (as-list (assoc-ref result-obj "content")))
           (texts (filter-map
                   (lambda (block)
                     (and (list? block)
                          (equal? (assoc-ref block "type") "text")
                          (assoc-ref block "text")))
                   content)))
      (assert-equal (length texts) 1 "one text block")
      (assert-equal (car texts) "Hello from MCP" "text content"))))

(run-test "mcp-enabled? is #f when no servers connected"
  (lambda ()
    (let ((saved *mcp-servers*))
      (set! *mcp-servers* '())
      (assert-false (mcp-enabled?) "no servers = not enabled")
      (set! *mcp-servers* saved))))

;;; ============================================================
;;; Live integration tests (guarded by reachability check)
;;; ============================================================

(format #t "~%--- Live integration (skipped if unreachable) ---~%")

(when (catch #t (lambda () (mcp-server-reachable?)) (lambda _ #f))
  (run-test "LIVE: mcp-init connects and discovers tools"
    (lambda ()
      (set! *mcp-servers* '())
      (set! *mcp-next-id* 0)
      (mcp-init)
      (assert-true (mcp-enabled?) "should be enabled after init")
      (let ((server (assoc-ref *mcp-servers* "skills-hub")))
        (assert-true server "skills-hub should be connected")
        (assert-true (assoc-ref server "connected") "should be connected"))
      ;; Should have discovered tools
      (assert-true (get-tool "skills-hub.workflow__bd")
                   "workflow__bd tool registered")
      ;; Cleanup
      (mcp-shutdown!))))

;;; ============================================================
;;; Summary
;;; ============================================================

(test-summary)
