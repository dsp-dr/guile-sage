#!/usr/bin/env guile
!#
;;; test-json-unicode.scm --- JSON parser \uXXXX escape decoding
;;;
;;; Regression for the tool-eval bug: models emit operators like <= as the
;;; JSON escape <=, which the parser previously dropped the backslash
;;; from, yielding the unbound variable `u003c=`. The parser must decode
;;; \uXXXX (and surrogate pairs) back to the real characters.

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage util) (ice-9 format))

(load (string-append (dirname (current-filename)) "/test-harness.scm"))

(format #t "~%=== JSON \\u escape decoding ===~%")

(test "\\u003c decodes to <"
  (lambda ()
    (assert-equal (json-read-string "\"a\\u003c=b\"") "a<=b"
                  "less-than escape")))

(test "\\u003c in a nested object value (the tool-input case)"
  (lambda ()
    (let ((obj (json-read-string "{\"code\":\"(\\u003c= n 1)\"}")))
      (assert-equal (assoc-ref obj "code") "(<= n 1)"
                    "operator survives inside object value"))))

(test "multiple escapes: & > and escaped slash"
  (lambda ()
    (assert-equal (json-read-string "\"\\u0026\\u003e\\/\"") "&>/"
                  "ampersand, greater-than, forward-slash")))

(test "surrogate pair decodes to astral char (emoji)"
  (lambda ()
    (assert-equal (json-read-string "\"x \\ud83d\\ude00 y\"") "x 😀 y"
                  "UTF-16 surrogate pair -> U+1F600")))

(test "conventional escapes still work"
  (lambda ()
    (assert-equal (json-read-string "\"a\\nb\\tc\"") "a\nb\tc"
                  "newline and tab")))

(test-summary)
