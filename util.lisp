(in-package #:ws)

(defun string-to-shareable-octets (string &key (encoding babel:*default-character-encoding*)
                                            (start 0) end (use-bom :default)
                                            (errorp (not babel::*suppress-character-coding-errors*)))
  #+lispworks
  (sys:in-static-area
    (babel:string-to-octets string :encoding encoding
                            :start start
                            :end end
                            :use-bom use-bom
                            :errorp errorp))
  #-lispworks
  (babel:string-to-octets string :encoding encoding
                          :start start
                          :end end
                          :use-bom use-bom
                          :errorp errorp))

(defun make-domain-policy (&key (from "*") (to-port "*"))
  "Generates a very basic cross-domain policy file, used for the
WebSocket emulation via Flash.

For more information on what that is, see
http://www.adobe.com/devnet/articles/crossdomain_policy_file_spec.html"
  (string-to-shareable-octets
   (format nil "<?xml version=\"1.0\"?>
<!DOCTYPE cross-domain-policy SYSTEM \"http://www.macromedia.com/xml/dtds/cross-domain-policy.dtd\">
<cross-domain-policy><allow-access-from domain=\"~a\" to-ports=\"~a\" /></cross-domain-policy>~c"
           from to-port
           (code-char 0))
   :encoding :ascii))

(defun lg (&rest args)
  (declare (special *log-level*))
  (when *log-level*
    (apply #'format t args)
    (finish-output)))

(defmacro make-array-ubyte8 (size &key (initial-element nil initial-element-p)
                                    (initial-contents nil initial-contents-p))
  (let ((body `(make-array ,size :element-type '(unsigned-byte 8)
                           #+(and lispworks (not (or lispworks3 lispworks4 lispworks5.0)))
                           ,@`(:allocation :static)
                           ,@(when initial-element-p `(:initial-element ,initial-element))
                           ,@(when initial-contents-p `(:initial-contents ,initial-contents)))))
    #+(or lispworks3 lispworks4 lispworks5.0)
    `(sys:in-static-area
       ,body)
    #-(or lispworks3 lispworks4 lispworks5.0)
    body
    ))
