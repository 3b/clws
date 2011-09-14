(in-package #:ws)

;; draft 7/protocol 7 support, used by firefox 6
;; 

(defun protocol-7+-handshake (client version-string origin-key)
  ;; required headers: Host, Sec-WebSocket-Key, Sec-WebSocket-Version
  ;; optional: Sec-Websocket-Origin, Sec-Websocket-Protocol, Sec-Websocket-Extensions
  (flet ((error-exit (message)
           (send-error-and-close client message)
           (return-from protocol-7+-handshake nil)))
    (let* ((headers (client-connection-headers client))
          (host (gethash :host headers nil))
          (key (gethash :sec-websocket-key headers nil))
          ;; don't need to actually decode the key...
          #++
          (decoded-key (when key
                         (base64:base64-string-to-usb8-array key)))
          (version (gethash :sec-websocket-version headers nil))
          (origin (gethash origin-key headers nil))
           #++(protocol (gethash :sec-websocket-protocol headers nil))
          #++(extensions (gethash :sec-websocket-extensions headers nil))
          (upgrade (gethash :upgrade headers ""))
          (connection (mapcar (lambda (a) (string-trim " " a))
                              (split-sequence:split-sequence
                               #\, (gethash :connection headers ""))))
          (resource-name (client-resource-name client))
          )
     (format t "resource = ~s, host=~s, version=~s query=~s~%"
             resource-name host version (client-query-string client))
     ;; version 7 requires Host, Sec-Websocket-Key which base64 decodes
     ;; to 16 octets, and Sec-Websocket-Version = 7
     ;; also need Connection: Upgrade and Upgrade: WebSocket
     ;; (ff sends Connection: keep-alive, Upgrade, so split on , first)
     (unless (and host key version (and (string= version version-string))
                  ;; not sure if "websocket" is case sensitive or not?
                  (string-equal upgrade "websocket")
                  (member "Upgrade" connection :test 'string-equal)
                  #++(= (length decoded-key) 16))
       (error-exit *400-message*))
     ;; todo: validate Host: header
     ;; 404 if we don't recognize the requested resource
     (destructuring-bind (resource check-origin)
         (valid-resource-p (client-server client) resource-name)
       (unless resource
         (error-exit *404-message*))
       (unless (funcall check-origin origin)
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
               (client-resource client) resource)
         (client-enqueue-read client (list client :connect)))
       (format t "got valid v7+ connection: upgrade: ~s, con: ~s~%" upgrade connection)
       (%write-to-client client
                            (babel:string-to-octets
                             ;; todo: Sec-WebSocket-Protocol, Sec-WebSocket-Extension
                             (format nil "HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: ~a

"
                                     (make-challenge-o7 key))
                             :encoding :iso-8859-1))
       (format t "sent"))
      t)))

(defun get-utf8-string-or-fail (chunk-buffer)
  (handler-case
      (get-utf8-string chunk-buffer)
    (flexi-streams:external-format-encoding-error ()
      (error 'fail-the-websockets-connection
             :status-code 1007
             :message "invalid UTF-8"))
    (babel:character-coding-error ()
      (error 'fail-the-websockets-connection
             :status-code 1007
             :message "invalid UTF-8"))))

(defun dispatch-message (client)
  (let ((opcode (message-opcode client))
        (partial-message (partial-message client)))
    (setf (partial-message client) nil)
    (case opcode
      (#x1 ;; text message
      (let ((s (get-utf8-string-or-fail partial-message)))
             #++(format t "got text message : ~s~%" s)
             (client-enqueue-read client (list client (list :text s)))))
     (#x2 ;; binary message
       (let ((*print-length* 32)
             (v (get-octet-vector partial-message)))
         #++(format t "got binary message : ~s~%" v)
         (client-enqueue-read client (list client (list :binary v))))))
    #++(format t "count = ~s~%" (mailbox-count (client-read-queue client)))
    #++(format t "res=~s / ~s, q=~s~%" (client-resource-name client)
            (client-resource client)
            (client-read-queue client))
    (when (> (mailbox-count (client-read-queue client))
             *max-handler-read-backlog*)
      ;; if server isn't processing events fast enuogh, disable the
      ;; reader temporarily and tell the handler
      (when (client-reader-active client)
        (client-disable-handler client :read t)
        (client-enqueue-read client (list client :flow-control))))))

(defun dispatch-control-message (client opcode)
  (let ((len (frame-length client))
        (chunks (chunks client)))
    (case opcode
      (#x8                              ; close
              ;; if close frame has a body, it should be big-endian 16bit code
       (let* ((code (when (>= len 2)
                      (dpb (read-octet chunks) (byte 8 8)
                           (read-octet chunks))))
              ;; optionally followed by utf8 text
              (message (when (> len 2)
                         (get-utf8-string-or-fail chunks))))
         (format t "got close frame ~s / ~s~%" code message)
         ;; 1005 is status code to pass to applications when none was provided
         ;; by peer
         (error 'close-from-peer :status-code (or code 1005)
                                 :message message)))
      (#x9 ; ping
       (let* ((v (get-octet-vector chunks))
              (pong (pong-frame-for-protocol (client-websocket-version client)
                                             v)))
         #++(format t "got ping, body=~s~%" v)
         (when pong
           (%write-to-client client pong))))
      (#xa ; pong
       (format t "got pong, body=~s~%" (get-octet-vector chunks)))
      (t (error 'fail-the-websockets-connection
                :status-code 1002
                :message (format nil "unknown control frame #x~2,'0x" opcode))))))

(defun dispatch-frame (client length)
  ;; control frames (opcodes 8+) can't be fragmented, so FIN=T
  ;; if 0<opcode<8, partial message must be NIL, FIN can be T or NIL
  ;; if 0=opcode, partial message must be non-nil, fin can be T or NIL
  (let ((opcode (frame-opcode client))
        (fin (frame-fin client)))
    (cond
      ((>= opcode 8)
       (if (or (not fin) (> length 125))
           (error 'fail-the-websockets-connection :status-code 1002
                  :message (if fin "fragmented control frame"
                               "control frame too large"))
           (dispatch-control-message client opcode)))
      ;; continuation frame, add to partial message
      ((zerop opcode)
       (when (not (partial-message client))
         ;; no message in progress, fail connection
         (error 'fail-the-websockets-connection
                :status-code 1002
                :message (format nil
                                 "continuation frame without start frame")))
       (when (and (not fin)
                  (> (+ length (buffer-size (partial-message client)))
                     *max-read-message-size*))
         (setf (partial-message client) nil)
         (error 'fail-the-websockets-connection
                :status-code 1009
                :message (format nil "message too large")))
       (add-chunks (partial-message client) (chunks client))
       (when fin
         (dispatch-message client)))
      ;; text/binary message
      ((or (= opcode 1) (= opcode 2))
       ;; shouldn't have unfinished message
       (when (partial-message client)
         (error 'fail-the-websockets-connection
                :status-code 1002
                :message (format nil
                                 "start frame without finishing previous message")))
       ;; check for too large partial message
       (when (and (not fin)
                  (> length *max-read-message-size*))
         (error 'fail-the-websockets-connection
                :status-code 1009
                :message (format nil "message too large")))
       ;; start new message
       (setf (partial-message client) (make-instance 'chunk-buffer)
             (message-opcode client) opcode)
       (add-chunks (partial-message client) (chunks client))
       (when fin
         (dispatch-message client)))
      (t
       (error 'fail-the-websockets-connection
              :status-code 1002
              :message (format nil "unknown data frame #x~2,'0x" opcode))))))

(defun protocol-7+-read-frame (client length mask)
  (next-reader-state
   client (octet-count-matcher length)
   (lambda (client)
     (when mask
       #++(format t "masking ... ~s~%" mask)
       (mask-octets (chunks client) mask))
     (dispatch-frame client length)
     #++(with-buffer-as-stream (client s)
          (format t "got frame: mask=~s ~s~%"
                  mask
                  (loop for i below length
                        for b = (read-byte s)
                        collect (if mask (logxor (aref mask (mod i 4)) b) b))))
     (protocol-7+-start-frame client))))

(defun protocol-7+-read-mask (client length)
  ;; read 4 octet mask
  (next-reader-state
   client
   (octet-count-matcher 4)
   (lambda (client)
     (with-buffer-as-stream (client s)
       (let ((mask (make-array 4 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
         (loop for i below 4
               do #++(setf mask
                           (+ (* length 256) (read-byte s)))
                  (setf (aref mask i) (read-byte s)))
         (protocol-7+-read-frame client length mask))))))

(defun protocol-7+-extended-length (client octets masked)
  ;; read 2/8 octets, extended length
  (next-reader-state client
                     (octet-count-matcher octets)
                     (lambda (client)
                       (with-buffer-as-stream (client s)
                         (let ((length 0))
                           (loop for i below octets
                                 do (setf length
                                          (+ (* length 256) (read-byte s))))
                           (setf (frame-length client) length)
                           #++(format t "~s octet long length = ~s~%" octets length)
                           (if masked
                               (protocol-7+-read-mask client length)
                               (protocol-7+-read-frame client length nil)))))))

(defun protocol-7+-start-frame (client)
  ;; read 2 octets, opcode+flags and short length
  (next-reader-state
   client
   (octet-count-matcher 2)
   (lambda (client)
     #++(format t "matched start frame~%")
     (with-buffer-as-stream (client s)
       (let* ((opcode-octet (read-byte s))
              (length-octet (read-byte s))
              (fin (logbitp 7 opcode-octet))
              (rsv (ldb (byte 3 4) opcode-octet))
              (opcode (ldb (byte 4 0) opcode-octet))
              (masked (logbitp 7 length-octet))
              (length (ldb (byte 7 0) length-octet)))
         ;; TODO: make sure we have partial message
         ;;   iff opcode=0
         ;; TODO: make sure MASK is set for client->server frames
         #++(format t "got frame header ~8,'0b ~8,'0b ~%"
                 opcode-octet length-octet)
         #++(format t "frame header = fin ~s, rsv ~s, op ~s, mask ~s, len ~s~%"
                 fin rsv opcode masked length)
         (unless (zerop rsv)
           (error 'fail-the-websockets-connection
                  :status-code 1002
                  :message (format nil "reserved bits ~3,'0b expected 000" rsv)))
         (setf (frame-opcode-octet client) opcode-octet
               (frame-opcode client) opcode
               (frame-length client) length
               (frame-fin client) fin)
         (cond
           ((> length 125)
            (protocol-7+-extended-length client
                                         (if (= length 126)
                                             2
                                             8)
                                         masked))
           (masked
            (protocol-7+-read-mask client length))
           (t
            (protocol-7+-read-frame client length nil))))))))

(defun protocol-7-parse-headers (client)
  (when (protocol-7+-handshake client "7" :sec-websocket-origin)
    (setf (client-websocket-version client) 7)
    (protocol-7+-start-frame client)))


(defun protocol-8-parse-headers (client)
  (when (protocol-7+-handshake client "8" :sec-websocket-origin)
    (setf (client-websocket-version client) 8)
    (protocol-7+-start-frame client)))

(defun protocol-13-parse-headers (client)
  (when (protocol-7+-handshake client "13" :origin)
    (setf (client-websocket-version client) 8)
    (protocol-7+-start-frame client)))

;; protocol 7,8,13 handshakes are almost the same
(setf (gethash "7" *protocol-header-parsers*) 'protocol-7-parse-headers
      (gethash "8" *protocol-header-parsers*) 'protocol-8-parse-headers
      (gethash "13" *protocol-header-parsers*) 'protocol-13-parse-headers)

(push 7 *supported-protocol-versions*)
(push 8 *supported-protocol-versions*)
(push 13 *supported-protocol-versions*)