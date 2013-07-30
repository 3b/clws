(in-package #:clws)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Queues
;;;;   Thread safe queue
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun make-queue (&key name initial-contents)
  "Returns a new QUEUE with NAME and contents of the INITIAL-CONTENTS
sequence enqueued."
  #+sbcl
  (sb-concurrency:make-queue :name name :initial-contents initial-contents))

(defun enqueue (value queue)
  "Adds VALUE to the end of QUEUE. Returns VALUE."
  #+sbcl
  (sb-concurrency:enqueue value queue))

(defun dequeue (queue)
  "Retrieves the oldest value in QUEUE and returns it as the primary value,
and T as secondary value. If the queue is empty, returns NIL as both primary
and secondary value."
  (sb-concurrency:dequeue queue))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Mailboxes
;;;;  Thread safe queue with ability to do blocking reads
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun make-mailbox (&key name initial-contents)
  "Returns a new MAILBOX with messages in INITIAL-CONTENTS enqueued."
  #+sbcl
  (sb-concurrency:make-mailbox :name name :initial-contents initial-contents))

(defun mailboxp (mailbox)
  "Returns true if MAILBOX is currently empty, NIL otherwise."
  #+sbcl
  (sb-concurrency:mailboxp mailbox))

(defun mailbox-empty-p (mailbox)
  "Returns true if MAILBOX is currently empty, NIL otherwise."
  #+sbcl
  (sb-concurrency:mailbox-empty-p mailbox))

(defun mailbox-send-message (mailbox message)
  "Adds a MESSAGE to MAILBOX. Message can be any object."
  #+sbcl
  (sb-concurrency:send-message mailbox message)
  #-sbcl
  (error "Not implemented"))

(defun mailbox-receive-message (mailbox &key)
  "Removes the oldest message from MAILBOX and returns it as the
primary value. If MAILBOX is empty waits until a message arrives."
  #+sbcl
  (sb-concurrency:receive-message mailbox))

(defun mailbox-receive-message-no-hang (mailbox)
  "The non-blocking variant of RECEIVE-MESSAGE. Returns two values,
the message removed from MAILBOX, and a flag specifying whether a
message could be received."
  #+sbcl
  (sb-concurrency:receive-message-no-hang mailbox))

(defun mailbox-count (mailbox)
  "The non-blocking variant of RECEIVE-MESSAGE. Returns two values,
the message removed from MAILBOX, and a flag specifying whether a
message could be received."
  #+sbcl
  (sb-concurrency:mailbox-count mailbox))

(defun mailbox-list-messages (mailbox)
  "Returns a fresh list containing all the messages in the
mailbox. Does not remove messages from the mailbox."
  #+sbcl
  (sb-concurrency:list-mailbox-messages mailbox))

(defun mailbox-receive-pending-messages (mailbox &optional n)
  "Removes and returns all (or at most N) currently pending messages
from MAILBOX, or returns NIL if no messages are pending.

Note: Concurrent threads may be snarfing messages during the run of
this function, so even though X,Y appear right next to each other in
the result, does not necessarily mean that Y was the message sent
right after X."
  #+sbcl
  (sb-concurrency:receive-pending-messages mailbox n))




