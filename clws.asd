(cl:in-package :cl-user)

(defpackage :clws-system
  (:use #:cl #:asdf))

(in-package :clws-system)

(defsystem :clws
  :depends-on ("sb-concurrency"
               "iolib"
               "ironclad")
  :serial t
  :components ((:file "package")
               (:file "sb-concurrency-patch")
               (:file "util")
               (:file "client")
               (:file "resource")
               (:file "read")
               (:file "server"))
  :description "CLWS implement the WebSockets protocol as described by
the latest specification draft[1].  Both server and client WebSockets
are implemented.

[1] http://tools.ietf.org/html/draft-hixie-thewebsocketprotocol-76")

