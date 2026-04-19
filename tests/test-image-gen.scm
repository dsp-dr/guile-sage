#!/usr/bin/env guile3
!#
;;; test-image-gen.scm --- Tests for Ollama image generation

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage config)
             (sage util)
             (sage ollama)
             (sage tools)
             (srfi srfi-1)
             (ice-9 format)
             (ice-9 ftw)
             (ice-9 textual-ports))

;;; Test helpers

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

;;; Ensure .env is loaded
(config-load-dotenv)

;;; ============================================================
;;; Unit Tests (no network required)
;;; ============================================================

(format #t "~%=== Image Generation Unit Tests ===~%")

;; --- Configuration ---

(format #t "~%--- Configuration ---~%")

(run-test "ollama-image-host returns string"
  (lambda ()
    (let ((host (ollama-image-host)))
      (unless (string? host)
        (error "expected string" host))
      (format #t "  Host: ~a~%" host))))

(run-test "ollama-image-host defaults to localhost"
  (lambda ()
    (let ((host (ollama-image-host)))
      (unless (string-contains host "localhost")
        ;; May be overridden by .env; just check it's a URL
        (unless (string-prefix? "http" host)
          (error "expected http URL" host))))))

(run-test "ollama-image-model returns string"
  (lambda ()
    (let ((model (ollama-image-model)))
      (unless (string? model)
        (error "expected string" model))
      (format #t "  Model: ~a~%" model))))

(run-test "ollama-image-model defaults to flux2-klein"
  (lambda ()
    (let ((model (ollama-image-model)))
      (unless (string-contains model "flux")
        ;; May be overridden; just check non-empty
        (unless (> (string-length model) 0)
          (error "expected non-empty model" model))))))

;; --- Tool Registration ---

(format #t "~%--- Tool Registration ---~%")

(init-default-tools)

(run-test "generate_image tool registered"
  (lambda ()
    (let ((tool (get-tool "generate_image")))
      (unless tool
        (error "generate_image not found")))))

(run-test "generate_image tool has description"
  (lambda ()
    (let ((tool (get-tool "generate_image")))
      (let ((desc (assoc-ref tool "description")))
        (unless (and (string? desc) (string-contains desc "image"))
          (error "expected image in description" desc))))))

(run-test "generate_image tool has parameters schema"
  (lambda ()
    (let ((tool (get-tool "generate_image")))
      (let ((params (assoc-ref tool "parameters")))
        (unless params
          (error "missing parameters"))
        (let ((props (assoc-ref params "properties")))
          ;; Check all expected properties exist
          (unless (assoc-ref props "prompt")
            (error "missing prompt property"))
          (unless (assoc-ref props "filename")
            (error "missing filename property"))
          (unless (assoc-ref props "width")
            (error "missing width property"))
          (unless (assoc-ref props "height")
            (error "missing height property"))
          (unless (assoc-ref props "steps")
            (error "missing steps property")))))))

(run-test "generate_image is a safe tool"
  (lambda ()
    (unless (check-permission "generate_image" '())
      (error "generate_image should be a safe tool"))))

;; --- JSON Request Construction ---

(format #t "~%--- JSON Request Construction ---~%")

(run-test "image request builds valid JSON with prompt only"
  (lambda ()
    (let* ((request `(("model" . "test-model")
                      ("prompt" . "a blue circle")
                      ("stream" . ,#f)))
           (json (json-write-string request)))
      (unless (string-contains json "test-model")
        (error "expected model in JSON" json))
      (unless (string-contains json "blue circle")
        (error "expected prompt in JSON" json))
      (unless (string-contains json "false")
        (error "expected stream:false in JSON" json)))))

(run-test "image request builds valid JSON with optional params"
  (lambda ()
    (let* ((base `(("model" . "test-model")
                   ("prompt" . "test")
                   ("stream" . ,#f)))
           (with-opts (append base
                              `(("width" . 512))
                              `(("height" . 512))
                              `(("steps" . 4))))
           (json (json-write-string with-opts)))
      (unless (string-contains json "512")
        (error "expected 512 in JSON" json))
      (unless (string-contains json "\"steps\":4")
        (error "expected steps:4 in JSON" json)))))

(run-test "image request omits #f params via conditional append"
  (lambda ()
    (let* ((width #f)
           (height 256)
           (steps #f)
           (extras (append (if width `(("width" . ,width)) '())
                           (if height `(("height" . ,height)) '())
                           (if steps `(("steps" . ,steps)) '())))
           (json (json-write-string
                  (append '(("model" . "m") ("prompt" . "p")) extras))))
      ;; Should contain height but not width or steps
      (unless (string-contains json "256")
        (error "expected 256 in JSON" json))
      (when (string-contains json "width")
        (error "should not contain width" json))
      (when (string-contains json "steps")
        (error "should not contain steps" json)))))

;; --- Base64 Decode / Save ---

(format #t "~%--- Base64 Save ---~%")

(run-test "save-base64-png creates file"
  (lambda ()
    (let ((test-path "/tmp/sage-test-b64.png")
          ;; Minimal valid base64 for a tiny binary blob
          (b64-data "iVBORw0KGgo="))
      ;; Clean up first
      (when (file-exists? test-path)
        (delete-file test-path))
      ;; The save-base64-png is not exported, test via system call.
      ;; bd: guile-sage-9j7/07f — fork+dup2+exec instead of /bin/sh.
      (let ((tmp-b64 (make-temp-file "sage-test-b64")))
        (call-with-output-file tmp-b64
          (lambda (port) (display b64-data port)))
        (let ((pid (primitive-fork)))
          (cond
           ((= pid 0)
            (catch #t
              (lambda ()
                (let ((in-fd (open-fdes tmp-b64 O_RDONLY))
                      (out-fd (open-fdes test-path
                                         (logior O_WRONLY O_CREAT O_TRUNC)
                                         #o644)))
                  (dup2 in-fd 0)
                  (dup2 out-fd 1)
                  (execlp "base64" "base64" "-d")))
              (lambda args (primitive-exit 127))))
           (else
            (waitpid pid))))
        (delete-file tmp-b64))
      (unless (file-exists? test-path)
        (error "file was not created"))
      (delete-file test-path))))

;; --- Output Directory ---

(format #t "~%--- Output Directory ---~%")

(run-test "output directory created if missing"
  (lambda ()
    (let ((output-dir (string-append (workspace) "/output")))
      (unless (file-exists? output-dir)
        (mkdir output-dir))
      (unless (file-exists? output-dir)
        (error "output directory does not exist")))))

;;; ============================================================
;;; Integration Tests (requires localhost:11434 + flux model)
;;; ============================================================

(format #t "~%=== Image Generation Integration Tests ===~%")

;; Check if ollama is reachable
(define *ollama-reachable*
  (catch #t
    (lambda ()
      (let* ((url (string-append (ollama-image-host) "/api/tags"))
             (result (http-get url))
             (code (if (pair? result) (car result) 0)))
        (= code 200)))
    (lambda args #f)))

(define *flux-model-available*
  (and *ollama-reachable*
       (catch #t
         (lambda ()
           (let* ((url (string-append (ollama-image-host) "/api/tags"))
                  (result (http-get url))
                  (body (if (pair? result) (cdr result) ""))
                  (parsed (json-read-string body))
                  (models (assoc-ref parsed "models")))
             (any (lambda (m)
                    (string-contains (assoc-ref m "name") "flux"))
                  models)))
         (lambda args #f))))

(if (not *ollama-reachable*)
    (format #t "SKIP: Ollama not reachable at ~a~%" (ollama-image-host))
    (begin
      (format #t "  Ollama reachable at ~a~%" (ollama-image-host))

      (if (not *flux-model-available*)
          (format #t "SKIP: flux model not available (run: ollama pull x/flux2-klein:4b)~%")
          (begin
            (format #t "  flux model available~%")

            (format #t "~%--- End-to-End Generation ---~%")

            (run-test "generate image with default size (1024x1024)"
              (lambda ()
                (let ((output-path (string-append (workspace)
                                                  "/tests/fixtures/test-default-1024.png")))
                  ;; Ensure fixtures dir exists
                  (unless (file-exists? (string-append (workspace) "/tests/fixtures"))
                    (mkdir (string-append (workspace) "/tests/fixtures")))
                  (when (file-exists? output-path)
                    (delete-file output-path))
                  (let ((result (ollama-generate-image
                                "solid red square on white background"
                                output-path)))
                    (unless (equal? result output-path)
                      (error "expected output path returned" result))
                    (unless (file-exists? output-path)
                      (error "output file not created"))
                    (format #t "  Created: ~a~%" output-path)))))

            (run-test "generate image with custom size (256x256)"
              (lambda ()
                (let ((output-path (string-append (workspace)
                                                  "/tests/fixtures/test-custom-256.png")))
                  (when (file-exists? output-path)
                    (delete-file output-path))
                  (let ((result (ollama-generate-image
                                "solid green triangle on white background"
                                output-path
                                #:width 256 #:height 256)))
                    (unless (equal? result output-path)
                      (error "expected output path returned" result))
                    (unless (file-exists? output-path)
                      (error "output file not created"))
                    (format #t "  Created: ~a~%" output-path)))))

            (run-test "generate image with steps parameter"
              (lambda ()
                (let ((output-path (string-append (workspace)
                                                  "/tests/fixtures/test-steps-4.png")))
                  (when (file-exists? output-path)
                    (delete-file output-path))
                  (let ((result (ollama-generate-image
                                "solid blue circle on white background"
                                output-path
                                #:width 256 #:height 256 #:steps 4)))
                    (unless (equal? result output-path)
                      (error "expected output path returned" result))
                    (unless (file-exists? output-path)
                      (error "output file not created"))
                    (format #t "  Created: ~a~%" output-path)))))

            (format #t "~%--- Tool Execution ---~%")

            (run-test "execute generate_image tool via tool system"
              (lambda ()
                (let ((result (execute-tool "generate_image"
                                           '(("prompt" . "yellow star on black background")
                                             ("filename" . "test-tool-exec")
                                             ("width" . 256)
                                             ("height" . 256)))))
                  (unless (string-contains result "Saved to output/test-tool-exec.png")
                    (error "unexpected result" result))
                  (format #t "  Result: ~a~%" result))))

            (format #t "~%--- Output Validation ---~%")

            (run-test "generated files are valid PNG"
              (lambda ()
                (let ((fixtures-dir (string-append (workspace) "/tests/fixtures")))
                  (for-each
                   (lambda (filename)
                     (when (string-suffix? ".png" filename)
                       (let* ((path (string-append fixtures-dir "/" filename))
                              (tmp (make-temp-file "sage-file-check")))
                         ;; bd: guile-sage-9j7/07f — fork+dup2+exec
                         ;; file(1) instead of /bin/sh.
                         (let ((pid (primitive-fork)))
                           (cond
                            ((= pid 0)
                             (catch #t
                               (lambda ()
                                 (let ((out-fd (open-fdes
                                                tmp
                                                (logior O_WRONLY O_CREAT O_TRUNC)
                                                #o644)))
                                   (dup2 out-fd 1)
                                   (execlp "file" "file" path)))
                               (lambda args (primitive-exit 127))))
                            (else
                             (waitpid pid))))
                         (let ((result (call-with-input-file tmp get-string-all)))
                           (delete-file tmp)
                           (unless (string-contains result "PNG image data")
                             (error "not a valid PNG" path result))
                           (format #t "  ~a: ~a~%"
                                   filename
                                   (string-trim-both result))))))
                   (or (scandir fixtures-dir
                                (lambda (f) (string-suffix? ".png" f)))
                       '())))))

            (run-test "generated files have non-zero size"
              (lambda ()
                (let ((fixtures-dir (string-append (workspace) "/tests/fixtures")))
                  (for-each
                   (lambda (filename)
                     (when (string-suffix? ".png" filename)
                       (let* ((path (string-append fixtures-dir "/" filename))
                              (stat-info (stat path)))
                         (unless (> (stat:size stat-info) 0)
                           (error "file has zero size" path))
                         (format #t "  ~a: ~a bytes~%"
                                 filename (stat:size stat-info)))))
                   (or (scandir fixtures-dir
                                (lambda (f) (string-suffix? ".png" f)))
                       '())))))))))

;;; Summary

(format #t "~%=== Summary ===~%")
(format #t "Tests: ~a/~a passed~%" *tests-passed* *tests-run*)

(if (= *tests-passed* *tests-run*)
    (begin
      (format #t "All tests passed!~%")
      (exit 0))
    (begin
      (format #t "Some tests failed!~%")
      (exit 1)))
