#+sbcl
(in-package :sb-concurrency)

;;; included upstream in 1.0.42.19, so only load on older versions
#+sbcl
(when (destructuring-bind (maj min point &rest r)
          (split-sequence:split-sequence #\. (lisp-implementation-version))
        (declare (ignore r))
        (and (string= maj "1") (string= min "0")
             (and point (<= 37 (parse-integer point :junk-allowed t) 42))))
;;; break up links when removing nodes to avoid problems with conservative
;;; GC in long-lived queues
(defun dequeue (queue)
  "Retrieves the oldest value in QUEUE and returns it as the primary value,
and T as secondary value. If the queue is empty, returns NIL as both primary
and secondary value."
  (tagbody
   :continue
     (let* ((head (queue-head queue))
            (tail (queue-tail queue))
            (first-node-prev (node-prev head))
            (val (node-value head)))
       (when (eq head (queue-head queue))
         (cond ((not (eq val +dummy+))
                (if (eq tail head)
                    (let ((dummy (make-node :value +dummy+ :next tail)))
                      (when (eq tail (sb-ext:compare-and-swap (queue-tail queue)
                                                              tail dummy))
                        (setf (node-prev head) dummy))
                      (go :continue))
                    (when (null first-node-prev)
                      (fixList queue tail head)
                      (go :continue)))
                (when (eq head (sb-ext:compare-and-swap (queue-head queue)
                                                        head first-node-prev))
                  ;; This assignment is not present in the paper, but is
                  ;; equivalent to the free(head.ptr) call there: it unlinks
                  ;; the HEAD from the queue -- the code in the paper leaves
                  ;; the dangling pointer in place.
                  (setf (node-next first-node-prev) nil)
                  (setf (node-prev head) nil
                        (node-next head) nil)
                  (return-from dequeue (values val t))))
               ((eq tail head)
                (return-from dequeue (values nil nil)))
               ((null first-node-prev)
                (fixList queue tail head)
                (go :continue))
               (t
                (sb-ext:compare-and-swap (queue-head queue)
                                         head first-node-prev)))))
     (go :continue))))