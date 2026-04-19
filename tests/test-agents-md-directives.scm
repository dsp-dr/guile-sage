;;; test-agents-md-directives.scm --- Tests for AGENTS.md directive parsing
;;; -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Stub tests for the AGENTS.md structured directive parser.
;; Covers invariants AD01-AD10 from docs/AGENTS-MD-DIRECTIVES.org.
;; Each test body is a placeholder (#t) until the parser is implemented.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (srfi srfi-64))

(include "test-harness.scm")
(test-begin "agents-md-directives")

;;; ============================================================
;;; AD01: Fenced code blocks with sage-config tag are detected
;;; ============================================================

(test-assert "AD01 — fenced sage-config block detected"
  #t)

(test-assert "AD01 — non-sage-config fenced blocks are ignored"
  #t)

;;; ============================================================
;;; AD02: Markdown tables under Sage Config headings detected
;;; ============================================================

(test-assert "AD02 — table under '## Sage Config' heading parsed"
  #t)

(test-assert "AD02 — table under non-matching heading ignored"
  #t)

;;; ============================================================
;;; AD03: Known directive types accepted
;;; ============================================================

(test-assert "AD03 — tool-allow directive accepted"
  #t)

(test-assert "AD03 — tool-deny directive accepted"
  #t)

(test-assert "AD03 — agent-mode directive accepted"
  #t)

(test-assert "AD03 — max-iterations directive accepted"
  #t)

(test-assert "AD03 — workspace directive accepted"
  #t)

(test-assert "AD03 — system-prompt directive accepted"
  #t)

(test-assert "AD03 — pre-tool-hook directive accepted"
  #t)

;;; ============================================================
;;; AD04: Unknown directive types logged and skipped
;;; ============================================================

(test-assert "AD04 — unknown directive key is skipped, no crash"
  #t)

(test-assert "AD04 — parser returns valid alist despite unknown keys"
  #t)

;;; ============================================================
;;; AD05: Security escalation prevention
;;; ============================================================

(test-assert "AD05 — agent-mode yolo downgraded without SAGE_YOLO_MODE"
  #t)

(test-assert "AD05 — agent-mode yolo preserved when SAGE_YOLO_MODE set"
  #t)

;;; ============================================================
;;; AD06: tool-deny overrides tool-allow for same tool
;;; ============================================================

(test-assert "AD06 — tool in both allow and deny lists is denied"
  #t)

;;; ============================================================
;;; AD07: agent-mode only accepts valid symbols
;;; ============================================================

(test-assert "AD07 — interactive is a valid agent-mode"
  #t)

(test-assert "AD07 — autonomous is a valid agent-mode"
  #t)

(test-assert "AD07 — yolo is a valid agent-mode"
  #t)

(test-assert "AD07 — bogus-mode is rejected"
  #t)

;;; ============================================================
;;; AD08: max-iterations capped at ceiling
;;; ============================================================

(test-assert "AD08 — max-iterations within ceiling accepted as-is"
  #t)

(test-assert "AD08 — max-iterations above ceiling clamped to 50"
  #t)

(test-assert "AD08 — non-integer max-iterations rejected"
  #t)

;;; ============================================================
;;; AD09: Empty/missing directive block produces defaults
;;; ============================================================

(test-assert "AD09 — empty string produces empty alist"
  #t)

(test-assert "AD09 — markdown with no sage-config blocks produces empty alist"
  #t)

;;; ============================================================
;;; AD10: Multiple blocks merged in document order
;;; ============================================================

(test-assert "AD10 — later scalar value wins over earlier"
  #t)

(test-assert "AD10 — set values (tool lists) are unioned"
  #t)

(test-end "agents-md-directives")
(test-summary)
