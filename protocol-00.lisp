(in-package #:ws)

;;; (todo? hixie75, chrome4/safari 5.0.0)

;;; draft hixie-76/hybi-00 protocol support
;;; used by firefox4/5, chrome6-13?, safari 5.0.1, opera 11
;;; (firefox and opera disabled by default)
(defparameter *draft-76/00-close-frame*
  (make-array 2 :element-type '(unsigned-byte 8)
                :initial-contents '(#xff #x00)))

#++
(defparameter *allow-draft-75* t)
#++
(defun make-handshake-75 (origin location protocol)
  (babel:string-to-octets
   (format nil "HTTP/1.1 101 Web Socket Protocol Handshake
Upgrade: WebSocket
Connection: Upgrade
WebSocket-Origin: ~a
WebSocket-Location: ~a
WebSocket-Protocol: ~a

"
           origin
           location
           protocol)
   :encoding :utf-8))

(defun make-handshake-76 (origin location protocol)
  (babel:string-to-octets
   (format nil "HTTP/1.1 101 Web Socket Protocol Handshake
Upgrade: WebSocket
Connection: Upgrade
Sec-WebSocket-Origin: ~a
Sec-WebSocket-Location: ~a
Sec-WebSocket-Protocol: ~a

"
           origin
           location
           protocol)
   :encoding :utf-8))
#++
(defun make-handshake (origin location protocol version)
  "Returns a WebSockets handshake string returned by a server to a
client."
  (ecase version
    (:draft-75 (make-handshake-75 origin location protocol))
    (:draft-76 (make-handshake-76 origin location protocol))))


(defun extract-key (k)
  (when k
    (loop
      :with n = 0
      :for i across k
      :when (char= i #\space)
      :count 1 :into spaces
      :when (digit-char-p i)
      :do (setf n (+ (* n 10) (digit-char-p i)))
      :finally (return
                 (multiple-value-bind (d r) (floor n spaces)
                   (when (zerop r)
                     d))))))
;; (extract-key "3e6b263  4 17 80") -> 906585445
;; (extract-key "17  9 G`ZD9   2 2b 7X 3 /r90") -> 179922739

(defun make-challenge-00 (k1 k2 k3)
  (let ((b (make-array 16 :element-type '(unsigned-byte 8))))
    (loop for i from 0 below 4
       for j from 24 downto 0 by 8
       do (setf (aref b i) (ldb (byte 8 j) k1))
       do (setf (aref b (+ 4 i)) (ldb (byte 8 j) k2)))
    (replace b k3 :start1 8 :end1 16 )
    b))


(defun protocol-76/00-nonce (client)
  (next-reader-state
   client
   (octet-count-matcher 8)
   (lambda (client)
     (flet ((error-exit (message)
              (send-error-and-close client message)
              (return-from protocol-76/00-nonce nil)))
       (let ((nonce (get-octet-vector (chunks client)))
             (headers (client-connection-headers client))
             (resource-name (client-resource-name client)))
         (destructuring-bind (resource check-origin)
             (valid-resource-p (client-server client) resource-name)
           (unless resource
             (error-exit *404-message*))
           (unless (funcall check-origin (gethash :origin headers))
             (error-exit *403-message*))

           (multiple-value-bind  (acceptp rqueue origin handshake-resource protocol)
               (resource-accept-connection resource resource-name
                                           headers
                                           client)
             (declare (ignorable origin handshake-resource protocol))
             (when (not acceptp)
               (error-exit *403-message*))
             (setf (client-read-queue client) (or rqueue
                                                  (resource-read-queue resource)
                                                  (make-mailbox))
                   (client-resource client) resource
                   (client-websocket-version client) 0)
             (client-enqueue-write
              client
              (make-handshake-76 (or origin
                                     (gethash :origin headers)
                                     "http://127.0.0.1/")
                                 (let ((*print-pretty*))
                                   (format nil "~a~a~a"
                                           "ws://"
                                           (or (gethash :host headers)
                                               "127.0.0.1:12345")
                                           (or handshake-resource
                                               resource-name)))
                                 (or protocol
                                     (gethash :websocket-protocol headers)
                                     "test")))
             (client-enqueue-write
              client
              (ironclad:digest-sequence
               'ironclad:md5
               (make-challenge-00
                (extract-key (gethash :sec-websocket-key1 headers))
                (extract-key (gethash :sec-websocket-key2 headers))
                nonce)))
             (setf (client-connection-state client) :connected)
             (client-enqueue-read client (list client :connect)))
           (protocol-76/00-frame-start client)))))))

(defun protocol-76/00-read-text-frame (client)
  (next-reader-state
   client
   (octet-pattern-matcher #(#xff) *max-read-message-size*)
   (lambda (client)
     (let ((s (get-utf8-string-or-fail (chunks client) :skip-octets-end 1)))
       (client-enqueue-read client (list client (list :text s)))
       (protocol-76/00-frame-start client)))))

(defun protocol-76/00-read-binary-frame (client)
  (next-reader-state
   client
   (octet-count-matcher 1)
   (lambda (client)
     (let ((o (read-octet (chunks client))))
       ;; only allowed binary frame is 0-length close frame
       (if (zerop o)
           (error 'close-from-peer :status-code 1005)
           (error 'fail-the-websockets-connection))))))

(defun protocol-76/00-frame-start (client)
  (next-reader-state
   client
   (octet-count-matcher 1)
   (lambda (client)
     (let ((frame-type (read-octet (chunks client))))
       (cond
         ((eql frame-type #x00)
          (setf (message-opcode client) frame-type)0
          (protocol-76/00-read-text-frame client))
         ((eql frame-type #xff)
          (setf (message-opcode client) frame-type)
          (protocol-76/00-read-binary-frame client))
         (t
          ;; unused message, just for debugging
          (error 'fail-the-websockets-connection
                 :message (format nil "unknown frame type #x~2,'0x" frame-type))))))))
