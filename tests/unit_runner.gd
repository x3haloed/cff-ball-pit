extends SceneTree

var failures := 0


func _init() -> void:
	_expect(FrameContract.normalize_action({"throttle": 9, "steering": -9, "brake": true}) == {
		"kind": "drive",
		"throttle": 1.0,
		"steering": -1.0,
		"brake": true,
	}, "actions are clamped and normalized")
	_expect(FrameContract.normalize_action({}) == {
		"kind": "drive",
		"throttle": 0.0,
		"steering": 0.0,
		"brake": false,
	}, "missing action values use neutral defaults")
	_expect(FrameContract.normalize_action({
		"kind": "hold",
		"throttle": 1.0,
		"steering": 1.0,
		"brake": false,
	}) == {
		"kind": "hold",
		"throttle": 0.0,
		"steering": 0.0,
		"brake": true,
	}, "authored hold preserves provenance and applies brakes")
	_expect(
		FrameContract.fallback_action().kind == "timeout_brake"
		and FrameContract.fallback_action().brake == true,
		"timeout fallback preserves timeout_brake provenance",
	)
	_expect(is_equal_approx(FrameContract.simulation_delta(0.01), 0.25), "simulation delta has a lower bound")
	_expect(is_equal_approx(FrameContract.simulation_delta(0.62), 0.5), "simulation delta is quantized")
	_expect(is_equal_approx(FrameContract.simulation_delta(99.0), 2.0), "simulation delta has an upper bound")
	_expect(FrameContract.action_key(7, "aster") == "7:aster", "action keys include frame and participant")
	if failures == 0:
		print("unit: 8 assertions passed")
		quit(0)
	else:
		push_error("unit: %d assertion(s) failed" % failures)
		quit(1)


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		failures += 1
		push_error("FAIL: %s" % label)
