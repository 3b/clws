(defpackage #:clws
  (:nicknames #:ws)
  (:use #:cl #:iolib)
  (:export
   ;; client
   #:write-to-client
   #:write-to-clients
   ;; resource
   #:ws-resource
   #:register-global-resource
   #:find-global-resource
   #:unregister-global-resource
   #:resource-accept-connection
   #:resource-received-frame
   #:resource-client-disconnected
   #:run-resource-listener
   #:kill-resource-listener

   #:send-custom-message-to-resource
   #:send-custom-message-to-resource
   #:call-on-resource-thread
   ;; server
   #:run-server))
   
(in-package :clws)

