extends Label
# ============================================================================
# world_hud.gd  (GDScript)  —  C# <-> GDScript interop demo.
# ----------------------------------------------------------------------------
# This GDScript HUD lives in the SAME scene as the C# camera and reads live data
# from it every frame: the built-in `global_position`, plus `MoveSpeed`, a field
# declared with [Export] in CameraRig.cs and looked up here by name. Proof that
# the two languages share one node tree and can read each other's state.
# ============================================================================

@onready var _camera: Node3D = $"../../Camera3D"

func _ready() -> void:
	# One-shot log line so the run output proves GDScript reached the C# node.
	print("[GD] HUD reading C#-driven camera; start pos = ", _camera.global_position)

func _unhandled_input(event: InputEvent) -> void:
	# R resets persisted progress (via the C# GameManager autoload) and reloads
	# the scene, so the pickups the AI already ate reappear.
	if event is InputEventKey and event.is_pressed() and not event.is_echo() \
			and event.keycode == KEY_R:
		GameManager.call("ResetProgress")
		get_tree().reload_current_scene()

func _process(_delta: float) -> void:
	var p: Vector3 = _camera.global_position
	var speed: Variant = _camera.get("MoveSpeed")  # a C# [Export] field
	# Read persistent record count straight from the C# autoload / SQLite DB.
	var collected: Variant = GameManager.call("CollectedCount")
	text = "WASD move   Q/E down/up   hold RMB look   Shift boost   Esc menu   F1 CRT   R reset\n"
	text += "camera: (%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]
	if speed != null:
		text += "      [read from C#] MoveSpeed = %.1f" % speed
	text += "\nitems collected (SQLite): %d / 3   — AI agent seeks & uses them" % collected
