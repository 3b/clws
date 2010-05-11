(in-package #:ws)

;;; control queue
;;;  commands from other threads, for enabling/disabling readers/writers,
;;;  dropping connections, whatever...
;;;
(defparameter *control-queue* (sb-concurrency:make-queue :name '*control-queue*))
(defvar *control-socket*)

(defun send-command (thunk &key (wake t))
  (sb-concurrency:enqueue thunk *control-queue*)
  ;; wake up network thread and tell it to check control queue...
  (when wake
    (write-byte 1 *control-socket*)))


;;; read-write queue stuff
(defstruct queue
  ;; socket to write to
  socket
  ;; disconnector closure for socket
  disconnect
  ;; flags indicating the read/write handlers are active
  reader-active
  writer-active
  ;; buffer being written currently, if last write couldn't send whole thing
  (write-buffer nil)
  ;; offset into write-buffer if write-buffer is set
  (write-offset 0)
  ;; queue of buffers (octet vectors) to write, or :close to kill connection
  (write-queue (sb-concurrency:make-queue))
  ;; list of partial buffers + offsets of CR/LF/etc to be decoded into
  ;; a line/frame once the end is found
  ;; offsets are inclusive start/end pairs, NIL for continued from previous
  ;;   or continued to next chunk
  (read-buffers nil)
  ;; total octets in read-buffers (so we can reject overly large frames/headers)
  (read-buffer-octets 0)
  ;; queue of decoded lines/frames
  (read-queue (sb-concurrency:make-mailbox))
  ;; reader fsm state
  (read-state :maybe-policy-file)
  ;; read handler for this queue/socket
  reader
  )

(defun activate-write (queue)
  (unless (or (queue-writer-active queue)
              (not (socket-os-fd (queue-socket queue))))
    (set-io-handler *event-base*
                    (socket-os-fd (queue-socket queue))
                    :write
                    (lambda (fd event exception)
                      (declare (ignore fd event exception))
                      (try-write-queue queue)))
    (setf (queue-writer-active queue) t)))

(defun deactivate-write (queue)
  (when (queue-writer-active queue)
    (funcall (queue-disconnect queue) :write t)
    (setf (queue-writer-active queue) nil)))


(defun activate-read (queue)
  (unless (or (queue-reader-active queue)
              (not (socket-os-fd (queue-socket queue))))
    (set-io-handler *event-base*
                    (socket-os-fd (queue-socket queue))
                    :read
                    (queue-reader queue))
    (setf (queue-reader-active queue) t)))

(defun deactivate-read (queue)
  (when (queue-reader-active queue)
    (funcall (queue-disconnect queue) :read t)
    (setf (queue-reader-active queue) nil)))

(defun try-write-queue (queue)
  (handler-case
      (loop
         unless (queue-write-buffer queue)
         do
           (setf (queue-write-buffer queue)
                 (sb-concurrency:dequeue (queue-write-queue queue)))
           (setf (queue-write-offset queue) 0)
         ;; if we got a :close command, clean up the socket
         when (eql (queue-write-buffer queue) :close)
         do
           (funcall (queue-disconnect queue) :close t)
           (return-from try-write-queue nil)
         when (queue-write-buffer queue)
         do
           (let ((count (send-to (queue-socket queue)
                                 (queue-write-buffer queue)
                                 :start (queue-write-offset queue)
                                 :end (length (queue-write-buffer queue)))))
             (incf (queue-write-offset queue) count)
             (when (>= (queue-write-offset queue)
                       (length (queue-write-buffer queue)))
               (setf (queue-write-buffer queue) nil)))
         ;; if we didn't write the entire buffer, make sure the writer is
         ;; enabled, and exit the loop
         when (queue-write-buffer queue)
         do
           (activate-write queue)
           (loop-finish)
         when (sb-concurrency:queue-empty-p (queue-write-queue queue))
         do
           (deactivate-write queue)
           (loop-finish))
    (isys:ewouldblock ()
      (format t "ewouldblock~%")
      nil)
    (isys:epipe ()
      ;; client closed conection, so drop it...
      (lg "epipe")
      (funcall (queue-disconnect queue) :close t))
    (socket-connection-reset-error ()
      (lg "connection reset")
      (funcall (queue-disconnect queue) :close t)
      )
))

(defun enqueue-write (queue data)
  (sb-concurrency:enqueue data (queue-write-queue queue))
  (try-write-queue queue))

(defparameter %frame-start% (make-array 1 :element-type '(unsigned-byte 8)
                                        :initial-element #x00))
(defparameter %frame-end% (make-array 1 :element-type '(unsigned-byte 8)
                                      :initial-element #xff))

(defun write-to-client (client string)
  (let ((hook (%client-server-hook client))
        (queue (%client-queue client)))
    (cond
      ((stringp string)
       ;; this is ugly, figure out how to write in 1 chunk without encoding
       ;; to a temp buffer and copying...
       (sb-concurrency:enqueue %frame-start% (queue-write-queue queue))
       (sb-concurrency:enqueue (babel:string-to-octets string :encoding :utf-8)
                               (queue-write-queue queue))
       (sb-concurrency:enqueue %frame-end% (queue-write-queue queue)))
      (t
       ;; fixme: verify this is something valid (like :close) before adding
       (sb-concurrency:enqueue string(queue-write-queue queue))))
    (funcall hook (lambda ()
                    (format t "server got write-to-client thunk for frame ~s~%" string)
                    (activate-write queue)))))

(defun enqueue-read (queue data)
  (sb-concurrency:send-message (queue-read-queue queue) data))

(defun dequeue-read (queue)
  (sb-concurrency:receive-message-no-hang (queue-read-queue queue)))

(defun store-partial-read (queue data offset)
  ;; fixme: should check for read-buffer-octets getting too big here?
  (push (list data offset) (queue-read-buffers queue))
  (incf (queue-read-buffer-octets queue) (length data)))

(defun extract-read-chunk-as-utf-8 (queue)
  (let ((*print-pretty* nil))
    (with-output-to-string (str)
      (loop for chunk in (nreverse (queue-read-buffers queue))
         for (b (s n . more)) = chunk
         do #++(write (babel:octets-to-string b :start (or s 0) :end n)
                      :stream str :readably nil :pretty nil)
         (format str "~a" (babel:octets-to-string b :start (or s 0) :end n))
         finally (if (and more (integerp (car n)))
                     (setf (second chunk) more
                           (queue-read-buffers queue) (list chunk)
                           (queue-read-buffer-octets queue) (- (length chunk)
                                                               (car more)))
                     (setf (queue-read-buffers queue) nil
                           (queue-read-buffer-octets queue) 0))))))

(write "foo" :readably nil :pretty nil)

;;
;;(position 1 '(1 2 3 1) :start 3)
;;(position 3 '(1 2 3 1))
;;
;;(babel:octets-to-string (coerce '(1 2 3) '(vector (unsigned-byte 8)))
;;                        :start nil :end 3)
;;
;;(type-of (coerce '(1 2 3) '(vector (unsigned-byte 8))))
