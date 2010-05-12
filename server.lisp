(in-package #:ws)

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
        (setf (gethash client *clients*) client)
        (add-reader-to-client client)))))

(defun run-server (port &key (addr +ipv4-unspecified+))
  (let ((*event-base* (make-instance 'event-base))
        (*clients* (make-hash-table))
        (temp (make-array 16 :element-type '(unsigned-byte 8)))
        (control-mailbox (sb-concurrency:make-mailbox :name "server-control")))
    (multiple-value-bind (control-socket-1 control-socket-2)
        (make-socket-pair)
      (flet ((execute-in-server-thread (thunk)
               ;; hook for waking up the server and telling it to run
               ;; some code, for things like enabling writers when
               ;; there is new data to write
               (sb-concurrency:send-message control-mailbox thunk)
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
                                       (loop for m in (sb-concurrency:receive-pending-messages control-mailbox)
                                          do (funcall m))
                                       (receive-from control-socket-1
                                                     :buffer temp
                                                     :start 0 :end 16)))
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
               (client-enqueue-write v (list v :dropped))
               (client-disconnect v :abort t))
          (close control-socket-1)
          (close control-socket-2))))))
