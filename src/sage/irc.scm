;;; irc.scm --- IRC client for agent communication -*- coding: utf-8 -*-

;;; Commentary:
;;
;; Simple IRC client using Guile sockets for agent messaging.
;; Provides connection to SageNet for:
;;   - Agent coordination (#sage-agents)
;;   - Task updates (#sage-tasks)
;;   - Debug logging (#sage-debug)
;;
;; Protocol: RFC 1459 subset (NICK, USER, JOIN, PART, PRIVMSG, PING/PONG)

(define-module (sage irc)
  #:use-module (sage config)
  #:use-module (sage logging)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 threads)
  #:export (*irc-connection*
            *irc-nick*
            *irc-channels*
            irc-enabled?
            irc-connected?
            irc-connect
            irc-disconnect
            irc-join
            irc-part
            irc-send
            irc-privmsg
            irc-broadcast
            irc-log-debug
            irc-log-task
            irc-send-raw
            irc-read-line
            init-irc))

;;; ============================================================
;;; Configuration
;;; ============================================================

;;; Connection state
(define *irc-connection* #f)  ; Socket or #f
(define *irc-nick* "sage")
(define *irc-channels* '())

;;; Default configuration
(define *irc-server* "localhost")
(define *irc-port* 6667)
(define *irc-realname* "guile-sage agent")

;;; Channel purposes
(define *channel-agents* "#sage-agents")
(define *channel-tasks* "#sage-tasks")
(define *channel-debug* "#sage-debug")

;;; ============================================================
;;; Initialization
;;; ============================================================

(define* (init-irc #:key (nick #f) (server #f) (port #f))
  "Initialize IRC configuration from environment or parameters."
  ;; Nick
  (set! *irc-nick* (or nick
                       (config-get "SAGE_IRC_NICK")
                       "sage"))
  ;; Server
  (set! *irc-server* (or server
                         (config-get "SAGE_IRC_SERVER")
                         "localhost"))
  ;; Port
  (let ((p (or port
               (let ((env-port (config-get "SAGE_IRC_PORT")))
                 (and env-port (string->number env-port))))))
    (when p (set! *irc-port* p)))

  (log-info "irc" "IRC configured"
            `(("server" . ,*irc-server*)
              ("port" . ,*irc-port*)
              ("nick" . ,*irc-nick*)))
  #t)

;;; ============================================================
;;; Connection Management
;;; ============================================================

(define (irc-enabled?)
  "Check if IRC is enabled via configuration."
  (let ((enabled (config-get "SAGE_IRC_ENABLED")))
    (and enabled (member enabled '("1" "true" "yes")))))

(define (irc-connected?)
  "Check if IRC is currently connected."
  (and *irc-connection* #t))

(define* (irc-connect #:key (nick #f) (server #f) (port #f))
  "Connect to IRC server. Returns #t on success."
  ;; Initialize if needed
  (when (or nick server port)
    (init-irc #:nick nick #:server server #:port port))

  ;; Close existing connection
  (when *irc-connection*
    (irc-disconnect))

  (catch #t
    (lambda ()
      (log-info "irc" "Connecting to IRC"
                `(("server" . ,*irc-server*)
                  ("port" . ,*irc-port*)))

      ;; Resolve hostname (prefer IPv4 for compatibility)
      (let* ((server-addr (if (equal? *irc-server* "localhost")
                              "127.0.0.1"
                              *irc-server*))
             (ai (car (getaddrinfo server-addr (number->string *irc-port*)
                                   (logior AI_NUMERICSERV AI_ADDRCONFIG))))
             (sock (socket (addrinfo:fam ai) SOCK_STREAM 0)))
        ;; Connect
        (connect sock (addrinfo:addr ai))
        (set! *irc-connection* sock)

        ;; Send NICK and USER
        (irc-send-raw (format #f "NICK ~a" *irc-nick*))
        (irc-send-raw (format #f "USER ~a 0 * :~a" *irc-nick* *irc-realname*))

        ;; Wait for welcome (001) or error
        (let loop ((attempts 10))
          (when (> attempts 0)
            (let ((line (irc-read-line)))
              (cond
               ((not line)
                (loop (1- attempts)))
               ((string-contains line " 001 ")
                ;; Welcome received
                (log-info "irc" "Connected to IRC" `(("nick" . ,*irc-nick*)))
                #t)
               ((string-prefix? "PING " line)
                ;; Respond to PING during registration
                (irc-send-raw (string-append "PONG " (substring line 5)))
                (loop attempts))
               ((or (string-contains line " 433 ")  ; Nick in use
                    (string-contains line "ERROR"))
                (log-error "irc" "IRC registration failed" `(("response" . ,line)))
                (irc-disconnect)
                #f)
               (else
                (loop (1- attempts))))))))
      #t)
    (lambda (key . args)
      (log-error "irc" "IRC connection failed"
                 `(("error" . ,(format #f "~a: ~a" key args))))
      (set! *irc-connection* #f)
      #f)))

(define (irc-disconnect)
  "Disconnect from IRC server."
  (when *irc-connection*
    (catch #t
      (lambda ()
        (irc-send-raw "QUIT :guile-sage shutting down")
        (close *irc-connection*))
      (lambda args #f))
    (set! *irc-connection* #f)
    (set! *irc-channels* '())
    (log-info "irc" "Disconnected from IRC")
    #t))

;;; ============================================================
;;; Channel Operations
;;; ============================================================

(define (irc-join channel)
  "Join an IRC channel. Returns #t on success."
  (if (not *irc-connection*)
      (begin
        (log-warn "irc" "Cannot join - not connected")
        #f)
      (begin
        (irc-send-raw (format #f "JOIN ~a" channel))
        (set! *irc-channels* (cons channel *irc-channels*))
        (log-info "irc" "Joined channel" `(("channel" . ,channel)))
        #t)))

(define (irc-part channel)
  "Leave an IRC channel."
  (when *irc-connection*
    (irc-send-raw (format #f "PART ~a :leaving" channel))
    (set! *irc-channels* (delete channel *irc-channels*))
    (log-info "irc" "Left channel" `(("channel" . ,channel))))
  #t)

;;; ============================================================
;;; Messaging
;;; ============================================================

(define (irc-privmsg target message)
  "Send a PRIVMSG to target (channel or nick)."
  (if (not *irc-connection*)
      (begin
        (log-debug "irc" "Message not sent - not connected"
                   `(("target" . ,target)))
        #f)
      (begin
        (irc-send-raw (format #f "PRIVMSG ~a :~a" target message))
        (log-debug "irc" "Message sent"
                   `(("target" . ,target)
                     ("length" . ,(string-length message))))
        #t)))

(define* (irc-send target message)
  "Alias for irc-privmsg."
  (irc-privmsg target message))

(define (irc-broadcast message)
  "Send message to all joined channels."
  (for-each (lambda (channel)
              (irc-privmsg channel message))
            *irc-channels*))

;;; ============================================================
;;; Convenience Functions
;;; ============================================================

(define (irc-log-debug message)
  "Send a debug message to #sage-debug."
  (irc-privmsg *channel-debug* (format #f "[DEBUG] ~a" message)))

(define (irc-log-task task-id status)
  "Send task update to #sage-tasks."
  (irc-privmsg *channel-tasks*
               (format #f "[TASK] ~a: ~a" task-id status)))

;;; ============================================================
;;; Low-Level I/O
;;; ============================================================

(define (irc-send-raw line)
  "Send raw IRC line (adds CRLF)."
  (when *irc-connection*
    (catch #t
      (lambda ()
        (display (string-append line "\r\n") *irc-connection*)
        (force-output *irc-connection*)
        #t)
      (lambda (key . args)
        (log-error "irc" "Send failed" `(("error" . ,(format #f "~a" key))))
        #f))))

(define* (irc-read-line #:key (timeout 5))
  "Read a line from IRC connection (blocking with timeout)."
  (if (not *irc-connection*)
      #f
      (catch #t
        (lambda ()
          ;; Simple blocking read - could add select() timeout later
          (let ((line (read-line *irc-connection*)))
            (if (eof-object? line)
                #f
                (begin
                  ;; Handle PING automatically
                  (when (string-prefix? "PING " line)
                    (irc-send-raw (string-append "PONG " (substring line 5))))
                  line))))
        (lambda (key . args)
          #f))))

;;; ============================================================
;;; Auto-connect on module load (if enabled)
;;; ============================================================

;; Initialize config on load
(init-irc)

