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



(defvar *ws-test-queue* (make-mailbox :name "ws-test-queue"))

(defclass ws-resource ()
  ((read-queue)))

(defgeneric ws-accept-connection (res resource-name headers client))
(defmethod ws-accept-connection (res resource-name headers client)
  (format t "got connection request on ws-resource? ~s / ~s~%" res resource-name)
  nil
)

