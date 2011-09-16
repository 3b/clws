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
               "cl-base64" ; for o7 hanshake
               "flexi-streams"
               "split-sequence")
  :serial t
  :components ((:file "package")
               #+sbcl(:file "sb-concurrency-patch")
               #+sbcl(:file "concurrency-sbcl")
               #-sbcl(:file "concurrency-chanl")
               (:file "util")
               (:file "config")
               (:file "buffer")
               (:file "protocol-common")
               (:file "protocol-00")
               (:file "protocol-7")
               (:file "protocol")
               (:file "client")
               (:file "resource")
               (:file "server"))
  :description "CLWS implement the WebSockets protocol as described by
the latest specification draft[1] (as well as some older drafts
implemented by recent browsers [2][3][4]).  Only a WebSockets server
implementation is provided.

[1] http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-14
[2] http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-08
[3] http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-07
[4] http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-00")

