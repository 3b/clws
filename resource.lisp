(in-package #:ws)

;;; resource stuff
;;;
;;;  name ("/foo", etc)
;;;
;;;  accept function
;;;    args = resource name, headers, client host/port
;;;    return
;;;      reject connection
;;;      abort connection?
;;;      ? for accepted

;; fixme: make this per-server, so we can run different servers on
;; different ports?
;; fixme: add support for more complex matching than just exact match
(defparameter *resources* (make-hash-table :test 'equal))


(defvar *ws-test-queue* (sb-concurrency:make-mailbox :name "ws-test-queue"))

(defclass ws-resource ()
  ((read-queue))
)
(defgeneric ws-accept-connection (res resource-name headers client))
(defmethod ws-accept-connection (res resource-name headers client)
  (format t "got connection request on ws-resource? ~s / ~s~%" res resource-name)
  nil
)





(defclass ws-echo-server (ws-resource)
  ((read-queue :allocation :class :initform *ws-test-queue*)))

(setf (gethash "/echo" *resources*)
      (make-instance 'ws-echo-server))


(defmethod ws-accept-connection ((res ws-echo-server) resource-name headers client)
  (format t "got connection on echo server from ~s : ~s~%" (client-host client) (client-port client))
  (values (slot-value res 'read-queue)
          ;; use defaults for origin/resource/protocol for now..
          nil nil nil)

)




; (sb-concurrency:receive-message-no-hang *ws-test-queue*)

(loop for (client data) = (sb-concurrency:receive-message-no-hang *ws-test-queue*)
   while client
   do (format t "handler got frame: ~s~%" data)
     (write-to-client client (format nil "echo: |~s|" data)))


(defparameter *echo-kill* nil)

(loop for (client data) = (sb-concurrency:receive-message *ws-test-queue*)
   until (or *echo-kill* (eq data :kill))
   when client
   do (format t "handler got frame: ~s~%" data)
     (write-to-client client (format nil "echo: |~s|" data))
     (when (eq data :eof)
       (write-to-client client :close)))

(defun kill-echo ()
  (setf *echo-kill* t)
  (sb-concurrency:send-message *ws-test-queue* (list nil :kill))
)
(kill-echo)



;;;; -----------

(defclass ws-chat-server (ws-resource)
  ((read-queue :allocation :class :initform *ws-test-queue*)
   (clients :initform () :accessor clients)))

(setf (gethash "/chat" *resources*)
      (make-instance 'ws-chat-server))

(defmethod ws-accept-connection ((res ws-chat-server) resource-name headers client)
  (push client (clients res))
  (values (slot-value res 'read-queue) nil nil nil))


(defun handle-frame (server client data)
  (loop for c in (clients server)
     unless (eq client c)
     do (write-to-client c (format nil "chat: ~s.~s : |~s|"
                                   (client-host client)
                                   (client-port client)
                                   data)))
  (when (eq data :eof)
    (setf (clients server) (delete client (clients server)))
    (write-to-client client :close)))

(loop with server = (gethash "/chat" *resources*)
   for (client data) = (sb-concurrency:receive-message *ws-test-queue*)
   until (eq data :kill)
   when client
   do (handle-frame server client data))
