(in-package #:ws)


;; predicates for determining if callback should be called or not

;; possibly these should have an external state rather than being closures,
;; so we can build them in advance?

(defun octet-count-matcher (n)
  (let ((read 0))
    (lambda (buffer start end)
      (declare (ignore buffer))
      (let ((c (- end start)))
        (if (>= (+ read c) n)
            (+ (- n read) start)
            (progn (incf read c) nil))))))

(defun octet-pattern-matcher (octets &optional max-octets)
  (let ((matched 0)
        (read 0)
        (next (make-array (length octets) :initial-element 0
                                          :element-type 'fixnum)))
    ;; find next shortest sub-string that could be a match for current
    ;; position in octets. for example if we have matched "aaa" from "aaab"
    ;; and get another "a", we should reset match to "aa" rather than
    ;; starting over completely (and then add the new "a" to end up back at
    ;; "aaa" again)
    ;; -- probably should add a compiler macro to do this in advance for
    ;;    the usual case of constant pattern?
    (loop
      with matches = 0
      for i from 1 below (length octets)
      when (= (aref octets matches) (aref octets i))
        do (incf matches)
      else do (setf matches 0)
      do (setf (aref next i) matches))
    (lambda (buffer start end)
      (flet ((match-octet (x)
               (loop
                 do (if (= x (aref octets matched))
                        (return (incf matched))
                        (setf matched (aref next matched)))
                 while (plusp matched))))
        (loop
          for i from 0
          for bi from start below end
          do
             (incf read)
             (match-octet (aref buffer bi))
          when (= matched (length octets))
            return (values (1+ bi) read)
          when (and max-octets (> read max-octets))
            do (error 'fail-the-websockets-connection
                      :status-code 1009
                      :message (format nil "message too large")))))))


(defun unsupported-protocol-version (client)
  ;; draft 7 suggests 'non-200'
  ;; 8 suggests  "appropriate HTTP error code (such as 426 Upgrade Required)"
  ;; 14 suggests 400
  ;; and all 3 put list of supported versions in sec-websocket-version header
  ;; when we get one we don't recognize, so do that then close the connection
  (client-enqueue-write
   client
   (babel:string-to-octets
    (format nil "HTTP/1.1 400 Bad Request
Sec-WebSocket-Version: ~{~s~^, ~}

" *supported-protocol-versions*)
    :encoding :utf-8))
  (client-enqueue-write client :close)
  ;; is this needed after enqueueing :close?
  (client-disconnect client :read t :write t)
  (ignore-remaining-input client))

(defun send-error-and-close (client message)
  (client-enqueue-write client message)
  (client-enqueue-write client :close)
  (client-disconnect client :read t :write t)
  (ignore-remaining-input client))

(defun invalid-header (client)
  ;; just sending same error as unknown version for now...
  (unsupported-protocol-version client))

(defun match-resource-line (buffer)
  (next-reader-state
   buffer
   (octet-pattern-matcher #(13 10))
   (alexandria:named-lambda resource-line-callback (x)
     (let ((request-line
             ;; fixme: process the buffers directly rather than this
             ;; complicated mess of nested streams and loop and coerce
             (with-buffer-as-stream (x s)
               (with-open-stream
                   (s (flex:make-flexi-stream s))
                 (string-right-trim '(#\space #\return #\newline)
                                    (read-line s nil ""))))))
       (unless (every (lambda (c) (<= 32 (char-code c) 126)) request-line)
         (return-from resource-line-callback
           (invalid-header buffer)))
       (let ((s1 (position #\space request-line))
             (s2 (position #\space request-line :from-end t)))
         (unless (and s1 s2 (> s2 (1+ s1))
                      (string= "GET " request-line :end2 (1+ s1))
                      ;; fixme: spec says "HTTP/1.1 or higher"
                      ;; ignoring that possibilty for now..
                      (string= " HTTP/1.1" request-line :start2 s2))
           (lg "got bad request line? ~s~%" request-line)
           (return-from resource-line-callback
             (invalid-header buffer)))
         (let* ((uri (subseq request-line (1+ s1) s2))
                (? (position #\? uri :from-end t))
                (query (when ? (subseq uri (1+ ?))))
                (\:// (search "://" uri))
                (scheme (when \:// (string-downcase (subseq uri 0 \://))))
                (c/ (when (and scheme (> (length uri) (+ \:// 3)))
                      (position #\/ uri :start  (+ \:// 3))))
                (resource-name (if (or c/ ?)
                                   (subseq uri (or c/ 0) ?)
                                   uri)))
           ;; websocket URIs must either start with / or
           ;; ws://.../ or wss://.../, and can't contain #
           ;; ... except draft 11-14 says "HTTP/HTTPS URI"?
           (unless (or (char= (char uri 0) #\/)
                       (string= scheme "ws")
                       (string= scheme "wss")
                       (not (position #\# uri)))
             (return-from resource-line-callback
               (invalid-header buffer)))
           ;; fixme: decode %xx junk in url/query string?
           (lg "got request line ~s ? ~s~%" resource-name query)
           (setf (client-resource-name buffer) resource-name)
           (setf (client-query-string buffer) query))))
     (match-headers buffer))))

;;; websockets emulation using flash needs to be able to read a
;;; flash 'policy file' to connect
(defparameter *policy-file-request*
  (concatenate '(vector (unsigned-byte 8))
               (babel:string-to-octets "<policy-file-request/>")
               #(0)))

(defun match-policy-file (buffer)
  (next-reader-state
   buffer
   (octet-pattern-matcher #(0))
   (alexandria:named-lambda policy-file-callback (buffer)
     (let ((request (get-octet-vector (chunks buffer))))
       (unless (and request (equalp request *policy-file-request*))
         (lg "broken policy file request?~%")
         (return-from policy-file-callback
           (invalid-header buffer)))
       (lg "send policy file~%")
       (client-enqueue-write buffer *policy-file*)
       #++(%write-to-client buffer :close)
       #++(babel:octets-to-string *policy-file* :encoding :ascii)
       (client-disconnect buffer :read t :write t)
       (ignore-remaining-input buffer)))))

(defun maybe-policy-file (buffer)
  (next-reader-state buffer
                     (octet-count-matcher 2)
                     (lambda (buffer)
                       (if (eql (peek-octet (chunks buffer)) (char-code #\<))
                           (match-policy-file buffer)
                           (match-resource-line buffer)))))

(defun ignore-remaining-input (client)
  ;; just accept any input and junk it, for use when no more input expected
  ;; or we don't care...
  (next-reader-state client
                     (lambda (b s e)
                       (declare (ignore b))
                       (unless (= s e)
                        e))
                     (lambda (x) (declare (ignore x))
                             #|| do nothing ||#)))


(defun dispatch-protocols (client)
  (let* ((headers (client-connection-headers client))
         (version (gethash :sec-websocket-version headers)))
    (cond
      ((and (not version)
            (gethash :sec-websocket-key1 headers)
            (gethash :sec-websocket-key2 headers))
       ;; protocol 76/00
       (if *protocol-76/00-support*
           (protocol-76/00-nonce client)
           (unsupported-protocol-version client)))
      (version
       (if (gethash version *protocol-header-parsers*)
           (funcall (gethash version *protocol-header-parsers*)
                    client)
           (unsupported-protocol-version client)))
      (t
       (lg "couldn't detect version? headers=~s~%"
           (alexandria:hash-table-alist headers))
       (invalid-header client)))))


(defun match-headers (client)
  (next-reader-state
   client (octet-pattern-matcher #(13 10 13 10))
   (lambda (x)
     (let ((headers (with-buffer-as-stream (x s)
                      (chunga:read-http-headers s))))
       (setf (client-connection-headers client) (alexandria:alist-hash-table headers))
       (dispatch-protocols client)))))


;;; fixme: these foo-for-protocol should probably be split out into
;;; separate functions, and stored in thunks in the client or looked
;;; up in a hash (or generic function) or whatever...
(defun close-frame-for-protocol (protocol &key (code 1000) message)
  ;; not sure what 'protocol' should be for now... assuming protocol
  ;; version numbers (as integers) for now, with hixie-76/ietf-00 as 0
  (let ((utf8 (when message
                (babel:string-to-octets message :encoding :utf-8)))
        (code (if (and (integerp code) (<= 0 code 65535)
                       ;; MUST NOT send 1005 or 1006
                       (/= code 1005)
                       (/= code 1006))
                  code
                  1000)))
    (when (> (length utf8) 122)
      (setf utf8 nil))
    (case protocol
      (0 *draft-76/00-close-frame*)
      ((7 8 13)
       (flex:with-output-to-sequence (s)
         ;; FIN + opcode 8
         (write-byte #x88 s)
         ;; MASK = 0, length
         (write-byte (+ 2 (length utf8)) s)
         ;; status code (optional, but we always send one)
         (write-byte (ldb (byte 8 8) code) s)
         (write-byte (ldb (byte 8 0) code) s)
         (when utf8
           (write-sequence utf8 s)))))))

(defun pong-frame-for-protocol (protocol body)
  (when (> (length body) 125)
    (setf body nil))
  (case protocol
    (0 nil)
    ((7 8 13)
     (flex:with-output-to-sequence (s)
       ;; FIN + opcode 8
       (write-byte #x8a s)
       ;; MASK = 0, length
       (write-byte (length body) s)
       (when body
         (write-sequence body s))))))


(defun build-frames (opcode octets frame-size)
  ;; sending non-simple vectors is slow, so don't want to use
  ;; w-o-t-sequence here...
  (loop for op = opcode then 0
        for octets-left = (length octets) then (- octets-left frame-octets)
        for fin = (if (<= octets-left frame-size) #x80 #x00)
        for offset = 0 then (+ offset frame-octets)
        for frame-octets = (min octets-left frame-size)
        for length-octets = (if (< frame-octets 126)
                                0 (if (< frame-octets 65536) 2 8))
        collect (let ((a (make-array (+ 2 length-octets frame-octets)
                                     :element-type '(unsigned-byte 8)
                                     :initial-element 0)))
                  (setf (aref a 0) (logior fin op))
                  (cond
                    ((< frame-octets 126)
                     (setf (aref a 1) frame-octets))
                    ((< frame-octets 65536)
                     (setf (aref a 1) 126)
                     (setf (aref a 2) (ldb (byte 8 8) frame-octets))
                     (setf (aref a 3) (ldb (byte 8 0) frame-octets)))
                    (t
                     (setf (aref a 1) 127)
                     (loop for i from 7 downto 0
                           for j from 0
                           do (setf (aref a (+ j 2))
                                    (ldb (byte 8 (* i 8)) frame-octets)))))
                  (when (plusp frame-octets)
                    (if (typep octets '(simple-array (unsigned-byte 8) (*)))
                        ;; duplicated so smart compilers can optimize the
                        ;; common case
                        (replace a octets :start1 (+ 2 length-octets)
                                          :start2 offset :end2 (+ offset frame-octets))
                        (replace a octets :start1 (+ 2 length-octets)
                                          :start2 offset :end2 (+ offset frame-octets))))
                  a)
        ;; check at end so we can send an empty frame if we want
        while (and (plusp octets-left)
                   (/= octets-left frame-octets))))

(defun text-message-for-protocol (protocol message &key frame-size)
  (let* ((utf8 (if (stringp message)
                   (babel:string-to-octets message :encoding :utf-8)
                   message))
         (frame-size (or frame-size (1+ (length utf8)))))
    (case protocol
      (0
       ;; todo: decide if frame-size should apply to draft76/00 ?
       (list
        (flex:with-output-to-sequence (s)
          (write-byte #x00 s)
          (write-sequence utf8 s)
          (write-byte #xff s))))
      ((7 8 13)
       (build-frames #x01 utf8 frame-size)))))

(defun binary-message-for-protocol (protocol message &key frame-size)
  (let ((frame-size (or frame-size (1+ (length message)))))
    (case protocol
      (0
       (error "can't send binary messages to draft-00 connection"))
      ((7 8 13)
       (build-frames #x02 message frame-size)))))

(defun write-to-client-close (client &key (code 1000) message)
  "Write a close message to client, and starts closing connection. If set,
CODE must be a valid close code for current protocol version, and MESSAGE
should be a string that encodes to fewer than 123 octets as UTF8 (it will
be ignored otherwise)"
  (if (or code message)
      (%write-to-client client (list :close (close-frame-for-protocol
                                             (client-websocket-version client)
                                             :code code :message message)))
      (%write-to-client client :close)))

(defun write-to-client-text (client message &key frame-size)
  "writes a text message to client. MESSAGE should either be a string,
or an octet vector containing a UTF-8 encoded string. If FRAME-SIZE is
set, breaks message into frames no larger than FRAME-SIZE octets."
  (loop for frame in (text-message-for-protocol
                      (client-websocket-version client)
                      message
                      :frame-size frame-size)
        do (%write-to-client client frame)))


(defun write-to-client-binary (client message &key frame-size)
  "writes a binary message to client. MESSAGE should either be an
octet vector containing data to be sent. If FRAME-SIZE is set, breaks
message into frames no larger than FRAME-SIZE octets."
  (loop for frame in (binary-message-for-protocol
                      (client-websocket-version client)
                      message
                      :frame-size frame-size)
        do (%write-to-client client frame)))
