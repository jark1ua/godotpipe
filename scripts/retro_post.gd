extends ColorRect
# ============================================================================
# retro_post.gd  (GDScript)  —  toggle for the retro (pixelate/dither/posterize)
# post-process. Mirrors crt_post.gd but bound to F2 and OFF by default, so the
# CRT (F1) and this can be compared independently or stacked.
# ============================================================================

@export var enabled: bool = false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = enabled

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo() \
			and event.keycode == KEY_F2:
		enabled = not enabled
		visible = enabled
