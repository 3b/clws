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
the latest specification draft[1].  Only a WebSockets server
implementation is provided.

[1] http://www.whatwg.org/specs/web-socket-protocol/
[2] http://tools.ietf.org/html/draft-hixie-thewebsocketprotocol-76 -- draft #76")

