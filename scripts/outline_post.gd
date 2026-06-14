extends ColorRect
# ============================================================================
# outline_post.gd  (GDScript)  —  toggle for the edge-detection outline
# post-process. Bound to F3, OFF by default. Stacks under the retro/CRT layers.
# ============================================================================

@export var enabled: bool = false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = enabled

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo() \
			and event.keycode == KEY_F3:
		enabled = not enabled
		visible = enabled
