(defsystem :clws
  :depends-on ("sb-concurrency"
               "iolib")
  :serial t
  :components ((:file "package")
               (:file "util")
               (:file "queue")
               (:file "resource")
               (:file "read")
               (:file "server")))

