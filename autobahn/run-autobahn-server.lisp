;;;; run-autobahn-server.lisp
;;;; Starts CLWS server for Autobahn Test Suite fuzzing
;;;;
;;;; This script relies on .sbclrc to set up ocicl runtime
;;;; Run with: sbcl --load run-autobahn-server.lisp

;; Suppress IOLIB/COMMON-LISP package conflict warnings
#+sbcl
(setf sb-ext:*on-package-variance* '(:warn nil))

;; Add /tmp/clws to ASDF registry so it can find clws.asd
(let* ((this-dir (make-pathname :name nil :type nil
                                :defaults (or *load-truename* *default-pathname-defaults*)))
       (project-root (truename (merge-pathnames "../" this-dir))))
  (pushnew project-root asdf:*central-registry* :test #'equal))

;; Load CLWS
(format t "~%Loading CLWS system...~%")
(force-output)

;; Don't suppress warnings/errors during loading
(setf *compile-verbose* t
      *compile-print* t
      *load-verbose* t)

(handler-case
    (asdf:load-system :clws)
  (error (e)
    (format t "~%~%========================================~%")
    (format t "ERROR loading CLWS:~%")
    (format t "~A~%" e)
    (format t "========================================~%~%")
    (force-output)
    (uiop:quit 1)))

(format t "~%CLWS loaded successfully!~%")
(force-output)

(in-package :clws)

(format t "Starting CLWS server for Autobahn testing...~%")
(format t "Server URL: ws://localhost:12345/echo~%")
(format t "Press Ctrl+C to stop~%~%")

;;; Define echo resource for testing
(defclass echo-resource (ws-resource) ())

(defmethod resource-client-connected ((res echo-resource) client)
  (declare (ignore res client))
  nil)

(defmethod resource-client-disconnected ((res echo-resource) client)
  (declare (ignore res client))
  nil)

(defmethod resource-received-text ((res echo-resource) client message)
  ;; Echo the message back
  (write-to-client-text client message))

(defmethod resource-received-binary ((res echo-resource) client message)
  ;; Echo the binary data back
  (write-to-client-binary client message))

;; Register echo resource with permissive origin validation (Autobahn doesn't send Origin header)
;; Use any-origin function to accept all origins including nil
(register-global-resource
  "/echo"
  (make-instance 'echo-resource)
  #'any-origin)  ; Accept any origin for protocol conformance testing

(format t "[Server] Resource registered: /echo~%")

;; Start server thread
(bt:make-thread
  (lambda ()
    (format t "[Server] Starting server on port 12345~%")
    (run-server 12345))
  :name "clws-autobahn-server")

(sleep 1)

;; Start resource listener thread
(bt:make-thread
  (lambda ()
    (format t "[Server] Starting resource listener~%")
    (run-resource-listener (find-global-resource "/echo")))
  :name "clws-echo-resource")

(format t "~%[Server] CLWS test server is ready for Autobahn!~%~%")

;; Keep the script running
(loop (sleep 60))
