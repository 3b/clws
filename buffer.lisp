(in-package #:ws)

;;; chunks stored by chunk-buffer class
(defclass buffer-chunk ()
  ((vector :reader buffer-vector :initarg :vector)
   (start :reader buffer-start :initarg :start)
   (end :reader buffer-end :initarg :end)))

(defmethod buffer-count ((buffer buffer-chunk))
  (- (buffer-end buffer) (buffer-start buffer)))


;;; chunked buffer class
;;; stores a sequence of vectors + start/end
;;;   intent is that one chunked-buffer is a single logical block of data
;;;   and will be consumed all at once after it is accumulated
;;; operations:
;;;   add a chunk (vector+bounds)
;;;     -- check last chunk and combine if contiguous
;;;   append another buffer
;;;     -- combine last/first chunks if contiguous?
;;;   read an octet
;;;   convert to a contiguous vector
;;;   (32bit xor for websockets masking stuff? maybe subclass?)
;;;   convert (as utf8) to string
;;;   call thunk with contents as (binary or text) stream?
;;;    -- or maybe return a stream once it is implemented directly
;;;       as a gray stream rather than a pile of concatenated
;;l       and flexi-streams?
;;;   ? map over octets/characters?
;;; todo: versions of octet-vector and string that don't clear buffer?
;;;   (mostly for debugging)
;;; todo: option to build octet vector with extra space at beginning/end?
;;;   (for example to make a pong response from a ping body)

(defclass chunk-buffer ()
  ((buffer-size :accessor buffer-size :initform 0)
   (chunks :accessor chunks :initform nil)
   ;; reference to last cons of chunks list, so we can append quickly
   (end-of-chunks :accessor end-of-chunks :initform nil)))

(defmethod %get-chunks ((cb chunk-buffer))
  (setf (end-of-chunks cb) nil)
  (values (shiftf (chunks cb) nil)
          (shiftf (buffer-size cb) 0)))

(defmethod add-chunk ((cb chunk-buffer) vector start end)
  (if (chunks cb)
      ;; we already have some chunks, add at end
      (let ((last (end-of-chunks cb)))
        ;; if we are continuing previous buffer, just combine them
        (if (and (eq vector (buffer-vector (car last)))
                 (= start (buffer-end (car last))))
            (setf (slot-value (car last) 'end) end)
            ;; else add new chunk
            (progn
              (push (make-instance 'buffer-chunk :vector vector
                                                 :start start :end end)
                    (cdr last))
              (pop (end-of-chunks cb)))))
      ;; add initial chunk
      (progn
        (push (make-instance 'buffer-chunk :vector vector
                                           :start start :end end)
              (chunks cb))
        (setf (end-of-chunks cb) (chunks cb))))
  (incf (buffer-size cb) (- end start)))

;;; fixme: should this make a new chunk-buffer? not clear more? reuse chunk-buffers better?
(defmethod add-chunks ((cb chunk-buffer) (more chunk-buffer))
  (loop for i in (%get-chunks more)
        do (add-chunk cb (buffer-vector i) (buffer-start i) (buffer-end i))))

(defmethod peek-octet ((cb chunk-buffer))
  ;; fixme: decide how to handle EOF?
  (unless (chunks cb)
    (return-from peek-octet nil))
  (let* ((chunk (car (chunks cb))))
    (aref (buffer-vector chunk) (buffer-start chunk))))

(defmethod read-octet ((cb chunk-buffer))
  ;; fixme: decide how to handle EOF?
  (unless (chunks cb)
    (return-from read-octet nil))
  (let* ((chunk (car (chunks cb)))
         (octet (aref (buffer-vector chunk) (buffer-start chunk))))
    (incf (slot-value chunk 'start))
    (decf (buffer-size cb))
    ;; if we emptied a chunk, get rid of it
    (when (= (buffer-start chunk) (buffer-end chunk))
      (pop (chunks cb))
      ;; and clear end ref as well if no more buffers
      (when (not (chunks cb))
        (setf (end-of-chunks cb) nil)))
    octet))

(defun call-with-buffer-as-stream (buffer thunk)
  (let ((streams nil))
    (unwind-protect
         (progn
           (setf streams
                 (loop for i in (%get-chunks buffer)
                       while i
                       collect (flex:make-in-memory-input-stream
                                (buffer-vector i)
                                :start (buffer-start i)
                                :end (buffer-end i))))
           (with-open-stream (cs (apply #'make-concatenated-stream streams))
             (funcall thunk cs)))
      (map 'nil 'close streams))))

(defmacro with-buffer-as-stream ((buffer stream) &body body)
  `(call-with-buffer-as-stream ,buffer
                               (lambda (,stream)
                                 ,@body)))

(defmethod get-octet-vector ((cb chunk-buffer))
  (let* ((size (buffer-size cb))
         (vector (make-array size :element-type '(unsigned-byte 8)
                                  :initial-element 0))
         (chunks (%get-chunks cb)))
    (loop for c in chunks
          for offset = 0 then (+ offset size)
          for size = (buffer-count c)
          for cv = (buffer-vector c)
          for cs = (buffer-start c)
          for ce = (buffer-end c)
          do (replace vector cv :start1 offset :start2 cs :end2 ce))
    vector))

(defmethod get-utf8-string ((cb chunk-buffer) &key (errorp t) octet-end)
  (declare (ignorable errorp))
  ;; not sure if it would be faster to pull through flexistreams
  ;; or make a separate octet vector and convert that with babel?
  ;; (best would be converting directly... possibly check for partial
  ;;  character at beginning of buffer, find beginning in previous buffer
  ;;  and only pass the valid part to babel, and add in the split char
  ;;  by hand? might need to watch out for split over multiple buffers
  ;;  if we get tiny chunks? (only when searching forward though, since
  ;;   we should see the partial char in the first tiny chunk...)
  ;;  (or maybe just implement our own converter since we only need utf8?))
  (let* ((size (buffer-size cb))
         (end (or octet-end size))
         (vector (make-array end
                             :element-type '(unsigned-byte 8)
                             :initial-element 0))
         (chunks (%get-chunks cb)))
    (loop for c in chunks
          for offset = 0 then (+ offset size)
          for size = (buffer-count c)
          for cv of-type (simple-array (unsigned-byte 8) (*)) = (buffer-vector c)
          for cs = (buffer-start c)
          for ce = (buffer-end c)
          while (< offset end)
          do (replace vector cv :start1 offset :end1 end
                                :start2 cs :end2 ce))
    ;; todo: probably should wrap babel error in something that doesn't leak
    ;; implementation details (like use of babel)
    #++(babel:octets-to-string vector :encoding :utf-8 :errorp errorp)
    ;; babel isn't picky enough for the Autobahn test suite (it lets
    ;; utf16 surrogates through, so using flexistreams for now...
    (flex:octets-to-string vector :external-format :utf-8)))

;;; this doesn't really belong here, too lazy to make a websockets
;;; specific subclass for now though
(defmethod mask-octets ((cb chunk-buffer) mask)
  (declare (type (simple-array (unsigned-byte 8) (*)) mask)
           (optimize speed))
  ;; todo: declare types, optimize to run 32/64 bits at a time, etc...
  (loop with i of-type (integer 0 4) = 0
        for chunk in (chunks cb)
        for vec of-type (simple-array (unsigned-byte 8) (*)) = (buffer-vector chunk)
        for start fixnum = (buffer-start chunk)
        for end fixnum = (buffer-end chunk)
        do (loop for j from start below end
                 do (setf (aref vec j)
                          (logxor (aref vec j)
                                  (aref mask i))
                          i (mod (1+ i) 4)))))

#++
(flet ((test-buf ()
         (let ((foo (make-instance 'chunk-buffer))
               (buf (babel:string-to-octets "_<continued-test>_")))
           (add-chunk foo (babel:string-to-octets "TEST" ) 0 4)
           (add-chunk foo (babel:string-to-octets "test2") 0 5)
           (add-chunk foo buf 1 5)
           (add-chunk foo buf 5 (1- (length buf)))
           (add-chunk foo (babel:string-to-octets "..test3") 2 7)
           foo)))
  (list
   (with-buffer-as-stream ((test-buf) s)
     (with-open-stream (s (flex:make-flexi-stream s))
       (read-line s nil nil)))
   (babel:octets-to-string (get-octet-vector (test-buf)))
   (get-utf8-string (test-buf))))

#++
(let ((foo (make-instance 'chunk-buffer)))
  (add-chunk foo #(1 2 3 4) 0 3)
  (add-chunk foo #(10 11 12 13) 0 1)
  (add-chunk foo #(20 21 22 23) 0 3)
  (loop repeat 10 collect (read-octet foo)))





;;; buffered reader class
;;; reads from a socket (or stream?) until some condition is met
;;;   (N octets read, specific pattern read (CR LF for example), etc)
;;; then calls a continuation callback, or calls error callback if
;;; connection closed, or too many octets read without condition being matched


(defclass buffered-reader ()
  (;; partially filled vector if any, + position of next empty octet
   (partial-vector :accessor partial-vector :initform nil)
   (partial-vector-pos :accessor partial-vector-pos :initform 0)
   ;; list of arrays + start,end values (in reverse order)
   (chunks :initform (make-instance 'chunk-buffer) :accessor chunks)
   ;; function to call with new data to determine if callback should
   ;; be called yet
   (predicate :initarg :predicate :accessor predicate)
   (callback :initarg :callback :accessor callback)
   (error-callback :initarg :error-callback :accessor error-callback)))

;;; allow calling some chunk-buffer functions on the buffered-reader
;;; and redirect to the slot...
(defmethod %get-chunks ((b buffered-reader))
  (%get-chunks (chunks b)))

(define-condition fail-the-websockets-connection (error)
  ((code :initarg :status-code :initform nil :reader status-code)
   ;; possibly should include a verbose message for logging as well?
   (message :initarg :message :initform nil :reader status-message)))

;; should this be an error?
(define-condition close-from-peer (error)
  ((code :initarg :status-code :initform 1000 :reader status-code)
   (message :initarg :message :initform nil :reader status-message)))

;;; low level implementations
;;; non-blocking iolib
;;;    when buffer gets more data, it checks predicate and calls
;;;    callback if matched. Callback sets new predicate+callback, and
;;;    loop repeats until predicate doesn't match, at which point it
;;;    waits for more input
(defun add-reader-to-client (client &key (init-function 'maybe-policy-file))
  (declare (optimize debug))
  (setf (client-reader client)
        (let ((socket (client-socket client))
              (buffer client))
          (funcall init-function buffer)
          (lambda (fd event exception)
            (declare (ignore fd event exception))
            (handler-bind
                ((error
                   (lambda (c)
                     (cond
                       (*debug-on-server-errors*
                        (invoke-debugger c))
                       (t
                        (ignore-errors
                         (lg "server error ~s, dropping connection~%" c))
                        (invoke-restart 'drop-connection))))))
              (restart-case
                  (handler-case
                      (progn
                        (when (or (not (partial-vector buffer))
                                  (> (partial-vector-pos buffer)
                                     (- (length (partial-vector buffer)) 16)))
                          (setf (partial-vector buffer)
                                (make-array 2048 :element-type '(unsigned-byte 8))
                                (partial-vector-pos buffer) 0))
                        (multiple-value-bind (_octets count)
                            ;; fixme: decide on good max read chunk size
                            (receive-from socket :buffer (partial-vector buffer)
                                                 :start (partial-vector-pos buffer)
                                                 :end (length (partial-vector buffer)))
                          (declare (ignore _octets))
                          (when (zerop count)
                            (error 'end-of-file))
                          (let* ((start (partial-vector-pos buffer))
                                 (end (+ start count))
                                 (failed nil))
                            (loop for match = (funcall (predicate buffer)
                                                       (partial-vector buffer)
                                                       start end)
                                  do
                                     (add-chunk (chunks buffer)
                                                (partial-vector buffer)
                                                start (or match end))
                                     (when match
                                       (setf start match)
                                       (funcall (callback buffer) buffer))
                                  while (and (not failed) match (>= end start)))
                            ;; todo: if we used up all the data that
                            ;; was read, dump the buffer in a pool or
                            ;; something so we don't hold a buffer in
                            ;; ram for each client while waiting for
                            ;; data
                            (setf (partial-vector-pos buffer) end))))
                    ;; protocol errors
                    (fail-the-websockets-connection (e)
                      (when (eq (client-connection-state client) :connected)
                        ;; probably can send directly since running from
                        ;; server thread here?
                        (write-to-client-close client :code (status-code e)
                                                      :message (status-message e)))
                      (setf (client-connection-state client) :failed)
                      (client-enqueue-read client (list client :eof))
                      (lg "failed connection ~s / ~s : ~s ~s~%"
                          (client-host client) (client-port client)
                          (status-code e) (status-message e))
                      (client-disconnect client :read t
                                                :write t))
                    (close-from-peer (e)
                      (when (eq (client-connection-state client) :connected)
                        (write-to-client-close client))
                      (lg "got close frame from peer: ~s / ~s~%"
                          (status-code e) (status-message e))
                      (setf (client-connection-state client) :cloed)
                      ;; probably should send code/message to resource handlers?
                      (client-enqueue-read client (list client :eof))
                      (client-disconnect client :read t
                                                :write t))
                    ;; close connection on socket/read errors
                    (end-of-file ()
                      (client-enqueue-read client (list client :eof))
                      (lg "closed connection ~s / ~s~%" (client-host client)
                          (client-port client))
                      (client-disconnect client :read t
                                                :write t))
                    (socket-connection-reset-error ()
                      (client-enqueue-read client (list client :eof))
                      (lg "connection reset by peer ~s / ~s~%"
                          (client-host client)
                          (client-port client))
                      (client-disconnect client :read t))
                    ;; ... add error handlers
                    )
                (drop-connection ()
                  (client-disconnect client :read t :write t :abort t)))))))
  (client-enable-handler client :read t))

(defun next-reader-state (buffer predicate callback)
  (setf (predicate buffer) predicate
        (callback buffer) callback))
