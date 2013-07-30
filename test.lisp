(defpackage #:ws-test
  (:use #:cl #:iolib))
(in-package #:ws-test)

(defparameter *ws-host* "127.0.0.1")
(defparameter *ws-port* 12345)
(defparameter *ws-base-path* "")

(defun ws-url (resource)
  (format nil "ws://~a:~a~a~a" *ws-host* *ws-port* *ws-base-path* resource))

(defun handshake (resource)
   (let ((crlf (format nil "~c~c" (code-char 13) (code-char 10))))
     (string-to-shareable-octets
      (print (format nil "GET ~a HTTP/1.1~a~
Upgrade: WebSocket~a~
Connection: Upgrade~a~
Host: ~a:~a~a~
Origin: http://~a~a~
WebSocket-Protocol: ~a~a~
~a"
               resource crlf
               crlf
               crlf
               *ws-host* *ws-port* crlf
               *ws-host* crlf
               "test" crlf
               crlf)))))

(defun handshake-76 (resource)
   (let ((crlf (format nil "~c~c" (code-char 13) (code-char 10))))
     (string-to-shareable-octets
      (print (format nil "GET ~a HTTP/1.1~a~
Upgrade: WebSocket~a~
Connection: Upgrade~a~
Host: ~a:~a~a~
Origin: http://~a~a~
WebSocket-Protocol: ~a~a~
Sec-WebSocket-Key1: 3e6b263  4 17 80~a~
Sec-WebSocket-Key2: 17  9 G`ZD9   2 2b 7X 3 /r90~a~
~a~
WjN}|M(6"
               resource crlf
               crlf
               crlf
               *ws-host* *ws-port* crlf
               *ws-host* crlf
               "test" crlf
               crlf
               crlf
               crlf)))))

(defun x (socket &key abort)
  (ignore-errors (shutdown socket :read t :write t))
  (close socket :abort abort))

;(babel:octets-to-string (handshake "/chat"))
;(length (handshake "/chat"))

;; fixme: organize this stuff and use some real testing lib

(defun ws-connect ()
  (make-socket :connect :active :address-family :internet
               :type :stream
               :remote-host *ws-host* :remote-port *ws-port*
               ))

;(close (ws-connect))
;(close (ws-connect) :abort t)
(defun send-handshake (socket resource)
  (let ((handshake (handshake resource)))
    (send-to socket handshake))
  socket)

(defun send-handshake-76 (socket resource)
  (let ((handshake (handshake-76 resource)))
    (send-to socket handshake))
  socket)

(defun send-handshake-fragmented (socket resource fragsize)
  (let ((handshake (handshake resource)))
    (loop for i from 0 below (length handshake) by fragsize
       do (send-to socket handshake :start i :end (+ i (min fragsize
                                                         (- (length handshake)
                                                            i))))
         (force-output socket)
         (sleep 0.01)))
  socket)

(defun send-handshake-incomplete (socket resource fragsize)
  (let ((handshake (handshake resource)))
    (send-to socket handshake :start 0 :end  (min fragsize
                                                  (length handshake)))
    (force-output socket))
  socket)

(defun read-handshake (socket)
  (loop repeat 100
     for (i l) = (multiple-value-list
                  (handler-case
                      (receive-from socket :size 2048 :dont-wait t)
                    (isys:ewouldblock ()
                      nil)))
     do (sleep 0.01)
       (when i
         (format t "read |~s|~%" (babel:octets-to-string i :encoding :utf-8 :end l :errorp nil))
         (format t "read (~{0x~2,'0x ~})~%" (coerce (subseq i (max 0 (- l 16)) l) 'list))))
  socket)
(defun read-handshake-rl (socket)
  (loop repeat 7
     do (format t "handshake: ~s~%" (read-line socket)))
  socket)
#++
(x  (send-handshake (ws-connect) "/chat"))
#++
(x (read-handshake (send-handshake-76 (ws-connect) "/chat")))
#++
(x  (send-handshake-fragmented (ws-connect) "/chat" 2))
#++
(x (read-handshake-rl (send-handshake (ws-connect) "/echo")))
#++
(loop for i from 1 below (length (handshake "/chat"))
   do (format t "-----------~%  --> ~s~%" i)
     (x (read-handshake-rl (send-handshake-fragmented (ws-connect) "/chat" i))))
#++
(x  (send-handshake-incomplete (ws-connect) "/chat" 2))
#++
(loop for i from 1 below (1+ (length (handshake "/chat")))
   do (format t "-----------~%  --> ~s~%" i)
     (x (send-handshake-incomplete (ws-connect) "/chat" i))
     (sleep 0.01))

#++
(loop for i from 1 below (1+ (length (handshake "/chat")))
   do (format t "-----------~%  --> ~s~%" i)
     (x (send-handshake-incomplete (ws-connect) "/chat" i) :abort t)
     (sleep 0.01))


#++
(let ((*ws-host* "3bb.cc"))
  (loop with s = (send-handshake (ws-connect) "/chat")
    for i from 1
    repeat 1000
    do (write-byte 0 s)
    (format s "test  ~s ddddddd dddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddq" i)
                                        ;(format t "test ~s" i)
    (write-byte #xff s)
    (finish-output s)
    (sleep 0.01)
    finally (x s)))


#++
(loop with s = (send-handshake (ws-connect) "/echo")
   for i from 1
   repeat 1000
   do (write-byte 0 s)
     (format s "test  ~s ddddddd dddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddd dddddddddddddddddddq" i)
     ;(format t "test ~s" i)
     (write-byte #xff s)
     (finish-output s)
     (loop repeat 100
        while (ignore-errors (receive-from s :size 1024)))
     (sleep 0.01)
   finally (x s))


#++
(macrolet ((ignore-some-errors (&body body)
                 `(handler-case
                      (progn ,@body)
                    (iolib.sockets:socket-not-connected-error ()
                      (format t "enotconn ~s~%" ,(format nil "~s" body))
                      nil)
                    (isys:epipe ()
                      (format t "epipe in disconnect~%")
                      nil)
                    (isys:enotconn ()
                      (format t "enotconn in shutdown/close?")
                      nil))))
   (loop
    for i1 below 50
    do
        (sleep 0.05)
    (sb-thread:make-thread
     (lambda ()
       (let (#++(*ws-host* "3bb.cc")
                #++(*ws-port* 12346)
                (i1 i1))
         (format t " thread ~s read ~s~%"
                 i1
                 (loop with s = (prog1
                                    (send-handshake (ws-connect) "/chat")
                                  (sleep 5))
                    for i from 1
                    repeat 5000
                    do (write-byte 0 s)
                    (format s "test  ~s " i)
                                        ;(format t "test ~s" i)
                    (write-byte #xff s)
                    (finish-output s)
                    sum
                    (loop repeat 100
                       for x = (ignore-errors (receive-from s :size 1024))
                       while x
                       sum (count #xff x))
                    into c
                    do (sleep 0.005)
                    finally
                    (progn
                      (format t "thread ~s waiting~%" i1)
                      (sleep 1)
                      (ignore-some-errors (shutdown s :write t))
                      (return
                        (let ((c2 #++(loop while (socket-connected-p s)
                                        repeat 600
                                        do (sleep 0.1)
                                        sum (loop for x = (ignore-errors (receive-from s :size 1024))
                                               while x
                                               sum (count #xff x)))
                                  (loop for x = (Read-byte s nil nil)
                                     while x
                                     count (= x #xff))))
                          (x s)
                          (list c c2 (+ c c2)))))))))
     :name (format nil "thread ~s" i1))))


 
