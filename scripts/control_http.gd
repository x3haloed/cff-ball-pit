extends Node

const HOST := "127.0.0.1"
const MAX_REQUEST_BYTES := 64 * 1024
const REQUEST_TIMEOUT_MSEC := 3000

var participant: Node
var server := TCPServer.new()
var port := 0
var connections: Array[Dictionary] = []
var sse_connections: Array[StreamPeerTCP] = []
var event_sequence := 0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func start(owner: Node, preferred_port: int) -> void:
	participant = owner
	for offset in 32:
		var candidate := preferred_port + offset
		if server.listen(candidate, HOST) == OK:
			port = candidate
			break
	if port == 0:
		push_error("Could not bind participant control interface near port %d" % preferred_port)
		return
	emit_semantic("control_ready", {
		"summary": "Participant control interface is ready at %s." % base_url(),
		"base_url": base_url(),
	})


func base_url() -> String:
	return "http://%s:%d" % [HOST, port]


func _process(_delta: float) -> void:
	while server.is_connection_available():
		var peer := server.take_connection()
		if peer != null:
			connections.append({
				"peer": peer,
				"buffer": PackedByteArray(),
				"started": Time.get_ticks_msec(),
			})
	var finished: Array[Dictionary] = []
	for connection in connections:
		var peer: StreamPeerTCP = connection.peer
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			finished.append(connection)
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			connection.buffer.append_array(peer.get_data(available)[1])
		if connection.buffer.size() > MAX_REQUEST_BYTES:
			_send_json(peer, 413, {"ok": false, "message": "Request too large."})
			finished.append(connection)
			continue
		var text: String = (connection.buffer as PackedByteArray).get_string_from_utf8()
		if _request_complete(text):
			var keep_open := _handle_request(peer, text)
			if not keep_open:
				peer.disconnect_from_host()
			finished.append(connection)
		elif Time.get_ticks_msec() - int(connection.started) >= REQUEST_TIMEOUT_MSEC:
			_send_json(peer, 408, {"ok": false, "message": "Request timed out."})
			finished.append(connection)
	for connection in finished:
		connections.erase(connection)
	var closed: Array[StreamPeerTCP] = []
	for peer in sse_connections:
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			closed.append(peer)
	for peer in closed:
		sse_connections.erase(peer)


func emit_semantic(kind: String, details: Dictionary) -> void:
	event_sequence += 1
	var event := {
		"sequence": event_sequence,
		"kind": kind,
		"at_unix_ms": Time.get_unix_time_from_system() * 1000.0,
		"details": details,
	}
	var payload := "data: %s\n\n" % JSON.stringify(event)
	var closed: Array[StreamPeerTCP] = []
	for peer in sse_connections:
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or peer.put_data(payload.to_utf8_buffer()) != OK:
			closed.append(peer)
	for peer in closed:
		sse_connections.erase(peer)


func _handle_request(peer: StreamPeerTCP, request_text: String) -> bool:
	var parsed := _parse_request(request_text)
	var method := str(parsed.method)
	var path := str(parsed.path)
	if method == "OPTIONS":
		_send_bytes(peer, 204, "text/plain", PackedByteArray())
		return false
	match path:
		"/", "/help":
			_send_json(peer, 200, {
				"ok": true,
				"name": "CFF Ball Pit participant control",
				"base_url": base_url(),
				"endpoints": {
					"GET /state": "Current participant, frame, roster, and latest authoritative observation.",
					"POST /action": "Submit {frame_id, throttle, steering, brake}.",
					"GET /stream": "Semantic SSE events including frame_ready and frame_observation.",
					"GET /camera": "Current participant camera as 640x360 WebP; unavailable in headless mode.",
					"GET /camera/inspection": "Current participant camera as higher-detail 960x540 WebP.",
				},
			})
		"/state":
			if method != "GET":
				_send_json(peer, 405, {"ok": false, "message": "Use GET /state."})
			else:
				_send_json(peer, 200, participant.semantic_state())
		"/action":
			if method != "POST":
				_send_json(peer, 405, {"ok": false, "message": "Use POST /action."})
			else:
				var body: Dictionary = parsed.body
				var frame := int(body.get("frame_id", participant.current_frame_id))
				var result: Dictionary = participant.submit_action(frame, body)
				_send_json(peer, 202 if bool(result.get("ok", false)) else 409, result)
		"/camera", "/camera/inspection":
			if method != "GET":
				_send_json(peer, 405, {"ok": false, "message": "Use GET /camera."})
			else:
				var tier := "inspection" if path == "/camera/inspection" else "standard"
				var webp: PackedByteArray = participant.capture_webp(tier)
				if webp.is_empty():
					_send_json(peer, 503, {"ok": false, "message": "Camera capture is unavailable in this renderer."})
				else:
					_send_bytes(peer, 200, "image/webp", webp)
		"/stream":
			if method != "GET":
				_send_json(peer, 405, {"ok": false, "message": "Use GET /stream."})
			else:
				_start_sse(peer)
				return true
		_:
			_send_json(peer, 404, {"ok": false, "message": "Unknown endpoint. Try GET /help."})
	return false


func _start_sse(peer: StreamPeerTCP) -> void:
	var headers := "\r\n".join([
		"HTTP/1.1 200 OK",
		"Content-Type: text/event-stream; charset=utf-8",
		"Cache-Control: no-cache",
		"Access-Control-Allow-Origin: *",
		"Connection: keep-alive",
		"",
		"",
	])
	peer.put_data(headers.to_utf8_buffer())
	sse_connections.append(peer)
	var hello := {
		"sequence": event_sequence,
		"kind": "hello",
		"at_unix_ms": Time.get_unix_time_from_system() * 1000.0,
		"details": {
			"summary": "CFF Ball Pit stream opened for %s." % participant.display_name,
			"state": participant.semantic_state(),
		},
	}
	peer.put_data(("data: %s\n\n" % JSON.stringify(hello)).to_utf8_buffer())


func _parse_request(text: String) -> Dictionary:
	var header_end := text.find("\r\n\r\n")
	var head := text.substr(0, header_end)
	var body_text := text.substr(header_end + 4)
	var lines := head.split("\r\n")
	var first := str(lines[0]).split(" ")
	var body := {}
	if not body_text.strip_edges().is_empty():
		var parsed: Variant = JSON.parse_string(body_text)
		if parsed is Dictionary:
			body = parsed
	return {
		"method": str(first[0]) if first.size() > 0 else "",
		"path": str(first[1]).split("?")[0] if first.size() > 1 else "/",
		"body": body,
	}


func _request_complete(text: String) -> bool:
	var header_end := text.find("\r\n\r\n")
	if header_end < 0:
		return false
	var content_length := 0
	for line in text.substr(0, header_end).split("\r\n"):
		var separator := str(line).find(":")
		if separator > 0 and str(line).substr(0, separator).to_lower() == "content-length":
			content_length = int(str(line).substr(separator + 1).strip_edges())
	var body := text.substr(header_end + 4)
	return body.to_utf8_buffer().size() >= content_length


func _send_json(peer: StreamPeerTCP, status: int, value: Dictionary) -> void:
	_send_bytes(peer, status, "application/json; charset=utf-8", JSON.stringify(value).to_utf8_buffer())


func _send_bytes(peer: StreamPeerTCP, status: int, content_type: String, body: PackedByteArray) -> void:
	var reason: String = {
		200: "OK",
		202: "Accepted",
		204: "No Content",
		404: "Not Found",
		405: "Method Not Allowed",
		408: "Request Timeout",
		409: "Conflict",
		413: "Payload Too Large",
		503: "Service Unavailable",
	}.get(status, "OK")
	var headers := "\r\n".join([
		"HTTP/1.1 %d %s" % [status, reason],
		"Content-Type: %s" % content_type,
		"Content-Length: %d" % body.size(),
		"Access-Control-Allow-Origin: *",
		"Access-Control-Allow-Headers: Content-Type",
		"Connection: close",
		"",
		"",
	])
	peer.put_data(headers.to_utf8_buffer())
	if not body.is_empty():
		peer.put_data(body)
