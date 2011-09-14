(in-package #:ws)

(defparameter *supported-protocol-versions* '())
(defparameter *protocol-header-parsers* (make-hash-table :test #'equalp))
