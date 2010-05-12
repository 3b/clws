(in-package #:ws)

;;; per-client data

(defclass client ()
  ((port :initarg :port :reader client-port)
   (host :initarg :host :reader client-host)
   ;; function to call to send a command to the network thread from other threads
   (server-hook :initarg :server-hook :reader %client-server-hook)
   (socket :initarg :socket :reader client-socket)
   ;; flags indicating the read/write handlers are active
   (reader-active :initform nil :accessor client-reader-active)
   (writer-active :initform nil :accessor client-writer-active)
   (error-active :initform nil :accessor client-error-active)
   ;; flags indicating (one side of) the connection is closed
   (read-closed :initform nil :accessor client-read-closed)
   (write-closed :initform nil :accessor client-write-closed)
   (closed :initform nil :accessor client-socket-closed)
   ;; buffer being written currently, if last write couldn't send whole thing
   (write-buffer :initform nil :accessor client-write-buffer)
   ;; offset into write-buffer if write-buffer is set
   (write-offset :initform 0 :accessor client-write-offset)
   ;; queue of buffers (octet vectors) to write, or :close to kill connection
   (write-queue :initform (sb-concurrency:make-queue)
                :reader client-write-queue)
   ;; list of partial buffers + offsets of CR/LF/etc to be decoded into
   ;; a line/frame once the end is found
   ;; offsets are inclusive start/end pairs, NIL for continued from previous
   ;;   or continued to next chunk
   (read-buffers :initform nil :accessor client-read-buffers)
   ;; total octets in read-buffers (so we can reject overly large frames/headers)
   ;; fixme: probably should hide write access to counts behind functions that manipulate the buffer?
   (read-buffer-octets :initform 0 :accessor client-read-buffer-octets)
   ;; queue of decoded lines/frames
   (read-queue :initform (sb-concurrency:make-mailbox)
               ;; possibly should have separate writer?
               :accessor client-read-queue)
   ;; reader fsm state
   (read-state :initform :maybe-policy-file :accessor client-read-state)
   ;; read handler for this queue/socket
   (reader :initform nil :accessor client-reader)))


(defun try-write-client (client)
  (handler-case
      (loop
         unless (client-write-buffer client)
         do
           (setf (client-write-buffer client)
                 (sb-concurrency:dequeue (client-write-queue client)))
           (setf (client-write-offset client) 0)
         ;; if we got a :close command, clean up the socket
         when (eql (client-write-buffer client) :close)
         do
           (client-disconnect client :close t)
           (return-from try-write-client nil)
         when (client-write-buffer client)
         do
           (let ((count (send-to (client-socket client)
                                 (client-write-buffer client)
                                 :start (client-write-offset client)
                                 :end (length (client-write-buffer client)))))
             (incf (client-write-offset client) count)
             (when (>= (client-write-offset client)
                       (length (client-write-buffer client)))
               (setf (client-write-buffer client) nil)))
         ;; if we didn't write the entire buffer, make sure the writer is
         ;; enabled, and exit the loop
         when (client-write-buffer client)
         do
           (client-enable-handler client :write t)
           (loop-finish)
         when (sb-concurrency:queue-empty-p (client-write-queue client))
         do
           (client-disable-handler client :write t)
           (loop-finish))
    (isys:ewouldblock ()
      (format t "ewouldblock~%")
      nil)
    (isys:epipe ()
      ;; client closed conection, so drop it...
      (lg "epipe~%")
      (client-disconnect client :close t))
    (socket-connection-reset-error ()
      (lg "connection reset~%")
      (client-disconnect client :close t))))

(defmethod client-enable-handler ((client client) &key read write error)
  #++
  (lg "enable handlers for ~s:~s ~s ~s ~s~%"
      (client-host client) (client-port client) read write error)
  (when (socket-os-fd (client-socket client))
    (let ((fd (socket-os-fd (client-socket client))))

      (when (and write
                 (not (client-writer-active client))
                 (not (client-write-closed client)))
        (set-io-handler *event-base* fd
                       :write (lambda (fd event exception)
                                (declare (ignore fd event exception))
                                (try-write-client client)))
        (setf (client-writer-active client) t))

      (when (and read
                 (not (client-reader-active client))
                 (not (client-read-closed client)))
        (set-io-handler *event-base* fd :read (client-reader client))
        (setf (client-reader-active client) t))

      (when (and error (not (client-error-active client)))
        (error "error handlers not implemented yet...")))))

(defmethod client-disable-handler ((client client) &key read write error)
  #++
  (lg "disable handlers for ~s:~s ~s ~s ~s~%"
      (client-host client) (client-port client) read write error)
  (let ((fd (socket-os-fd (client-socket client))))
    (when (and write (client-writer-active client))
      (remove-fd-handlers *event-base* fd :write t)
      (setf (client-writer-active client) nil))
    (when (and read (client-reader-active client))
      (remove-fd-handlers *event-base* fd :read t)
      (setf (client-reader-active client) nil))
    (when (and error (client-error-active client))
      (error "error handlers not implemented yet..."))))

(defmethod client-disconnect ((client client) &key read write close abort)
  "shutdown 1 or both sides of a connection, close it if both sides shutdown"
  (lg "disconnect for ~s:~s ~s ~s / ~s ~s~%"
      (client-host client) (client-port client) read write close abort)
  (unless (client-socket-closed client)
    (macrolet ((ignore-some-errors (&body body)
                 `(handler-case
                     (progn ,@body)
                   (socket-not-connected-error ()
                     (format t "enotconn~%")
                     nil)
                   (isys:epipe ()
                     (format t "epipe in disconnect~%")
                     nil)
                   (isys:enotconn ()
                     (format t "enotconn in shutdown/close?")
                     nil))))
      (let* ((socket (client-socket client))
             (fd (socket-os-fd socket)))
        (when (or read close abort)
          ;; is all of this valid/useful for abort?
          (unless (client-read-closed client)
            (ignore-some-errors (client-disable-handler client :read t))
            (ignore-some-errors (shutdown socket :read t))
            (setf (client-read-closed client) t)))
        (when (or write close abort)
          ;; is all of this valid/useful for abort?
          (unless (client-write-closed client)
            (ignore-some-errors (client-disable-handler client :write t))
            (ignore-some-errors (shutdown socket :write t))
            (setf (client-write-closed client) t)))
        (when (or close abort
                  (and (client-read-closed client)
                       (client-write-closed client)))
          ;; shouldn't need to remove read/write handlers by this point?
          (when (or (client-reader-active client)
                    (client-writer-active client)
                    (client-error-active client))
            (ignore-some-errors (remove-fd-handlers *event-base* fd :read t :write t :error t)))
          (ignore-some-errors (close socket :abort abort))))))
  (when (or close abort)
    (setf (client-socket-closed client) t)
    (remhash client *clients*)))




;;; fixme: decide if any of these should be methods? (or others should be functions?)

(defun client-enqueue-write (client data)
  (sb-concurrency:enqueue data (client-write-queue client))
  (try-write-client client))

(defparameter %frame-start% (make-array 1 :element-type '(unsigned-byte 8)
                                        :initial-element #x00))
(defparameter %frame-end% (make-array 1 :element-type '(unsigned-byte 8)
                                      :initial-element #xff))

(defun write-to-client (client string)
  (unless (client-write-closed client)
    (let ((hook (%client-server-hook client)))
      (cond
        ((stringp string)
         ;; this is ugly, figure out how to write in 1 chunk without encoding
         ;; to a temp buffer and copying...
         (sb-concurrency:enqueue %frame-start% (client-write-queue client))
         (sb-concurrency:enqueue (babel:string-to-octets string
                                                         :encoding :utf-8)
                                 (client-write-queue client))
         (sb-concurrency:enqueue %frame-end% (client-write-queue client)))
        (t
         ;; fixme: verify this is something valid (like :close) before adding
         (sb-concurrency:enqueue string (client-write-queue client))))
      (funcall hook
               (lambda ()
                 (client-enable-handler client :write t))))))

(defun client-enqueue-read (client data)
  (sb-concurrency:send-message (client-read-queue client) data))

(defun client-dequeue-read (client)
  (sb-concurrency:receive-message-no-hang (client-read-queue client)))

(defun store-partial-read (client data offset)
  ;; fixme: should check for read-buffer-octets getting too big here?
  (push (list data offset) (client-read-buffers client))
  (incf (client-read-buffer-octets client) (length data)))

(defun extract-read-chunk-as-utf-8 (client)
  (let ((*print-pretty* nil))
    (with-output-to-string (str)
      (loop for chunk in (nreverse (client-read-buffers client))
         for (b (s n . more)) = chunk
         do
           (format str "~a" (babel:octets-to-string b :start (or s 0) :end n))
         finally (if (and more (integerp (car n)))
                     (setf (second chunk) more
                           (client-read-buffers client) (list chunk)
                           (client-read-buffer-octets client) (- (length chunk)
                                                                 (car more)))
                     (setf (client-read-buffers client) nil
                           (client-read-buffer-octets client) 0))))))
