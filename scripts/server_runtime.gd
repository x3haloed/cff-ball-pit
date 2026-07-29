extends Node

const DEFAULT_PORT := 39090
const DEFAULT_DEADLINE_SECONDS := 20.0
const PHYSICS_HZ := 60.0
const ROBOT_SPEED := 5.0
const ROBOT_TURN_RATE := 2.2

var world: Node3D
var peer := ENetMultiplayerPeer.new()
var participants := {}
var peer_to_participant := {}
var actions := {}
var action_results := {}
var frame_participants: Array = []
var frame_id := 0
var frame_opened_usec := 0
var last_resolution_usec := 0
var deadline_seconds := DEFAULT_DEADLINE_SECONDS
var stepping := false
var substeps_remaining := 0
var active_simulation_delta := 0.0
var audit_path := ""


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func start(args: Dictionary) -> void:
	var port := int(args.get("port", DEFAULT_PORT))
	deadline_seconds = float(args.get("deadline", DEFAULT_DEADLINE_SECONDS))
	audit_path = str(args.get("audit", "user://server-events.jsonl"))
	world = Node3D.new()
	world.name = "AuthoritativeWorld"
	add_child(world)
	WorldBuilder.build_world(world)

	var error := peer.create_server(port, 32)
	if error != OK:
		push_error("Could not create ENet server on %d: %s" % [port, error_string(error)])
		get_tree().quit(2)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_append_audit("server_started", {"port": port})
	get_tree().paused = true
	call_deferred("_open_frame")


func _process(_delta: float) -> void:
	if frame_opened_usec <= 0 or stepping:
		return
	if frame_participants.is_empty():
		return
	if _all_actions_present():
		_begin_simulation_step()
		return
	var elapsed := (Time.get_ticks_usec() - frame_opened_usec) / 1_000_000.0
	if elapsed >= deadline_seconds:
		for participant_id in frame_participants:
			if not actions.has(participant_id):
				actions[participant_id] = FrameContract.fallback_action()
				participants[participant_id]["timed_out"] = true
				_append_audit("action_timeout_fallback", {
					"frame_id": frame_id,
					"participant_id": participant_id,
					"action": actions[participant_id],
				})
		_begin_simulation_step()


func _physics_process(delta: float) -> void:
	if not stepping:
		return
	for participant_id in frame_participants:
		var participant: Dictionary = participants[participant_id]
		var robot: CharacterBody3D = participant["robot"]
		var action: Dictionary = actions.get(participant_id, FrameContract.fallback_action())
		var heading := float(robot.get_meta("heading", 0.0))
		var throttle := float(action.throttle)
		var steering := float(action.steering)
		if bool(action.brake):
			throttle = 0.0
		heading += steering * ROBOT_TURN_RATE * delta
		robot.set_meta("heading", heading)
		robot.rotation.y = heading
		var forward := -robot.global_transform.basis.z
		robot.velocity = forward * throttle * ROBOT_SPEED
		robot.velocity.y = -1.0
		robot.move_and_slide()
		for collision_index in robot.get_slide_collision_count():
			var collision := robot.get_slide_collision(collision_index)
			var collider := collision.get_collider()
			if collider is RigidBody3D:
				var push := forward * throttle * 1.8
				push.y = 0.15
				collider.apply_central_impulse(push)
	substeps_remaining -= 1
	if substeps_remaining <= 0:
		_finish_simulation_step()


func _open_frame() -> void:
	frame_id += 1
	actions.clear()
	frame_participants = _active_ids()
	frame_opened_usec = Time.get_ticks_usec()
	for participant_id in participants:
		participants[participant_id]["timed_out"] = false
	_append_audit("frame_opened", {"frame_id": frame_id, "participants": frame_participants})
	for participant_id in frame_participants:
		var participant: Dictionary = participants[participant_id]
		frame_open.rpc_id(int(participant.peer_id), frame_id, _roster_snapshot())


func _begin_simulation_step() -> void:
	if stepping:
		return
	stepping = true
	var now := Time.get_ticks_usec()
	var delta_origin := frame_opened_usec if last_resolution_usec <= 0 else last_resolution_usec
	var real_delta := (now - delta_origin) / 1_000_000.0
	active_simulation_delta = FrameContract.simulation_delta(real_delta)
	substeps_remaining = maxi(1, roundi(active_simulation_delta * PHYSICS_HZ))
	_append_audit("frame_committed", {
		"frame_id": frame_id,
		"simulation_delta": active_simulation_delta,
		"substeps": substeps_remaining,
		"actions": actions,
	})
	for participant_id in frame_participants:
		if participants.has(participant_id):
			var participant: Dictionary = participants[participant_id]
			frame_committed.rpc_id(int(participant.peer_id), frame_id, active_simulation_delta)
	get_tree().paused = false


func _finish_simulation_step() -> void:
	stepping = false
	get_tree().paused = true
	last_resolution_usec = Time.get_ticks_usec()
	var snapshot := _world_snapshot()
	var result := {
		"frame_id": frame_id,
		"simulation_delta": active_simulation_delta,
		"resolved_at_unix_ms": Time.get_unix_time_from_system() * 1000.0,
		"action_kinds": _action_kind_snapshot(),
		"participants": snapshot.participants,
		"balls": snapshot.balls,
	}
	action_results[frame_id] = result
	while action_results.size() > 64:
		action_results.erase(action_results.keys().min())
	_append_audit("frame_resolved", result)
	for participant_id in frame_participants:
		var participant: Dictionary = participants[participant_id]
		frame_resolved.rpc_id(
			int(participant.peer_id),
			result,
			participant_id,
			bool(participant.timed_out),
			str(actions.get(participant_id, FrameContract.fallback_action()).kind),
		)
	call_deferred("_open_frame")


@rpc("any_peer", "call_remote", "reliable")
func register_participant(participant_id: String, display_name: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var clean_id := participant_id.strip_edges().substr(0, 48)
	if clean_id.is_empty():
		registration_rejected.rpc_id(sender, "participant_id is required")
		return
	if participants.has(clean_id) and int(participants[clean_id].peer_id) != sender:
		registration_rejected.rpc_id(sender, "participant profile is already active")
		return
	var robot := WorldBuilder.create_robot(clean_id, _participant_color(clean_id), _spawn_for(participants.size()))
	world.add_child(robot)
	participants[clean_id] = {
		"peer_id": sender,
		"display_name": display_name.strip_edges().substr(0, 48),
		"robot": robot,
		"active": true,
		"timed_out": false,
	}
	peer_to_participant[sender] = clean_id
	_append_audit("participant_joined", {"participant_id": clean_id, "peer_id": sender})
	registration_accepted.rpc_id(sender, clean_id, frame_id)
	if frame_id > 0 and not stepping:
		if not frame_participants.has(clean_id):
			frame_participants.append(clean_id)
			frame_participants.sort()
		frame_open.rpc_id(sender, frame_id, _roster_snapshot())


@rpc("any_peer", "call_remote", "reliable")
func submit_frame_action(request_frame_id: int, raw_action: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var participant_id := str(peer_to_participant.get(sender, ""))
	if participant_id.is_empty():
		action_rejected.rpc_id(sender, request_frame_id, "participant is not registered")
		return
	if request_frame_id < frame_id:
		if action_results.has(request_frame_id):
			_append_audit("action_replayed", {"frame_id": request_frame_id, "participant_id": participant_id})
			action_replayed.rpc_id(sender, action_results[request_frame_id], participant_id)
		else:
			_append_audit("action_rejected", {"frame_id": request_frame_id, "participant_id": participant_id, "reason": "stale frame"})
			action_rejected.rpc_id(sender, request_frame_id, "stale frame")
		return
	if request_frame_id > frame_id:
		_append_audit("action_rejected", {"frame_id": request_frame_id, "participant_id": participant_id, "reason": "future frame"})
		action_rejected.rpc_id(sender, request_frame_id, "future frame")
		return
	if not frame_participants.has(participant_id):
		action_rejected.rpc_id(sender, request_frame_id, "participant joins on the next decision frame")
		return
	if actions.has(participant_id):
		_append_audit("action_duplicate", {"frame_id": frame_id, "participant_id": participant_id})
		action_accepted.rpc_id(sender, frame_id, true)
		return
	actions[participant_id] = FrameContract.normalize_action(raw_action)
	action_accepted.rpc_id(sender, frame_id, false)
	_append_audit("action_submitted", {
		"frame_id": frame_id,
		"participant_id": participant_id,
		"action": actions[participant_id],
	})


@rpc("authority", "call_remote", "reliable")
func registration_accepted(_participant_id: String, _frame: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func registration_rejected(_reason: String) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func frame_open(_frame: int, _roster: Array) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func frame_committed(_frame: int, _simulation_delta: float) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func action_accepted(_frame: int, _duplicate: bool) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func action_rejected(_frame: int, _reason: String) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func action_replayed(_result: Dictionary, _participant_id: String) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func frame_resolved(
	_result: Dictionary,
	_participant_id: String,
	_timed_out: bool,
	_action_kind: String,
) -> void:
	pass


func _on_peer_connected(peer_id: int) -> void:
	_append_audit("peer_connected", {"peer_id": peer_id})


func _on_peer_disconnected(peer_id: int) -> void:
	var participant_id := str(peer_to_participant.get(peer_id, ""))
	peer_to_participant.erase(peer_id)
	if participant_id.is_empty() or not participants.has(participant_id):
		return
	var participant: Dictionary = participants[participant_id]
	participant.active = false
	var robot: Node = participant.robot
	if is_instance_valid(robot):
		robot.queue_free()
	participants.erase(participant_id)
	actions.erase(participant_id)
	frame_participants.erase(participant_id)
	_append_audit("participant_departed", {"participant_id": participant_id, "peer_id": peer_id})
	if not stepping and not _active_ids().is_empty() and _all_actions_present():
		_begin_simulation_step()


func _active_ids() -> Array:
	var ids := []
	for participant_id in participants:
		if bool(participants[participant_id].active):
			ids.append(participant_id)
	ids.sort()
	return ids


func _all_actions_present() -> bool:
	var ids := frame_participants
	return not ids.is_empty() and ids.all(func(participant_id): return actions.has(participant_id))


func _action_kind_snapshot() -> Dictionary:
	var kinds := {}
	for participant_id in frame_participants:
		kinds[participant_id] = str(
			actions.get(participant_id, FrameContract.fallback_action()).kind
		)
	return kinds


func _world_snapshot() -> Dictionary:
	var participant_snapshot := {}
	for participant_id in _active_ids():
		var robot: CharacterBody3D = participants[participant_id].robot
		participant_snapshot[participant_id] = {
			"position": [robot.position.x, robot.position.y, robot.position.z],
			"heading": float(robot.get_meta("heading", 0.0)),
			"velocity": [robot.velocity.x, robot.velocity.y, robot.velocity.z],
		}
	var ball_snapshot := []
	var balls := world.get_node_or_null("Balls")
	if balls:
		for ball in balls.get_children():
			if ball is RigidBody3D:
				ball_snapshot.append([
					ball.position.x,
					ball.position.y,
					ball.position.z,
					ball.rotation.x,
					ball.rotation.y,
					ball.rotation.z,
				])
	return {"participants": participant_snapshot, "balls": ball_snapshot}


func _roster_snapshot() -> Array:
	return _active_ids().map(func(participant_id): return {
		"participant_id": participant_id,
		"display_name": participants[participant_id].display_name,
	})


func _participant_color(participant_id: String) -> Color:
	var hue := float(abs(participant_id.hash()) % 1000) / 1000.0
	return Color.from_hsv(hue, 0.68, 0.95)


func _spawn_for(index: int) -> Vector3:
	var angle := float(index) * TAU / 8.0
	return Vector3(cos(angle) * 7.0, 0.1, sin(angle) * 7.0)


func _append_audit(kind: String, details: Dictionary) -> void:
	var path := ProjectSettings.globalize_path(audit_path)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not open audit path %s" % path)
		return
	file.seek_end()
	file.store_line(JSON.stringify({
		"kind": kind,
		"at_unix_ms": Time.get_unix_time_from_system() * 1000.0,
		"details": details,
	}))
