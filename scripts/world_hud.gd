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

func _process(_delta: float) -> void:
	var p: Vector3 = _camera.global_position
	var speed: Variant = _camera.get("MoveSpeed")  # a C# [Export] field
	text = "WASD move   Q/E down/up   hold RMB look   Shift boost   Esc menu   F1 CRT\n"
	text += "camera: (%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]
	if speed != null:
		text += "      [read from C#] MoveSpeed = %.1f" % speed
