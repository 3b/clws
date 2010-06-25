(in-package #:ws)

;; max number of queued write frames before dropping a client
(defparameter *max-write-backlog* 16)


;;; per-client data

(defclass client ()
  ((port :initarg :port :reader client-port)
   (host :initarg :host :reader client-host)
   ;; function to call to send a command to the network thread from other threads
   (server-hook :initarg :server-hook :reader %client-server-hook)
   (socket :initarg :socket :reader client-socket)
   ;; flags indicating the read/write handlers are active
   ;(reader-active :initform nil :accessor client-reader-active)
   ;(writer-active :initform nil :accessor client-writer-active)
   ;(error-active :initform nil :accessor client-error-active)
   ;; flags indicating (one side of) the connection is closed
   (read-closed :initform nil :accessor client-read-closed)
   (write-closed :initform nil :accessor client-write-closed)
   (closed :initform nil :accessor client-socket-closed)
   ;; buffer being written currently, if last write couldn't send whole thing
   (write-buffer :initform nil :accessor client-write-buffer)
   ;; offset into write-buffer if write-buffer is set
   (write-offset :initform 0 :accessor client-write-offset)
   ;; queue of buffers (octet vectors) to write, or :close to kill connection
   ;; :enable-read to reenable reader after being disabled for flow control
   ;; (mailbox instead of queue since it tracks length)
   (write-queue :initform (sb-concurrency:make-mailbox)
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
   (reader :initform nil :accessor client-reader)
   ;; space for handler to store connection specific data
   (handler-data :initform nil :accessor client-handler-data)
   ;; probably don't need to hold onto these for very long, but easier to
   ;; store here trhan pass around while parsing handshake
   (connection-headers :initform nil :accessor client-connection-headers)
   ))

;; fixme: should the cilent remember which *event-base* it uses so
;; these can work from other threads too?
(defmethod client-reader-active ((client client))
  (iolib.multiplex::fd-monitored-p *event-base* (socket-os-fd (client-socket client)) :read))
(defmethod client-writer-active ((client client))
  (iolib.multiplex::fd-monitored-p *event-base* (socket-os-fd (client-socket client)) :write))
(defmethod client-error-active ((client client))
  (iolib.multiplex::fd-has-error-handler-p *event-base* (socket-os-fd (client-socket client))))

(defun try-write-client (client)
  (let ((fd (socket-os-fd (client-socket client))))
    (when (and fd
               (not (client-socket-closed client))
               (not (client-write-closed client)))
     (flet ((enable ()
              (when (and (not (client-socket-closed client))
                         (not (client-writer-active client))
                         (not (client-write-closed client)))
                (set-io-handler *event-base* fd
                                :write (lambda (fd event exception)
                                         (declare (ignore fd event exception))
                                         (try-write-client client)))
                #++(setf (client-writer-active client) t))))
       (handler-case
           (loop
              unless (client-write-buffer client)
              do
              (setf (client-write-buffer client) (client-dequeue-write client))
              (setf (client-write-offset client) 0)
              ;; if we got a :close command, clean up the socket
              when (eql (client-write-buffer client) :close)
              do
              (client-disconnect client :close t)
              (return-from try-write-client nil)
              when (eql (client-write-buffer client) :enable-read)
              do
              (client-enable-handler client :read t)
              (setf (client-write-buffer client) nil)
              else when (client-write-buffer client)
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
              (enable)
              (loop-finish)
              when (sb-concurrency:mailbox-empty-p (client-write-queue client))
              do
              (client-disable-handler client :write t)
              (loop-finish))
         (isys:ewouldblock ()
           (enable)
           nil)
         (isys:epipe ()
           ;; client closed conection, so drop it...
           (lg "epipe~%")
           (client-enqueue-read client (list client :dropped))
           (client-disconnect client :close t))
         (socket-connection-reset-error ()
           (lg "connection reset~%")
           (client-enqueue-read client (list client :dropped))
           (client-disconnect client :close t)))))))

(defmethod client-enable-handler ((client client) &key read write error)
  (lg "enable handlers for ~s:~s ~s ~s ~s~%"
      (client-host client) (client-port client) read write error)
  (when (and (not (client-socket-closed client))
             (socket-os-fd (client-socket client)))
    (let ((fd (socket-os-fd (client-socket client))))

      (when (and write
                 (not (client-writer-active client))
                 (not (client-write-closed client)))
        (try-write-client client))
      (when read (format t "enable read ~s ~s ~s~%"
                         fd
                         (client-reader-active client)
                         (client-read-closed client)))
      (when (and read
                 (not (client-reader-active client))
                 (not (client-read-closed client)))
        (set-io-handler *event-base* fd :read (client-reader client))
        #++(setf (client-reader-active client) t))

      (when (and error (not (client-error-active client)))
        (error "error handlers not implemented yet...")))))

(defmethod client-disable-handler ((client client) &key read write error)
  (lg "disable handlers for ~s:~s ~s ~s ~s~%"
      (client-host client) (client-port client) read write error)
  (let ((fd (socket-os-fd (client-socket client))))
    (when (and write (client-writer-active client))
      (remove-fd-handlers *event-base* fd :write t)
      #++(setf (client-writer-active client) nil))
      (when read (format t "disable read ~s ~s ~s~%"
                         fd
                         (client-reader-active client)
                         (client-read-closed client)))
    (when (and read (client-reader-active client))
      (remove-fd-handlers *event-base* fd :read t)
      #++(setf (client-reader-active client) nil))
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
                      (format t "enotconn ~s ~s ~s~%" ,(format nil "~s" body)
                              (client-port client) fd)
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
  (when (or close abort
            (and (client-read-closed client)
                 (client-write-closed client)))
    (format t "removing client ~s~%" (client-port client))
    ;(setf *foo* client )
    (setf (client-socket-closed client) t)
    (remhash client *clients*)))




;;; fixme: decide if any of these should be methods? (or others should be functions?)

(defun client-enqueue-write (client data)
  (sb-concurrency:send-message (client-write-queue client) data)
  (try-write-client client))

(defun client-dequeue-write (client)
  (sb-concurrency:receive-message-no-hang (client-write-queue client)))

(defparameter %frame-start% (make-array 1 :element-type '(unsigned-byte 8)
                                        :initial-element #x00))
(defparameter %frame-end% (make-array 1 :element-type '(unsigned-byte 8)
                                      :initial-element #xff))


(defun %client-enqueue-write-or-kill (frame client)
  (unless (client-write-closed client)
    (cond
      ((symbolp frame)
       ;; don't count control messages against limit for now
       )
      ((> (sb-concurrency:mailbox-count (client-write-queue client))
          *max-write-backlog*)
       (format t "client write backlog = ~s, killing conectiom~%"
               (sb-concurrency:mailbox-count (client-write-queue client)))
       (funcall (%client-server-hook client)
                (lambda ()
                  (client-disconnect client :abort t)
                  (client-enqueue-read client (list client :dropped))
                  (sb-concurrency:receive-pending-messages
                   (client-write-queue client)))))
      (t
       (sb-concurrency:send-message (client-write-queue client) frame)))))

(defun make-frame-from-string (string)
  (concatenate '(vector (unsigned-byte 8))
               '(0)
               (babel:string-to-octets string :encoding :utf-8)
               '(#xff)))
(defparameter *close-frame* (make-array 2 :element-type))
(defun write-to-client (client string)
  (unless (client-write-closed client)
    (let ((hook (%client-server-hook client)))
      (cond
        ((stringp string)
         ;; this is ugly, figure out how to write in 1 chunk without encoding
         ;; to a temp buffer and copying...
         (%client-enqueue-write-or-kill (make-frame-from-string string)
                                        client))
        ((eq string :close)
         ;; draft-76/00 adds a close handshake, so enqueue that as
         ;; well when closing socket
         (%client-enqueue-write-or-kill *close-frame* client)
         (%client-enqueue-write-or-kill string client))
        (t
         ;; fixme: verify this is something valid (like :close) before adding
         (%client-enqueue-write-or-kill string client)))
      (funcall hook
               (lambda ()
                 (client-enable-handler client :write t))))))

(defun write-to-clients (clients string)
  (when clients
    (loop with msg = (if (stringp string)
                        (make-frame-from-string string)
                        string)
      for client in clients
      do (unless (client-write-closed client)
           ;; fixme: verify this is something valid (like :close) before adding
           (%client-enqueue-write-or-kill msg client)))
  ;; fixme: handle clients with different server hooks...
    (let ((hook (%client-server-hook (car clients))))
      (funcall hook
               (lambda ()
                 (loop for client in clients
                    do (try-write-client client)
                    #++ (client-enable-handler client :write t)))))))

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

