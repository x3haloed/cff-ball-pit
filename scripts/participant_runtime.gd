extends Node

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 39090

var peer := ENetMultiplayerPeer.new()
var participant_id := "participant"
var display_name := "Participant"
var current_frame_id := 0
var current_roster := []
var latest_result := {}
var latest_result_metadata := {}
var latest_personal_state := {}
var accepting_actions := false
var submitted_frame_id := 0
var connected := false
var registered := false
var world: Node3D
var robots := {}
var camera: Camera3D
var control: Node
var runtime_descriptor_path := ""
var contact_strip_webp := PackedByteArray()

const CAMERA_TIERS := {
	"standard": {
		"width": 640,
		"height": 360,
		"quality": 0.75,
	},
	"inspection": {
		"width": 960,
		"height": 540,
		"quality": 0.85,
	},
}
const CONTACT_PANEL_SIZE := Vector2i(320, 180)
const CONTACT_PROGRESS := [0.25, 0.60, 1.0]


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func start(args: Dictionary) -> void:
	participant_id = str(args.get("profile", "participant")).strip_edges()
	display_name = str(args.get("name", participant_id.capitalize())).strip_edges()
	world = Node3D.new()
	world.name = "ReplicatedWorld"
	add_child(world)
	WorldBuilder.build_world(world, false)
	_build_camera()

	control = preload("res://scripts/control_http.gd").new()
	add_child(control)
	control.start(self, int(args.get("control-port", 38473)))
	_write_runtime_descriptor(str(args.get("runtime-dir", ".cff/runtimes")))

	var error := peer.create_client(str(args.get("host", DEFAULT_HOST)), int(args.get("port", DEFAULT_PORT)))
	if error != OK:
		push_error("Could not create ENet client: %s" % error_string(error))
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_disconnected)


func submit_action(frame: int, action: Dictionary) -> Dictionary:
	if not connected or not registered:
		return {"ok": false, "message": "Participant is not connected and registered."}
	if frame > current_frame_id:
		return {"ok": false, "message": "Expected frame %d." % current_frame_id, "current_frame_id": current_frame_id}
	if frame < current_frame_id:
		submit_frame_action.rpc_id(1, frame, FrameContract.normalize_action(action))
		return {"ok": true, "accepted_for_frame": frame, "replay_pending": true}
	if not accepting_actions:
		return {"ok": false, "message": "Frame %d is already committed; wait for the next frame." % current_frame_id}
	submit_frame_action.rpc_id(1, frame, FrameContract.normalize_action(action))
	submitted_frame_id = frame
	return {"ok": true, "accepted_for_frame": frame, "pending_authority": true}


func semantic_state() -> Dictionary:
	return {
		"protocol_version": FrameContract.PROTOCOL_VERSION,
		"participant_id": participant_id,
		"display_name": display_name,
		"connected": connected,
		"registered": registered,
		"frame_id": current_frame_id,
		"accepting_actions": accepting_actions,
		"roster": current_roster,
		"personal_state": latest_personal_state,
		"latest_result": latest_result_metadata,
	}


func capture_webp(tier: String = "standard") -> PackedByteArray:
	if DisplayServer.get_name() == "headless":
		return PackedByteArray()
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return PackedByteArray()
	var settings: Dictionary = CAMERA_TIERS.get(tier, CAMERA_TIERS.standard)
	image.resize(
		int(settings.width),
		int(settings.height),
		Image.INTERPOLATE_LANCZOS,
	)
	return image.save_webp_to_buffer(true, float(settings.quality))


func capture_contact_strip_webp() -> PackedByteArray:
	if DisplayServer.get_name() == "headless":
		return PackedByteArray()
	return contact_strip_webp


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "ParticipantCamera"
	camera.current = true
	camera.fov = 78.0
	world.add_child(camera)


func _apply_snapshot(result: Dictionary) -> void:
	var states: Dictionary = result.get("participants", {})
	for id in states:
		if not robots.has(id):
			var robot := WorldBuilder.create_robot(id, _participant_color(id), Vector3.ZERO)
			world.add_child(robot)
			robots[id] = robot
		var state: Dictionary = states[id]
		var robot: CharacterBody3D = robots[id]
		var position: Array = state.get("position", [0, 0, 0])
		robot.position = Vector3(float(position[0]), float(position[1]), float(position[2]))
		robot.rotation.y = float(state.get("heading", 0.0))
	for id in robots.keys():
		if not states.has(id):
			robots[id].queue_free()
			robots.erase(id)
	var ball_states: Array = result.get("balls", [])
	var balls := world.get_node_or_null("Balls")
	if balls:
		var count := mini(ball_states.size(), balls.get_child_count())
		for index in count:
			var values: Array = ball_states[index]
			if values.size() >= 6:
				var ball: RigidBody3D = balls.get_child(index)
				ball.position = Vector3(float(values[0]), float(values[1]), float(values[2]))
				ball.rotation = Vector3(float(values[3]), float(values[4]), float(values[5]))
	if states.has(participant_id):
		latest_personal_state = states[participant_id]
		var own: Node3D = robots[participant_id]
		var heading := float(latest_personal_state.get("heading", 0.0))
		var basis := Basis(Vector3.UP, heading)
		camera.global_position = own.global_position + basis * Vector3(0, 1.5, 0.15)
		camera.global_rotation = Vector3(-0.08, heading, 0)


@rpc("any_peer", "call_remote", "reliable")
func register_participant(_participant_id: String, _display_name: String) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable")
func submit_frame_action(_frame: int, _action: Dictionary) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func registration_accepted(accepted_id: String, frame: int) -> void:
	registered = true
	participant_id = accepted_id
	current_frame_id = frame
	control.emit_semantic("registered", {
		"summary": "%s joined the simulation." % display_name,
		"participant_id": participant_id,
	})


@rpc("authority", "call_remote", "reliable")
func registration_rejected(reason: String) -> void:
	registered = false
	control.emit_semantic("registration_rejected", {"summary": reason, "reason": reason})


@rpc("authority", "call_remote", "reliable")
func frame_open(frame: int, roster: Array) -> void:
	current_frame_id = frame
	current_roster = roster
	accepting_actions = true
	control.emit_semantic("frame_ready", {
		"summary": "Decision frame %d is ready for %s." % [frame, display_name],
		"frame_id": frame,
		"roster": roster,
		"state_url": "%s/state" % control.base_url(),
		"camera_url": "%s/camera" % control.base_url(),
	})


@rpc("authority", "call_remote", "reliable")
func frame_committed(frame: int, simulation_delta: float) -> void:
	if frame == current_frame_id:
		accepting_actions = false
	control.emit_semantic("frame_committed", {
		"summary": "Frame %d is committed and advancing %.2f simulated seconds." % [frame, simulation_delta],
		"frame_id": frame,
		"simulation_delta": simulation_delta,
	})


@rpc("authority", "call_remote", "reliable")
func action_accepted(frame: int, duplicate: bool) -> void:
	control.emit_semantic("action_accepted", {
		"summary": "Action accepted for frame %d%s." % [frame, " (duplicate)" if duplicate else ""],
		"frame_id": frame,
		"duplicate": duplicate,
	})


@rpc("authority", "call_remote", "reliable")
func action_rejected(frame: int, reason: String) -> void:
	control.emit_semantic("action_rejected", {
		"summary": "Action rejected for frame %d: %s" % [frame, reason],
		"frame_id": frame,
		"reason": reason,
	})


@rpc("authority", "call_remote", "reliable")
func action_replayed(result: Dictionary, for_participant_id: String) -> void:
	if for_participant_id == participant_id:
		control.emit_semantic("action_replayed", {
			"summary": "Frame %d was already resolved; its action was not applied again." % int(result.get("frame_id", 0)),
			"frame_id": int(result.get("frame_id", 0)),
			"result": result,
		})


@rpc("authority", "call_remote", "reliable")
func frame_resolved(
	result: Dictionary,
	for_participant_id: String,
	timed_out: bool,
	action_kind: String,
	temporal_samples: Array,
) -> void:
	if for_participant_id == participant_id:
		_accept_result(result, timed_out, false, action_kind, temporal_samples)


func _accept_result(
	result: Dictionary,
	timed_out: bool,
	replayed: bool,
	action_kind: String,
	temporal_samples: Array,
) -> void:
	accepting_actions = false
	latest_result = result
	_apply_snapshot(result)
	if DisplayServer.get_name() != "headless":
		await _build_contact_strip(temporal_samples, result)
	latest_result_metadata = {
		"frame_id": int(result.get("frame_id", 0)),
		"simulation_delta": float(result.get("simulation_delta", 0.0)),
		"action_kind": action_kind,
		"timed_out": timed_out,
		"replayed": replayed,
	}
	control.emit_semantic("frame_observation", {
		"summary": "Frame %d resolved after %.2f simulated seconds." % [
			int(result.get("frame_id", 0)),
			float(result.get("simulation_delta", 0.0)),
		],
		"frame_id": int(result.get("frame_id", 0)),
			"simulation_delta": float(result.get("simulation_delta", 0.0)),
			"action_kind": action_kind,
			"timed_out": timed_out,
		"replayed": replayed,
		"personal_state": latest_personal_state,
		"camera_url": "%s/camera" % control.base_url(),
	})


func _build_contact_strip(samples: Array, final_result: Dictionary) -> void:
	var strip := Image.create(
		CONTACT_PANEL_SIZE.x * CONTACT_PROGRESS.size(),
		CONTACT_PANEL_SIZE.y,
		false,
		Image.FORMAT_RGB8,
	)
	strip.fill(Color(0.08, 0.08, 0.08))
	for index in CONTACT_PROGRESS.size():
		var sample: Dictionary = (
			samples[index]
			if index < samples.size() and samples[index] is Dictionary
			else final_result
		)
		_apply_snapshot(sample)
		await RenderingServer.frame_post_draw
		var panel := get_viewport().get_texture().get_image()
		if panel == null or panel.is_empty():
			continue
		panel.resize(
			CONTACT_PANEL_SIZE.x,
			CONTACT_PANEL_SIZE.y,
			Image.INTERPOLATE_LANCZOS,
		)
		panel.convert(Image.FORMAT_RGB8)
		var panel_origin := Vector2i(index * CONTACT_PANEL_SIZE.x, 0)
		strip.blit_rect(
			panel,
			Rect2i(Vector2i.ZERO, CONTACT_PANEL_SIZE),
			panel_origin,
		)
		_draw_progress_mark(strip, panel_origin.x, float(CONTACT_PROGRESS[index]))
	_apply_snapshot(final_result)
	await RenderingServer.frame_post_draw
	contact_strip_webp = strip.save_webp_to_buffer(true, 0.75)


func _draw_progress_mark(image: Image, panel_x: int, progress: float) -> void:
	const MARK_WIDTH := 48
	const MARK_HEIGHT := 3
	const MARK_BOTTOM_MARGIN := 6
	var x := panel_x + (CONTACT_PANEL_SIZE.x - MARK_WIDTH) / 2
	var y := CONTACT_PANEL_SIZE.y - MARK_BOTTOM_MARGIN - MARK_HEIGHT
	image.fill_rect(
		Rect2i(x, y, MARK_WIDTH, MARK_HEIGHT),
		Color(0.18, 0.18, 0.18),
	)
	image.fill_rect(
		Rect2i(x, y, roundi(MARK_WIDTH * progress), MARK_HEIGHT),
		Color(0.78, 0.78, 0.78),
	)


func _on_connected() -> void:
	connected = true
	register_participant.rpc_id(1, participant_id, display_name)


func _on_connection_failed() -> void:
	connected = false
	control.emit_semantic("connection_failed", {"summary": "Could not connect to the simulation authority."})


func _on_disconnected() -> void:
	connected = false
	registered = false
	control.emit_semantic("disconnected", {"summary": "Disconnected from the simulation authority."})


func _exit_tree() -> void:
	if runtime_descriptor_path.is_empty() or not FileAccess.file_exists(runtime_descriptor_path):
		return
	var file := FileAccess.open(runtime_descriptor_path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(file.get_as_text()) if file else null
	if parsed is Dictionary and int(parsed.get("pid", -1)) == OS.get_process_id():
		DirAccess.remove_absolute(runtime_descriptor_path)


func _write_runtime_descriptor(runtime_dir: String) -> void:
	var absolute_dir := runtime_dir
	if not runtime_dir.is_absolute_path():
		absolute_dir = ProjectSettings.globalize_path("res://%s" % runtime_dir.trim_prefix("./"))
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	runtime_descriptor_path = absolute_dir.path_join("%s.json" % participant_id.validate_filename())
	var existing := FileAccess.open(runtime_descriptor_path, FileAccess.READ)
	if existing:
		var parsed: Variant = JSON.parse_string(existing.get_as_text())
		if parsed is Dictionary:
			var existing_pid := int(parsed.get("pid", -1))
			push_error("Profile %s already has a runtime descriptor for pid %d." % [participant_id, existing_pid])
			get_tree().quit(3)
			return
	var file := FileAccess.open(runtime_descriptor_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({
			"protocol_version": FrameContract.PROTOCOL_VERSION,
			"profile": participant_id,
			"display_name": display_name,
			"pid": OS.get_process_id(),
			"control_url": control.base_url(),
			"control_port": control.port,
			"started_at_unix_ms": Time.get_unix_time_from_system() * 1000.0,
		}, "  "))


func _participant_color(id: String) -> Color:
	return Color.from_hsv(float(abs(id.hash()) % 1000) / 1000.0, 0.68, 0.95)
