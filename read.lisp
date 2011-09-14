(in-package #:ws)

(defparameter *max-read-frame-size* 8192
  "Default buffer size for reading lines/frames.")

(defparameter *max-read-message-size* (* 32 (expt 2 20))
  "Default buffer size for reading lines/frames.")

(defparameter *max-header-size* 16384
  "Default max header size in octets (not used yet?)")

(defparameter *read-max-fragments* 8
  "Max number of reads before reader gives up on assembling a line/frame.

\(Temporary hack until fragments are stored more efficiently, to avoid
wasting a bunch of space if we only get 1 octet per read or
whatever.\)

Currently allocating 2kio/read, so stores multiples of that.")

;; fixme: should this have a separate setting for when to reenable readers?
(defparameter *max-handler-read-backlog* 256
  "Max number of frames that can be queued before the reader will
 start throttling reads for clients using that queue (for now, just
 drops the connections...).")

(defparameter *policy-file* (make-domain-policy)
  "cross-domain policy file, used for the Flash WebSocket emulator.")

(defparameter *400-message* (babel:string-to-octets
                             "HTTP/1.1 400 Bad Request

"
                             :encoding :utf-8))

(defparameter *403-message* (babel:string-to-octets
                             "HTTP/1.1 403 Forbidden

"
                             :encoding :utf-8))
(defparameter *404-message* (babel:string-to-octets
                             "HTTP/1.1 404 Resource not found

"
                             :encoding :utf-8))

(defun make-challenge-o7 (k &aux (o7-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  "Compute the WebSocket opening handshake challenge, according to:

   http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-07#section-1.3

Test this with the example provided in the above document:

   (string= (clws::make-challenge-o7 \"dGhlIHNhbXBsZSBub25jZQ==\")
            \"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\")

..which must return T."
  (cl-base64:usb8-array-to-base64-string
   (ironclad:digest-sequence
    :sha1 (map '(vector (unsigned-byte 8)) #'char-code
               (concatenate 'string k o7-guid)))))



