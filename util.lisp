(in-package #:ws)

(defparameter *event-base* nil)
;; hash of client objects to them selves (just used as a set for now)
(defparameter *clients* nil)

(defun parse-handshake (lines)
  (format t "parsing handshake: ~s~%" lines)
  (let* ((resource nil)
         (headers (make-hash-table :test 'equal))
         (resource-line (pop lines))
         (s1 (position #\space resource-line))
         ;; fixme: send a proper error if no space found
         (s2 (position #\space resource-line :start (1+ s1))))
    (assert (string= "GET" (subseq resource-line 0 s1)))
    (assert (string= " HTTP/1.1" (subseq resource-line s2)))
    (setf resource (subseq resource-line (1+ s1) s2))
    (assert (string= "Upgrade: WebSocket" (pop lines)))
    (assert (string= "Connection: Upgrade" (pop lines)))
    (loop for l in lines
       for c = (position #\: l)
       do (setf (gethash (subseq l 0 c) headers)
                (subseq l (+ (if (and (< c (1- (length l)))
                                      (char= #\space (aref l (1+ c))))
                                 2 1)
                             c))))
    (values resource headers)))


(defun make-handshake (origin location protocol)
  (babel:string-to-octets
   (format nil "HTTP/1.1 101 Web Socket Protocol Handshake
Upgrade: WebSocket
Connection: Upgrade
WebSocket-Origin: ~a
WebSocket-Location: ~a
WebSocket-Protocol: ~a

"
           origin
           location
           protocol)
   :encoding :ascii))


(defun make-domain-policy (&key (from "*") (to-port "*"))
  (babel:string-to-octets
   (format nil "<cross-domain-policy><allow-access-from domain=\"~a\" to-ports=\"~a\" /></cross-domain-policy>~c"
           from to-port
           (code-char 0))
   :encoding :ascii)
)

(defun lg (&rest args)
  (apply #'format t args)
  (finish-output))