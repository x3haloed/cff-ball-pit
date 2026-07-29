extends Node

const DEFAULT_PORT := 39090

var runtime: Node


func _ready() -> void:
	var args := parse_args(OS.get_cmdline_user_args())
	var mode := str(args.get("mode", "participant"))
	if mode == "server":
		runtime = preload("res://scripts/server_runtime.gd").new()
	else:
		runtime = preload("res://scripts/participant_runtime.gd").new()
	add_child(runtime)
	runtime.start(args)


func parse_args(values: PackedStringArray) -> Dictionary:
	var result := {}
	var index := 0
	while index < values.size():
		var item := values[index]
		if item.begins_with("--"):
			var key := item.trim_prefix("--")
			var value: Variant = true
			if index + 1 < values.size() and not values[index + 1].begins_with("--"):
				index += 1
				value = values[index]
			result[key] = value
		index += 1
	return result
