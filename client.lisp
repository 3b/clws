(in-package #:ws)

(defparameter *max-write-backlog* 16
  "Max number of queued write frames before dropping a client.")

(defclass client ()
  ((server :initarg :server :reader client-server
           :documentation "The instance of WS:SERVER that owns this
           client.")
   (resource :initarg :resource :initform nil :accessor client-resource
             :documentation "The resource object the client has
             requested-- Not the string, but the object.")
   (port :initarg :port :reader client-port)
   (host :initarg :host :reader client-host)
   (server-hook :initarg :server-hook :reader %client-server-hook
                :documentation "Function to call to send a command to
                the network thread from other threads")
   (socket :initarg :socket :reader client-socket
           :documentation "Bidirectional socket stream used for communicating with
           the client.")
   (read-closed :initform nil :accessor client-read-closed
                :documentation "Flag indicates read side of the
                connection is closed")
   (write-closed :initform nil :accessor client-write-closed
                :documentation "Flag indicates write side of the
                connection is closed")
   (closed :initform nil :accessor client-socket-closed
           :documentation "Flag indicates connection is closed")

   (write-buffer :initform nil :accessor client-write-buffer
                 :documentation "Buffer being written currently, if
                 last write couldn't send whole thing")
   (write-offset :initform 0 :accessor client-write-offset
                 :documentation "Offset into write-buffer if
                 write-buffer is set")
   (write-queue :initform (make-mailbox)
                :reader client-write-queue
                :documentation "Queue of buffers (octet vectors) to
                write, or :close to kill connection :enable-read to
                reenable reader after being disabled for flow
                control (mailbox instead of queue since it tracks
                length).")
   (read-buffers :initform nil :accessor client-read-buffers
                 :documentation "List of partial buffers + offsets of
                 CR/LF/etc to be decoded into a line/frame once the
                 end is found offsets are inclusive start/end pairs,
                 NIL for continued from previous or continued to next
                 chunk")
   ;; fixme: probably should hide write access to counts behind
   ;; functions that manipulate the buffer?
   (read-buffer-octets :initform 0 :accessor client-read-buffer-octets
                       :documentation "Total octets in
                       read-buffers (so we can reject overly large
                       frames/headers)")
   (read-queue :initform (make-mailbox)
               ;; possibly should have separate writer?
               :accessor client-read-queue
               :documentation "queue of decoded lines/frames")
   (read-state :initform :maybe-policy-file :accessor client-read-state
               :documentation "Reader fsm state")
   (reader :initform nil :accessor client-reader
           :documentation "Read handler for this queue/socket")
   (handler-data :initform nil :accessor client-handler-data
                 :documentation "Space for handler to store connection
                 specific data.")
   ;; probably don't need to hold onto these for very long, but easier
   ;; to store here trhan pass around while parsing handshake
   (connection-headers :initform nil :accessor client-connection-headers))
  (:documentation "Per-client data used by a WebSockets server."))

(defmethod client-reader-active ((client client))
  (iolib.multiplex::fd-monitored-p (server-event-base (client-server client))
                                   (socket-os-fd (client-socket client)) :read))

(defmethod client-writer-active ((client client))
  (iolib.multiplex::fd-monitored-p (server-event-base (client-server client))
                                   (socket-os-fd (client-socket client)) :write))

(defmethod client-error-active ((client client))
  (iolib.multiplex::fd-has-error-handler-p (server-event-base (client-server client))
                                           (socket-os-fd (client-socket client))))

(defun special-client-write-value-p (value)
  "Certain values, like :close and :enable-read, are special symbols
that may be passed to WRITE-TO-CLIENT or otherwise enqueued on the
client's write queue.  This predicate returns T if value is one of
those special values"
  (member value '(:close :enable-read)))

(defgeneric client-enable-handler (client &key read write error)
  (:documentation "Enables the read, write, or error handler for a a
client.  Once a read handler is set up, the client can handle the
handshake coming in from the client."))

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
        (set-io-handler (server-event-base (client-server client))
                        fd
                        :read (client-reader client))
        #++(setf (client-reader-active client) t))

      (when (and error (not (client-error-active client)))
        (error "error handlers not implemented yet...")))))

(defgeneric client-disable-handler (client &key read write error)
  (:documentation "Stop listening for READ, WRITE, or ERROR events on the socket for
the given client object. "))

(defmethod client-disable-handler ((client client) &key read write error)
  (lg "disable handlers for ~s:~s ~s ~s ~s~%"
      (client-host client) (client-port client) read write error)
  (let ((fd (socket-os-fd (client-socket client))))
    (when (and write (client-writer-active client))
      (iolib:remove-fd-handlers (server-event-base (client-server client)) fd :write t))

    (when read (lg "disable read ~s ~s ~s~%"
                   fd
                   (client-reader-active client)
                   (client-read-closed client)))

    (when (and read (client-reader-active client))
      (remove-fd-handlers (server-event-base (client-server client)) fd :read t))

    (when (and error (client-error-active client))
      (error "error handlers not implemented yet..."))))

(defgeneric client-disconnect (client &key read write close abort)
  (:documentation "Shutdown 1 or both sides of a connection, close it
if both sides shutdown"))

(defmethod client-disconnect ((client client) &key read write close abort)
  "shutdown 1 or both sides of a connection, close it if both sides shutdown"
  (declare (optimize (debug 3)))
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
            (ignore-some-errors (remove-fd-handlers (server-event-base (client-server client))
                                                    fd :read t :write t :error t)))
          (ignore-some-errors (close socket :abort abort))))))

  (when (or close abort
            (and (client-read-closed client)
                 (client-write-closed client)))
    (lg "removing client ~s (closed already? ~A)~%" (client-port client) (client-socket-closed client))
    ;;(setf *foo* client )
    (setf (client-socket-closed client) t)
    (let ((resource (client-resource client)))
      (when resource
        (resource-client-disconnected resource client)))
    (remhash client (server-clients (client-server client)))))




;;; fixme: decide if any of these should be methods? (or others should be functions?)

;; What are differences are for the many different
;; write functions available?  There are a bunch of write functions:
;;
;; - write-to-client -- user-level function for writing some data
;;      string to a client
;;
;; - %client-enqueue-write-or-kill -- sits in between
;;      client-enqueue-write and write-to-client to prevent too many
;;      user messages from piling up.  It also handles the special
;;      :close argument to close a client gracefully by including a
;;      *close-frame* handshake
;;
;; - client-enqueue-write -- slightly more primitive than
;;      write-to-client because it does not inspect the passed data or
;;      write-queue very much at all, so this is used internally a lot
;;
;; - try-write-client -- should only be called on the server thread,
;;      attempts to flush some of the data in the write-queue in a
;;      non-blocking fashion.
;;


(defun client-enqueue-write (client data)
  "Adds data to the client's write-queue and asynchronously send it to
the client."
  (mailbox-send-message (client-write-queue client) data)
  (try-write-client client))

(defun client-dequeue-write (client)
  "Non-blocking call to dequeue a piece of data in the write-queue to
be sent to the client."
  (mailbox-receive-message-no-hang (client-write-queue client)))

(defun make-frame-from-string (string)
  "Given a string, returns bytes that can be transmitted to the client
as a WebSockets frame."
  (concatenate '(vector (unsigned-byte 8))
               '(0)
               (babel:string-to-octets string :encoding :utf-8)
               '(#xff)))

(defparameter *close-frame* (make-array 2 :element-type '(unsigned-byte 8)
                                        :initial-contents '(#xff #x00)))

(defun write-to-client (client string-or-keyword)
  "Writes the given message to the client, where STRING-OR-KEYWORD is
either a string, an octet-vector, or :CLOSE.  If it is a string, it is
sent to the client as a framed message.  An octet vector is assumed to
be a valid frame and sent without further translation. :close closes
the connection."
  ;; fixme: ensure this function is truly thread-safe, particularly
  ;; against connections closing at arbitrary points in time
  (unless (client-write-closed client)
    (let ((hook (%client-server-hook client)))
      (etypecase string-or-keyword
        (string
         ;; this is ugly, figure out how to write in 1 chunk without encoding
         ;; to a temp buffer and copying...
         (%client-enqueue-write-or-kill (make-frame-from-string string-or-keyword)
                                        client))
        ((eql :close)
         ;; draft-76/00 adds a close handshake, so enqueue that as
         ;; well when closing socket
         (%client-enqueue-write-or-kill *close-frame* client)
         (%client-enqueue-write-or-kill :close client))
        ((vector (unsigned-byte 8))
         (%client-enqueue-write-or-kill string-or-keyword client)))
      (funcall hook
               (lambda ()
                 (client-enable-handler client :write t))))))

(defun write-to-clients (clients string)
  "Like WRITE-TO-CLIENT but sends the message to all of the clients."
  ;; fixme: validate type of STRING?
  (when clients
    (loop :with msg = (if (stringp string)
                        (make-frame-from-string string)
                        string)
          :for client in clients
          :do (unless (client-write-closed client)
                (%client-enqueue-write-or-kill msg client)))

    ;; fixme: handle clients with different server hooks...
    (let ((hook (%client-server-hook (car clients))))
      (funcall hook
               (lambda ()
                 (loop :for client :in clients
                       :do (try-write-client client)))))))

(defun try-write-client (client)
  "Should only be called on the server thread,
attempts to flush some of the data in the write-queue in a
non-blocking fashion."
  (let ((fd (socket-os-fd (client-socket client))))
    (when (and fd
               (not (client-socket-closed client))
               (not (client-write-closed client)))
     (flet ((enable ()
              (when (and (not (client-socket-closed client))
                         (not (client-writer-active client))
                         (not (client-write-closed client)))
                (set-io-handler (server-event-base (client-server client)) fd
                                :write (lambda (fd event exception)
                                         (declare (ignore fd event exception))
                                         (try-write-client client)))
                #++(setf (client-writer-active client) t))))
       (handler-case
           (loop
             :do
             (progn
               ;; set up the active client-write-buffer
               (unless (client-write-buffer client)
                 (setf (client-write-buffer client) (client-dequeue-write client))
                 (setf (client-write-offset client) 0))

               ;; if we got a :close command, clean up the socket
               (when (eql (client-write-buffer client) :close)
                 (client-disconnect client :close t)
                 (return-from try-write-client nil))

               (when (eql (client-write-buffer client) :enable-read)
                 (client-enable-handler client :read t)
                 (setf (client-write-buffer client) nil))

               (when (client-write-buffer client)
                 (let ((count (send-to (client-socket client)
                                       (client-write-buffer client)
                                       :start (client-write-offset client)
                                       :end (length (client-write-buffer client)))))
                   (incf (client-write-offset client) count)
                   (when (>= (client-write-offset client)
                             (length (client-write-buffer client)))
                     (setf (client-write-buffer client) nil))))

               ;; if we didn't write the entire buffer, make sure the writer is
               ;; enabled, and exit the loop

               ;; > But shouldn't we ensure that the writer is enabled
               ;; > regardless of whether iolib manages to write out the
               ;; > entire buffer? -- RED
               (when (client-write-buffer client)
                 (enable)
                 (loop-finish))

               (when (mailbox-empty-p (client-write-queue client))
                 (client-disable-handler client :write t)
                 (loop-finish))))

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
      ((> (mailbox-count (client-write-queue client))
          *max-write-backlog*)
       (format t "client write backlog = ~s, killing conectiom~%"
               (mailbox-count (client-write-queue client)))
       (funcall (%client-server-hook client)
                (lambda ()
                  (client-disconnect client :abort t)
                  (client-enqueue-read client (list client :dropped))
                  (mailbox-receive-pending-messages
                   (client-write-queue client)))))
      (t
       (mailbox-send-message (client-write-queue client) frame)))))

(defun client-enqueue-read (client data)
  "Adds a piece of data to the client's read-queue so that it may be
read and processed."
  (mailbox-send-message (client-read-queue client) data))

(defun client-dequeue-read (client)
  "Non-blocking call to dequeue a piece of data from a client' read-queue."
  (mailbox-receive-message-no-hang (client-read-queue client)))

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

