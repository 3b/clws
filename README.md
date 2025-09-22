# CLWS - a [WebSocket][] server in Common Lisp

Currently requires SBCL or CCL, but shouldn't be too hard to port to
other implementations/platforms supported by iolib.

Supports [WebSocket][] draft protocols [7][],[8][], and [13][], and optionally
[0][].

Doesn't currently support `wss:` (TLS/SSL) connections, but proxying behind [stud][] or [stunnel][] should work.

[WebSocket]: http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-15
[hixie]: http://tools.ietf.org/html/draft-hixie-thewebsocketprotocol
[0]: http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-00
[7]: http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-07
[8]: http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-08
[13]: http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-15
[stud]: https://github.com/bumptech/stud
[stunnel]: http:www.stunnel.org/



## Sample usage: Echo Server

First, set up a package:

```lisp
(defpackage #:clws-echo
  (:use :cl :clws))

(in-package #:clws-echo)

```

Then we can start the websockets server, here we use port 12345:

```lisp
(bordeaux-threads:make-thread (lambda ()
                                (run-server 12345))
                              :name "websockets server")
```

Next we need to define a 'resource', which we will call `/echo` (so we will connect with URIs like `ws://localhost/echo`). To do that, we subclass `ws-resource` and specialize a few generic functions on that class:

```lisp
(defclass echo-resource (ws-resource)
  ())

(defmethod resource-client-connected ((res echo-resource) client)
  (format t "got connection on echo server from ~s : ~s~%" (client-host client) (client-port client))
  t)

(defmethod resource-client-disconnected ((resource echo-resource) client)
  (format t "Client disconnected from resource ~A: ~A~%" resource client))

(defmethod resource-received-text ((res echo-resource) client message)
  (format t "got frame ~s from client ~s" message client)
  (write-to-client-text client message))

(defmethod resource-received-binary((res echo-resource) client message)
  (format t "got binary frame ~s from client ~s" (length message) client)
  (write-to-client-binary client message))
```

Finally, we register the resource with the server, and start a thread to handle messages for that resource:

```lisp
(register-global-resource "/echo"
                          (make-instance 'echo-resource)
                          (origin-prefix "http://127.0.0.1" "http://localhost"))

(bordeaux-threads:make-thread (lambda ()
                                (run-resource-listener
                                 (find-global-resource "/echo")))
                              :name "resource listener for /echo")
```


## Configuration variables

* `*protocol-76/00-support*`: set to T to enable support for [draft-hixie-76][hixie]/[draft-ietf-hybi-00][0] protocol  
  No longer used by current browsers, and doesn't support binary frames. May go away soon.

* `*max-clients*`: maximum number of simultaneous connections allowed, or `NIL` for no limit

* `*max-read-frame-size*`, `*max-read-message-size*`: maximum 'frame' and 'message' sizes allowed from clients.  
  Malicious clients can cause the server to buffer up to `*max-read-message-size*` per connection, so these should probably be reduced as much as possible for production servers.

* `*debug-on-server-errors*`, `*debug-on-resource-errors*`: set to T to enter debugger on errors instead of dropping connections, for the server thread and resource handler thread respectively.

## Resource handler API

* `register-global-resource (name resource-handler origin-validation-function)`:  
  Registers `resource-handler` for the resource `name`, which should be the `abs_path` part of a URI, like `/foo/bar`, `origin-validation-function` should be a function of one argument which returns true for any origin from which connections will be accepted. See `any-origin`,`origin-prefix`,`origin-exact`. ("Origin" in this case refers to the value of the `Origin` or `Sec-Webcosket-Origin` header required to be sent by browsers, specifying the host from which the page was loaded, like `http://localhost`.)

* `resource-received-text (resource client message)`: Resource handlers should specialize this generic function to handle `text` messages from clients. `message` is a lisp `string` containing the message from `client`.

* `resource-received-binary (resource client message)`: Resource handlers should specialize this generic function to handle `binary` messages from clients. `message` is a `(vector (unsigned-byte 8))` containing the message from `client`.

* `resource-received-pong (resource client message)`: Resource handlers can specialize this generic function to handle `pong` frames from clients. `message` is the payload data from the pong frame (may be empty). This is typically used for latency testing and connection keep-alive monitoring when combined with `write-to-client-ping`.

* `resource-client-connected (resource client)`: Called to notify a resource handler when a client connects. If the handler objects to a particular client for some reason, it can return `:reject` to close the connection and ignore any already received data from that client.

* `resource-client-disconnected (resource client)`: Called when a client disconnects.

## Sending data to clients

* `write-to-client-text (client message &key frame-size)`: Send `message` to `client`. `message` should be a CL `string` or a `(simple-array (unsigned-byte 8) (*))` containing a utf-8 encoded string. If `frame-size` is not `nil`, message will be broken up into frames of `frame-size` octets.

* `write-to-clients-text (clients message &key frame-size)`: Send `message` to a list of `clients`. Same as `write-to-client-text`, but tries to avoid repeated processing (utf-8 encoding, building frames, etc) that can be shared between clients.

* `write-to-client-binary (client message &key frame-size)`: Send `message` to `client`. `message` should be a `(simple-array (unsigned-byte 8) (*))`.  If `frame-size` is not `nil`, message will be broken up into frames of `frame-size` octets.

* `write-to-clients-binary (clients message &key frame-size)`: Send `message` to a list of `clients`. Same as `write-to-client-binary`, but tries to avoid repeated processing (utf-8 encoding, building frames, etc) that can be shared between clients.

* `write-to-client-close (client &key (code 1000) message)`: Send a `close` message to `client`. `code` specifies the 'status code' to be send in the close message (see the [websocket spec][http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-15#section-7.4] for valid codes) defaults to 1000, indicating "normal closure".  `message` can be a short string (must utf-8 encode to < 123 octets) describing the reason for closing the connection.

* `write-to-client-ping (client &optional message)`: Send a `ping` frame to `client` according to RFC 6455. `message` is optional payload data (max 125 bytes). The client must respond with a pong frame containing the same payload data. Useful for connection keep-alive and latency testing.

## Getting information about connected clients  
   (most of these should be treated as read-only, and any visible `setf`
 functions may go away at some point)

* `client-resource-name (client)`: Name of resource requested by `client`.

* `client-query-string (client)`: Query string (the part of the URI after #\? if any) provided by `client` when connecting.  
  For example if client connects to `ws://example.com/test?foo`, `client-resource-name` would return `"/test"` and `client-query-string` would return `"foo"`.

* `client-websocket-version (client)`: Protocol version being used for specified `client`.

* `client-host (client)`: IP address of client, as a string.

* `client-port (client)`: Port from which client connected.

* `client-connection-headers (client)`: Hash table containing any HTTP headers supplied by `client`, as a hash table of keywords (`:user-agent`, `:cookie`, etc) -> strings.




