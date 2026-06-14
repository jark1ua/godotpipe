extends MeshInstance3D
# ============================================================================
# outline_post.gd  (GDScript)  —  toggle for the edge-detection outline.
# Attached to the fullscreen-quad MeshInstance3D child of the camera (the
# outline must be a spatial shader to read depth/normals). Toggle on F3, OFF
# by default.
# ============================================================================

@export var enabled: bool = false

func _ready() -> void:
	visible = enabled

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo() \
			and event.keycode == KEY_F3:
		enabled = not enabled
		visible = enabled
