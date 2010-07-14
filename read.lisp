(in-package #:ws)

(defparameter *max-read-frame-size* 8192
  "Default buffer size for reading lines/frames.")

(defparameter *max-header-size* 16384
  "Default max header size in octets (not used yet?)")

;; 
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

(defparameter *404-message* (babel:string-to-octets
                             "HTTP/1.1 404 Resource not found

"
                             :encoding :utf-8))


(defparameter *allow-draft-75* t)

#+not-done-yet
(defun disable-readers-for-queue (client)
  (loop for c being the hash-values of *clients*
     when (eq c client)
     do (client-disable-handler client :read t)))
#+not-done-yet
(defun enable-readers-for-queue (client)
  (loop for c being the hash-values of *clients*
     when (eq c client)
     do (client-enable-handler client :read t)))

(defun valid-resource-p (resource)
  "Returns non-nil if there is a handler registered for the resource
of the given name (a string)."
  (declare (type string resource))
  (when resource
    (gethash resource *resources*)))

(defun handle-connection-header (client)
  "Parses the client's handshake and returns two values:

1.  Either :invalid-resource in the case of a bad request or the name
of the resource requested as a string.

2.  The headers received as an EQUALP hash table."

  #++(format t "parsing handshake: ~s~%"
          (mailbox-list-messages (client-read-queue client)))
  (let* ((resource nil)
         (headers nil)
         (resource-line (client-dequeue-read client))
         (s1 (position #\space resource-line))
         (s2 (if s1 (position #\space resource-line :start (1+ s1)))))
    #++(format t "checking header...~%")
    #++(format t "s1,s2=~s ~s~%" s1 s2)
    #++(format t "header : |~s~|~%" resource-line)
    #++(when s1
      (format t "GET: ~s =>~s~%" (subseq resource-line 0 s1)
             (string= "GET" (subseq resource-line 0 s1))))
    #++(when s2
      (format t "HTTP: ~s =>~s~%" (subseq resource-line s2)
             (string= " HTTP/1.1" (subseq resource-line s2))))
    (when (and s1 s2
               (string= "GET" (subseq resource-line 0 s1))
               (string= " HTTP/1.1" (subseq resource-line s2)))
      (setf resource (subseq resource-line (1+ s1) s2)))

    (when resource
      ;; resources must be absolute path (start with /),
      ;; otherwise abort connection
      (unless (char= (aref resource 0) #\/)
        (return-from handle-connection-header
          (values :invalid-resource nil)))
      ;; if we don't recognize the resource, return 404
      (unless (valid-resource-p resource)
        (lg "unknown resource ~s~%" resource)
        (return-from handle-connection-header
          (values :404 nil)))
      ;; otherwise try to parse remaining headers
      ;; (headers field names are case insensitive so use equalp)
      (setf headers (make-hash-table :test 'equalp))
      (loop for l = (client-dequeue-read client)
         while l
         for c = (position #\: l)
         do
         ;; check for malformed headers
         ;; (spec draft allows either ignoring them, or aborting
         ;;  connection, so aborting for now)
           (unless c
             (lg "header line missing #\: \"~s\"~%" l)
             (return-from handle-connection-header
               (values :invalid-header nil)))
         ;; otherwise store the header into the hash
           (setf (gethash (subseq l 0 c) headers)
                 (subseq l (+ (if (and (< c (1- (length l)))
                                       (char= #\space (aref l (1+ c))))
                                  2 1)
                              c)))))
    (values (or resource :invalid-handshake) headers)))

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
                   #++(Format t "got key = ~s -> ~s (~s)~%" n d r)
                   (when (zerop r)
                     d))))))
;; (extract-key "3e6b263  4 17 80") -> 906585445
;; (extract-key "17  9 G`ZD9   2 2b 7X 3 /r90") -> 179922739

(Defun make-challenge (k1 k2)
  (let ((b (make-array 16 :element-type '(unsigned-byte 8))))
    (loop for i from 0 below 4
       for j from 24 downto 0 by 8
       do (setf (aref b i) (ldb (byte 8 j) k1))
       do (setf (aref b (+ 4 i)) (ldb (byte 8 j) k2)))
    #++(format t "made challenge  (~{0x~2,'0x ~}) ~%" (coerce b 'list))
    b))

(defparameter *reader-fsm* (make-hash-table)
  "Mapping of state to lambda.

- lambda handles a buffer, and returns new state + extra state info to
pass to next call")

(defmacro define-reader-state (state lambda-list &body body)
  "Defines a state and associated lambda used by the reader finite
state machine.  STATE is a keyword, lambda-list should be a lambda
list capable of handling (buffer client state) arguments, and body is
the body of the lambda.  The lambda handles a buffer, and returns new
state + extra state info to pass to next call"
  `(setf (gethash ,state *reader-fsm*)
         (lambda ,lambda-list ,@body)))

(define-reader-state :maybe-policy-file (buffer client state)
  "In order to support the .swf websocket emulation, we optionally can
send a policy file on the socket instead of making a ws connection in
that case, we read \"<policy-file-request/>\0\" and respond with
policy file followed by 0 octet and close the socket."
  (declare (ignore client state))
  (cond
    ((= (aref buffer 0) (char-code #\<))
     (values :policy-file (list :start 0)))
    ((= (aref buffer 0) (char-code #\G))
     (values :header (list :start 0)))
    (t
     (lg "bad header?, got ~s = ~s~%"
         buffer
         (babel:octets-to-string buffer :errorp nil))
     (values :abort nil))))

(define-reader-state :policy-file (b client state)
  "We might be getting a policy file request, so check for and handle
that case"
  (let* ((start (getf state :start))
         (p (position 0 b :start (or start 0)))
         (junk nil))
    ;; fixme: optimize for the (usual) case where we get request as 1 pkt
    (store-partial-read client b (list start p))
    (cond
      ((and p (string= (setf junk (extract-read-chunk-as-utf-8 client))
                       "<policy-file-request/>"))
       (lg "got policy request = ~s~%" junk)
       ;; got a policy request, send response and close connection
       (client-enqueue-write client *policy-file*)
       (client-enqueue-write client :close)
       (values :close-read nil))
      (p
       (lg "got malformed policy request = ~s~%" junk)
       ;; got a whole 0 terminated chunk, but didn't match, kill connection
       (values :abort nil))
      ((> (client-read-buffer-octets client)
          (length "<policy-file-request/>" ))
       ;; got more octets than expected without a valid request,
       ;; kill connection
       (lg "got oversized policy request~%")
       (values :abort nil))
      ((> (length (client-read-buffers client)) *read-max-fragments*)
       ;; got too many tiny fragments, kill connection
       (lg "got overly fragmented policy request~%")
       (values :abort nil))
      (t
       (lg "got partial policy request?~%")
       ;; not enough octets to tell yet, keep reading...
       (values :policy-file nil)))))

(define-reader-state :header (b client state)
  "Reading header -- for now just accumulating lines until CRLFCRLF or
too many bytes read probably should add a real parser at some point,
and for policy-file as well."
  (let* ((start (getf state :start))
         (cr (position #x0d b :start (or start 0)))
         (next (if (and cr (< (1+ cr) (length b))) (1+ cr))))
    (cond
      ((and cr (eql start cr))
       ;; got empty line, check for final LF and finish header
       (values :header-final-lf (if next (list :start next))))
      ((and cr)
       ;; got end of line, check for LF and extract a line
       (store-partial-read client b (list start cr))
       (values :header-lf (if next (list :start next))))
      ((> (client-read-buffer-octets client)
          *max-header-size*)
       ;; header too big, kill connection...
       (lg "read too many octets without finishing header?~%")
       (values :abort nil))
      ((> (length (client-read-buffers client)) *read-max-fragments*)
       ;; got too many tiny fragments, kill connection
       (lg "got too many fragments reading header?~%")
       (values :abort nil))
      (t
       ;; not enough octets to tell yet, store what we have and
       ;; keep reading...
       (store-partial-read client b (list start ))
       (values :header nil)))))

(define-reader-state :header-lf (b client state)
  (let* ((start (or (getf state :start) 0))
         (next (if (< (1+  start) (length b)) (1+ start))))
    (cond
      ((and (> (length b) start) (eql #x0a (aref b start)))
       ;; got CRLF pair, extract a string and add to queue,
       ;; then go back to reading header lines
       (let ((l (extract-read-chunk-as-utf-8 client)))
         (if (zerop (length l))
             (values :header-final-lf (list :start start))
             (progn (client-enqueue-read client l)
                    (values :header (if next (list :start next)))))))
      (t ;; assuming 0 length packets won't happen for now...
       ;; no LF, kill connection
       (lg "got CR without LF?")
       (values :abort nil)))))


(define-reader-state :header-final-lf (b client state)
  (let* ((start (or (getf state :start) 0))
         (next (if (< (1+ start) (length b)) (1+ start)))
         k1 k2)
    (cond
      ((and (> (length b) start) (eql #x0a (aref b start)))
       ;; got final CRLF pair, parse the header
       ;; then go to frame mode
       (multiple-value-bind (resource headers)
           (handle-connection-header client)
         (setf (client-connection-headers client) headers)
         ;; fixme: probably should dispatch on type or something
         ;; so we can catch unexpected other symbols if
         ;; handle-connection-header is modified without matching
         ;; changes here
         (case resource
           (:404
              (client-enqueue-write client *404-message*)
              (client-enqueue-write client :close)
              (values :close-read nil))
           ((:invalid-handshake :invalid-header :invalid-resource)
              (lg "bad header ~s~%" resource)
              (values :abort nil))
           (t
              (cond
                ((and (string= (gethash "Connection" headers "") "Upgrade")
                      (string= (gethash "Upgrade" headers "") "WebSocket")
                      (setf k1 (extract-key (gethash "Sec-WebSocket-Key1"
                                                     headers nil)))
                      (setf k2 (extract-key (gethash "Sec-WebSocket-Key2"
                                                     headers nil))))
                 (values :draft-76-key3
                         `(,@(if next (list :start next))
                             :resource ,resource
                             :count 0
                             :octets ,(make-challenge k1 k2)
                             )))
                ((and *allow-draft-75* ;; fixme: don't duplicate these
                      (string= (gethash "Connection" headers "") "Upgrade")
                      (string= (gethash "Upgrade" headers "") "WebSocket"))
                 (values :handshake-done `(,@(if next (list :start next))
                                             :resource ,resource
                                             :version :draft-75)))
                (t ;; bad header
                 (values :abort nil)))))))
      (t ;; assuming 0 length packets won't happen for now...
       ;; no LF, kill connection
       (lg "got CR without LF on final header line?")
       (values :abort nil)))))


(define-reader-state :draft-76-key3 (b client state)
  "Using draft 76 or later, check for key3 octets."
  (declare (ignore client))
  (let* ((count (getf state :count))
         (octets (getf state :octets))
         (start (getf state :start 0))
         (next nil)
         (needed (- 8 count)))
    (cond
      ((and (>= (- (length b) start) needed))
       ;; we can finish the challenge, do so
       (replace octets b :start2 start :end2 (+ start needed)
                :start1 (+ 8 count) :end1 16)
       (when (< (+ start needed) (length b))
         (setf next (+ start needed)))
       (values :handshake-done
               `(,@(if next (list :start next))
                   :resource ,(getf state :resource)
                   :challenge-response ,(ironclad:digest-sequence
                                         'ironclad:md5 octets)
                   :version :draft-76)))
      ((and (> (length b) start))
       ;; todo : read partial key3
       (format t "fragmented key3?~%")
       (format t " octets remaining = ~s~%"
               (subseq b start))
       (values :abort nil))
      (t ;; assuming 0 length packets won't happen for now...
       (format t "draft-76-challenge broken?")
       (values :abort nil)))))

(define-reader-state :handshake-done (b client state)
  "Finished handshake, start connectioon."
  (declare (ignore b))
  ;; if header parsed OK, see if the origin is valid
  ;; send handshake and start reading frames
  (let ((headers (client-connection-headers client))
        (next (getf state :start))
        (resource (getf state :resource))
        (version (getf state :version))
        (challenge-response (getf state :challenge-response)))
    (destructuring-bind (resource-handler check-origin)
        (valid-resource-p resource)
      (cond
        ((not (funcall check-origin (gethash "Origin" headers)))
         (lg "got bad origin ~s~%" (gethash "Origin" headers))
         ;; unknown origin, just drop the connection
         ;; possibly should return an error code instead?
         (values :abort nil))
        (t
         (multiple-value-bind (rqueue origin handshake-resource protocol)
             (ws-accept-connection resource-handler resource
                                   headers
                                   client)
           (setf (client-read-queue client) rqueue)
           (client-enqueue-write client
                                 (make-handshake
                                  (or origin
                                      (gethash "Origin" headers)
                                      "http://127.0.0.1/")
                                  (let ((*print-pretty*))
                                    (format nil "~a~a~a"
                                            "ws://"
                                            (or (gethash "Host" headers)
                                                "127.0.0.1:12345")
                                            (or handshake-resource
                                                resource)))
                                  (or protocol
                                      (gethash "WebSocket-Protocol" headers)
                                      "test")
                                  version))
           (when challenge-response
             (client-enqueue-write client challenge-response)))
         (values :frame-00 (if next (list :start next))))))))


(define-reader-state :frame-00 (b client state)
  "For now only handling 00.ff frames, not other text/binary frame types."
  (declare (ignore client))

  (let* ((start (or (getf state :start) 0))
         (next (if (< start (1+ (length b))) (1+ start))))
    (cond
      ((and (> (length b) start) (eql #x00 (aref b start)))
       ;; got beginning of frame marker, look for end...
       (values :frame-ff (if next (list :start next))))
      ((and (> (length b) start) (eql #xff (aref b start)))
       ;; got binary frame/close frame marker, look for end...
       (values :bin-frame-length (if next (list :start next))))
      (t
       ;; got empty packet (something broken?) or unsupported frame type
       ;; (or junk between frames)
       (lg "got bad frame marker, expected #x00? got ~s~%"
           (if (> (length b) start)
               (aref b start)
               "not enough octets"))
       (values :abort nil)))))

(define-reader-state :frame-ff (b client state)
  (let* ((start (getf state :start))
         (ff (position #xff b :start (or start 0)))
         (next (if (and ff (< (1+ ff) (length b))) (1+ ff))))
    (store-partial-read client b (list start ff))
    (cond
      (ff
       ;; got end of frame marker, extract a frame, queue it, and
       ;; look for next frame
       (let ((f (extract-read-chunk-as-utf-8 client)))
         (client-enqueue-read client (list client f))
         #++(lg "got frame, next=~s, ff=~s, len=~s~%  frame = ~s~%"
                next ff (length b) f))
       (cond
         ((> (mailbox-count (client-read-queue client))
             *max-handler-read-backlog*)
          ;; if server isn't processing events fast enuogh, disable the
          ;; reader temporarily and tell the handler
          (when (client-reader-active client)
            (client-disable-handler client :read t)
            (client-enqueue-read client (list client :flow-control)))
          (values :frame-00 (if next (list :start next))))
         (t
          (values :frame-00 (if next (list :start next))))))
      ((> (client-read-buffer-octets client)
          *max-read-frame-size*)
       ;; frame too big, kill connection...
       (lg "read too many octets without finishing frame?")
       (values :abort nil))
      ((> (length (client-read-buffers client)) *read-max-fragments*)
       ;; got too many tiny fragments, kill connection
       (lg "got too many fragments without finishing frame?~%")
       (values :abort nil))
      (t
       ;; not enough octets to tell yet, keep reading...
       (values :frame-ff nil)))))

(define-reader-state :bin-frame-length (b client state)
  (declare (ignore client))
  (let* ((start (or (getf state :start) 0))
         #++(next (if (< (1+  start) (length b)) (1+ start))))
    (cond
      ((and (> (length b) start) (eql #x00 (aref b start)))
       ;; got draft-76/00 close frame, close connection
       ;; read handler sends :eof to handler, so relying on that for now
       (values :close-read nil))
      (t
       ;; other binary frames not supported yet, kill connection...
       (lg "got unsupported binary frame?")
       (values :abort nil)))))

(define-reader-state :close (&rest r)
  (declare (ignore r))
  (error "reader kept reading on socket that should have been closed?"))

(define-reader-state :abort (&rest r)
  (declare (ignore r))
  (error "reader kept reading on socket that should have been aborted?"))


(defun add-reader-to-client (client)
  "Supplies the client with a reader function responsible for
processing input coming in from the client."
  (setf (client-reader client)
        (lambda (fd event exception)
          (declare (ignore fd event exception))
          (let* ((octets (make-array 2048 :element-type '(unsigned-byte 8)
                                     :fill-pointer 2048))
                 (socket (client-socket client)))
            (handler-case
                (progn
                  (multiple-value-bind (_octets count)
                      ;; fixme: decide on good max read chunk size
                      (receive-from socket :buffer octets :end 2048)
                    (declare (ignore _octets))
                    (setf (fill-pointer octets) count)
                    #++(format t "(frame) read ~s octets...~%" count)
                    (when (zerop count)
                      (error 'end-of-file))
                    #++(format t "  ==  |~s|~%"
                            (babel:octets-to-string octets
                                                    :encoding :utf-8
                                                    :errorp nil))
                    (loop 
                      :with next-state
                      :with next-data
                      :for state = (client-read-state client) :then next-state
                      :for data = nil :then next-data
                      :do
                      ;; Perform the finite-state-machine transition
                      (setf (values next-state next-data)
                            (funcall (gethash state *reader-fsm*)
                                     octets client data))

                      ;; Handle special-cased FSM states
                      (case next-state
                        ((:close :close-read)
                           (client-enqueue-read client (list client :eof))
                           (client-disconnect client
                                              :read t
                                              :write (eq next-state :close))
                           (loop-finish))
                        (:abort
                           (format t "aborting connection~%")
                           (client-enqueue-read client (list client :dropped))
                           (client-disconnect client :abort t)
                           (loop-finish)))
                      (unless next-data
                        (loop-finish))
                      :finally (setf (client-read-state client) next-state))))
              ;; close connection on socket/read errors
              (end-of-file ()
                (client-enqueue-read client (list client :eof))
                (format t "closed connection ~s / ~s~%" (client-host client)
                        (client-port client))
                (client-disconnect client :read t
                                   :write (not (member
                                                (client-read-state client)
                                                '(:frame-00 :frame-ff)))))
              (socket-connection-reset-error ()
                (client-enqueue-read client (list client :eof))
                (format t "connection reset by peer ~s / ~s~%" (client-host client)
                        (client-port client))
                (client-disconnect client :read t))
              ;; ... add error handlers
              ))))
  (client-enable-handler client :read t))
