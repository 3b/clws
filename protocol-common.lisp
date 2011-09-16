(in-package #:ws)

(defparameter *supported-protocol-versions* '())
(defparameter *protocol-header-parsers* (make-hash-table :test #'equalp))

(defun get-utf8-string-or-fail (chunk-buffer &key skip-octets-end)
  (handler-case
      (if skip-octets-end
          (get-utf8-string chunk-buffer :octet-end (- (buffer-size chunk-buffer)
                                                      skip-octets-end))
          (get-utf8-string chunk-buffer))
    (flexi-streams:external-format-encoding-error ()
      (error 'fail-the-websockets-connection
             :status-code 1007
             :message "invalid UTF-8"))
    (babel:character-coding-error ()
      (error 'fail-the-websockets-connection
             :status-code 1007
             :message "invalid UTF-8"))))
