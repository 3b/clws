(in-package #:clws)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Queues
;;;;   Thread safe queue
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun make-queue (&key name initial-contents)
  "Returns a new QUEUE with NAME and contents of the INITIAL-CONTENTS
sequence enqueued."
  (declare (ignorable name))
  (let ((c (make-instance 'chanl:unbounded-channel)))
    (loop for i on initial-contents
       do (chanl:send c i))
    c))

(defun enqueue (value queue)
  "Adds VALUE to the end of QUEUE. Returns VALUE."
  (chanl:send queue value))

(defun dequeue (queue)
  "Retrieves the oldest value in QUEUE and returns it as the primary value,
and T as secondary value. If the queue is empty, returns NIL as both primary
and secondary value."
  ;; fixme: doesn't actually return T for second value, returns the queue
  ;; determine if that matters and either fix it or change docstring
  (chanl:recv queue :blockp nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Mailboxes
;;;;  Thread safe queue with ability to do blocking reads
;;;;  and get count of currently queueud items
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
#+sbcl
(defstruct atomic-place
  (val 0 :type (unsigned-byte #+x86-64 64 #+x86 32)))

(defun make-mailbox (&key name initial-contents)
  "Returns a new MAILBOX with messages in INITIAL-CONTENTS enqueued."  
  (cons
   (make-atomic-place :val (length initial-contents))
   (make-queue :name name :initial-contents initial-contents)))

#++
(defun mailboxp (mailbox)
  "Returns true if MAILBOX is currently empty, NIL otherwise."
  (chanl:channelp mailbox))

(defun mailbox-empty-p (mailbox)
  "Returns true if MAILBOX is currently empty, NIL otherwise."
  (zerop (mailbox-count mailbox)))

(defun mailbox-send-message (mailbox message)
  "Adds a MESSAGE to MAILBOX. Message can be any object."
   #- (or ccl sbcl)
  (error "not implemented")
  (progn
      #+ccl (ccl::atomic-incf (car mailbox))
      #+sbcl (sb-ext:atomic-incf (atomic-place-val (car mailbox)))
    (chanl:send (cdr mailbox) message)))

(defun mailbox-receive-message (mailbox &key)
  "Removes the oldest message from MAILBOX and returns it as the
primary value. If MAILBOX is empty waits until a message arrives."
  #- (or ccl sbcl)
  (error "not implemented")
  (prog1
      (chanl:recv (cdr mailbox))
    #+sbcl (sb-ext:atomic-decf (atomic-place-val (car mailbox)))
    #+ccl(ccl::atomic-decf (car mailbox))))

(defun mailbox-receive-message-no-hang (mailbox)
  "The non-blocking variant of RECEIVE-MESSAGE. Returns two values,
the message removed from MAILBOX, and a flag specifying whether a
message could be received."
  #- (or ccl sbcl)
  (error "not implemented")
  (multiple-value-bind (message found)
      (chanl:recv (cdr mailbox) :blockp nil)
    (when found
      #+sbcl (sb-ext:atomic-decf (atomic-place-val (car mailbox)))
      #+ccl(ccl::atomic-decf (car mailbox)))
    (values message found)))

(defun mailbox-count (mailbox)
  "The non-blocking variant of RECEIVE-MESSAGE. Returns two values,
the message removed from MAILBOX, and a flag specifying whether a
message could be received."
  #+sbcl (atomic-place-val (car mailbox))
  #-sbcl (car mailbox))

(defun mailbox-list-messages (mailbox)
  "Returns a fresh list containing all the messages in the
mailbox. Does not remove messages from the mailbox."
  (error "not implemented"))

(defun mailbox-receive-pending-messages (mailbox &optional n)
  "Removes and returns all (or at most N) currently pending messages
from MAILBOX, or returns NIL if no messages are pending.

Note: Concurrent threads may be snarfing messages during the run of
this function, so even though X,Y appear right next to each other in
the result, does not necessarily mean that Y was the message sent
right after X."
  (loop with msg = nil
     with found = nil
     for i from 0
     while (or (not n) (< i n))
     do (setf (values msg found) (mailbox-receive-message-no-hang mailbox))
     while found
     collect msg))

