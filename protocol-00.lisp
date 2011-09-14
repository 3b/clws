(in-package #:ws)

;;; (todo? hixie75, chrome4/safari 5.0.0)

;;; draft hixie-76/hybi-00 protocol support
;;; used by firefox4/5, chrome6-13?, safari 5.0.1, opera 11
;;; (firefox and opera disabled by default)
(defun protocol-76/00-nonce (client)
  (unsupported-protocol-version client)
)

(defparameter *draft-76/00-close-frame*
  (make-array 2 :element-type '(unsigned-byte 8)
                :initial-contents '(#xff #x00)))

