(in-package #:ws)

;;;; Echo server
;;;; -----------

(defclass echo-resource (ws-resource)
  ())

(register-global-resource
 "/echo"
 (make-instance 'echo-resource)
 (ws::origin-prefix "http://127.0.0.1" "http://localhost"))

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
  (write-to-client-text client message))

(defmethod resource-received-binary((res echo-resource) client message)
  #++(format t "got binary frame ~s from client ~s" (length message) client)
 #++ (write-to-client-text client (format nil "got binary ~s" message))
  (write-to-client-binary client message))


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

(defmethod resource-accept-connection ((res chat-server) resource-name headers client)
  (declare (ignore headers resource-name))
  (format t "got connection on chat server from ~s : ~s~%" (client-host client) (client-port client))
  ;; this gets called from wrong thread?
  (push client (clients res))
  t)

(defmethod resource-client-disconnected ((resource chat-server) client)
  (format t "Client disconnected from resource ~A: ~A~%" resource client)
  (setf (clients resource) (remove client (clients resource))))

(defmethod resource-received-text ((res chat-server) client message)
  ;(format t "got frame ~s from chat client ~s" message client)
  (let ((*print-pretty* nil))
    (write-to-clients (clients res)
                      (concatenate '(vector (unsigned-byte 8))
                                   '(0)
                                   (babel:string-to-octets
                                    (format nil "chat: ~s.~s : |~s|"
                                            (client-host client)
                                            (client-port client)
                                            message)
                                    :encoding :utf-8)
                                   '(#xff)))))

#++
(bordeaux-threads:make-thread
 (lambda ()
   (ws:run-resource-listener (ws:find-global-resource "/chat")))
 :name "chat resource listener for /chat")
