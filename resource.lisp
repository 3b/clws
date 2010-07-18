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

(defun register-global-resource (name resource-handler origin-validation-fn)
  "Registers a resource instance where NAME is a path string like
'/swank', resource-handler is an instance of WS-RESOURCE, and
ORIGIN-VALIDATION-FN is a function that takes an origin string as
input and returns T if that origin is allowed to access this
resource."
  (setf (gethash name *resources*)
        (list resource-handler origin-validation-fn)))

(defun find-global-resource (name)
  "Returns the resource registerd via REGISTER-GLOBAL-RESOURCE with name NAME."
  (first (gethash name *resources*)))

(defun unregister-global-resource (name)
  "Removes the resource registerd via REGISTER-GLOBAL-RESOURCE with name NAME."
  (remhash name *resources*))

(defun valid-resource-p (server resource)
  "Returns non-nil if there is a handler registered for the resource
of the given name (a string)."
  (declare (type string resource)
           (ignore server))
  (when resource
    (gethash resource *resources*)))

;; functions for checking origins...
(defun any-origin (o) (declare (ignore o)) t)

(defun origin-prefix (&rest prefixes)
  "Returns a function that checks whether a given path matches any of
the prefixes passed as arguments."
  (lambda (o)
    (loop :for p :in prefixes
          :for m = (mismatch o p)
          :when (or (not m) (= m (length p)))
          :return t)))

(defun origin-exact (&rest origins)
  "Returns a function that checks whether a given path matches any of
the origins passed as arguments exactly."
  ;; fixme: probably should use something better than a linear search
  (lambda (o)
    (member o origins :test #'string=)))

(defgeneric resource-read-queue (resource)
  (:documentation "The concurrent mailbox used to pass messages
  between the server thread and resource thread."))

(defclass ws-resource ()
  ((read-queue :initform (make-mailbox) :reader resource-read-queue))
  (:documentation "A server may have many resources, each associated
  with a particular resource path (like /echo or /chat).  An single
  instance of a resource handles all requests on the server for that
  particular url, with the thelp of RUN-RESOURCE-LISTENER,
  RESOURCE-RECEIVED-FRAME, and RESOURCE-CLIENT-DISCONNECTED."))

(defgeneric resource-accept-connection (res resource-name headers client)
  (:documentation "Decides whether to accept a connection and returns
values to process the connection further.

Passed values
    - RES is the instance of ws-resource
    - RESOURCE-NAME is the resource name requested by the client (string)
    - HEADERS is the hash table of headers from the client
    - client is the instance of client

Returns values
    1. NIL if the connection should be rejected, or non-nil otherwise
    2. Concurrent mailbox in which to place messages received from the 
       client, or NIL for default
    3. origin origin from which to claim this resource is responding, 
       or NIL  for default.
    4. handshake-resource or NIL for default
    5. protocol or NIL for default

Most of the time this function will just return a mailbox and nil for
the other values."))

(defgeneric resource-client-disconnected (resource client)
  (:documentation "Called when a client disconnected from a WebSockets resource."))

(defgeneric resource-received-frame (resource client message)
  (:documentation "Called when a client sent a frame to a WebSockets resource."))

(defgeneric resource-received-custom-message (resource message)
  (:documentation "Called on the resource listener thread when a
  client is passed an arbitrary message via
  SEND-CUSTOM-MESSAGE-TO-RESOURCE. "))

(defgeneric send-custom-message-to-resource (resource message)
  (:documentation "Thread-safe way to pass a message to the resource
  listener.  Any message passed with this function will result in
  RESOURCE-RECEIVED-CUSTOM-MESSAGE being called on the resource thread
  with the second argument of this function."))

(defmethod resource-accept-connection (res resource-name headers client)
  (lg "Got connection request on ws-resource ~s / ~s: REJECTING~%" res resource-name)
  nil)

(defmethod send-custom-message-to-resource (resource message)
  (mailbox-send-message (resource-read-queue resource)
                        (list message  :custom)))

(defclass funcall-custom-message ()
  ((function :initarg :function :initform nil :reader message-function))
  (:documentation "A type of so-called 'custom message' used to call a
  function on the main resource thread."))

(defmethod resource-received-custom-message (resource (message funcall-custom-message))
  (funcall (message-function message)))

(defgeneric call-on-resource-thread (resource fn)
  (:documentation "Funcalls FN on the resource thread of RESOURCE."))

(defmethod call-on-resource-thread (resource fn)
  (send-custom-message-to-resource
   resource (make-instance 'funcall-custom-message :function fn)))

(defun run-resource-listener (resource)
  "Runs a resource listener in its own thread indefinitely, calling
RESOURCE-CLIENT-DISCONNECTED and RESOURCE-RECEIVED-FRAME as appropriate."
  (loop :for (client data) = (mailbox-receive-message (slot-value resource 'read-queue))
        :do
        (cond
          ((eql data :eof) (write-to-client client :close))
          ((eql data :dropped) (write-to-client client :close))
          ((eql data :close-resource))
          ((eql data :custom) ;; here we use the client place to store the custom message
           (let ((message client))
             (resource-received-custom-message resource message)))
          ((symbolp data) (error "Unknown symbol in read-queue of resource: ~S " data))
          (t              (resource-received-frame resource client data)))
        ;; fixme should probably call some generic function with all
        ;; the remaining messages
        :until (eql data :close-resource)))

(defun kill-resource-listener (resource)
  "Terminates a RUN-RESOURCE-LISTENER from another thread."
  (mailbox-send-message (resource-read-queue resource)
                        '(nil :close-resource)))
