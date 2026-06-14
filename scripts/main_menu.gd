extends Control
# ============================================================================
# main_menu.gd  (GDScript)
# ----------------------------------------------------------------------------
# Wires the two menu buttons. `Start` loads the 3D world scene (whose camera is
# driven by C#); `Quit` exits. Signals are connected in code here so the wiring
# is visible in one place rather than hidden in the .tscn.
# ============================================================================

@onready var _start: Button = $Center/Buttons/StartButton
@onready var _quit: Button = $Center/Buttons/QuitButton

func _ready() -> void:
	_start.pressed.connect(_on_start_pressed)
	_quit.pressed.connect(_on_quit_pressed)
	_start.grab_focus()

func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/village.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
