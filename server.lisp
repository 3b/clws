(in-package #:ws)

(defparameter *server-busy-message* (babel:string-to-octets
                             "HTTP/1. 503 service unavailable

"
                             :encoding :utf-8))

(defun make-listener-handler (socket server-hook)
  (lambda (fd event exception)
    (declare (ignore fd event exception))
    (let* ((client-socket (accept-connection socket :wait t))
           (client (when client-socket
                     (make-instance 'client
                                    :host (remote-host client-socket)
                                    :port (remote-port client-socket)
                                    :server-hook server-hook
                                    :socket client-socket))))
      (when client
        (lg "got client connection from ~s ~s~%" (client-host client)
            (client-port client))
        (lg "client count = ~s/~s~%" (hash-table-count *clients*) *max-clients*)
        (setf (gethash client *clients*) client)
        (cond
          ((and *max-clients* (> (hash-table-count *clients*) *max-clients*))
           ;; too many clients, send a server busy response and close connection
           (client-disconnect client :read t)
           (client-enqueue-write client *server-busy-message*)
           (client-enqueue-write client :close))
          (t
           ;; otherwise handle normally
           (add-reader-to-client client)))))))

(defun run-server (port &key (addr +ipv4-unspecified+))
  (let ((*event-base* (make-instance 'event-base))
        (*clients* (make-hash-table))
        (temp (make-array 16 :element-type '(unsigned-byte 8)))
        (control-mailbox (sb-concurrency:make-queue :name "server-control")))
    (multiple-value-bind (control-socket-1 control-socket-2)
        (make-socket-pair)
      (flet ((execute-in-server-thread (thunk)
               ;; hook for waking up the server and telling it to run
               ;; some code, for things like enabling writers when
               ;; there is new data to write
               (sb-concurrency:enqueue thunk control-mailbox)
               (write-byte 0 control-socket-2)
               (finish-output control-socket-2)))
        (unwind-protect
             (with-open-socket (socket :connect :passive
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
               (set-io-handler *event-base*
                               (socket-os-fd control-socket-1)
                               :read (lambda (fd e ex)
                                       (declare (ignorable fd e ex))
                                       (receive-from control-socket-1
                                                     :buffer temp
                                                     :start 0 :end 16)
                                       (loop for m = (sb-concurrency:dequeue control-mailbox)
                                          while m
                                          do (funcall m))))
               (set-io-handler *event-base*
                               (socket-os-fd socket)
                               :read (make-listener-handler
                                      socket
                                      #'execute-in-server-thread))
               (handler-case
                   (event-dispatch *event-base*)
                 ;; ... handle errors
                 )
               )
          (loop for v being the hash-values of *clients*
             do
               (format t "cleanup up dropping client ~s~%" v)
               (client-enqueue-read v (list v :dropped))
               (client-disconnect v :abort t))
          (close control-socket-1)
          (close control-socket-2))))))
