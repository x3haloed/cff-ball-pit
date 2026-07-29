class_name FrameContract
extends RefCounted

const PROTOCOL_VERSION := 3
const MIN_SIMULATION_DELTA := 0.25
const MAX_SIMULATION_DELTA := 2.0
const QUANTUM := 0.25


static func normalize_action(raw: Dictionary) -> Dictionary:
	var kind := "hold" if str(raw.get("kind", "drive")) == "hold" else "drive"
	if kind == "hold":
		return {
			"kind": "hold",
			"throttle": 0.0,
			"steering": 0.0,
			"brake": true,
		}
	return {
		"kind": "drive",
		"throttle": clampf(float(raw.get("throttle", 0.0)), -1.0, 1.0),
		"steering": clampf(float(raw.get("steering", 0.0)), -1.0, 1.0),
		"brake": bool(raw.get("brake", false)),
	}


static func fallback_action() -> Dictionary:
	return {
		"kind": "timeout_brake",
		"throttle": 0.0,
		"steering": 0.0,
		"brake": true,
	}


static func simulation_delta(real_seconds: float) -> float:
	var quantized := roundf(real_seconds / QUANTUM) * QUANTUM
	return clampf(quantized, MIN_SIMULATION_DELTA, MAX_SIMULATION_DELTA)


static func action_key(frame_id: int, participant_id: String) -> String:
	return "%d:%s" % [frame_id, participant_id]
