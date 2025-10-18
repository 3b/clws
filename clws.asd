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
  :license "MIT"
  :author "Bart Botta <00003b at gmail.com>"
  :description "CLWS implement the WebSocket Protocol as described by
RFC6455[1] (as well as some older drafts implemented by recent
browsers [2][3][4][5]).  Only a WebSockets server implementation is
provided.

[1]http://tools.ietf.org/html/rfc6455
[2] http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-17
[3] http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-08
[4] http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-07
[5] http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-00")

