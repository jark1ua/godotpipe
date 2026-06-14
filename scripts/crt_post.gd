extends ColorRect
# ============================================================================
# crt_post.gd  (GDScript)  —  thin controller for the CRT post-process.
# ----------------------------------------------------------------------------
# The visual work lives entirely in shaders/crt.gdshader (GPU). This script does
# only the orchestration the shader can't: toggle the effect on/off and let you
# eyeball it with/without. Deliberately tiny — it shows that the language driving
# a shader is incidental; this would be the same handful of lines in C#.
#
# Controls (added in _ready as input actions would be overkill for a demo):
#   F1  -> toggle the CRT filter
# ============================================================================

@export var enabled: bool = true

func _ready() -> void:
	# Cover the whole viewport and never eat mouse/keyboard input meant for the
	# game underneath it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = enabled

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo() \
			and event.keycode == KEY_F1:
		enabled = not enabled
		visible = enabled
