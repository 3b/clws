(in-package #:ws)

;;; some of these should probably be per resource handler rather than global?

(defvar *protocol-76/00-support* nil
  "set to NIL to disable draft-hixie-76/draft-ietf-00 support, true to enable.")

(defvar *max-clients* 256
  "Max number of simultaneous clients allowed (nil for no limit).
Extra connections will get a HTTP 5xx response (without reading headers).")

(defvar *max-read-frame-size* (* 16 (expt 2 20))
  "Max size of frames allowed. Connection will be dropped if client sends
a larger frame.")

;;; firefox defaults to ~16MB and Autobahn tests test up to 16MB as well
;;; probably should be lower for production servers, until there is
;;; some sort of aggregate limit to prevent a few hundred connections
;;; from buffering 16MB each
(defvar *max-read-message-size* (* 16 (expt 2 20))
  "Largest (incomplete) message allowed. Connection will be dropped if
client sends a larger message. Malicious clients can cause lower amounts
to be buffered indefinitely though, so be careful with large settings.")

(defvar *max-header-size* 16384
  "Default max header size in octets (not used yet?)")

;; fixme: should this have a separate setting for when to reenable readers?
(defvar *max-handler-read-backlog* 4
  "Max number of frames that can be queued before the reader will
 start throttling reads for clients using that queue (for now, just
 drops the connections...).")

(defvar *policy-file* (make-domain-policy :from "*" :to-port "*")
  "cross-domain policy file, used for the Flash WebSocket emulator.")

(defvar *log-level* nil
  ;; todo: intermediate settings
  "set to NIL to disable log messages, T to enable")

(defvar *debug-on-server-errors* nil
  "set to T to enter debugger on server errors, NIL to just drop the connections.")

(defvar *debug-on-resource-errors* nil
  "set to T to enter debugger on resource-handler errors, NIL to drop the connections and try to send a disconnect to handler.")


(defvar *400-message* (string-to-shareable-octets
                             "HTTP/1.1 400 Bad Request

"
                             :encoding :utf-8))

(defvar *403-message* (string-to-shareable-octets
                             "HTTP/1.1 403 Forbidden

"
                             :encoding :utf-8))
(defvar *404-message* (string-to-shareable-octets
                             "HTTP/1.1 404 Resource not found

"
                             :encoding :utf-8))
