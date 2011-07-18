(cl:in-package :cl-user)

(defpackage :clws-system
  (:use #:cl #:asdf))

(in-package :clws-system)

(defsystem :clws
  :depends-on (#+sbcl "sb-concurrency"
               #-sbcl "chanl"
               "iolib"
               "ironclad"
               "chunga"     ; for o7 hanshake
               "cl-base64") ; for o7 hanshake
  :serial t
  :components ((:file "package")
               #+sbcl(:file "sb-concurrency-patch")
               #+sbcl(:file "concurrency-sbcl")
               #-sbcl(:file "concurrency-chanl")
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

