(in-package #:ws)

(defparameter *server-busy-message* (babel:string-to-octets
                             "HTTP/1.1 503 service unavailable

"
                             :encoding :utf-8))

(defclass server ()
  ((event-base :initform nil :accessor server-event-base :initarg :event-base)
   (clients :initform (make-hash-table) :reader server-clients
            :documentation "Hash of client objects to them
            selves (just used as a set for now)."))
  (:documentation "A WebSockets server listens on a socket for
connections and has a bunch of client instances that it controls."))

(defgeneric server-client-count (server)
  (:documentation "Returns number the server's clients."))

(defgeneric server-list-clients (server)
  (:documentation "Returns a list of the server's clients."))

(defmethod server-list-clients ((server server))
  (loop :for v :being the hash-values :of (server-clients server)
        :collect v))

(defmethod server-client-count ((server server))
  (hash-table-count (server-clients server)))

(defun make-listener-handler (server socket server-hook)
  (lambda (fd event exception)
    (declare (ignore fd event exception))
    (let* ((client-socket (accept-connection socket :wait t))
           (client (when client-socket
                     (make-instance 'client
                                    :server server
                                    :%host (remote-host client-socket)
                                    :host (address-to-string
                                           (remote-host client-socket))
                                    :port (remote-port client-socket)
                                    :server-hook server-hook
                                    :socket client-socket))))
      (when client
        (lg "got client connection from ~s ~s~%" (client-host client)
            (client-port client))
        (lg "client count = ~s/~s~%" (server-client-count server) *max-clients*)
        ;; fixme: probably shouldn't do this if we are dropping the connection
        ;; due to too many connections?
        (setf (gethash client (server-clients server)) client)
        (cond
          ((and *max-clients* (> (server-client-count server) *max-clients*))
           ;; too many clients, send a server busy response and close connection
           (client-disconnect client :read t)
           (client-enqueue-write client *server-busy-message*)
           (client-enqueue-write client :close))
          (t
           ;; otherwise handle normally
           (add-reader-to-client client)))))))

(defun run-server (port &key (addr +ipv4-unspecified+))
  "Starts a server on the given PORT and blocks until the server is
closed.  Intended to run in a dedicated thread (the current one),
dubbed the Server Thread.

Establishes a socket listener in the current thread.  This thread
handles all incoming connections, and because of this fact is able to
handle far more concurrent connections than it would be able to if it
spawned off a new thread for each connection.  As such, most of the
processing is done on the Server Thread, though most user functions
are thread-safe.

"
  (let* ((event-base (make-instance 'iolib:event-base))
         (server (make-instance 'server
                                :event-base event-base))
         (temp (make-array 16 :element-type '(unsigned-byte 8)))
         (control-mailbox (make-queue :name "server-control"))
         (wake-up (make-array 1 :element-type '(unsigned-byte 8)
                              :initial-element 0)))

    ;; To be clear, there are three sockets used for a server.  The
    ;; main one is the WebSockets server (socket).  There is also a
    ;; pair of connected sockets (control-socket-1 control-socket-2)
    ;; used merely as a means of making the server thread execute a
    ;; lambda from a different thread.
    (multiple-value-bind (control-socket-1 control-socket-2)
        (make-socket-pair)
      (flet ((execute-in-server-thread (thunk)
               ;; hook for waking up the server and telling it to run
               ;; some code, for things like enabling writers when
               ;; there is new data to write
               (enqueue thunk control-mailbox)
               (ignore-errors
                 (iolib:send-to control-socket-2 wake-up))))
        (unwind-protect
             (iolib:with-open-socket (socket :connect :passive
                                             :address-family :internet
                                             :type :stream
                                             :ipv6 nil
                                             ;;:external-format '(unsigned-byte 8)
                                             ;; bind and listen as well
                                             :local-host addr
                                             :local-port port
                                             :backlog 5
                                             :reuse-address t
                                             #++ :no-delay)
               (iolib:set-io-handler event-base
                                     (socket-os-fd control-socket-1)
                                     :read (lambda (fd e ex)
                                             (declare (ignorable fd e ex))
                                             (receive-from control-socket-1
                                                           :buffer temp
                                                           :start 0 :end 16)
                                             (loop for m = (dequeue control-mailbox)
                                                   while m
                                                   do (funcall m))))
               (iolib:set-io-handler event-base
                                     (iolib:socket-os-fd socket)
                                     :read (let ((true-handler (make-listener-handler
                                                                server
                                                                socket
                                                                #'execute-in-server-thread)))
                                             (lambda (&rest rest)
                                               (lg "There is something to read on fd ~A~%" (first rest))
                                               (apply true-handler rest))))
               (handler-case
                   (event-dispatch event-base)
                 ;; ... handle errors
                 )
               )
          (loop :for v :in (server-list-clients server)
                :do
                (format t "cleanup up dropping client ~s~%" v)
                (client-enqueue-read v (list v :dropped))
                (client-disconnect v :abort t))
          (close control-socket-1)
          (close control-socket-2))))))
