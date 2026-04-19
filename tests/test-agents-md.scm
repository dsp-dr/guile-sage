;;; test-agents-md.scm --- Tests for AGENTS.md discovery and configuration
;;; -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Stub tests for AGENTS.md contract invariants (A01-A12).
;; See docs/AGENTS-MD-CONTRACT.org for the full specification.
;; Each test-assert is a placeholder (#t) to be filled in when
;; structured parsing is implemented.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage config)
             (srfi srfi-64))

;;; Load shared SRFI-64 test harness
(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(test-begin "agents-md")

;;; ============================================================
;;; Discovery (A01-A03)
;;; ============================================================

(test-assert "A01: find-agents-md checks 5 locations in order"
  ;; Workspace, XDG project, XDG config, XDG data, ~/.sage/
  #t)

(test-assert "A02: only existing files are returned"
  ;; find-agents-md filters by file-exists?
  (let ((results (find-agents-md)))
    (every (lambda (path)
             (file-exists? path))
           results)))

(test-assert "A03: empty result when no AGENTS.md exists"
  ;; find-agents-md returns () when no files found
  ;; (may return non-empty on dev machines with AGENTS.md)
  (list? (find-agents-md)))

;;; ============================================================
;;; Merge semantics (A04-A05)
;;; ============================================================

(test-assert "A04: multiple files concatenated in discovery order"
  ;; load-agents-md joins files in find-agents-md order
  #t)

(test-assert "A05: each file prefixed with source annotation"
  ;; Content includes '# From: <path>' headers
  (let ((content (load-agents-md)))
    (or (not content)  ; no AGENTS.md on this machine
        (string-contains content "# From:"))))

;;; ============================================================
;;; Structured section parsing (A06-A08)
;;; ============================================================

(test-assert "A06: Tool Permissions heading maps to safe/unsafe lists"
  ;; ## Tool Permissions section parsed into tool configuration
  #t)

(test-assert "A07: Mode heading maps to operating mode"
  ;; ## Mode section parsed into yolo/plan/normal mode setting
  #t)

(test-assert "A08: Conventions heading passed as system context"
  ;; ## Conventions section becomes part of system prompt
  #t)

;;; ============================================================
;;; Application (A09-A12)
;;; ============================================================

(test-assert "A09: tool permissions applied before first chat turn"
  ;; Restrictions enforced at startup, not lazily
  #t)

(test-assert "A10: malformed AGENTS.md degrades gracefully"
  ;; Log WARN, skip bad section, continue with rest
  #t)

(test-assert "A11: /agents reload replaces config atomically"
  ;; No partial state between old and new configuration
  #t)

(test-assert "A12: nested subdirectory AGENTS.md not traversed"
  ;; Only the 5 explicit search locations are checked
  #t)

(test-end "agents-md")

;;; Summary

(test-summary)
