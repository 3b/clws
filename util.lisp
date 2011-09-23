(in-package #:ws)

(defun make-domain-policy (&key (from "*") (to-port "*"))
  "Generates a very basic cross-domain policy file, used for the
WebSocket emulation via Flash.

For more information on what that is, see
http://www.adobe.com/devnet/articles/crossdomain_policy_file_spec.html"
  (babel:string-to-octets
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