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
(defparameter *resources* (make-hash-table :test 'equal)
  "hash mapping resource name to (list of handler instance, origin
 validation function, ?)")

;; functions for checking origins...
(defun any-origin (o) (declare (ignore o)) t)

(defun origin-prefix (&rest prefixes)
  (lambda (o)
    (loop for p in prefixes
       for m = (mismatch o p)
       when (or (not m) (= m (length p)))
       return t)))

(defun origin-exact (&rest origins)
  ;; fixme: probably should use something better than a linear search
  (lambda (o)
    (member o origins :test #'string=)))



(defvar *ws-test-queue* (sb-concurrency:make-mailbox :name "ws-test-queue"))

(defclass ws-resource ()
  ((read-queue)))

(defgeneric ws-accept-connection (res resource-name headers client))
(defmethod ws-accept-connection (res resource-name headers client)
  (format t "got connection request on ws-resource? ~s / ~s~%" res resource-name)
  nil
)




(defclass ws-echo-server (ws-resource)
  ((read-queue :allocation :class :initform *ws-test-queue*)))

(setf (gethash "/echo" *resources*)
      (list (make-instance 'ws-echo-server)
            (origin-prefix "http://127.0.0.1" "http://localhost")))


(defmethod ws-accept-connection ((res ws-echo-server) resource-name headers client)
  (format t "got connection on echo server from ~s : ~s~%" (client-host client) (client-port client))
  (values (slot-value res 'read-queue)
          ;; use defaults for origin/resource/protocol for now..
          nil nil nil))




; (sb-concurrency:receive-message-no-hang *ws-test-queue*)
#++
(loop for (client data) = (sb-concurrency:receive-message-no-hang *ws-test-queue*)
   while client
   do (format t "handler got frame: ~s~%" data)
     (write-to-client client (format nil "echo: |~s|" data)))


(defparameter *echo-kill* nil)
#++
(loop for (client data) = (sb-concurrency:receive-message *ws-test-queue*)
   until (or *echo-kill* (eq data :kill))
   when client
   do #++(format t "handler got frame: ~s~%" data)
     (write-to-client client (format nil "echo: |~s|" data))
     (when (eq data :eof)
       (write-to-client client :close)))

(defun kill-echo ()
  (setf *echo-kill* t)
  (sb-concurrency:send-message *ws-test-queue* (list nil :kill)))
#++
(kill-echo)



;;;; -----------

(defclass ws-chat-server (ws-resource)
  ((read-queue :allocation :class :initform *ws-test-queue*)
   (clients :initform () :accessor clients)))

(setf (gethash "/chat" *resources*)
      (list (make-instance 'ws-chat-server)
            (origin-prefix "http://127.0.0.1" "http://localhost")))

(defmethod ws-accept-connection ((res ws-chat-server) resource-name headers client)
  (format t "add client ~s (~s)~%" client (client-port client))
  ;; wrong thread, can't do this here...
  ;;(push client (clients res))
  ;; fixme: probably should do this from caller...
  (sb-concurrency:send-message (slot-value res 'read-queue) (list client :add))
  (values (slot-value res 'read-queue) nil nil nil))

(defun handle-frame (server client data)
  ;(sleep 0.1)
  #++(format t "got frame ~s~%" data)
  (let ((*print-pretty* nil))
    #++(write-to-client client (format nil "chat: ~s.~s : |~s|"
                                    (client-host client)
                                    (client-port client)
                                    data)
)
    (loop with msg = (format nil "chat: ~s.~s : |~s|"
                                    (client-host client)
                                    (client-port client)
                                    data)
       for c in (clients server)
       ;;unless (eq client c)
      do (write-to-client c msg)))
  (when (or (eq data :eof)
            (eq data :dropped))
    (format t "removed client ~s (~s)~%" client (client-port client))
    (setf (clients server) (delete client (clients server)))
    (write-to-client client :close)))
#++
(let ((server (car (gethash "/chat" *resources*))))
  (sb-concurrency:receive-pending-messages *ws-test-queue*)
  (setf (clients server) nil)
  (loop
    for (client data) = (sb-concurrency:receive-message *ws-test-queue*)
     until (eq data :kill)
     when (eq data :add)
     do (push client (clients server))
       (format t "add client ~s~%" client)
     else when client
     do (handle-frame server client data)
     ;; don't hold onto client while waiting for more data
     do (setf client nil)))

#++
(kill-echo)


#++
(sb-concurrency:receive-pending-messages *ws-test-queue*)
