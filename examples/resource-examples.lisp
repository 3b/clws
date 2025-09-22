(in-package #:ws)

;;;; Echo server
;;;; -----------

(defclass echo-resource (ws-resource)
  ((ping-times :initform (make-hash-table :test 'equal) :accessor ping-times)))

(register-global-resource
 "/echo"
 (make-instance 'echo-resource)
 (ws::origin-prefix "http://127.0.0.1" "http://localhost" "null"))

#++
(defmethod resource-accept-connection ((res echo-resource) resource-name headers client)
  (declare (ignore headers resource-name))
  (format t "got connection on echo server from ~s : ~s~%" (client-host client) (client-port client))
  t)

(defmethod resource-client-connected ((res echo-resource) client)
  (format t "got connection on echo server from ~s : ~s~%" (client-host client) (client-port client))
  t)

(defmethod resource-client-disconnected ((resource echo-resource) client)
  (format t "Client disconnected from resource ~A: ~A~%" resource client))

(defmethod resource-received-text ((res echo-resource) client message)
  #++(format t "got frame ~s from client ~s" message client)
  (when (string= message "error")
    (error "got \"error\" message "))
  ;; Test ping functionality - if message is "ping", send a ping frame with timestamp
  (when (string= message "ping")
    (let ((timestamp (get-universal-time)))
      (format t "Sending ping to client ~s at time ~s~%" client timestamp)
      ;; Store the ping time with the payload as key
      (setf (gethash (format nil "~d" timestamp) (ping-times res)) timestamp)
      (write-to-client-ping client (format nil "~d" timestamp))))
  (write-to-client-text client message))

(defmethod resource-received-binary((res echo-resource) client message)
  #++(format t "got binary frame ~s from client ~s" (length message) client)
 #++ (write-to-client-text client (format nil "got binary ~s" message))
  (write-to-client-binary client message))

(defmethod resource-received-pong ((res echo-resource) client message)
  "Handle pong frames for latency measurement"
  (let* ((payload-str (if (vectorp message)
                          (babel:octets-to-string message :encoding :utf-8)
                          (format nil "~s" message)))
         (send-time (gethash payload-str (ping-times res)))
         (current-time (get-universal-time)))
    (if send-time
        (let ((latency (- current-time send-time)))
          (format t "Pong received from client ~s. Latency: ~d seconds~%" client latency)
          (remhash payload-str (ping-times res))
          ;; Send latency measurement back to client
          (write-to-client-text client (format nil "Latency: ~d seconds" latency)))
        (format t "Pong received from client ~s with unknown payload: ~s~%" client payload-str))))


#++
(bordeaux-threads:make-thread
          (lambda ()
            (ws:run-server 12345))
          :name "websockets server")

#++
(bordeaux-threads:make-thread
 (lambda ()
   (ws:run-resource-listener (ws:find-global-resource "/echo")))
 :name "resource listener for /echo")

#++
(kill-resource-listener (ws:find-global-resource "/echo"))


;;; for autobahn test suite
#++
(register-global-resource
 "/"
 (make-instance 'echo-resource)
 #'ws::any-origin)

#++
(bordeaux-threads:make-thread
 (lambda ()
   (ws:run-resource-listener (ws:find-global-resource "/")))
 :name "resource listener for /")

#++
(kill-resource-listener (ws:find-global-resource "/"))


;;;; Chat server
;;;; -----------

(defclass chat-server (ws-resource)
  ((clients :initform () :accessor clients)))


(register-global-resource
 "/chat"
 (make-instance 'chat-server)
 #'ws::any-origin
 #++
 (ws::origin-prefix "http://127.0.0.1" "http://localhost"))

(defmethod resource-client-connected ((res chat-server) client)
  (format t "got connection on chat server from ~s : ~s~%" (client-host client) (client-port client))
  (push client (clients res))
  (let ((*print-pretty* nil))
    (write-to-clients-text (clients res)
                           (format nil "client joined from ~s.~s, ws protocol ~s"
                                   (client-host client)
                                   (client-port client)
                                   (client-websocket-version client)))
    (write-to-client-text client
                          (format nil "headers = ~s~%"
                                  (alexandria:hash-table-alist (client-connection-headers client)))))
  t)

(defmethod resource-client-disconnected ((resource chat-server) client)
  (format t "Client disconnected from resource ~A: ~A~%" resource client)
  (setf (clients resource) (remove client (clients resource)))
    (write-to-clients-text (clients resource)
                           (format nil "client from ~s.~s left"
                                   (client-host client)
                                   (client-port client))))

(defmethod resource-received-text ((res chat-server) client message)
  ;(format t "got frame ~s from chat client ~s" message client)
  (let ((*print-pretty* nil))
    (write-to-clients-text (clients res)
                           (format nil "chat: ~s.~s : |~s|"
                                   (client-host client)
                                   (client-port client)
                                   message))))

(defmethod resource-received-binary ((res chat-server) client message)
  ;(format t "got frame ~s from chat client ~s" message client)
  (let ((*print-pretty* nil)
        (binary-clients)
        (text-clients))
    (loop for c in (clients res)
          do (if (> (client-websocket-version c) 0)
                 (push c binary-clients)
                 (push c text-clients)))
    (write-to-clients-text (clients res)
                           (format nil "chat: binary message from ~s.~s"
                                   (client-host client)
                                   (client-port client)))
    (write-to-clients-binary binary-clients message)))

#++
(bordeaux-threads:make-thread
 (lambda ()
   (ws:run-resource-listener (ws:find-global-resource "/chat")))
 :name "chat resource listener for /chat")
